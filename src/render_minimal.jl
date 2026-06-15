# Minimal 3-channel overlay template: THROTTLE / BRAKE / STEERING.
#
# Pairs with render.jl. Every helper there (OverlayLayout, ChannelTrace,
# _mk, CH_COLORS, bake_static_surface, bake_track_background,
# draw_dynamic!, blit_surface!, argbuffer) is already channel-count
# agnostic — it iterates whichever channels you hand it. So this file
# only needs to supply a different `build_channels`.
#
# Select via `template = :minimal` on generate_lap_video / render_lap /
# process. The full 6-channel layout remains the default.

const CH_ORDER_MINIMAL = (:THROTTLE, :BRAKE, :STEERING)

"""
    build_channels_minimal(tel, lap_rows, ranges) -> Vector{ChannelTrace}

Throttle/brake/steering only, in that order. Same axis ranges and
formatters as the corresponding rows in `build_channels`.
"""
function build_channels_minimal(tel, lap_rows::UnitRange{Int}, ranges)
    throttle = Float64.(view(tel.throttle, lap_rows))
    brake    = Float64.(view(tel.brake,    lap_rows))
    steering = Float64.(view(tel.steering, lap_rows))

    fmt_int(v)   = (@sprintf("%d", round(Int, v)))
    fmt_steer(v) = (@sprintf("%+.1f", v))

    return ChannelTrace[
        _mk(:THROTTLE, throttle, ranges.throttle..., "%",   fmt_int),
        _mk(:BRAKE,    brake,    ranges.brake...,    "PSI", fmt_int),
        _mk(:STEERING, steering, ranges.steering...,  "°",  fmt_steer),
    ]
end

# ── Car-number icon overlay ───────────────────────────────────────────────
#
# The minimal template replaces the moving yellow dot on the mini-map with
# the car's number graphic from `NCS Car Number Graphics/<car>/`. The source
# files are JPGs with a white photo background, so on first use we shell out
# to ffmpeg's `colorkey` filter to bake a transparent PNG alongside the JPG
# and cache it (`_icon_keyed.png`). Subsequent runs just load that PNG.

const _CAR_ICON_PNG_NAME = "_icon_alpha.png"
const CAR_ICON_SIZE_PX   = 36   # square draw size on the mini-map
const _CAR_ICON_WORK_PX  = 128  # working resolution we bake to PNG
const _CAR_ICON_WHITE    = 220  # R/G/B >= this counts as "background white"

"""
    _car_icon_jpg_path(car_number) -> String or nothing

Find the first `.jpg` inside `NCS Car Number Graphics/<car_number>/`. Returns
`nothing` if the folder or any JPG is missing.
"""
function _car_icon_jpg_path(car_number::Integer)
    folder = joinpath(@__DIR__, "..", "NCS Car Number Graphics", string(car_number))
    isdir(folder) || return nothing
    for f in readdir(folder)
        lf = lowercase(f)
        (endswith(lf, ".jpg") || endswith(lf, ".jpeg")) || continue
        startswith(f, "_") && continue   # skip our cached output
        return joinpath(folder, f)
    end
    return nothing
end

"""
    _ensure_car_icon_png(backend, car_number) -> String or nothing

Make sure a transparent-background PNG of the car icon exists next to the
source JPG, regenerating it if the source is newer. Returns the PNG path, or
`nothing` if no source JPG was found.
"""
function _ensure_car_icon_png(backend, car_number::Integer)
    jpg = _car_icon_jpg_path(car_number)
    jpg === nothing && return nothing
    png = joinpath(dirname(jpg), _CAR_ICON_PNG_NAME)
    if !isfile(png) || mtime(png) < mtime(jpg)
        try
            _bake_car_icon_png(backend, jpg, png)
        catch err
            @warn "Failed to build car-icon PNG for #$car_number" exception=err
            return nothing
        end
    end
    return png
end

