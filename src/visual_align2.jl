# ─────────────────────────────────────────────────────────────────────────────
# Design (verbatim from the request that kicked this off):
#
#   mutable struct frame
#   height
#   width
#   raw::Vector(Uint)
#   index
#   Data
#   end
#
#   then set up channels that take frames, and link one processor to the next,
#   they can be their own async processes now.
#
#   We also need an updateFrame that takes an old frame from a pool and updates it
#   so we don't get stale data. this allows reuse.
#
#   Each type of process should have the same name. We need a type struct yaw end,
#   struct pitch end, struct forward end or so. We need a common interface. each
#   one should get an input struct at initialzation with their window, their
#   channels (in, out channels, daisy chained together).
#
#   Then they no longer need an ffmpeg backend, they only get a stream of frames.
#   THey initialize a vector to store their data in, when the sream ends, they
#   each kick off their correlation process, and return a result struct.
#
#   decoder ──► ch ──► [Yaw] ──► ch ──► [Pitch] ──► ch ──► [Forward] ──► pool
# ─────────────────────────────────────────────────────────────────────────────

using FFTW
using DSP
using Statistics
using Arrow
using Tables
using LinearAlgebra: mul!

# ── types ────────────────────────────────────────────────────────────────────
mutable struct Frame
    height::Int
    width::Int
    raw::Vector{UInt8}
    index::Int
    data::Matrix{Float64}
end

Frame(width::Int, height::Int) =
    Frame(height, width, Vector{UInt8}(undef, width * height), -1,
          Matrix{Float64}(undef, width, height))

abstract type Stage end
struct Yaw     <: Stage end
struct Pitch   <: Stage end
struct Forward <: Stage end

# Crop window as resolved, inclusive pixel bounds in the frame's [x, y] grid. The
# fractions → pixels conversion happens ONCE, in this constructor, when `align`
# builds each StageConfig — the worker never recomputes offsets.
struct Crop
    x0::Int
    x1::Int
    y0::Int
    y1::Int
    w::Int          # x1 - x0 + 1, stored so the worker never recomputes it
    h::Int          # y1 - y0 + 1
end
# Fraction args typed Float64 so this can't collide with the 6-Int field constructor.
function Crop(x0f::Float64, wf::Float64, y0f::Float64, hf::Float64, frame_w::Int, frame_h::Int)
    x0 = max(1, round(Int, x0f * frame_w) + 1)
    y0 = max(1, round(Int, y0f * frame_h) + 1)
    # Snap the crop extent up to a 5-smooth size: a prime dim (e.g. 61) forces
    # FFTW onto its Bluestein slow path — ~12× slower for the same pixel count.
    w = min(frame_w, nextprod([2, 3, 5], round(Int, wf * frame_w)))
    h = min(frame_h, nextprod([2, 3, 5], round(Int, hf * frame_h)))
    x0 = min(x0, frame_w - w + 1)        # shift in-bounds if the snap overran the edge
    y0 = min(y0, frame_h - h + 1)
    return Crop(x0, x0 + w - 1, y0, y0 + h - 1, w, h)
end

# A worker's init input: its (resolved) crop, its channels, its telemetry
# reference (preloaded by `align` from one arrow read), and fps. `out_ch ===
# nothing` ⇒ last in the chain ⇒ recycle frames back to `pool`.
struct StageConfig
    crop::Crop
    window::Matrix{Float64}       # Hann over the crop, built once by `align`
    in_ch::Channel{Frame}
    out_ch::Union{Channel{Frame}, Nothing}
    pool::Channel{Frame}
    ref_t::Vector{Float64}        # telemetry timestamps for this stage's channel
    ref_x::Vector{Float64}        # the channel itself (gyro yaw/pitch, or GPS speed)
    fps::Float64
    start_s::Float64              # decode start, so series times are absolute video time
    capacity::Int                 # expected frame count; the worker preallocates series to it
end

# State = per-stage MUTABLE scratch only (buffers, plans, series). Everything
# immutable (crop, window, fps, refs) lives in StageConfig and is read from there.
abstract type State end

