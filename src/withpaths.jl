using JSON3
using Cairo
using Colors

# Optional per-track overlay: the pretty SVG-path track outline shipped in
# `Track Maps/withPaths/*.json`. Replaces the db polyline when a matching file
# exists for the resolved track key; the moving-car marker keeps using the db
# polyline's arc-length table, so the dot may drift a few pixels off the
# visible outline (accepted tradeoff — see the "Marker source" decision).

# One parsed SVG path segment: a series of Cairo-ready draw ops.
# Ops are tuples: (:M, x, y), (:L, x, y), (:C, x1, y1, x2, y2, x, y).
struct WithPathsSegment
    name::String
    ops::Vector{NTuple{N,Float64} where N}
end

struct WithPathsMap
    name::String
    segments::Vector{WithPathsSegment}
    xmin::Float64; xmax::Float64
    ymin::Float64; ymax::Float64
end

# Substring match after stripping non-alphanumerics from both sides. Handles
# `"watkins glen"` alias ↔ `"041_watkins-glen-international.json"` filename.
_alnum(s) = filter(isletter, lowercase(String(s)))

function _withpaths_file_for(track_key::AbstractString)
    dir = joinpath(@__DIR__, "..", "Track Maps", "withPaths")
    isdir(dir) || return nothing
    files = readdir(dir)
    aliases = String[a for (a, k) in TRACK_KEY_MAP if k == track_key]
    # Also try the key itself, alphanumeric-normalized, as a final fallback.
    key_norm = _alnum(track_key)
    for alias in aliases
        a = _alnum(alias)
        isempty(a) && continue
        for f in files
            occursin(a, _alnum(f)) && return joinpath(dir, f)
        end
    end
    for f in files
        occursin(key_norm, _alnum(f)) && return joinpath(dir, f)
    end
    return nothing
end

# Parse a subset of SVG path mini-language: M, L, C (absolute only). Supports
# implicit command repetition (`C x1,y1 x2,y2 x,y  x1,y1 x2,y2 x,y` → two Cs).
# Errors clearly on lowercase (relative) commands or anything else; the current
# withPaths files only use uppercase M/L/C.
function _parse_svg_path(d::AbstractString)
    tokens = String[]
    buf = IOBuffer()
    flush_buf() = (s = String(take!(buf)); !isempty(s) && push!(tokens, s))
    for c in d
        if c in ('M','L','C','Z','z')
            flush_buf()
            push!(tokens, string(c))
        elseif c in (',', ' ', '\t', '\n')
            flush_buf()
        else
            print(buf, c)
        end
    end
    flush_buf()

    ops = Vector{NTuple{N,Float64} where N}()
    i = 1
    last_cmd = ""
    while i <= length(tokens)
        tok = tokens[i]
        if !isnothing(tryparse(Float64, tok))
            # Implicit repeat of previous command
            cmd = last_cmd
            cmd == "" && error("SVG path starts with a number: $(d)")
        else
            cmd = tok; i += 1
            last_cmd = cmd
        end
        if cmd == "M"
            x = parse(Float64, tokens[i]); y = parse(Float64, tokens[i+1]); i += 2
            push!(ops, (x, y, 0.0))       # sentinel :M via 3-tuple; distinguished below
            # Convert into typed tuple later — actually let's just use fixed forms:
        elseif cmd == "L"
            x = parse(Float64, tokens[i]); y = parse(Float64, tokens[i+1]); i += 2
            push!(ops, (x, y))
        elseif cmd == "C"
            x1 = parse(Float64, tokens[i]);   y1 = parse(Float64, tokens[i+1])
            x2 = parse(Float64, tokens[i+2]); y2 = parse(Float64, tokens[i+3])
            x  = parse(Float64, tokens[i+4]); y  = parse(Float64, tokens[i+5])
            i += 6
            push!(ops, (x1, y1, x2, y2, x, y))
        elseif cmd == "Z" || cmd == "z"
            # Close path — no operands; represent as an empty tuple
            push!(ops, ())
        else
            error("Unsupported SVG path command '$cmd' in: $(d)")
        end
    end
    return ops
end

# Segment names to keep as the racing surface outline. "SF" + any Lk (k≥1).
_is_track_segment(name::AbstractString) =
    name == "SF" || (startswith(name, "L") && !isnothing(tryparse(Int, name[2:end])))

