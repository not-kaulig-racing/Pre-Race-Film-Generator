using FFTW
using DSP
using Statistics
using Arrow
using Tables

# ─────────────────────────────────────────────────────────────────────────────
# Visual ↔ telemetry alignment.
#
# Companion to the audio↔RPM aligner in `alignment.jl`, for clips with no usable
# engine audio (e.g. radio-only in-car feeds). It recovers the camera's yaw/pitch
# RATE from the video — phase correlation on consecutive frames, restricted to a
# far-field "horizon band" where image motion is ~pure rotation (depth-independent,
# parallax-free) — and cross-correlates that against the chassis rate gyros
# (`ChassisRotVelYawIDR` / `ChassisRotVelPitchIDR`).
#
# We only need a signal PROPORTIONAL to the gyro (sign + scale free) because we
# sync by cross-correlation: no camera intrinsics, no undistortion, no rad/s.
#
# Validated on Watkins Glen car 16: visual joint offset −594.5s vs the audio↔RPM
# offset −594.0s — two physically independent estimators agreeing to 0.5s.
# ─────────────────────────────────────────────────────────────────────────────

# Camera-dependent crop (fractions of frame) isolating distant content: grandstands,
# horizon, vanishing point. EXCLUDE near foreground (hood/road) and static cockpit
# (A-pillars, banners) — those pin the correlation to zero or to translation flow.
const VISUAL_CROP_DEFAULT = (x0 = 0.25, w = 0.50, y0 = 0.22, h = 0.28)
#TODO: the other ones should have a similar const if this is how we want to do that.....


#region IDK
# ── frame preprocessing ─────────────────────────────────────────────────────
# Separable Hann window, laid out [x, y] to match the raster frame buffer so the
# load below stays a flat contiguous pass. Built once, reused per frame.
function _hann_window(outw::Int, outh::Int)
    wx = [0.5 - 0.5cos(2π * (i - 1) / max(outw - 1, 1)) for i in 1:outw]
    wy = [0.5 - 0.5cos(2π * (i - 1) / max(outh - 1, 1)) for i in 1:outh]
    return wx * wy'                                   # [x, y]
end

# Convert one raster gray frame (`bytes` at `offset`) to Float64 in `dest`,
# DC-remove, and apply `window` — two flat contiguous @simd passes (the UInt8→
# Float64 widening and the windowing both vectorize; no transpose). `dest` and
# `window` share the frame's raster [x, y] layout.
function _load_frame!(dest::Matrix{Float64}, bytes::Vector{UInt8}, offset::Int,
                      window::Matrix{Float64})
    n = length(dest)
    total = 0.0
    @inbounds @simd for i in 1:n
        value = Float64(bytes[offset + i])
        dest[i] = value
        total += value
    end
    mean_value = total / n
    @inbounds @simd for i in 1:n
        dest[i] = (dest[i] - mean_value) * window[i]
    end
    return dest
end

"""
    _vs_phase_shift(a, b) -> (dx, dy, peak)

Sub-pixel global translation mapping preprocessed frame `a` onto `b` via the
normalized cross-power spectrum. `dx` = horizontal shift (yaw proxy), `dy` =
vertical (pitch proxy). `peak` is a peak-to-mean confidence.
"""
function _vs_phase_shift(a::AbstractMatrix, b::AbstractMatrix)
    #TODO, no abstract matrix
    A = fft(a)
    B = fft(b)

    #TODO: explain this with a quick comment pls
    R = A .* conj(B); R ./= abs.(R) .+ eps()
    r = real(ifft(R))
    py, px = Tuple(argmax(r))       # why casting??
    
    h, w = size(r)      # Height, width??
    dy = (py - 1) + _parabolic_peak(r[mod1(py - 1, h), px], r[py, px], r[mod1(py + 1, h), px])
    dx = (px - 1) + _parabolic_peak(r[py, mod1(px - 1, w)], r[py, px], r[py, mod1(px + 1, w)])
    dy = dy >= h/2 ? dy - h : dy
    dx = dx >= w/2 ? dx - w : dx
    peak = r[py, px] / (sum(abs, r) / length(r) + eps())
    return dx, dy, peak
end

# Shared frame streamer: open one ffmpeg pipe for the cropped/scaled gray stream
# and call `process(buf, k)` per frame — `buf` is the reused raw-bytes buffer
# (one frame), `k` is the 0-based index. One decode, one buffer, no per-frame alloc.
function _stream_frames(process, video_path::AbstractString, vf::String, start_s::Real,
                        dur_s::Real, fps::Real, pixels::Int, backend::FfmpegBackend)
    targs = isfinite(dur_s) ? ["-t", string(dur_s)] : String[]
    buf = Vector{UInt8}(undef, pixels)
    with_backend(backend) do exe
        io = open(`$exe -hide_banner -loglevel error $(backend.hwaccel_args) -ss $start_s $targs -i $video_path -vf $vf -r $fps -f rawvideo pipe:1`, "r")
        k = 0
        while true
            try
                read!(io, buf)
            catch e
                e isa EOFError && break
                rethrow()
            end
            process(buf, k)
            k += 1
        end
        close(io)
    end