# The one place crop math lives: window `config`'s crop out of `frame` into
# `state.cur` (complex, DC-removed). Shared by every stage's consume!.
function crop!(state::State, config::StageConfig, frame::Frame)
    crop = config.crop; cur = state.cur; win = config.window; data = frame.data
    x0 = crop.x0; cw = crop.w; ch = crop.h
    total = 0.0
    # copy + DC sum in one contiguous pass. Direct (non-view) 2D indexing strength-
    # reduces to a stride-1 column walk — unlike copyto!(@view …), which falls to
    # generic SubArray iteration (per-element sub2ind, no memcpy).
    @fastmath @inbounds for jy in 1:ch
        col = crop.y0 + jy - 1
        @simd for jx in 1:cw
            v = data[x0 - 1 + jx, col]
            cur[jx, jy] = v
            total += v
        end
    end
    mean = total / (cw * ch)
    @fastmath @inbounds @simd for i in eachindex(cur)      # demean before window, vectorized
        cur[i] = (cur[i] - mean) * win[i]
    end
    return cur
end

# Append one measurement to the preallocated series.
function record!(state::State, config::StageConfig, value::Float64, frame::Frame)
    state.n += 1
    state.series[state.n] = value
    state.times[state.n] = config.start_s + frame.index / config.fps
    return nothing
end

# ── interface (stubs — fill once inputs are settled) ─────────────────────────

# The decoder reads the next frame's bytes straight into `frame.raw`; this stamps
# the index and SIMD-widens raw (UInt8) → data (Float64). No copy, no temp buffer.
function update_frame!(frame::Frame, index::Int)
    frame.index = index
    raw = frame.raw; data = frame.data
    @inbounds @simd for i in eachindex(data)      
        data[i] = Float64(raw[i])
    end
    return frame
end


# One stage as an async task: allocate its own state, fold every frame, pass it
# on (or recycle if last), then correlate when the input channel closes.
function run_worker(stage::Stage, state::State, config::StageConfig)
    for frame in config.in_ch
        consume!(stage, state, config, frame)
        config.out_ch === nothing ? put!(config.pool, frame) : put!(config.out_ch, frame)
    end
    config.out_ch === nothing || close(config.out_ch)
    return correlate(stage, state, config)
end

# Decoder task: owns ffmpeg, streams full gray frames into `out_ch`. Pulls a
# recycled Frame from `pool`, reads the next frame straight into its `raw`, widens
# to `data`, and forwards it. Closes `out_ch` at end-of-stream to drain the chain.
function run_decoder(out_ch::Channel{Frame}, pool::Channel{Frame}, video_path::AbstractString,
                     vf::String, start_s::Real, dur_s::Real, fps::Real, backend::FfmpegBackend)
    targs = isfinite(dur_s) ? ["-t", string(dur_s)] : String[]
    with_backend(backend) do exe
        io = open(`$exe -hide_banner -loglevel error $(backend.hwaccel_args) -ss $start_s $targs -i $video_path -vf $vf -r $fps -f rawvideo pipe:1`, "r")
        index = 0
        while true
            frame = take!(pool)
            try
                read!(io, frame.raw)
            catch e
                e isa EOFError && (put!(pool, frame); break)
                rethrow()
            end
            update_frame!(frame, index)
            put!(out_ch, frame)
            index += 1
        end
        close(io)
    end
    close(out_ch)
end

# Load a telemetry channel (Time + `channel`), dropping pre-green / NaN samples.
function _load_channel(arrow_path::AbstractString, channel::Symbol)
    tbl = Arrow.Table(arrow_path)
    t = Float64.(collect(Tables.getcolumn(tbl, :Time)))
    x = Float64.(collect(Tables.getcolumn(tbl, channel)))
    keep = isfinite.(t) .& isfinite.(x)
    return t[keep], x[keep]
end

