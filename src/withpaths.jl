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
