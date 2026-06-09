"""
Session-library resolution.

Race session files (.mpg videos, .arrow telemetry) live OUTSIDE the repo on
an external drive or network share. The location changes weekly. Two env
vars steer the defaults the CLI and Pluto notebook show:

- `PRERACEFILM_DATA_DIR`  → where .mpg videos live  (also default for .arrow
                            if `PRERACEFILM_ARROW_DIR` is unset)
- `PRERACEFILM_ARROW_DIR` → where .arrow telemetry lives, if different

Set them per-session in PowerShell:

    \$env:PRERACEFILM_DATA_DIR  = "D:\\Race_Videos\\25POC1"
    \$env:PRERACEFILM_ARROW_DIR = "D:\\Race_Videos\\25POC1"   # optional

Or persistently for your user account:

    [Environment]::SetEnvironmentVariable(
        "PRERACEFILM_DATA_DIR", "D:\\Race_Videos\\25POC1", "User")
"""

"""
    data_dir() -> String

Where to look for session input files (.mpg videos). Reads
`PRERACEFILM_DATA_DIR`, then falls back to `Sample Race Data/` in the repo
root (the legacy default), then returns `""` if neither exists.
"""
function data_dir()
    e = get(ENV, "PRERACEFILM_DATA_DIR", "")
    !isempty(e) && return e
    legacy = abspath(joinpath(@__DIR__, "..", "Sample Race Data"))
    return isdir(legacy) ? legacy : ""
end

"""
    arrow_dir() -> String

Where to look for .arrow telemetry. Defaults to `PRERACEFILM_ARROW_DIR`, then
to `data_dir()` (if both kinds live together).
"""
function arrow_dir()
    e = get(ENV, "PRERACEFILM_ARROW_DIR", "")
    !isempty(e) && return e
    return data_dir()
end

"""
    set_data_dir(path; arrow_path=path)

Update the env vars for the current Julia session. Useful at the top of a
notebook or script when you're switching to a new week's folder.
"""
function set_data_dir(path::AbstractString; arrow_path::AbstractString = path)
    ENV["PRERACEFILM_DATA_DIR"]  = String(path)
    ENV["PRERACEFILM_ARROW_DIR"] = String(arrow_path)
    return (data_dir = data_dir(), arrow_dir = arrow_dir())
end

"""
    list_session_files(; data = data_dir(), arrow = arrow_dir()) -> DataFrame

Return a table of `(name, video, arrow, video_size_mb, arrow_size_mb)` for
every video/arrow pair that share a stem. Useful for the Pluto picker and
for batch jobs.
"""
function list_session_files(; data::AbstractString = data_dir(),
                              arrow::AbstractString = arrow_dir())
    videos = isdir(data) ? sort(filter(f -> endswith(lowercase(f), ".mpg"),
                                       readdir(data; join = true))) : String[]
    arrows = isdir(arrow) ? sort(filter(f -> endswith(lowercase(f), ".arrow"),
                                        readdir(arrow; join = true))) : String[]

    arrow_by_stem = Dict(splitext(basename(a))[1] => a for a in arrows)
    rows = NamedTuple[]
    for v in videos
        stem = splitext(basename(v))[1]
        a = get(arrow_by_stem, stem, "")
        push!(rows, (
            name           = stem,
            video          = v,
            arrow          = a,
            video_size_mb  = round(filesize(v) / 1e6;  digits = 1),
            arrow_size_mb  = isempty(a) ? 0.0 : round(filesize(a) / 1e6; digits = 1),
            has_arrow      = !isempty(a),
        ))
    end
    return DataFrame(rows)
end
