using DSP
using FFTW
using FFMPEG_jll
using Statistics

"""
    extract_audio_mono(video_path; start_s, duration_s, sr=8000,
                       backend=detect_backend()) -> Vector{Float32}

Pull mono PCM samples from the video via ffmpeg. Default 8 kHz is plenty for
the firing-fundamental band (≤800 Hz). Returns Float32 in [-1, 1].
"""
function extract_audio_mono(video_path::AbstractString;
                            start_s::Real = 0.0,
                            duration_s::Union{Nothing,Real} = nothing,
                            sr::Int = 8000,
                            backend::FfmpegBackend = detect_backend())
    bytes = with_backend(backend) do exe
        args = String[exe, "-hide_banner", "-loglevel", "error",
                      "-ss", string(start_s), "-i", String(video_path)]
        duration_s !== nothing && append!(args, ["-t", string(duration_s)])
        append!(args, ["-ac", "1", "-ar", string(sr),
                       "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1"])
        read(Cmd(args))
    end
    isempty(bytes) && error("ffmpeg returned no audio bytes for $video_path at start=$start_s dur=$duration_s")
    n = length(bytes) - mod(length(bytes), 4)
    return collect(reinterpret(Float32, view(bytes, 1:n)))
end

"""
    rpm_to_firing_envelope(audio, sr; band=(200,800), env_hz=50) -> (env, env_sr)

Band-pass the audio around the V8 firing fundamental, take the analytic
envelope, then decimate to `env_hz`.
"""
function audio_firing_envelope(audio::AbstractVector{<:AbstractFloat}, sr::Int;
                               band::Tuple{Real,Real} = (200.0, 800.0),
                               env_hz::Int = 50)
    low, high = band
    bp_filter = digitalfilter(Bandpass(Float64(low), Float64(high)), Butterworth(4); fs = sr)
    bp = filtfilt(bp_filter, Float64.(audio))
    # Rectify + low-pass to get amplitude envelope (cheaper than analytic signal)
    rect = abs.(bp)
    lp = digitalfilter(Lowpass(Float64(env_hz) / 2), Butterworth(4); fs = sr)
    env = filtfilt(lp, rect)
    # Decimate to env_hz
    decim = max(1, fld(sr, env_hz))
    env_d = env[1:decim:end]
    env_sr = sr ÷ decim
    return env_d, env_sr
end

"""
    rpm_proxy_signal(time, rpm; env_sr=50) -> Vector{Float64}

Resample the RPM trace to the envelope's sample rate. RPM is already a
"power proxy" — when the engine is louder the RPM is higher — so we just
need it on a common time grid. Returns a vector covering [time[1], time[end]].
"""
function rpm_proxy_signal(time::AbstractVector, rpm::AbstractVector; env_sr::Int = 50)
    t0, t1 = Float64(time[1]), Float64(time[end])
    n = floor(Int, (t1 - t0) * env_sr) + 1
    out = Vector{Float64}(undef, n)
    j = 1
    @inbounds for i in 1:n
        tq = t0 + (i - 1) / env_sr
        while j < length(time) && Float64(time[j+1]) < tq
            j += 1
        end
        if j >= length(time)
            out[i] = Float64(rpm[end])
        else
            x0, x1 = Float64(time[j]), Float64(time[j+1])
            y0, y1 = Float64(rpm[j]),  Float64(rpm[j+1])
            frac = (tq - x0) / (x1 - x0)
            out[i] = y0 * (1 - frac) + y1 * frac
        end
    end
    return out
end

zscore(v) = begin
    μ = mean(v); σ = std(v)
    σ == 0 ? v .- μ : (v .- μ) ./ σ
end

