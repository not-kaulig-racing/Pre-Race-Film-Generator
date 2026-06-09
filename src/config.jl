using TOML

"""
TOML config loader.

Looks for (in order):
1. `\$PRERACEFILM_CONFIG` env var
2. `config.local.toml` in the repo root  (gitignored — your personal paths)
3. `config.toml`       in the repo root  (committed — team defaults)

Values from the chosen file are surfaced via `config_get(section, key)`.
The data-dir resolution in `src/datadir.jl` checks ENV first, then the
config, so an env var always wins over the file.
"""

const _CONFIG_CACHE = Ref{Union{Nothing,Dict{String,Any}}}(nothing)
const _CONFIG_PATH  = Ref{String}("")

function _config_search_paths()
    root = abspath(joinpath(@__DIR__, ".."))
    paths = String[]
    e = get(ENV, "PRERACEFILM_CONFIG", "")
    !isempty(e) && push!(paths, e)
    push!(paths, joinpath(root, "config.local.toml"))
    push!(paths, joinpath(root, "config.toml"))
    return paths
end

"""
    load_config(; force=false) -> Dict{String,Any}

Read the first config file that exists. Caches the result; pass
`force=true` to re-read (e.g. after editing the TOML).
"""
function load_config(; force::Bool = false)
    !force && _CONFIG_CACHE[] !== nothing && return _CONFIG_CACHE[]
    for p in _config_search_paths()
        if isfile(p)
            _CONFIG_CACHE[] = TOML.parsefile(p)
            _CONFIG_PATH[]  = p
            return _CONFIG_CACHE[]
        end
    end
    _CONFIG_CACHE[] = Dict{String,Any}()
    _CONFIG_PATH[]  = ""
    return _CONFIG_CACHE[]
end

"""
    config_path() -> String

The path of the config file that was loaded, or `""` if none was found.
"""
config_path() = (load_config(); _CONFIG_PATH[])

"""
    config_get(section, key, default=nothing)

Pull `[section].key` from the loaded config. `default` is returned if the
section or key is missing.
"""
function config_get(section::AbstractString, key::AbstractString, default = nothing)
    sec = get(load_config(), section, nothing)
    sec isa AbstractDict || return default
    return get(sec, key, default)
end