end

# ── video → rotation track ──────────────────────────────────────────────────
"""
    video_rotation_track(video_path; start_s, dur_s, fps, crop, outw, outh, backend)
        -> (t, yaw, pitch, peak)

ffmpeg-downconverts a window of the video to a small grayscale horizon-band
stream (piped, no temp files) and phase-correlates consecutive frames. `t` is in
video clip-time (seconds). Uses the repo ffmpeg backend so the bundled binary's
libs resolve.
"""
function video_rotation_track(video_path::AbstractString;
                              start_s::Real, dur_s::Real, fps::Real = 30.0,
                              crop = VISUAL_CROP_DEFAULT, outw::Int = 256, outh::Int = 80,
                              backend::FfmpegBackend = detect_backend())
    vf = "crop=iw*$(crop.w):ih*$(crop.h):iw*$(crop.x0):ih*$(crop.y0),scale=$(outw):$(outh),format=gray"
    # GPU-decode when the backend has NVDEC (-hwaccel cuda); frames copy back to
    # system memory so the CPU crop/scale/gray filters still apply. No-op on the
    # bundled backend (empty hwaccel_args).
    bytes = with_backend(backend) do exe
        read(`$exe -hide_banner -loglevel error $(backend.hwaccel_args) -ss $start_s -t $dur_s -i $video_path -vf $vf -r $fps -f rawvideo pipe:1`)
    end

    #TODO, de-obfuscate the names, fsz, frame size?? outh, w, height width? 
    fsz = outw * outh
    nframes = length(bytes) ÷ fsz
    nframes < 2 && error("video_rotation_track: got $nframes frames (need ≥2) at start=$start_s")

    #TODO: THese can be initialized better, no?? like, actually sized??
    t = Float64[]; yaw = Float64[]; pitch = Float64[]; pk = Float64[]

    # TODO: Compiler has no idea the type of prev now, nothing or what is cur??? do better
    prev = nothing
    @inbounds for k in 0:nframes-1
        off = k * fsz
        frame = permutedims(reshape(view(bytes, off+1:off+fsz), outw, outh))  # -> [y,x]
        # TODO: Oh god reshape, fuck, no thanks, I want as much of that out as possible. 

        cur = _vs_preprocess(frame)         #TODO: Not concretely typed!!!!!!
        if prev !== nothing                 #TODO: branch prediction should do fine here??? 
            dx, dy, p = _vs_phase_shift(prev, cur)
            push!(yaw, dx); push!(pitch, dy); push!(pk, p)
            push!(t, start_s + (k - 0.5) / fps)             # TODO, push, really?????
        end
        prev = cur
    end
    return (t = t, yaw = yaw, pitch = pitch, peak = pk)
end

# ── signal conditioning + global cross-correlation search ───────────────────
_vs_znorm(x) = (m = mean(x); s = std(x); s == 0 ? (x .- m) : (x .- m) ./ s)

function _vs_resample(t, x, fs; t0 = first(t), t1 = last(t))
    g = collect(t0:(1/fs):t1)
    out = similar(g)
    @inbounds for (i, q) in enumerate(g)
        if q <= first(t); out[i] = float(first(x))
        elseif q >= last(t); out[i] = float(last(x))
        else
            j = searchsortedlast(t, q); w = (q - t[j]) / (t[j+1] - t[j])
            out[i] = (1 - w) * x[j] + w * x[j+1]
        end
    end
    return g, out
end

function _vs_bandpass(x, fs; lo = 0.1, hi = 8.0, order = 4)             
    nyq = fs / 2
    hi = min(hi, 0.95 * nyq)
    lo = max(lo, 1e-3)
    flt = digitalfilter(Bandpass(lo, hi), Butterworth(order); fs = fs)
    return filtfilt(flt, float.(collect(x)))            #TODO, not sure, but pretty sure this float.() is a nightmare..... just demand X as a concrete type!!!
end

"""
    _vs_ncc_kernel!(out, V, R, cs, cs2, m, Lmax)

Normalized sliding cross-correlation: `out[L+1]` = Pearson(`V`, `R[L+1:L+m]`) for
`L in 0:Lmax`. `cs`/`cs2` are ZERO-PADDED prefix sums of `R` (`cs[1]=0`) so the
window sum is `cs[L+m+1]-cs[L+1]` — no per-lag branch. Kept as its own typed
function (a "function barrier") so nothing boxes under `Threads.@threads`; the
inner reduction is `@simd` (emits `vfmadd`).
"""
function _vs_ncc_kernel!(out::Vector{Float64}, V::Vector{Float64}, R::Vector{Float64},
                         cs::Vector{Float64}, cs2::Vector{Float64}, m::Int, Lmax::Int)
    Threads.@threads for L in 0:Lmax    
        d = 0.0
        @inbounds @simd for i in 1:m
            d += V[i] * R[L+i]
        end
        @inbounds begin
            μ  = (cs[L+m+1]  - cs[L+1])  / m
            σ2 = (cs2[L+m+1] - cs2[L+1]) / m - μ * μ
            out[L+1] = σ2 > 1e-12 ? d / (sqrt(σ2) * m) : 0.0            #TODO, branching, why, can't we guard at the end or something? don't completely follow may be wrong
        end
    end
    return out