# Build the pool + daisy-chained channels (decoder → Yaw → Pitch → Forward → pool),
# spawn the decoder and one worker per stage, and gather each stage's AlignEstimate.
# States are built here (serially) before spawning — FFTW planning isn't thread-safe.
function align(video_path::AbstractString, arrow_path::AbstractString;
               start_s::Real = 300.0, dur_s::Real = 900.0, fps::Real = 30.0,
               frame_w::Int = 320, frame_h::Int = 180,
               rotation_crop = (0.25, 0.50, 0.22, 0.28),
               forward_crop  = (0.18, 0.64, 0.30, 0.34),
               backend::FfmpegBackend = detect_backend())
    yaw_t,   yaw_x   = _load_channel(arrow_path, :ChassisRotVelYawIDR)
    pitch_t, pitch_x = _load_channel(arrow_path, :ChassisRotVelPitchIDR)
    speed_t, speed_x = _load_channel(arrow_path, :VectorGPS_Speed)

    capacity = ceil(Int, Float64(dur_s) * fps) + 16
    rot = Crop(Float64.(rotation_crop)..., frame_w, frame_h)
    fwd = Crop(Float64.(forward_crop)...,  frame_w, frame_h)
    rot_window = _hann(rot.w, rot.h)
    fwd_window = _hann(fwd.w, fwd.h)

    pool = Channel{Frame}(10)
    for _ in 1:10
        put!(pool, Frame(frame_w, frame_h))
    end
    ch_yaw   = Channel{Frame}(4)
    ch_pitch = Channel{Frame}(4)
    ch_fwd   = Channel{Frame}(4)

    cfg_yaw   = StageConfig(rot, rot_window, ch_yaw,   ch_pitch, pool, yaw_t,   yaw_x,   Float64(fps), Float64(start_s), capacity)
    cfg_pitch = StageConfig(rot, rot_window, ch_pitch, ch_fwd,   pool, pitch_t, pitch_x, Float64(fps), Float64(start_s), capacity)
    cfg_fwd   = StageConfig(fwd, fwd_window, ch_fwd,   nothing,  pool, speed_t, speed_x, Float64(fps), Float64(start_s), capacity)

    # build states serially (FFTW planning), then run each stage on its own task
    state_yaw   = make_state(Yaw(),     cfg_yaw)
    state_pitch = make_state(Pitch(),   cfg_pitch)
    state_fwd   = make_state(Forward(), cfg_fwd)

    vf = "scale=$(frame_w):$(frame_h),format=gray"
    decoder = Threads.@spawn run_decoder(ch_yaw, pool, video_path, vf, start_s, dur_s, fps, backend)
    w_yaw   = Threads.@spawn run_worker(Yaw(),     state_yaw,   cfg_yaw)
    w_pitch = Threads.@spawn run_worker(Pitch(),   state_pitch, cfg_pitch)
    w_fwd   = Threads.@spawn run_worker(Forward(), state_fwd,   cfg_fwd)

    wait(decoder)
    return (yaw = fetch(w_yaw), pitch = fetch(w_pitch), forward = fetch(w_fwd))
end

# ─────────────────────────────────────────────────────────────────────────────
# Yaw / Pitch — camera rotation by phase correlation on a far-field crop. Both
# share the machinery; Yaw keeps the horizontal shift, Pitch the vertical.
# ─────────────────────────────────────────────────────────────────────────────

# Separable Hann window, cw × ch.
function _hann(cw::Int, ch::Int)
    wx = [0.5 - 0.5cos(2π * (i - 1) / max(cw - 1, 1)) for i in 1:cw]
    wy = [0.5 - 0.5cos(2π * (i - 1) / max(ch - 1, 1)) for i in 1:ch]
    return wx * wy'
end

mutable struct RotationState{P, IP} <: State
    cur::Matrix{ComplexF64}       # windowed crop (complex), filled by crop!
    cur_freq::Matrix{ComplexF64}
    prev_freq::Matrix{ComplexF64}
    cross::Matrix{ComplexF64}
    corr::Matrix{ComplexF64}
    plan::P
    iplan::IP
    have_prev::Bool
    series::Vector{Float64}
    times::Vector{Float64}
    n::Int
end

function make_state(::Union{Yaw, Pitch}, config::StageConfig)
    cw = config.crop.w; ch = config.crop.h
    cur = Matrix{ComplexF64}(undef, cw, ch); cross = similar(cur)
    return RotationState(cur, similar(cur), similar(cur), cross, similar(cur),
        plan_fft(cur), plan_bfft(cross), false,
        Vector{Float64}(undef, config.capacity), Vector{Float64}(undef, config.capacity), 0)