"""
    load_withpaths_map(track_key) -> WithPathsMap or nothing

Find `Track Maps/withPaths/*.json` matching `track_key` (via TRACK_KEY_MAP
aliases → alphanumeric-normalized substring), parse the racing-surface
segments (`SF`, `L1..Lk`), and compute a bounding box for letterbox fitting.
Returns `nothing` when no file matches.
"""
function load_withpaths_map(track_key::AbstractString)
    path = _withpaths_file_for(track_key)
    path === nothing && return nothing
    raw  = JSON3.read(read(path, String))
    segs = WithPathsSegment[]
    xmin =  Inf; xmax = -Inf; ymin =  Inf; ymax = -Inf
    seen = Set{String}()   # withPaths files often duplicate SF/L* — take first only
    for entry in raw["Track_Paths"]
        name = String(entry["name"])
        _is_track_segment(name) || continue
        name in seen && continue
        push!(seen, name)
        ops = _parse_svg_path(String(entry["path_data"]))
        push!(segs, WithPathsSegment(name, ops))
        # Update bbox by scanning endpoint coords of each op.
        for op in ops
            if length(op) == 3        # M (x, y, 0.0 sentinel)
                x, y = op[1], op[2]
                xmin = min(xmin, x); xmax = max(xmax, x)
                ymin = min(ymin, y); ymax = max(ymax, y)
            elseif length(op) == 2    # L
                x, y = op[1], op[2]
                xmin = min(xmin, x); xmax = max(xmax, x)
                ymin = min(ymin, y); ymax = max(ymax, y)
            elseif length(op) == 6    # C — bbox uses control + end points
                for (x, y) in ((op[1], op[2]), (op[3], op[4]), (op[5], op[6]))
                    xmin = min(xmin, x); xmax = max(xmax, x)
                    ymin = min(ymin, y); ymax = max(ymax, y)
                end
            end
        end
    end
    isempty(segs) && return nothing
    return WithPathsMap(String(basename(path)), segs, xmin, xmax, ymin, ymax)
end

# Sample `samples_per_bezier+1` points along one cubic Bézier (start, k/n·end).
# We include the endpoint but not the start-point (the start point was already
# emitted by the previous op).
function _flatten_bezier!(xs::Vector{Float64}, ys::Vector{Float64},
                          cx::Float64, cy::Float64,
                          x1::Float64, y1::Float64, x2::Float64, y2::Float64,
                          ex::Float64, ey::Float64;
                          samples_per_bezier::Int = 24)
    @inbounds for k in 1:samples_per_bezier
        t  = k / samples_per_bezier
        mt = 1 - t
        bx = mt^3 * cx + 3*mt^2*t*x1 + 3*mt*t^2*x2 + t^3*ex
        by = mt^3 * cy + 3*mt^2*t*y1 + 3*mt*t^2*y2 + t^3*ey
        push!(xs, bx); push!(ys, by)
    end
end

# Sort track segments so SF comes first, then L1, L2, ..., Lk. Any other name
# (shouldn't happen after `_is_track_segment` filter) sorts to the end.
_seg_sort_key(n::AbstractString) = n == "SF" ? -1 : (startswith(n, "L") ? something(tryparse(Int, n[2:end]), 10^6) : 10^6)

