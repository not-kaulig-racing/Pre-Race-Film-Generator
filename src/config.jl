using TOML

# Machine config lives in `config.local.toml` (gitignored; see
# `config.example.toml`) or `config.toml`. It is read once by `getConfig` and
# resolved into a `RaceConfig`; nothing else reads config.

# First config file that exists, parsed → Dict (empty Dict if none).
function _read_config()
    root = abspath(joinpath(@__DIR__, ".."))
    for p in (joinpath(root, "config.local.toml"), joinpath(root, "config.toml"))
        isfile(p) && return TOML.parsefile(p)
    end
    return Dict{String,Any}()
end

# ── Per-race configuration ───────────────────────────────────────────────────

const RACE_CONFIG_FILENAME = "race.toml"

"""
    RaceConfig

Per-race config: resolved paths + race metadata, loaded once by `getConfig`.
`<data_dir>/race.toml` supplies event/track/date, a `file_stem` template
(`{car}` → car number), a race-wide `alignment_method`, `[drivers]`, and
`[cars.N]` overrides (e.g. `alignment_method`, `stem`).

`alignment_method` is `seed` | `audio` | `visual` | a numeric offset (seconds),
or `nothing` if unset — there is no silent default; the entry points error
unless a method is given here or passed explicitly.
"""
struct RaceConfig
    race::String
    data_dir::String
    arrow_dir::String
    output_dir::String
    alignment_method::Union{Nothing,Symbol,Float64}   # seed|audio|visual|offset; nothing = unset
    config_path::String
    event::String
    track::String
    date::String
    file_stem::String
    drivers::Dict{Int,String}
    car_overrides::Dict{Int,Dict{String,Any}}

    function RaceConfig(race, data_dir, arrow_dir, output_dir, alignment_method,
                        config_path, event, track, date, file_stem, drivers, car_overrides)
        isdir(data_dir)  || error("Race data dir not found: $data_dir  (check [paths] in config.local.toml)")
        isdir(arrow_dir) || error("Arrow dir not found: $arrow_dir  (check [paths] in config.local.toml)")
        # Normalise + validate alignment everywhere it can be set (race-wide and
        # per-car), so a RaceConfig always holds a valid method (or nothing) and
        # nothing downstream has to parse. "audio"/":audio" → :audio, "-208.5" →
        # -208.5; an unknown symbol is a hard error.
        norm(::Nothing) = nothing
        norm(v::Real)   = Float64(v)
        function norm(v)
            s = String(v); s = startswith(s, ":") ? s[2:end] : s
            isempty(s) && return nothing
            m = something(tryparse(Float64, s), Symbol(s))
            m isa Symbol && m ∉ (:seed, :audio, :visual, :none, :auto) &&
                error("Unknown alignment_method `$s` — use seed | audio | visual | none | a numeric offset")
            return m
        end
        for ov in values(car_overrides)
            haskey(ov, "alignment_method") && (ov["alignment_method"] = norm(ov["alignment_method"]))
        end
        return new(race, data_dir, arrow_dir, output_dir, norm(alignment_method),
                   config_path, event, track, date, file_stem, drivers, car_overrides)
    end
end

"""
    getConfig(race=""; arrow_root="") -> RaceConfig

Resolve a race weekend from `config.local.toml` (`[paths]` + `[current].race`)
and its `race.toml`. Errors if no race or no data path is configured.
"""
function getConfig(race::AbstractString = ""; arrow_root::AbstractString = "")
    mc    = _read_config()
    paths = get(mc, "paths", Dict{String,Any}())
    race  = isempty(race) ? String(get(get(mc, "current", Dict{String,Any}()), "race", "")) : race
    isempty(race) && error("No race: pass getConfig(\"25POC1\") or set [current].race in config.local.toml")

    root = String(get(paths, "data_root", ""))
    dir  = String(get(paths, "data_dir", ""))
    data_dir = !isempty(root) ? joinpath(root, race) :
               !isempty(dir)  ? dir : error("Set [paths].data_root or data_dir in config.local.toml")

    arrow_dir = !isempty(arrow_root) ? joinpath(arrow_root, race) :
                let a = String(get(paths, "arrow_dir", "")); isempty(a) ? data_dir : a end
    out = String(get(paths, "output_dir", "out"))
    output_dir = isabspath(out) ? out : abspath(joinpath(@__DIR__, "..", out))

    cfg_path = joinpath(data_dir, RACE_CONFIG_FILENAME)
    isfile(cfg_path) || return RaceConfig(race, data_dir, arrow_dir, output_dir, nothing, "",
        race, "", "", "", Dict{Int,String}(), Dict{Int,Dict{String,Any}}())

    raw  = TOML.parsefile(cfg_path)
    ints(d) = ((parse(Int, String(k)), v) for (k, v) in d if tryparse(Int, String(k)) !== nothing)
    drivers   = Dict{Int,String}(k => String(v) for (k, v) in ints(get(raw, "drivers", Dict())))
    overrides = Dict{Int,Dict{String,Any}}(k => Dict{String,Any}(String(kk) => vv for (kk, vv) in v)
                    for (k, v) in ints(get(raw, "cars", Dict())) if v isa AbstractDict)
    return RaceConfig(race, data_dir, arrow_dir, output_dir,
        get(raw, "alignment_method", nothing), cfg_path,
        String(get(raw, "event", race)), String(get(raw, "track", "")),
        String(get(raw, "date", "")), String(get(raw, "file_stem", "")), drivers, overrides)
end

"""
    list_session_files(cfg::RaceConfig) -> DataFrame

Table of `(name, video, arrow, video_size_mb, arrow_size_mb, has_arrow)` for
every video/arrow pair sharing a stem in the race's data/arrow dirs.
"""
function list_session_files(cfg::RaceConfig)
    mpgs   = sort(filter(f -> endswith(lowercase(f), ".mpg"),   readdir(cfg.data_dir;  join = true)))
    arrows = sort(filter(f -> endswith(lowercase(f), ".arrow"), readdir(cfg.arrow_dir; join = true)))
    arrow_by_stem = Dict(splitext(basename(a))[1] => a for a in arrows)
    rows = NamedTuple[]
    for v in mpgs
        stem = splitext(basename(v))[1]
        a = get(arrow_by_stem, stem, "")
        push!(rows, (name = stem, video = v, arrow = a,
                     video_size_mb = round(filesize(v) / 1e6; digits = 1),
                     arrow_size_mb = isempty(a) ? 0.0 : round(filesize(a) / 1e6; digits = 1),
                     has_arrow     = !isempty(a)))
    end
    return DataFrame(rows)
end
