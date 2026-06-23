# Pre-Race Film Generator

Julia pipeline that takes a session-length in-car video (`.mpg`/`.mp4`) + ERDP
telemetry (`.arrow`), aligns them — by audio↔RPM correlation **or**, for feeds
with no usable engine audio, by camera-rotation↔gyro correlation from the video
itself — trims to a chosen lap, and renders a 1280×720 H.264 overlay video
showing the track map, six telemetry traces (MPH, RPM, GEAR, THROTTLE, BRAKE,
STEERING) and their current values.

## Setup

Two TOML files configure everything — no environment variables.

**`config.local.toml`** (repo root, gitignored — your machine's paths). Copy
`config.example.toml` and edit:

```toml
[paths]
data_root  = "D:/Race_Videos"      # parent of per-race folders: data_root/<race>/
# ...or a single one-off folder instead:
# data_dir = "D:/Race_Videos/25POC1"
output_dir = "out"                 # rendered .mp4s (relative paths → repo root)

[current]
race = "25POC1"                    # default race for getConfig()
```

**`<race_dir>/race.toml`** (per race: drivers, labels, alignment, overrides):

```toml
event            = "25POC1"
track            = "Pocono"
file_stem        = "19_POCONO_car{car}_sessionID2"   # {car} → car number
alignment_method = "audio"         # seed | audio | visual | <offset_s>  (required)

[drivers]
9  = "Chase Elliott"
10 = "Aric Almirola"

[cars.10]                          # per-car overrides
alignment_method = -1100.0         # a baked manual offset for this car
stem             = "10_POCONO_alt_naming"
```

`getConfig` resolves these into a `RaceConfig` once; everything downstream takes
that object. A missing data dir, or an unknown `alignment_method`, errors at load.

## Usage

### REPL (primary)

```julia
using PreRaceFilm
cfg = getConfig("25POC1")          # or getConfig() to use [current].race

list_session_files(cfg)            # video/arrow pairs in this race's folders
list_cars(cfg)                     # cars known for this race

# One lap, one car
generate_lap_video(cfg, 9, 119; alignment_method = :audio)

# Whole race — alignment resolved once per car, reused across that car's laps
process(cfg; cars = :all, laps = :all, alignment_method = :audio)
process(cfg; cars = [9, 10], laps = [50, 119], template = :minimal,
        alignment_method = :seed)
```

`alignment_method` is **required** — pass it, or set it in `race.toml` (race-wide
or per `[cars.N]`). There is no silent default; if it's set nowhere, the call
errors and tells you the options.

### CLI (scripts, agent integration)

```powershell
julia --project=. bin/pre_race_film.jl render --race 25POC1 --car 9 --lap 119 --align audio
julia --project=. bin/pre_race_film.jl laps  --arrow "D:\Race_Videos\25POC1\...car9....arrow"
julia --project=. bin/pre_race_film.jl backend     # resolved ffmpeg / NVENC info
```

All commands print JSON to stdout (errors to stderr, non-zero exit). For
embedding in other Julia tools: `list_laps_json(arrow_path)` and
`generate_lap_video_json(config::Dict)` (keys: `car`, `lap`, optional `race`,
`alignment_method`, `fps`, …).

## Alignment

Telemetry and video clocks rarely start together. `alignment_method` picks the
estimator, resolved as **explicit arg → per-car `race.toml` → race-wide
`race.toml`**, and is required. Sign convention: `offset_s` means
`telemetry_time = video_time + offset_s`.

| Method | What it does | When to use |
|---|---|---|
| `:seed` | `find_race_start(rpm) − find_audio_active_start(video)` | Fast and robust — a good default for engine-audio clips |
| `:audio` (`:auto` alias) | FFT cross-correlation of RPM vs firing-band audio envelope | Clip has clean **engine** audio. Sub-sample refined (parabolic). |
| `:visual` | Camera yaw/pitch **rate** (phase-correlation on a horizon crop) ↔ chassis gyros `ChassisRotVel{Yaw,Pitch}IDR` | Clip has **no usable engine audio** (e.g. broadcast/radio in-car feeds) |
| `:none` | No shift | Streams are already aligned |
| `Float64` | Manual override in seconds | Reuse a known offset, tuning, or fallback |

There is no ground truth — validate by **convergence** of methods that don't
share a failure mode. On Watkins Glen car 16, `:audio` gave −594.0 s and
`:visual` −594.5 s independently. `:visual` self-checks via `channel_spread_s`
(yaw vs pitch agreement; ≲0.05 s = a clean lock).

```julia
cfg = getConfig("25POC1")

# No engine audio (e.g. a dolby/broadcast in-car feed): use the video itself
generate_lap_video(cfg, 9, 119; alignment_method = :visual)

# Reuse a known offset (skips re-alignment entirely)
generate_lap_video(cfg, 9, 119; alignment_method = -208.49)
```

## GPU acceleration

The package uses the **system `ffmpeg`** — install the
[gyan.dev](https://www.gyan.dev/ffmpeg/builds/) Windows build (it ships
NVENC/NVDEC) and put it on `PATH` (or a standard install dir). On a machine with
an Nvidia GPU it encodes with `h264_nvenc` and decodes the source with NVDEC
(`-hwaccel cuda`); otherwise it falls back to `libx264`.

```powershell
julia --project=. bin/pre_race_film.jl backend
```

## Project layout

```
src/
  PreRaceFilm.jl     top-level module
  math.jl            shared numeric primitives (resample, parabolic peak, moving average)
  runtime.jl         system ffmpeg + NVENC/NVDEC resolution
  config.jl          config load + RaceConfig + getConfig + session listing
  telemetry.jl       Arrow load, lap detection, channel binding
  race.jl            per-race accessors + process()
  track_map.jl       track_map_db.json + position lookup
  alignment.jl       audio extract, RPM xcorr (threaded STFT), seed/audio offset
  visual_align2.jl   camera-rotation↔gyro alignment (the :visual mode)
  render.jl          Cairo overlay compositor
  render_minimal.jl  minimal overlay template
  pipeline.jl        generate_lap_video + JSON helpers
bin/
  pre_race_film.jl   CLI
Track Maps/
  track_map_db.json  track outlines + arc-length tables
```

## Adding a new track

Drop the outline into `Track Maps/track_map_db.json` under a new key with
`x`, `y`, `s` (arc length, ft) arrays and `total_dist_ft`. Then add an
alias to `TRACK_KEY_MAP` in `src/track_map.jl` so the filename
auto-detector recognises it.