end

"""
    _vs_xcorr_search(vt, vx, rt, rx; fs, lo, hi) -> (Δgrid, ncc)

Sign-invariant normalized cross-correlation of a short video template against a
long telemetry reference. Returns the full curve: `Δgrid` (offset s, where
telemetry_time = video_time + Δ) and per-offset Pearson `ncc`.
"""
function _vs_xcorr_search(vt, vx, rt, rx; fs = 30.0, lo = 0.1, hi = 8.0)            #TODO, holy shit this is unreadable
    _, V = _vs_resample(vt, vx, fs)
    Rg, R = _vs_resample(rt, rx, fs)
    V = _vs_znorm(_vs_bandpass(V, fs; lo, hi))
    R = _vs_bandpass(R, fs; lo, hi)
    m, n = length(V), length(R)
    m < n || error("visual template ($m) must be shorter than telemetry ref ($n)")
    v_t0 = first(vt); r_t0 = first(Rg)
    cs  = pushfirst!(cumsum(R), 0.0)       # zero-padded prefix sums (branch-free windows)      #TODO, push, fuck off, this is bad
    cs2 = pushfirst!(cumsum(R .^ 2), 0.0)
    K = n - m
    ncc = Vector{Float64}(undef, K + 1)
    _vs_ncc_kernel!(ncc, V, R, cs, cs2, m, K)
    Δgrid = [(r_t0 + k / fs) - v_t0 for k in 0:K]
    return Δgrid, ncc
end

"""
    _vs_refine_curve(vt, vx, rt, rx, Δ0; fs=240, halfwin=2.0, lo, hi) -> (δgrid, corr)

High-resolution local cross-correlation in a ±`halfwin` window around a coarse
offset `Δ0`, resampled to `fs` Hz. Because both signals are bandlimited, the
peak of this finely-sampled curve (+ parabolic interpolation) localizes the
offset far below the original frame spacing. SIMD inner / threaded outer.
"""
function _vs_refine_curve(vt, vx, rt, rx, Δ0; fs = 240.0, halfwin = 2.0, lo = 0.1, hi = 8.0)
    _, V = _vs_resample(vt, vx, fs; t0 = first(vt), t1 = last(vt))
    V = _vs_znorm(_vs_bandpass(V, fs; lo = lo, hi = hi))
    m = length(V)
    tlo = first(vt) + Δ0 - halfwin; thi = last(vt) + Δ0 + halfwin
    _, R = _vs_resample(rt, rx, fs; t0 = tlo, t1 = thi)
    R = _vs_bandpass(R, fs; lo = lo, hi = hi)
    nL = length(R) - m
    nL < 2 && error("refine window too small (got nL=$nL)")
    cs  = pushfirst!(cumsum(R), 0.0)                    #TODO, same shit, fix these please!!!
    cs2 = pushfirst!(cumsum(R .^ 2), 0.0)
    corr = Vector{Float64}(undef, nL + 1)
    _vs_ncc_kernel!(corr, V, R, cs, cs2, m, nL)
    δgrid = [Δ0 - halfwin + L / fs for L in 0:nL]
    return δgrid, corr
end

# top-K peaks of a curve with a minimum spacing (offset units = seconds)
function _vs_top_k(Δgrid, score, fs; k = 12, min_spacing_s = 30.0)
    order = sortperm(score; rev = true)
    sel = Tuple{Float64,Float64}[]
    sp = min_spacing_s
    for j in order
        d = Δgrid[j]
        if all(abs(d - s[1]) >= sp for s in sel)
            push!(sel, (d, score[j])); length(sel) >= k && break
        end
    end
    return sel
end

function _vs_load_rate(arrow_path, channel)         #TODO, where are your types!! why are we casting so much???? meh maybe its fine here... this still just seems awful
    tbl = Arrow.Table(arrow_path)
    T = Float64.(collect(Tables.getcolumn(tbl, :Time)))
    X = Float64.(collect(Tables.getcolumn(tbl, Symbol(channel))))
    m = isfinite.(T) .& isfinite.(X)   # drop pre-green NaNs
    return T[m], X[m]
end