"""
    fft_xcorr_lag(ref, query, max_lag) -> (best_k, normalised_peak)

FFT-based cross-correlation: O(N log N) instead of O(N·max_lag). Returns the
integer lag `k` (in samples) maximising `Σ ref[i] * query[i+k]` over
`|k| <= max_lag`, plus a normalised confidence score in roughly [-1, 1].

`ref` and `query` must be equal-length, real, finite Float64 vectors.
Positive `k` means `query` is *ahead* of `ref` by `k` samples (i.e. `ref`
needs to shift right by `k` to align with `query`).
"""
function fft_xcorr_lag(ref::AbstractVector{<:Real},
                       query::AbstractVector{<:Real},
                       max_lag::Int)
    N = min(length(ref), length(query))
    r = Float64.(view(ref, 1:N))
    q = Float64.(view(query, 1:N))
    replace!(r, NaN => 0.0); replace!(q, NaN => 0.0)
    r .-= mean(r); q .-= mean(q)

    n  = nextpow(2, 2N)
    rp = vcat(r, zeros(n - N))
    qp = vcat(q, zeros(n - N))
    R  = rfft(rp); Q = rfft(qp)
    xc = irfft(conj.(R) .* Q, n)

    max_lag = clamp(max_lag, 1, n ÷ 2 - 1)
    best_k = 0; best_c = -Inf
    @inbounds for k in -max_lag:max_lag
        idx = k >= 0 ? k + 1 : n + k + 1
        c = xc[idx]
        if c > best_c
            best_c = c; best_k = k
        end
    end

    norm = sqrt(sum(abs2, r) * sum(abs2, q))
    confidence = norm == 0 ? 0.0 : best_c / norm
    return best_k, confidence
end

"""
    find_race_start(rpm; window_s=60, dt_s=0.01,
                    threshold=3000, margin_s=30, sustain_s=300) -> Int

Index of the first sample where the rolling-window-averaged RPM exceeds
`threshold` and stays above it for at least `sustain_s` seconds, minus a
`margin_s` safety pad. Useful as a coarse seed for alignment and for
trimming away the pre-race idle / staging period.
"""
function find_race_start(rpm::AbstractVector{<:Real};
                         window_s::Real  = 60.0,
                         dt_s::Real      = 0.01,
                         threshold::Real = 3000.0,
                         margin_s::Real  = 30.0,
                         sustain_s::Real = 300.0)
    w       = round(Int, window_s / dt_s)
    mar     = round(Int, margin_s / dt_s)
    sustain = round(Int, sustain_s / dt_s)
    rpm_f   = Float64.(rpm); replace!(rpm_f, NaN => 0.0)
    cs      = cumsum(rpm_f)
    n       = length(rpm_f)
    avg     = Vector{Float64}(undef, n)
    @inbounds for i in 1:n
        lo = i > w ? cs[i - w] : 0.0
        avg[i] = (cs[i] - lo) / min(i, w)
    end

    i = 1
    while i <= n
        rise = findnext(>=(threshold), avg, i)
        rise === nothing && break
        drop = findnext(<(threshold), avg, rise)
        duration = drop === nothing ? n - rise : drop - rise
        if duration >= sustain
            return max(1, rise - mar)
        end
        i = drop === nothing ? n + 1 : drop
    end
    return 1
end

"""
    find_audio_active_start(video_path; probe_s=10.0, step_s=60.0,
                            sr=8000, rms_threshold=0.005) -> Float64

Scan the video in `step_s` increments, extract a short `probe_s` audio
sample, and return the first video timestamp where the RMS exceeds
`rms_threshold`. Used to skip muted intros / commentary-only stretches.
Returns 0.0 if loud audio is found in the very first probe.
"""
function find_audio_active_start(video_path::AbstractString;
                                 probe_s::Real = 10.0,
                                 step_s::Real = 60.0,
                                 sr::Int = 8000,
                                 rms_threshold::Real = 0.005,
                                 search_limit_s::Real = 7200.0,
                                 backend::FfmpegBackend = detect_backend())
    t = 0.0
    while t < search_limit_s
        a = try
            extract_audio_mono(video_path; start_s = t, duration_s = probe_s,
                               sr = sr, backend = backend)
        catch
            return t
        end
        rms = sqrt(mean(abs2, a))
        rms >= rms_threshold && return t
        t += step_s
    end
    return 0.0