end

# (dx, dy) sub-pixel shift between this crop and the previous; (NaN, NaN) priming.
function shift!(state::RotationState, config::StageConfig, frame::Frame)
    crop!(state, config, frame)
    mul!(state.cur_freq, state.plan, state.cur)
    if !state.have_prev
        state.prev_freq, state.cur_freq = state.cur_freq, state.prev_freq
        state.have_prev = true
        return (NaN, NaN)
    end
    cross = state.cross; prev = state.prev_freq; cur = state.cur_freq
    @fastmath @inbounds @simd for i in eachindex(cross)   # cross-power + phase-normalize, one pass
        z = prev[i] * conj(cur[i])
        cross[i] = z / (sqrt(abs2(z)) + eps())
    end
    mul!(state.corr, state.iplan, state.cross)
    state.prev_freq, state.cur_freq = state.cur_freq, state.prev_freq   # cur becomes next prev
    return peak_shift(state.corr)
end

# Sub-pixel peak of a phase-correlation surface → (dx, dy), wraparound handled.
function peak_shift(corr)
    nx, ny = size(corr); bx = 1; by = 1; best = -Inf
    @inbounds for y in 1:ny, x in 1:nx
        v = real(corr[x, y])
        if v > best; best = v; bx = x; by = y; end
    end
    peak = real(corr[bx, by])
    dx = (bx - 1) + _parabolic_peak(real(corr[mod1(bx - 1, nx), by]), peak, real(corr[mod1(bx + 1, nx), by]))
    dy = (by - 1) + _parabolic_peak(real(corr[bx, mod1(by - 1, ny)]), peak, real(corr[bx, mod1(by + 1, ny)]))
    dx = dx >= nx / 2 ? dx - nx : dx
    dy = dy >= ny / 2 ? dy - ny : dy
    return (dx, dy)
end

# ─────────────────────────────────────────────────────────────────────────────
# Forward — vehicle speed by Fourier-Mellin: FFT magnitude → log-polar →
# phase-correlate consecutive frames; the radial (log-scale) shift is the scene's
# zoom rate ∝ speed. Translation-invariant, so cornering doesn't contaminate it.
# ─────────────────────────────────────────────────────────────────────────────

# Signed, sub-bin radial (log-scale) shift of a phase-correlation surface.
function radial_peak(corr)
    n_angle, n_radius = size(corr)
    best = -Inf; pa = 1; pr = 1
    @inbounds for b in 1:n_radius, a in 1:n_angle
        v = real(corr[a, b])
        if v > best; best = v; pa = a; pr = b; end
    end
    left  = real(corr[pa, mod1(pr - 1, n_radius)])
    middle = real(corr[pa, pr])
    right = real(corr[pa, mod1(pr + 1, n_radius)])
    curvature = left - 2middle + right
    sub_bin = abs(curvature) < eps() ? 0.0 : clamp(0.5 * (left - right) / curvature, -1.0, 1.0)
    shift = (pr - 1) + sub_bin
    return shift > n_radius / 2 ? shift - n_radius : shift
end

mutable struct ForwardState{P, LP, LIP} <: State
    cur::Matrix{ComplexF64}          # windowed crop (complex), filled by crop!
    cur_freq::Matrix{ComplexF64}
    mag::Matrix{Float64}             # centred, high-passed magnitude
    highpass::Matrix{Float64}        # FM tables (immutable, crop-specific)
    shx::Vector{Int}
    shy::Vector{Int}
    sample_x::Matrix{Float64}
    sample_y::Matrix{Float64}
    lp::Matrix{ComplexF64}           # this frame's log-polar magnitude (complex, DC-removed)
    lp_freq::Matrix{ComplexF64}      # its FFT
    lp_prev_freq::Matrix{ComplexF64} # last frame's FFT, carried over — no recompute
    lp_cross::Matrix{ComplexF64}
    lp_corr::Matrix{ComplexF64}
    img_plan::P
    lp_plan::LP
    lp_iplan::LIP
    n_angle::Int
    n_radius::Int
    have_prev::Bool
    series::Vector{Float64}
    times::Vector{Float64}
    n::Int