"""
    align_visual_rotation(video_path, arrow_path; start_s=600, dur_s=300,
                          crop=VISUAL_CROP_DEFAULT, fs=30, band=(0.1,8.0),
                          seed=nothing, seed_tol_s=60, backend=detect_backend())
        -> NamedTuple

Estimate the video↔telemetry offset from camera rotation. Returns `offset_s`
(telemetry_time = video_time + offset_s — SAME sign convention as
`align_audio_rpm`), a `confidence` (joint |ncc| at the lock), the per-channel
locks, and `candidate_peaks` (the lap-aliased comb; pass `seed` — e.g. a coarse
offset from wall-clock or GPS-speed — to pick the right lap).
"""
function align_visual_rotation(video_path::AbstractString, arrow_path::AbstractString;
                               start_s::Real = 600.0, dur_s::Real = 300.0,
                               crop = VISUAL_CROP_DEFAULT, fs::Real = 30.0,
                               band::Tuple{Real,Real} = (0.1, 8.0),
                               seed::Union{Nothing,Real} = nothing, seed_tol_s::Real = 60.0,
                               fs_fine::Real = 240.0, refine_halfwin_s::Real = 2.0,
                               backend::FfmpegBackend = detect_backend())
    lo, hi = band
    track = video_rotation_track(video_path; start_s = start_s, dur_s = dur_s,
                                 fps = fs, crop = crop, backend = backend)
    Ty, Yaw   = _vs_load_rate(arrow_path, "ChassisRotVelYawIDR")
    Tp, Pitch = _vs_load_rate(arrow_path, "ChassisRotVelPitchIDR")
    Δg, ny = _vs_xcorr_search(track.t, track.yaw,   Ty, Yaw;   fs = fs, lo = lo, hi = hi)
    _,  np = _vs_xcorr_search(track.t, track.pitch, Tp, Pitch; fs = fs, lo = lo, hi = hi)
    joint = abs.(ny) .+ abs.(np)

    #TODO: more in favor of eliminating seed.... maybe not, but either way, the input here should be a struct!!!! Common!!!
    # ── coarse pick: within ±seed_tol of seed if given, else global max of joint
    pick = seed === nothing ? eachindex(joint) :
           findall(d -> abs(d - Float64(seed)) <= seed_tol_s, Δg)
    isempty(pick) && (pick = eachindex(joint))
    Δ0 = Δg[pick[argmax(joint[pick])]]

    # ── fine refine: re-correlate at fs_fine in a ±halfwin window, sub-sample peak
    dg, cy = _vs_refine_curve(track.t, track.yaw,   Ty, Yaw,   Δ0;
                              fs = fs_fine, halfwin = refine_halfwin_s, lo = lo, hi = hi)
    _,  cp = _vs_refine_curve(track.t, track.pitch, Tp, Pitch, Δ0;
                              fs = fs_fine, halfwin = refine_halfwin_s, lo = lo, hi = hi)
    jf = abs.(cy) .+ abs.(cp)
    # parabolic sub-sample peak of a curve -> (offset_s, peak_value)
    subpk(c) = (k = argmax(c);
                s = (1 < k < length(c)) ? _vs_parabolic(c[k-1], c[k], c[k+1]) : 0.0;
                (dg[k] + s / fs_fine, c[k]))
    off_j, pk_j = subpk(jf)
    off_y, pk_y = subpk(abs.(cy))
    off_p, pk_p = subpk(abs.(cp))

    return AlignEstimate(off_j, pk_j / 2, :visual_rotation, (
        coarse_offset_s  = Δ0,
        yaw_offset_s     = off_y, yaw_conf = pk_y,
        pitch_offset_s   = off_p, pitch_conf = pk_p,
        channel_spread_s = abs(off_y - off_p),   # yaw/pitch agreement = a self-check
        window           = (start_s, dur_s),
        mean_phase_peak  = mean(track.peak),
        seed             = seed,
        candidate_peaks  = [(offset_s = d, conf = c) for (d, c) in _vs_top_k(Δg, joint, fs)],
    ))
end

#endretion

#region Forward Flow
# ═════════════════════════════════════════════════════════════════════════════
# Forward optical-flow ↔ GPS-speed alignment (the COARSE, lap-fixing channel).
#
# The yaw/pitch rotation aligner is sharp but lap-aliased — corners repeat, so
# its correlation is a comb with one tooth per lap. This channel fixes WHICH
# tooth. It extracts a speed PROXY from the video — the inter-frame image change
# in a forward-looking foreground crop, which grows with how fast the scene
# streams past — and cross-correlates it against `VectorGPS_Speed`.
#
# The trick (per the design notes): the session SHAPE of speed — out-lap, racing
# pace, the dips at cautions/pits, the unique sequence of braking zones — is
# GLOBALLY unique over a session, not lap-periodic. So we DON'T band-pass it (a
# high-pass would delete exactly the slow envelope that makes it unique); we only
# lightly smooth. The result locks the absolute lap with no seed; yaw/pitch then
# refine the sub-second offset.
# ═════════════════════════════════════════════════════════════════════════════

# Window over the scene around the vanishing point (read off the motion heatmaps).
# Fourier-Mellin is translation-invariant, so the exact framing isn't critical —
# just keep the bulk of the static cockpit/hood out of it.
const FORWARD_CROP_DEFAULT = (x0 = 0.18, w = 0.64, y0 = 0.30, h = 0.34)