"""
    _bake_car_icon_png(backend, jpg, png; work_size, white_thresh)

Decode the source JPG via ffmpeg, flood-fill the outer white background
starting from the four image corners, and write an ARGB PNG. Pixels inside
a closed yellow outline (the digit infill) aren't reachable from the
corners, so they stay opaque — that's what keeps the number readable.
"""
function _bake_car_icon_png(backend, jpg::AbstractString, png::AbstractString;
                            work_size::Int = _CAR_ICON_WORK_PX,
                            white_thresh::Int = _CAR_ICON_WHITE)
    vf = "scale=$(work_size):$(work_size):flags=lanczos"
    raw = with_backend(backend) do exe
        read(`$exe -hide_banner -loglevel error -i $jpg -vf $vf -f rawvideo -pix_fmt rgba -`)
    end
    expected = work_size * work_size * 4
    length(raw) == expected || error(
        "ffmpeg produced $(length(raw)) bytes for icon, expected $expected")

    npix = work_size * work_size
    transparent = falses(npix)
    @inline iswhite(i) = (raw[4(i - 1) + 1] >= white_thresh &&
                          raw[4(i - 1) + 2] >= white_thresh &&
                          raw[4(i - 1) + 3] >= white_thresh)

    stack = Int[]
    push!(stack, 1)
    push!(stack, work_size)
    push!(stack, work_size * (work_size - 1) + 1)
    push!(stack, work_size * work_size)
    while !isempty(stack)
        i = pop!(stack)
        transparent[i] && continue
        iswhite(i) || continue
        transparent[i] = true
        col = ((i - 1) % work_size) + 1
        row = ((i - 1) ÷ work_size) + 1
        col > 1         && push!(stack, i - 1)
        col < work_size && push!(stack, i + 1)
        row > 1         && push!(stack, i - work_size)
        row < work_size && push!(stack, i + work_size)
    end

    surf = CairoARGBSurface(work_size, work_size)
    abuf = argbuffer(surf)
    @inbounds for i in 1:npix
        if transparent[i]
            abuf[i] = UInt32(0)
        else
            r = UInt32(raw[4(i - 1) + 1])
            g = UInt32(raw[4(i - 1) + 2])
            b = UInt32(raw[4(i - 1) + 3])
            abuf[i] = (UInt32(255) << 24) | (r << 16) | (g << 8) | b
        end
    end
    Cairo.flush(surf)
    Cairo.write_to_png(surf, png)
    return png
end

"""
    load_car_icon_surface(backend, car_number) -> CairoSurface or nothing

Return a Cairo surface of the car-number icon with the white background
keyed out, or `nothing` if the graphic isn't available.
"""
function load_car_icon_surface(backend, car_number::Integer)
    png = _ensure_car_icon_png(backend, car_number)
    png === nothing && return nothing
    try
        return Cairo.read_from_png(png)
    catch err
        @warn "Failed to load car-icon PNG for #$car_number" png exception=err
        return nothing
    end
end

"""
    draw_car_icon_on_map!(cr, layout, tm, cur_dist, icon; size_px = CAR_ICON_SIZE_PX)

Draw the car-number `icon` centred on the current track position. Overlays
the yellow dot produced by `draw_dynamic!` so callers can keep the existing
fallback when no icon is available.
"""
function draw_car_icon_on_map!(cr, layout::OverlayLayout, tm,
                               cur_dist::Float64, icon::CairoSurface;
                               size_px::Real = CAR_ICON_SIZE_PX)
    margin = 10
    tw = layout.map_w - 2 * margin
    th = layout.top_h - 2 * margin
    inset = 0.05
    xn, yn = dist_to_map_norm(cur_dist, tm)
    px = layout.vid_w + margin + (inset + xn * (1 - 2 * inset)) * tw
    py = margin + (1 - (inset + yn * (1 - 2 * inset))) * th

    iw = Float64(width(icon))
    ih = Float64(height(icon))
    s  = Float64(size_px) / max(iw, ih)

    save(cr)
    translate(cr, px - s * iw / 2, py - s * ih / 2)
    scale(cr, s, s)
    set_source_surface(cr, icon, 0, 0)
    paint(cr)
    restore(cr)
end