"""
    synthesize_trackmap_from_withpaths(track_key) -> TrackMap or nothing

Build a `TrackMap` from a withPaths bezier outline when the main track_map_db
has no polyline for this track (e.g. New Hampshire ships only in withPaths).
Concatenates SF → L1 → L2 → … → Lk, flattens the beziers to a polyline, and
scales the arc-length table from image-pixel units to feet using the Track
length (miles) from the withPaths JSON. Falls back to pixel-unit arc lengths
if the length is missing — outline still renders correctly; only the marker's
absolute distance tracking would be off.

Y is flipped so the resulting `y_norm` matches the y-UP convention the rest
of the renderer expects (image coordinates are y-DOWN).
"""
function synthesize_trackmap_from_withpaths(track_key::AbstractString)
    path = _withpaths_file_for(track_key)
    path === nothing && return nothing
    raw = JSON3.read(read(path, String))
    length_mi = 0.0
    if haskey(raw, :Track) && haskey(raw[:Track], :length)
        length_mi = Float64(raw[:Track][:length])
    end
    length_ft = length_mi * 5280.0

    # First-occurrence-wins: withPaths files sometimes duplicate SF/L* entries.
    seg_ops = Dict{String, Vector}()
    for entry in raw[:Track_Paths]
        n = String(entry["name"])
        _is_track_segment(n) || continue
        haskey(seg_ops, n) && continue
        seg_ops[n] = _parse_svg_path(String(entry["path_data"]))
    end
    isempty(seg_ops) && return nothing
    ordered = sort!(collect(keys(seg_ops)); by = _seg_sort_key)

    xs = Float64[]; ys = Float64[]
    cx = cy = NaN
    for name in ordered
        for op in seg_ops[name]
            if length(op) == 3      # M
                cx, cy = op[1], op[2]
                push!(xs, cx); push!(ys, cy)
            elseif length(op) == 2  # L
                cx, cy = op[1], op[2]
                push!(xs, cx); push!(ys, cy)
            elseif length(op) == 6  # C
                _flatten_bezier!(xs, ys, cx, cy, op[1], op[2], op[3], op[4], op[5], op[6])
                cx, cy = op[5], op[6]
            end
        end
    end
    length(xs) < 2 && return nothing

    # Arc length in pixel units, scaled to feet if a real length is available.
    s_pix = _arc_length(xs, ys, nothing)
    total_pix = s_pix[end]
    if length_ft > 0 && total_pix > 0
        scale = length_ft / total_pix
        s     = s_pix .* scale
        total = length_ft
    else
        s     = s_pix
        total = total_pix
    end

    xmin, xmax = extrema(xs); ymin, ymax = extrema(ys)
    xn = (xs .- xmin) ./ (xmax - xmin)
    # Flip y: withPaths uses image-y (down), TrackMap consumers expect y-UP
    # (bake_track_background applies `1 - yn` when mapping to screen).
    yn = 1.0 .- (ys .- ymin) ./ (ymax - ymin)

    return TrackMap(String(track_key), xs, ys, s, total, xn, yn)
end

# Letterbox fit for a withPaths bbox into a `w × h` panel with 5% inset. Mirror
# of `_map_fit` for db polylines, but with y-DOWN (image coords, no flip).
function _wp_fit(wp::WithPathsMap, W::Real, H::Real; inset::Float64 = 0.05)
    aspect = (wp.xmax - wp.xmin) / (wp.ymax - wp.ymin)
    Wi = W * (1 - 2 * inset)
    Hi = H * (1 - 2 * inset)
    if aspect >= Wi / Hi
        inner_w = Float64(Wi); inner_h = Wi / aspect
    else
        inner_h = Float64(Hi); inner_w = Hi * aspect
    end
    off_x = (W - inner_w) / 2
    off_y = (H - inner_h) / 2
    return (inner_w = inner_w, inner_h = inner_h,
            off_x   = off_x,   off_y   = off_y)
end

"""
    stroke_withpaths!(cr, wp, W, H; line_width=2.5, color=colorant"#666666")

Stroke the parsed withPaths segments into the current Cairo context, letterbox-
fit into a `W × H` panel. Called by `bake_track_background` when a WithPathsMap
is available.
"""
function stroke_withpaths!(cr, wp::WithPathsMap, W::Real, H::Real;
                           line_width::Real = 2.5, color = colorant"#aaaaaa")
    fit = _wp_fit(wp, W, H)
    sx = fit.inner_w / (wp.xmax - wp.xmin)
    sy = fit.inner_h / (wp.ymax - wp.ymin)
    to_px(x, y) = (fit.off_x + (x - wp.xmin) * sx,
                   fit.off_y + (y - wp.ymin) * sy)

    set_rgb!(cr, color)
    set_line_width(cr, line_width)
    set_line_join(cr, Cairo.CAIRO_LINE_JOIN_ROUND)
    set_line_cap(cr, Cairo.CAIRO_LINE_CAP_ROUND)

    for seg in wp.segments
        for op in seg.ops
            if length(op) == 3      # M
                px, py = to_px(op[1], op[2]); move_to(cr, px, py)
            elseif length(op) == 2  # L
                px, py = to_px(op[1], op[2]); line_to(cr, px, py)
            elseif length(op) == 6  # C — cubic bezier
                x1, y1 = to_px(op[1], op[2])
                x2, y2 = to_px(op[3], op[4])
                x,  y  = to_px(op[5], op[6])
                curve_to(cr, x1, y1, x2, y2, x, y)
            end
        end
        stroke(cr)
    end
end
