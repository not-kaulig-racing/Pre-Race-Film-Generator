# System ffmpeg only. Resolve the binary and its GPU capabilities once, cache them,
# and expose the encode/decode args. There's no backend struct to thread around —
# callers just call ffmpeg_exe() / encode_args() / hwaccel_args() directly.

const _FFMPEG = Ref{String}("")
const _CAPS   = Ref{Union{Nothing,NamedTuple}}(nothing)

# Well-known ffmpeg install locations to probe when it isn't on PATH: a manual
# unzip under the user profile, the winget `Gyan.FFmpeg` link shim, C:\ffmpeg,
# and chocolatey's shim dir.
function _ffmpeg_fallback_dirs()
    dirs = String[]
    home = get(ENV, "USERPROFILE", get(ENV, "HOME", ""))
    if !isempty(home)
        push!(dirs, joinpath(home, "ffmpeg", "bin"))
        push!(dirs, joinpath(home, "AppData", "Local", "Microsoft", "WinGet", "Links"))
    end
    push!(dirs, raw"C:\ffmpeg\bin")
    push!(dirs, joinpath(get(ENV, "ProgramData", raw"C:\ProgramData"), "chocolatey", "bin"))
    return dirs
end

# Locate a system ffmpeg: ask the OS (`where`/`which`), swallowing a non-zero exit
# (means "not found"), then probe common install dirs. Returns nothing if absent.
function _which_ffmpeg()
    exe = Sys.iswindows() ? "ffmpeg.exe" : "ffmpeg"
    onpath = try
        raw = Sys.iswindows() ? readchomp(`where ffmpeg`) : readchomp(`which ffmpeg`)
        p = first(eachline(IOBuffer(raw)))
        isempty(p) ? nothing : p
    catch
        nothing
    end
    onpath !== nothing && return onpath
    for d in _ffmpeg_fallback_dirs()
        cand = joinpath(d, exe)
        isfile(cand) && return cand
    end
    return nothing
end

"""
    ffmpeg_exe() -> String

Path to the system ffmpeg (cached). Errors if none is found — install the
gyan.dev build (it ships NVENC/NVDEC) or put ffmpeg on PATH.
"""
function ffmpeg_exe()
    isempty(_FFMPEG[]) || return _FFMPEG[]
    p = _which_ffmpeg()
    p === nothing && error("system ffmpeg not found — install the gyan.dev build or put ffmpeg on PATH")
    return _FFMPEG[] = p
end

"ffprobe path alongside the system ffmpeg."
ffprobe_exe() = joinpath(dirname(ffmpeg_exe()), Sys.iswindows() ? "ffprobe.exe" : "ffprobe")

# NVENC/NVDEC capabilities of the resolved ffmpeg, probed once.
function _caps()
    _CAPS[] === nothing || return _CAPS[]
    exe = ffmpeg_exe(); nvenc = false; nvdec = false
    try; nvdec = occursin("cuda",       lowercase(read(`$exe -hide_banner -hwaccels`, String))); catch; end
    try; nvenc = occursin("h264_nvenc", lowercase(read(`$exe -hide_banner -encoders`, String))); catch; end
    return _CAPS[] = (nvenc = nvenc, nvdec = nvdec)
end

"Encoder args: h264_nvenc if the system build has it, else libx264."
encode_args() = _caps().nvenc ?
    ["-c:v", "h264_nvenc", "-preset", "p4", "-tune", "hq", "-rc", "vbr", "-cq", "20", "-b:v", "0", "-pix_fmt", "yuv420p"] :
    ["-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p"]

"NVDEC decode flag if available, else empty."
hwaccel_args() = _caps().nvdec ? ["-hwaccel", "cuda"] : String[]

