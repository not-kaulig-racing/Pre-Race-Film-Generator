module PreRaceFilm

using Printf

include("runtime.jl")
include("config.jl")
include("telemetry.jl")
include("datadir.jl")
include("track_map.jl")
include("alignment.jl")
include("render.jl")
include("pipeline.jl")

export detect_laps,
       load_telemetry,
       load_track_map,
       align_audio_rpm,
       find_race_start,
       find_audio_active_start,
       generate_lap_video,
       generate_lap_video_json,
       list_laps_json,
       default_ranges,
       default_db_path,
       detect_backend,
       auto_detect_track,
       data_dir,
       arrow_dir,
       output_dir,
       set_data_dir,
       list_session_files,
       load_config,
       config_path,
       config_get

end # module