# Precompute the fixed pieces of the Fourier-Mellin pass — built once, reused every
# frame: a 2D Hann window (cuts crop-edge spectral leakage), a Reddy–Chatterji
# high-pass over the spectrum, an fftshift index map (so we never allocate a shifted
# copy per frame), and the log-polar sampling grid centred on DC. Sample coordinates
# are clamped into bounds here so the per-frame sampler needs no bounds check.
function _fm_build(side::Int, n_angle::Int, n_radius::Int)
    hann_1d = [0.5 - 0.5cos(2π * (i - 1) / (side - 1)) for i in 1:side]
    hann_window = hann_1d * hann_1d'
    highpass = Matrix{Float64}(undef, side, side)
    @inbounds for y in 1:side, x in 1:side
        freq_x = (x - (side + 1) / 2) / side
        freq_y = (y - (side + 1) / 2) / side
        cos_term = cos(π * freq_x) * cos(π * freq_y)
        highpass[y, x] = (1 - cos_term) * (2 - cos_term)        # suppress DC, emphasize structure
    end
    shift_index = [((r - 1 + side ÷ 2) % side) + 1 for r in 1:side]   # 1-D fftshift map
    center = (side + 1) / 2
    log_radii = range(log(3.0), log(side / 2 - 1.0); length = n_radius)
    sample_x = Matrix{Float64}(undef, n_angle, n_radius); sample_y = similar(sample_x)
    @inbounds for angle_i in 1:n_angle
        angle = π * (angle_i - 1) / n_angle                     # 0..π: |spectrum| is point-symmetric
        cos_a = cos(angle); sin_a = sin(angle)
        for radius_i in 1:n_radius
            radius = exp(log_radii[radius_i])
            sample_x[angle_i, radius_i] = clamp(center + radius * cos_a, 1.0, side - 1e-3)
            sample_y[angle_i, radius_i] = clamp(center + radius * sin_a, 1.0, side - 1e-3)
        end
    end
    return hann_window, highpass, shift_index, sample_x, sample_y
end

# Bilinear-sample the centred magnitude `mag` onto the log-polar grid, then DC-remove.
# Coordinates are pre-clamped in `_fm_build`, so no per-sample bounds branch.
function _fm_logpolar!(out, mag, sample_x, sample_y, n_angle, n_radius)
    @inbounds for radius_i in 1:n_radius, angle_i in 1:n_angle
        x = sample_x[angle_i, radius_i]; y = sample_y[angle_i, radius_i]
        xi = floor(Int, x); yi = floor(Int, y)
        frac_x = x - xi; frac_y = y - yi
        out[angle_i, radius_i] =
            (1 - frac_x) * (1 - frac_y) * mag[yi, xi]     + frac_x * (1 - frac_y) * mag[yi, xi + 1] +
            (1 - frac_x) * frac_y       * mag[yi + 1, xi] + frac_x * frac_y       * mag[yi + 1, xi + 1]
    end
    out .-= mean(out); return out
end

# Signed, sub-bin radial (log-scale) shift from the phase-correlation surface.
function _fm_radial_peak(corr_surface, n_angle, n_radius)
    best = -Inf; peak_angle = 1; peak_radius = 1
    @inbounds for radius_i in 1:n_radius, angle_i in 1:n_angle
        value = real(corr_surface[angle_i, radius_i])
        if value > best
            best = value; peak_angle = angle_i; peak_radius = radius_i
        end
    end
    left  = real(corr_surface[peak_angle, mod1(peak_radius - 1, n_radius)])             # TODO what is the real for??? are we just looping over data for fun???
    middle = real(corr_surface[peak_angle, peak_radius])
    right = real(corr_surface[peak_angle, mod1(peak_radius + 1, n_radius)])
    curvature = left - 2middle + right
    sub_bin = abs(curvature) < eps() ? 0.0 : clamp(0.5 * (left - right) / curvature, -1.0, 1.0)
    shift = (peak_radius - 1) + sub_bin
    return shift > n_radius / 2 ? shift - n_radius : shift
end