end

"""
    align_audio_rpm(video_path, arrow_path;
                    band=(200,800), env_hz=50,
                    window_s=600.0, max_lag_s=600.0,
                    audio_sr=4000, rms_threshold=0.005) -> NamedTuple

Two-stage alignment:

1. `find_race_start` on RPM finds the green flag in telemetry time.
   `find_audio_active_start` finds when the in-car camera audio actually
   becomes loud (its mic is often muted during pre-race).
2. A `window_s` slice is placed at the **later** of those two events, so
   both signals are actively varying. The RPM envelope is FFT-cross-
   correlated against a wider audio chunk to find the lag.

Returns `(offset_s, confidence, ...)` where
`telemetry_time ≈ video_time + offset_s`.
"""
function align_audio_rpm(video_path::AbstractString,
                         arrow_path::AbstractString;
                         band::Tuple{Real,Real} = (200.0, 800.0),
                         env_hz::Int = 50,
                         window_s::Real = 600.0,
                         max_lag_s::Real = 600.0,
                         audio_sr::Int = 4000,
                         rms_threshold::Real = 0.005)
    tel = load_telemetry(arrow_path)
    t1_tel = Float64(tel.time[end])

    race_idx        = find_race_start(tel.rpm)
    race_t_tel      = Float64(tel.time[race_idx])
    audio_active_t  = find_audio_active_start(video_path;
                                              sr = audio_sr,
                                              rms_threshold = rms_threshold)

    # Coarse seed: assume telemetry's race-start event and the video's
    # audio-active event are the same physical moment (engines firing).
    # offset_s_seed = telemetry_time - video_time at that moment.
    seed_offset_s = race_t_tel - audio_active_t

    # Place telemetry window safely inside the loud region (add a small pad
    # past race start so we're past the launch ramp).
    win_start_t = race_t_tel + 30.0
    win_end_t   = min(t1_tel, win_start_t + window_s)

    # Align the video window so xcorr only needs to find a small refinement
    # to the seed offset. video_time_corresponding_to_win_start =
    # win_start_t - seed_offset_s. Pad ±max_lag_s.
    video_start = max(0.0, (win_start_t - seed_offset_s) - max_lag_s)
    video_dur   = (win_end_t - win_start_t) + 2 * max_lag_s

    audio = extract_audio_mono(video_path;
                               start_s = video_start,
                               duration_s = video_dur,
                               sr = audio_sr)
    env_a, _ = audio_firing_envelope(audio, audio_sr; band = band, env_hz = env_hz)

    # Telemetry envelope at env_hz over the same telemetry window
    i0 = searchsortedfirst(tel.time, win_start_t)
    i1 = searchsortedlast(tel.time,  win_end_t)
    env_r = rpm_proxy_signal(view(tel.time, i0:i1),
                             view(tel.rpm,  i0:i1); env_sr = env_hz)

    max_lag = round(Int, max_lag_s * env_hz)
    best_k, conf = fft_xcorr_lag(env_r, env_a, max_lag)

    # env_r covers [win_start_t,   win_end_t]                (telemetry clock)
    # env_a covers [video_start,   video_start+video_dur]    (video clock)
    # xcorr(env_r, env_a) peak at best_k means env_r[i] ↔ env_a[i+best_k].
    # So the same physical moment is at:
    #     telemetry time = win_start_t + i / env_hz
    #     video time     = video_start + (i + best_k) / env_hz
    # offset_s = telemetry - video
    offset_s = (win_start_t - video_start) - best_k / env_hz

    return (
        offset_s          = offset_s,
        confidence        = conf,
        lag_samples       = best_k,
        env_hz            = env_hz,
        race_start_tel_s  = race_t_tel,
        audio_active_vid_s = audio_active_t,
        seed_offset_s     = seed_offset_s,
        refinement_s      = offset_s - seed_offset_s,
        tel_window        = (win_start_t, win_end_t),
        video_window      = (video_start, video_start + video_dur),
        method            = :fft_xcorr_focused,
    )
end