end

function make_state(::Forward, config::StageConfig; n_angle::Int = 128, n_radius::Int = 64)
    cw = config.crop.w; ch = config.crop.h
    # FM tables for this crop, built once:
    highpass = Matrix{Float64}(undef, cw, ch)                   # Reddy–Chatterji high-pass
    @inbounds for j in 1:ch, i in 1:cw
        fx = (i - (cw + 1) / 2) / cw; fy = (j - (ch + 1) / 2) / ch
        cosine = cos(π * fx) * cos(π * fy)
        highpass[i, j] = (1 - cosine) * (2 - cosine)
    end
    #TODO: you can store .5cw, not sure the compiler would do that or not
    shx = [((i - 1 + cw ÷ 2) % cw) + 1 for i in 1:cw]           # per-axis fftshift maps
    shy = [((j - 1 + ch ÷ 2) % ch) + 1 for j in 1:ch]
    cx = (cw + 1) / 2; cy = (ch + 1) / 2                        # log-polar grid on DC, clamped
    log_radii = range(log(3.0), log(min(cw, ch) / 2 - 1.0); length = n_radius)
    sample_x = Matrix{Float64}(undef, n_angle, n_radius); sample_y = similar(sample_x)
    @inbounds for a in 1:n_angle
        angle = π * (a - 1) / n_angle; cos_a = cos(angle); sin_a = sin(angle)
        for b in 1:n_radius
            radius = exp(log_radii[b])
            sample_x[a, b] = clamp(cx + radius * cos_a, 1.0, cw - 1e-3)
            sample_y[a, b] = clamp(cy + radius * sin_a, 1.0, ch - 1e-3)
        end
    end
    cur = Matrix{ComplexF64}(undef, cw, ch)
    lp = Matrix{ComplexF64}(undef, n_angle, n_radius); lp_cross = similar(lp)
    return ForwardState(
        cur, similar(cur), Matrix{Float64}(undef, cw, ch), highpass, shx, shy, sample_x, sample_y,
        lp, similar(lp), similar(lp), lp_cross, similar(lp),
        plan_fft(cur), plan_fft(lp), plan_bfft(lp_cross), n_angle, n_radius, false,
        Vector{Float64}(undef, config.capacity), Vector{Float64}(undef, config.capacity), 0)
end

# The FM pass, as steps: window the crop → image FFT → centred magnitude →
# log-polar → phase-correlate vs the previous → radial (zoom) shift. NaN priming.
function forward_zoom!(state::ForwardState, config::StageConfig, frame::Frame)
    crop!(state, config, frame)
    mul!(state.cur_freq, state.img_plan, state.cur)
    magnitude!(state)
    logpolar!(state)                                # → state.lp (complex)
    mul!(state.lp_freq, state.lp_plan, state.lp)    # the only log-polar FFT this frame
    @inbounds state.lp_freq[1, 1] = 0               # DC removal ≡ demean pre-FFT (no window → exact)
    if !state.have_prev
        state.lp_prev_freq, state.lp_freq = state.lp_freq, state.lp_prev_freq
        state.have_prev = true
        return NaN
    end
    zoom = lp_radius!(state)
    state.lp_prev_freq, state.lp_freq = state.lp_freq, state.lp_prev_freq   # carry forward
    return zoom
end

# cur_freq → centred, high-passed magnitude. The x-fftshift is a block swap, so
# each column is two contiguous runs — kept separate so the abs·highpass goes wide
# (sqrt∘abs2 vectorizes; complex `abs`/hypot does not). Locals hoisted off `state`.
function magnitude!(state::ForwardState)
    cur_freq = state.cur_freq; mag = state.mag; hp = state.highpass; shy = state.shy
    cw, ch = size(mag); half = cw ÷ 2; rest = cw - half
    @fastmath @inbounds for j in 1:ch
        col = shy[j]                                   # column fftshift: one lookup per column
        @simd for i in 1:rest
            mag[i, j] = sqrt(abs2(cur_freq[half + i, col])) * hp[i, j]
        end
        @simd for i in 1:half
            mag[rest + i, j] = sqrt(abs2(cur_freq[i, col])) * hp[rest + i, j]
        end
    end
    return mag