"""
    video_forward_track(video_path; start_s, dur_s, fps, crop, side, n_angle, n_radius, backend)
        -> (t, forward)

Forward-speed signal by **Fourier-Mellin**: per frame, FFT → magnitude spectrum →
log-polar → phase-correlate against the previous frame's. The radial (log-scale)
shift is the scene's zoom rate ∝ vehicle speed. Because the magnitude spectrum is
translation-invariant, pan/tilt from cornering doesn't contaminate it. Streams
frames; every FFT plan and buffer is preallocated, so the per-frame loop allocates
nothing. `forward[k]` ∝ speed.
"""
function video_forward_track(video_path::AbstractString;
                             start_s::Real = 0.0, dur_s::Real = Inf, fps::Real = 30.0,
                             crop = FORWARD_CROP_DEFAULT, side::Int = 128,
                             n_angle::Int = 128, n_radius::Int = 64,
                             backend::FfmpegBackend = detect_backend())

    #TODO: Same deal, we shouuld have an imput struct..... fuck bro. this is bad. 
    vf = "crop=iw*$(crop.w):ih*$(crop.h):iw*$(crop.x0):ih*$(crop.y0),scale=$(side):$(side),format=gray"
    targs = isfinite(dur_s) ? ["-t", string(dur_s)] : String[]
    pixels = side * side
    hann_window, highpass, shift_index, sample_x, sample_y = _fm_build(side, n_angle, n_radius)
    # preallocated FFT plans + scratch (reused every frame)
    # TODO: ON WHAT EARTH IS THIS ACCEPTABLE CODE TO OUTPUT! LITERALLY A BLOCK, A FUCKING BRICK HAS MORE READABLE STRUCTURE
    complex_frame = Matrix{ComplexF64}(undef, side, side); frame_freq = similar(complex_frame)
    mag = Matrix{Float64}(undef, side, side); image_plan = plan_fft(complex_frame)
    lp_prev = Matrix{Float64}(undef, n_angle, n_radius); lp_cur = similar(lp_prev)
    prev_complex = Matrix{ComplexF64}(undef, n_angle, n_radius); cur_complex = similar(prev_complex)
    prev_freq = similar(prev_complex); cur_freq = similar(prev_complex)
    cross_power = similar(prev_complex); corr_surface = similar(prev_complex)
    lp_plan = plan_fft(prev_complex); lp_inverse_plan = plan_bfft(cross_power)
    cap = isfinite(dur_s) ? ceil(Int, Float64(dur_s) * fps) + 16 : 200_000
    t = Vector{Float64}(undef, cap); forward = Vector{Float64}(undef, cap)
    buf = Vector{UInt8}(undef, pixels); emitted = 0
    with_backend(backend) do exe
        io = open(`$exe -hide_banner -loglevel error $(backend.hwaccel_args) -ss $start_s $targs -i $video_path -vf $vf -r $fps -f rawvideo pipe:1`, "r")
        frame = 0; have_prev = false
        while emitted < cap
            try
                read!(io, buf)                  # one frame, or EOFError at end
            catch e
                e isa EOFError && break
                rethrow()
            end
            @inbounds for y in 1:side, x in 1:side
                complex_frame[y, x] = buf[(y - 1) * side + x] * hann_window[y, x]
            end
            mul!(frame_freq, image_plan, complex_frame)
            @inbounds for col in 1:side, row in 1:side
                mag[row, col] = abs(frame_freq[shift_index[row], shift_index[col]]) * highpass[row, col]
            end
            _fm_logpolar!(lp_cur, mag, sample_x, sample_y, n_angle, n_radius)
            if have_prev
                @inbounds @. prev_complex = complex(lp_prev)
                @inbounds @. cur_complex  = complex(lp_cur)
                mul!(prev_freq, lp_plan, prev_complex)
                mul!(cur_freq,  lp_plan, cur_complex)
                @. cross_power = prev_freq * conj(cur_freq)
                @. cross_power = cross_power / (abs(cross_power) + eps())
                mul!(corr_surface, lp_inverse_plan, cross_power)
                emitted += 1
                @inbounds forward[emitted] = _fm_radial_peak(corr_surface, n_angle, n_radius)
                @inbounds t[emitted]       = start_s + (frame - 0.5) / fps
            end
            lp_prev, lp_cur = lp_cur, lp_prev   # rotate buffers, no alloc
            have_prev = true; frame += 1
        end
        close(io)
    end
    resize!(forward, emitted); resize!(t, emitted)
    emitted < 2 && error("video_forward_track: got $emitted frames at start=$start_s")
    return (t = t, forward = forward)
end

#endregion


#region ALTERNATE
# ─────────────────────────────────────────────────────────────────────────────
# ALTERNATE (parked — kept for later, NOT on the default path): per-pixel motion
# mask + per-frame edge/glare rejection. More robust in principle (rejects glare,
# fits the cockpit's true shape) but heavier. Reachable via video_forward_track_masked.
# ─────────────────────────────────────────────────────────────────────────────

# ── motion mask + per-frame edge/glare rejection ────────────────────────────
# The speed proxy must fire only on REAL streaming scene — not the static cockpit
# (A-pillars/hood/dash) and not glare/reflections. Two complementary stages:
#   (a) motion mask  — a first pass over the whole session keeps only pixels whose
#       intensity actually VARIES over time, rejecting the static cockpit by its
#       true (irregular) shape — better than any rectangular crop.
#   (b) per-frame edge diff — the flow runs on the Sobel GRADIENT of each frame,
#       so smooth glare/reflections (≈0 gradient every frame) contribute ≈0, while
#       a white bitmask drops sun/specular pixels (bright + low-saturation RGB).

# Sobel gradient magnitude of luma `Y` (w×h, raster order) into `E`; borders 0.
function _sobel_mag!(E::Vector{Float64}, Y::Vector{Float64}, w::Int, h::Int)
    fill!(E, 0.0)
    @inbounds for r in 2:h-1
        base = (r - 1) * w
        for c in 2:w-1
            i = base + c
            gx = (Y[i-w+1] + 2Y[i+1] + Y[i+w+1]) - (Y[i-w-1] + 2Y[i-1] + Y[i+w-1])
            gy = (Y[i+w-1] + 2Y[i+w] + Y[i+w+1]) - (Y[i-w-1] + 2Y[i-w] + Y[i-w+1])
            E[i] = sqrt(gx * gx + gy * gy)
        end
    end
    return E
end