"""
    probe_video(path) -> (; duration_s, fps, nframes)

Read a clip's duration, average frame rate, and frame count from the container
(via ffprobe) so a session can be processed without hardcoding a length.
`nframes` falls back to `duration_s*fps` if the container omits it.
"""
function probe_video(path::AbstractString)
    isfile(path) || error("video not found: $path")
    probe = ffprobe_exe()
    isfile(probe) || error("ffprobe not found next to $(ffmpeg_exe())")
    out = read(`$probe -v error -select_streams v:0 -show_entries stream=r_frame_rate,nb_frames -show_entries format=duration -of default=noprint_wrappers=1 $path`, String)
    f = Dict{String,String}()
    for ln in eachline(IOBuffer(out))
        kv = split(ln, '='; limit = 2)
        length(kv) == 2 && (f[kv[1]] = kv[2])
    end
    dur = parse(Float64, get(f, "duration", "NaN"))
    fps = let r = split(get(f, "r_frame_rate", "0/1"), '/')
        length(r) == 2 ? parse(Float64, r[1]) / parse(Float64, r[2]) : parse(Float64, r[1])
    end
    nf = get(f, "nb_frames", "N/A")
    nframes = nf == "N/A" ? round(Int, dur * fps) : parse(Int, nf)
    return (duration_s = dur, fps = fps, nframes = nframes)
end

# Chime sounds. Chest = success, zombie = skipped-because-output-exists,
# break = render errored out. Absolute paths so PowerShell doesn't have to
# resolve them via CWD.
const _CHIME_OPEN   = abspath(joinpath(@__DIR__, "..", "noises", "Chest_open.ogg"))
const _CHIME_CLOSE  = abspath(joinpath(@__DIR__, "..", "noises", "Chest_close1.ogg"))
const _CHIME_HURT1  = abspath(joinpath(@__DIR__, "..", "noises", "Zombie_hurt1.ogg"))
const _CHIME_HURT2  = abspath(joinpath(@__DIR__, "..", "noises", "Zombie_hurt2.ogg"))
const _CHIME_BREAK  = abspath(joinpath(@__DIR__, "..", "noises", "Random_break.ogg"))

# ffplay.exe alongside ffmpeg.exe. The Gyan.dev build ships both; the JLL
# fallback doesn't ship ffplay, so this may return "" and we chime differently.
function _ffplay_exe()
    fm = ffmpeg_exe()
    isempty(fm) && return ""
    fp = joinpath(dirname(fm), Sys.iswindows() ? "ffplay.exe" : "ffplay")
    return isfile(fp) ? fp : ""
end

# Fire one or more ogg files back-to-back through ffplay in a background
# PowerShell so Julia returns immediately. Returns true if the ffplay command
# was launched, false if we couldn't (missing ffplay or files, non-Windows, or
# exception) — callers use that to decide whether to fall back to a beep.
function _play_chimes(files::AbstractString...)
    Sys.iswindows() || return false
    fp = _ffplay_exe()
    (isempty(fp) || !all(isfile, files)) && return false
    cmd = join(("& \"$(fp)\" -nodisp -autoexit -loglevel quiet \"$f\"" for f in files), "; ")
    try
        run(pipeline(`powershell -NoProfile -Command $cmd`;
                     stdout = devnull, stderr = devnull); wait = false)
        return true
    catch
        return false
    end
end

function _fallback_beep(freq1, freq2)
    try
        run(pipeline(`powershell -NoProfile -Command "[console]::beep($freq1,150); [console]::beep($freq2,220)"`;
                     stdout = devnull, stderr = devnull); wait = false)
    catch
    end
end

# Success chime: Chest_open → Chest_close1. Fired at successful render returns.
# Falls back to a rising two-note beep (880→1174 Hz) if ffplay isn't available.
function notify_render_done()
    print("\a"); flush(stdout)
    _play_chimes(_CHIME_OPEN, _CHIME_CLOSE) && return nothing
    _fallback_beep(880, 1174)
    return nothing
end

# Skip chime: Zombie_hurt1 → Zombie_hurt2. Fired when a render is skipped
# because the target .mp4 already exists (pass overwrite=true to override).
# Falls back to a falling two-note beep (440→262 Hz) — deliberately different
# from the success chime so the ear can distinguish them.
function notify_render_skipped()
    print("\a"); flush(stdout)
    _play_chimes(_CHIME_HURT1, _CHIME_HURT2) && return nothing
    _fallback_beep(440, 262)
    return nothing
end

# Failure chime: Random_break. Fired when a render throws for any reason other
# than the already-exists skip (which has its own chime). Falls back to a
# harsh low two-note beep (220→165 Hz) so it's audibly distinct from the
# other two.
function notify_render_failed()
    print("\a"); flush(stdout)
    _play_chimes(_CHIME_BREAK) && return nothing
    _fallback_beep(220, 165)
    return nothing
end