end

# mag → state.lp: bilinear log-polar sample (separable muladd lerp → FMAs),
# written complex (imag 0). DC is NOT removed here — it's killed by zeroing the
# DC bin after the FFT (forward_zoom!), which is exactly equivalent (no window on
# the log-polar, so no leakage) and saves the sum + demean passes over `lp`.
function logpolar!(state::ForwardState)
    mag = state.mag; out = state.lp; sx = state.sample_x; sy = state.sample_y
    @inbounds for b in 1:state.n_radius, a in 1:state.n_angle
        x = sx[a, b]; y = sy[a, b]
        xi = floor(Int, x); yi = floor(Int, y); fx = x - xi; fy = y - yi
        m00 = mag[xi, yi];     m10 = mag[xi + 1, yi]
        m01 = mag[xi, yi + 1]; m11 = mag[xi + 1, yi + 1]
        top = muladd(fx, m10 - m00, m00)               # lerp in x at yi
        bot = muladd(fx, m11 - m01, m01)               # lerp in x at yi+1
        out[a, b] = muladd(fy, bot - top, top)         # lerp in y
    end
    return out
end

# Phase-correlate the carried previous log-polar FFT vs this frame's → radial shift.
# Cross-power + phase-normalize fused into ONE pass — no broadcast materialize, no
# second sweep of lp_cross (sqrt∘abs2, not hypot).
function lp_radius!(state::ForwardState)
    cross = state.lp_cross; prev = state.lp_prev_freq; cur = state.lp_freq
    @fastmath @inbounds @simd for i in eachindex(cross)
        z = prev[i] * conj(cur[i])
        cross[i] = z / (sqrt(abs2(z)) + eps())
    end
    mul!(state.lp_corr, state.lp_iplan, cross)
    return radial_peak(state.lp_corr)
end

# ── consume! — fold one frame into a stage's series (all stages, together) ────
function consume!(::Yaw, state::RotationState, config::StageConfig, frame::Frame)
    dx, _ = shift!(state, config, frame)
    isnan(dx) || record!(state, config, dx, frame)
    return nothing
end

function consume!(::Pitch, state::RotationState, config::StageConfig, frame::Frame)
    _, dy = shift!(state, config, frame)
    isnan(dy) || record!(state, config, dy, frame)
    return nothing
end

function consume!(::Forward, state::ForwardState, config::StageConfig, frame::Frame)
    zoom = forward_zoom!(state, config, frame)
    isnan(zoom) || record!(state, config, zoom, frame)
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Correlation — at end-of-stream, slide each stage's series against its telemetry
# reference and return the offset (telemetry_time = video_time + offset) as an
# AlignEstimate. Rotation band-passes (sign-invariant peak); Forward smooths
# (signed peak — the speed proxy and speed share sign).
# ─────────────────────────────────────────────────────────────────────────────

# Resample (t, x) onto a uniform fs-Hz grid by linear interpolation, returning
# (grid_start, values). Both t and the grid are monotonic, so one forward sweep
# with a sample pointer suffices — no per-query search (the two-pointer trick from
# ERDP_pipeline's growKernel). The grid is uniform, so the query time is implicit
# (t0 + (i-1)/fs) and never materialized.
function _resample(t, x, fs::Float64)
    t0 = first(t); t1 = last(t); n = length(t)
    ngrid = floor(Int, (t1 - t0) * fs) + 1
    out = Vector{Float64}(undef, ngrid)
    inv_fs = 1.0 / fs                                # hoist the divide out of the loop
    k = 1                                            # bracket: t[k] ≤ q ≤ t[k+1]
    @inbounds for i in 1:ngrid
        q = muladd(i - 1, inv_fs, t0)                # t0 + (i-1)/fs, as an FMA
        while k < n - 1 && t[k + 1] < q
            k += 1
        end
        tk = t[k]; tk1 = t[k + 1]
        w = tk1 == tk ? 0.0 : (q - tk) / (tk1 - tk)
        out[i] = muladd(x[k + 1] - x[k], w, x[k])    # lerp as an FMA
    end
    return t0, out
end