"""
    _build_forward_mask(video_path; mw, mh, sample_fps, thresh, backend) -> Vector{Bool}

First pass: sample frames across the whole video and keep pixels whose temporal
std-dev exceeds `thresh`×max — the dynamic scene, with the static cockpit
(A-pillars/hood/dash) rejected by its actual shape.
"""
function _build_forward_mask(video_path::AbstractString; mw::Int = 320, mh::Int = 180,
                             sample_fps::Real = 1/6, thresh::Real = 0.40,
                             backend::FfmpegBackend = detect_backend())
    fsz = mw * mh
    bytes = with_backend(backend) do exe
        read(`$exe -hide_banner -loglevel error $(backend.hwaccel_args) -i $video_path -vf fps=$(sample_fps),scale=$(mw):$(mh),format=gray -f rawvideo pipe:1`)
    end
    n = length(bytes) ÷ fsz
    n < 2 && error("_build_forward_mask: only $n sample frames")
    acc = zeros(Float64, fsz); acc2 = zeros(Float64, fsz)
    @inbounds for k in 0:n-1
        off = k * fsz
        @simd for i in 1:fsz
            v = Float64(bytes[off + i]); acc[i] += v; acc2[i] += v * v
        end
    end
    sd = sqrt.(max.(acc2 ./ n .- (acc ./ n) .^ 2, 0.0))
    mx = maximum(sd)
    raw = Bool[sd[i] >= thresh * mx for i in 1:fsz]
    return _fill_window(raw, mw, mh)
end

# Fill the window interior: flood the static "exterior" inward from the image
# border through rejected (cold) pixels — that traces the cockpit frame. Anything
# the frame ENCLOSES (the view through the glass, holes and interior glare blobs
# included) becomes the ROI; the per-frame edge/white filter sorts glare from
# scene inside it. Captures the whole windshield opening by its true loop shape.
function _fill_window(raw::AbstractVector{Bool}, w::Int, h::Int)
    ext = falses(w * h)
    st = Int[]
    idx(r, c) = (r - 1) * w + c
    seed(i) = (@inbounds !raw[i] && !ext[i]) && (@inbounds ext[i] = true; push!(st, i))
    for c in 1:w; seed(idx(1, c)); seed(idx(h, c)); end
    for r in 1:h; seed(idx(r, 1)); seed(idx(r, w)); end
    @inbounds while !isempty(st)
        i = pop!(st); r = (i - 1) ÷ w + 1; c = (i - 1) % w + 1
        r > 1 && seed(idx(r-1, c)); r < h && seed(idx(r+1, c))
        c > 1 && seed(idx(r, c-1)); c < w && seed(idx(r, c+1))
    end
    return Bool[!ext[i] for i in 1:w*h]
end

"""
    video_forward_track_masked(video_path; start_s, dur_s, fps, mw, mh, mask, backend)
        -> (t, forward)

(Parked alternate.) Glare-robust speed proxy. STREAMS full frames (memory stays flat over long full-
fps windows), converts each to a Sobel-gradient image, and sums the inter-frame
change of that gradient over the motion `mask`, dropping near-white glare pixels.
Smooth glare/reflections → ≈0 gradient → ≈0 contribution; sharp streaming
road/walls dominate. `forward[k]` ∝ scene speed.
"""
function video_forward_track_masked(video_path::AbstractString;
                             start_s::Real = 0.0, dur_s::Real = Inf, fps::Real = 30.0,
                             mw::Int = 320, mh::Int = 180,
                             mask::Union{Nothing,AbstractVector{Bool}} = nothing,
                             backend::FfmpegBackend = detect_backend())
    fsz = mw * mh; fsz3 = 3 * fsz
    msk = mask === nothing ? trues(fsz) : mask
    length(msk) == fsz || error("mask length $(length(msk)) != $(fsz)")
    targs = isfinite(dur_s) ? ["-t", string(dur_s)] : String[]
    vf = "scale=$(mw):$(mh),format=rgb24"

    # Preallocate from the known frame count (dur_s*fps); index-fill, no per-frame
    # push!. resize! once at the end (and amortized-double only if we overrun).
    cap = isfinite(dur_s) ? ceil(Int, Float64(dur_s) * fps) + 8 : 4096
    t = Vector{Float64}(undef, cap); fwd = Vector{Float64}(undef, cap)
    buf = Vector{UInt8}(undef, fsz3)
    Y = Vector{Float64}(undef, fsz); white = Vector{Bool}(undef, fsz)
    Ecur = Vector{Float64}(undef, fsz); Eprev = Vector{Float64}(undef, fsz)
    j = 0
    with_backend(backend) do exe
        io = open(`$exe -hide_banner -loglevel error $(backend.hwaccel_args) -ss $start_s $targs -i $video_path -vf $vf -r $fps -f rawvideo pipe:1`, "r")
        k = 0
        while true
            try
                read!(io, buf)                  # exactly one frame, or EOFError at end
            catch e
                e isa EOFError && break
                rethrow()
            end
            @inbounds for i in 1:fsz
                r = Float64(buf[3i-2]); g = Float64(buf[3i-1]); b = Float64(buf[3i])
                Y[i] = (r + g + b) / 3
                mxc = max(r, g, b); mnc = min(r, g, b)
                white[i] = mxc > 220.0 && (mxc - mnc) < 0.18 * mxc + 1.0   # bright + low-sat = glare
            end
            _sobel_mag!(Ecur, Y, mw, mh)
            if k > 0
                s = 0.0; cnt = 0
                @inbounds for i in 1:fsz
                    if msk[i] && !white[i]
                        s += abs(Ecur[i] - Eprev[i]); cnt += 1
                    end
                end
                j += 1
                if j > length(fwd)              # overrun guard (amortized, not per-frame)
                    resize!(fwd, 2length(fwd)); resize!(t, 2length(t))
                end
                @inbounds fwd[j] = cnt > 0 ? s / cnt : 0.0
                @inbounds t[j]   = start_s + (k - 0.5) / fps
            end
            Ecur, Eprev = Eprev, Ecur
            k += 1
        end
        close(io)
    end
    resize!(fwd, j); resize!(t, j)
    j < 2 && error("video_forward_track: got $j frames at start=$start_s")
    return (t = t, forward = fwd)
