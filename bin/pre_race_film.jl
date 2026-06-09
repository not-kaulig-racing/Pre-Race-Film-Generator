#!/usr/bin/env julia
#
# PreRaceFilm CLI.
#
# Examples:
#   julia --project=. bin/pre_race_film.jl laps --arrow path/to/session.arrow
#   julia --project=. bin/pre_race_film.jl render \
#       --video path/to/session.mpg --arrow path/to/session.arrow \
#       --lap 50 --out out/lap50.mp4
#
# All commands print JSON to stdout on success. Errors go to stderr with a
# non-zero exit code. This is the integration surface used by the AI agent
# and any other downstream tool.

using Pkg
project = abspath(joinpath(@__DIR__, ".."))
Pkg.activate(project)

using PreRaceFilm
using JSON3

const USAGE = """
PreRaceFilm CLI
===============

Commands:
  laps      List race laps detected in an .arrow file
  render    Render an overlay video for a chosen lap
  backend   Print the resolved ffmpeg backend (NVENC, libx264, ...)

Run `<command> --help` for command-specific options.
"""

const LAPS_USAGE = """
laps  --arrow PATH [--include-partial] [--min-seconds N]

Required:
  --arrow PATH               .arrow telemetry file

Options:
  --include-partial          Include pit-out / cool-down / caution laps
  --min-seconds N            Minimum lap duration to consider (default 20)
"""

const RENDER_USAGE = """
render  --video PATH --arrow PATH --lap N --out PATH [options]

Required:
  --video PATH               .mpg in-car camera video
  --arrow PATH               .arrow telemetry file
  --lap N                    Lap number to render
  --out PATH                 Output .mp4 path

Common options:
  --track NAME               Track key (e.g. "Pocono"). Default: auto-detect
  --no-track                 Skip the mini-map entirely
  --driver LABEL             Driver string for the overlay
  --event LABEL              Event string for the overlay
  --fps N                    Output fps (default 25)
  --width N                  Output width (default 1280)
  --height N                 Output height (default 720)
  --align MODE               seed | auto | none | <offset_s>  (default: seed)
  --encoder MODE             auto | gpu | cpu | system | bundled (default: auto)
"""

function main(argv::Vector{String})
    if isempty(argv) || argv[1] in ("-h", "--help")
        println(USAGE); return 0
    end
    cmd = argv[1]
    rest = argv[2:end]
    try
        return if cmd == "laps"
            cmd_laps(rest)
        elseif cmd == "render"
            cmd_render(rest)
        elseif cmd == "backend"
            cmd_backend(rest)
        else
            println(stderr, "Unknown command: $cmd")
            println(stderr, USAGE)
            2
        end
    catch e
        println(stderr, "ERROR: ", sprint(showerror, e))
        for f in stacktrace(catch_backtrace())[1:min(6,end)]
            println(stderr, "  ", f)
        end
        1
    end
end

function cmd_laps(args::Vector{String})
    if isempty(args) || args[1] in ("-h", "--help")
        println(LAPS_USAGE); return 0
    end
    opts = parse_args(args)
    arrow = required(opts, "arrow")
    drop_partial = !get(opts, "include-partial", false)
    min_seconds = parse(Float64, get(opts, "min-seconds", "20"))
    JSON3.pretty(stdout, list_laps_json(arrow;
                                       min_seconds = min_seconds,
                                       drop_partial = drop_partial))
    println()
    return 0
end

function cmd_render(args::Vector{String})
    if isempty(args) || args[1] in ("-h", "--help")
        println(RENDER_USAGE); return 0
    end
    opts = parse_args(args)
    config = Dict{String,Any}(
        "video_path"  => required(opts, "video"),
        "arrow_path"  => required(opts, "arrow"),
        "lap_number"  => parse(Int, required(opts, "lap")),
        "output_path" => required(opts, "out"),
    )
    haskey(opts, "track")    && (config["track"]        = opts["track"])
    haskey(opts, "no-track") && (config["track"]        = nothing)
    haskey(opts, "driver")   && (config["driver_label"] = opts["driver"])
    haskey(opts, "event")    && (config["event_label"]  = opts["event"])
    haskey(opts, "fps")      && (config["fps"]          = parse(Int, opts["fps"]))
    haskey(opts, "width") && haskey(opts, "height") &&
        (config["resolution"] = [parse(Int, opts["width"]), parse(Int, opts["height"])])
    haskey(opts, "encoder")  && (config["encoder"]      = opts["encoder"])

    if haskey(opts, "align")
        v = opts["align"]
        config["audio_alignment"] = (v in ("seed","auto","none")) ? ":" * v : v
    end

    result = generate_lap_video_json(config)
    JSON3.pretty(stdout, result)
    println()
    return 0
end

function cmd_backend(_args::Vector{String})
    bk = detect_backend()
    JSON3.pretty(stdout, Dict(
        "exe"        => bk.exe,
        "use_system" => bk.use_system,
        "encoder"    => bk.encoder,
        "nvenc"      => bk.has_nvenc,
        "nvdec"      => bk.has_nvdec,
    ))
    println()
    return 0
end

"""
    parse_args(args) -> Dict{String,String}

Tiny flag parser. Supports `--key value` and bare `--flag` (sets to `"true"`).
"""
function parse_args(args::Vector{String})
    out = Dict{String,Any}()
    i = 1
    while i <= length(args)
        a = args[i]
        startswith(a, "--") || error("Unexpected positional arg: $a")
        key = a[3:end]
        if i == length(args) || startswith(args[i + 1], "--")
            out[key] = true
            i += 1
        else
            out[key] = args[i + 1]
            i += 2
        end
    end
    return out
end

function required(opts::Dict, k::String)
    haskey(opts, k) || error("Missing required argument: --$k")
    return opts[k]
end

isinteractive() || exit(main(ARGS))