_znorm(x) = (m = mean(x); s = std(x); s == 0 ? x .- m : (x .- m) ./ s)

# Centred moving average — denoise without high-passing (keeps the slow envelope).
function _smooth(x::Vector{Float64}, n::Int)
    n <= 1 && return copy(x)
    cs = pushfirst!(cumsum(x), 0.0); m = length(x); out = Vector{Float64}(undef, m); half = n ÷ 2
    @inbounds for i in 1:m
        lo = max(1, i - half); hi = min(m, i + half)
        out[i] = (cs[hi + 1] - cs[lo]) / (hi - lo + 1)
    end
    return out
end

# Zero-phase Butterworth band-pass.
function _bandpass(x::Vector{Float64}, fs::Float64; lo = 0.1, hi = 8.0, order = 4)
    nyquist = fs / 2; hi = min(hi, 0.95 * nyquist); lo = max(lo, 1e-3)
    return filtfilt(digitalfilter(Bandpass(lo, hi), Butterworth(order); fs = fs), x)
end

# Normalized sliding cross-correlation: out[L+1] = Pearson(template, ref[L+1:L+m]).
# prefix/prefix2 are zero-padded prefix sums of ref → branch-free window stats.
# Serial on purpose: the three stages already run concurrently as pipeline tasks,
# so threading here would just oversubscribe the same pool.
function _ncc!(out::Vector{Float64}, template::Vector{Float64}, ref::Vector{Float64},
               prefix::Vector{Float64}, prefix2::Vector{Float64}, m::Int, Lmax::Int)
    @inbounds for L in 0:Lmax
        acc = 0.0
        @simd for i in 1:m
            acc += template[i] * ref[L + i]
        end
        μ = (prefix[L + m + 1] - prefix[L + 1]) / m
        σ2 = (prefix2[L + m + 1] - prefix2[L + 1]) / m - μ * μ
        out[L + 1] = σ2 > 1e-12 ? acc / (sqrt(σ2) * m) : 0.0
    end
    return out
end

# Slide the (conditioned, z-normed) series against the conditioned reference and
# return (offset_s, confidence). `condition` band-passes or smooths each signal;
# `signed` keeps the max peak (speed) vs the |peak| (rotation, sign/scale-free).
function _crosscorr(state::State, ref_t, ref_x, fs::Float64, condition, signed::Bool)
    vtimes = view(state.times, 1:state.n)
    _, template = _resample(vtimes, view(state.series, 1:state.n), fs)
    ref_t0, ref = _resample(ref_t, ref_x, fs)
    template = _znorm(condition(template, fs))
    ref = condition(ref, fs)
    m, n = length(template), length(ref)
    m < n || error("template ($m) longer than reference ($n) — shorten the window")
    prefix  = pushfirst!(cumsum(ref), 0.0)
    prefix2 = pushfirst!(cumsum(ref .^ 2), 0.0)
    Lmax = n - m
    ncc = Vector{Float64}(undef, Lmax + 1)
    _ncc!(ncc, template, ref, prefix, prefix2, m, Lmax)
    score = signed ? ncc : abs.(ncc)
    k = argmax(score)
    sub = 1 < k < length(score) ? _parabolic_peak(score[k - 1], score[k], score[k + 1]) : 0.0
    offset = (ref_t0 + (k - 1 + sub) / fs) - first(vtimes)
    return offset, score[k]
end

# Rotation (Yaw/Pitch): band-pass, sign-invariant peak.
function correlate(stage::Union{Yaw, Pitch}, state::RotationState, config::StageConfig)
    offset, conf = _crosscorr(state, config.ref_t, config.ref_x, 30.0,
                              (x, fs) -> _bandpass(x, fs), false)
    return AlignEstimate(offset, conf, stage isa Yaw ? :yaw : :pitch, (n_frames = state.n,))
end

# Forward: smooth, signed peak.
function correlate(::Forward, state::ForwardState, config::StageConfig)
    offset, conf = _crosscorr(state, config.ref_t, config.ref_x, 5.0,
                              (x, fs) -> _smooth(x, max(1, round(Int, 3.0 * fs))), true)
    return AlignEstimate(offset, conf, :forward, (n_frames = state.n,))
end