end

# Simple centred moving-average (zero-padded prefix sums). Used to denoise the
# speed proxy WITHOUT high-passing — we keep the slow session envelope.
function _fwd_smooth(x::AbstractVector{<:Real}, n::Int)
    n <= 1 && return Float64.(collect(x))
    m = length(x); cs = pushfirst!(cumsum(Float64.(collect(x))), 0.0)
    out = Vector{Float64}(undef, m); half = n ÷ 2
    @inbounds for i in 1:m
        lo = max(1, i - half); hi = min(m, i + half)
        out[i] = (cs[hi + 1] - cs[lo]) / (hi - lo + 1)
    end
    return out
end

"""
    _fwd_xcorr_search(vt, vx, rt, rx; fs=4, smooth_s=3) -> (Δgrid, ncc)

Positive (sign-preserving) normalized cross-correlation of the video speed proxy
against telemetry speed. No band-pass — only light smoothing — so the slow
session envelope (the lap-fixing signal) survives. Returns the full curve;
`Δgrid` is the offset (telemetry_time = video_time + Δ).
"""
function _fwd_xcorr_search(vt, vx, rt, rx; fs = 4.0, smooth_s = 3.0)
    _, V = _vs_resample(vt, vx, fs)
    Rg, R = _vs_resample(rt, rx, fs)
    sn = max(1, round(Int, smooth_s * fs))
    V = _vs_znorm(_fwd_smooth(V, sn))
    R = _fwd_smooth(R, sn)
    m, n = length(V), length(R)
    m < n || error("forward template ($m) must be shorter than telemetry ref ($n) — shorten dur_s")
    cs  = pushfirst!(cumsum(R), 0.0)
    cs2 = pushfirst!(cumsum(R .^ 2), 0.0)
    K = n - m
    ncc = Vector{Float64}(undef, K + 1)
    _vs_ncc_kernel!(ncc, V, R, cs, cs2, m, K)        # signed Pearson; speed proxy ↔ speed is same-sign
    Δgrid = [(first(Rg) + k / fs) - first(vt) for k in 0:K]
    return Δgrid, ncc
end

"""
    align_forward_speed(video_path, arrow_path; start_s=300, dur_s=900, fps=30,
                        corr_fs=5, smooth_s=3, crop, side, n_angle, n_radius, backend)
        -> AlignEstimate

Offset from the forward-flow (Fourier-Mellin zoom) ↔ GPS-speed axis. The video
zoom rate is captured at full `fps`, then cross-correlated against telemetry speed
at the lower `corr_fs` (the speed envelope is slow). `start_s` should be past any
pre-green footage so the template lands inside the green-based telemetry; `dur_s`
must be shorter than the telemetry span. `detail` carries the candidate-peak comb
and the margin of the winning peak over the runner-up.
"""
function align_forward_speed(video_path::AbstractString, arrow_path::AbstractString;
                             start_s::Real = 300.0, dur_s::Real = 900.0, fps::Real = 30.0,
                             corr_fs::Real = 5.0, smooth_s::Real = 3.0,
                             crop = FORWARD_CROP_DEFAULT, side::Int = 128,
                             n_angle::Int = 128, n_radius::Int = 64,
                             backend::FfmpegBackend = detect_backend())
    track = video_forward_track(video_path; start_s = start_s, dur_s = dur_s, fps = fps,
                                crop = crop, side = side, n_angle = n_angle, n_radius = n_radius,
                                backend = backend)
    tel = load_telemetry(arrow_path)
    ref_time = Float64.(collect(tel.time)); ref_speed = Float64.(collect(tel.speed))
    keep = isfinite.(ref_time) .& isfinite.(ref_speed)
    ref_time = ref_time[keep]; ref_speed = ref_speed[keep]
    offsets, corr = _fwd_xcorr_search(track.t, track.forward, ref_time, ref_speed;
                                      fs = corr_fs, smooth_s = smooth_s)
    best = argmax(corr)
    peaks = _vs_top_k(offsets, corr, corr_fs; min_spacing_s = 20.0)
    margin = length(peaks) > 1 ? corr[best] - peaks[2][2] : corr[best]
    return AlignEstimate(offsets[best], corr[best], :forward_fmellin,
        (margin = margin, window = (start_s, dur_s), n_frames = length(track.forward),
         candidate_peaks = [(offset_s = d, conf = c) for (d, c) in peaks]))
end
