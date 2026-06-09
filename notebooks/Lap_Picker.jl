### A Pluto.jl notebook ###
# v0.20.0

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running outside of
# Pluto, the following 'mock version' of @bind gives bound variables a default
# value (instead of an error).
macro bind(def, element)
    #! format: off
    return quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el, :default) ? Base.get(el, :default, iv(el)) : iv(el)
        el
    end
    #! format: on
end

# ╔═╡ 00000000-0000-0000-0000-000000000001
begin
    using Pkg
    Pkg.activate(@__DIR__)
end

# ╔═╡ 00000000-0000-0000-0000-000000000002
using PreRaceFilm, PlutoUI, HypertextLiteral

# ╔═╡ 00000000-0000-0000-0000-000000000010
md"""
# Pre-Race Film Generator
Pick a session, choose a lap, render an overlay video.

This notebook is a thin UI over `PreRaceFilm.jl`. The same `generate_lap_video`
function is what the CLI (`bin/pre_race_film.jl`) and the agent integration
call — so everything you do here is reproducible from code or JSON config.
"""

# ╔═╡ 00000000-0000-0000-0000-000000000020
md"""## 1. Session library

This week's external drive folder. Change once at the start of the week —
all the file pickers below will follow it.
"""

# ╔═╡ 00000000-0000-0000-0000-000000000021
@bind data_dir_input TextField((80, 1); default = data_dir())

# ╔═╡ 00000000-0000-0000-0000-000000000022
@bind arrow_dir_input TextField((80, 1); default = arrow_dir())

# ╔═╡ 00000000-0000-0000-0000-000000000025
session_table = let
    isempty(data_dir_input) ? nothing :
        list_session_files(data = data_dir_input,
                           arrow = isempty(arrow_dir_input) ? data_dir_input : arrow_dir_input)
end;

# ╔═╡ 00000000-0000-0000-0000-000000000026
session_table === nothing ? md"_Point at your weekly drive folder above._" : session_table

# ╔═╡ 00000000-0000-0000-0000-000000000027
session_options = session_table === nothing ? String[] :
    [row.video => row.name * (row.has_arrow ? "" : " ⚠️ no .arrow")
     for row in eachrow(session_table)];

# ╔═╡ 00000000-0000-0000-0000-000000000028
@bind video_path Select(isempty(session_options) ? [""=>"(none)"] : session_options)

# ╔═╡ 00000000-0000-0000-0000-000000000029
arrow_path = let
    if session_table === nothing || isempty(video_path)
        ""
    else
        idx = findfirst(==(video_path), session_table.video)
        idx === nothing ? "" : session_table.arrow[idx]
    end
end;

# ╔═╡ 00000000-0000-0000-0000-000000000030
md"""## 2. Backend & track auto-detection"""

# ╔═╡ 00000000-0000-0000-0000-000000000031
backend_info = let
    bk = detect_backend()
    @htl """
    <div style="padding:8px;background:#1a1a1a;color:#eee;font-family:monospace;border-radius:6px">
      <b>ffmpeg:</b> $(bk.exe)<br>
      <b>encoder:</b> $(bk.encoder) $(bk.has_nvenc ? "(NVENC available)" : "")<br>
      <b>hwaccel:</b> $(bk.has_nvdec ? "NVDEC" : "software decode")
    </div>
    """
end

# ╔═╡ 00000000-0000-0000-0000-000000000032
detected_track = isfile(arrow_path) ? something(auto_detect_track(arrow_path), "(unrecognised)") : "—";

# ╔═╡ 00000000-0000-0000-0000-000000000033
md"Auto-detected track from filename: **$(detected_track)**"

# ╔═╡ 00000000-0000-0000-0000-000000000040
md"""## 3. Detected laps"""

# ╔═╡ 00000000-0000-0000-0000-000000000041
laps_df = isfile(arrow_path) ? detect_laps(arrow_path; drop_partial = true) : nothing;

# ╔═╡ 00000000-0000-0000-0000-000000000042
laps_df === nothing ? md"_Drop an `.arrow` path above to see laps._" : laps_df

# ╔═╡ 00000000-0000-0000-0000-000000000043
lap_options = laps_df === nothing ? Int[] : laps_df.lap;

# ╔═╡ 00000000-0000-0000-0000-000000000044
@bind lap_number Select([l => "Lap $l ($(round(d;digits=2)) s, max $(round(Int,m)) mph)"
                          for (l, d, m) in zip(lap_options,
                                                laps_df === nothing ? Float64[] : laps_df.duration,
                                                laps_df === nothing ? Float64[] : laps_df.max_mph)])

# ╔═╡ 00000000-0000-0000-0000-000000000050
md"""## 4. Overlay labels and options"""

# ╔═╡ 00000000-0000-0000-0000-000000000051
@bind driver_label TextField((40, 1); default = "")

# ╔═╡ 00000000-0000-0000-0000-000000000052
@bind event_label TextField((40, 1); default = detected_track == "—" ? "" : detected_track)

# ╔═╡ 00000000-0000-0000-0000-000000000053
@bind fps Select([25, 30, 60]; default = 25)

# ╔═╡ 00000000-0000-0000-0000-000000000054
@bind align_mode Select([
    :seed => "Seed (fast, race-start + audio-onset)",
    :none => "None (assume aligned)",
    :auto => "Auto FFT cross-correlation (slow, lower confidence on noisy audio)",
]; default = :seed)

# ╔═╡ 00000000-0000-0000-0000-000000000055
@bind manual_offset NumberField(-3600.0:1.0:3600.0; default = 0.0)

# ╔═╡ 00000000-0000-0000-0000-000000000056
@bind use_manual_offset CheckBox(default = false)

# ╔═╡ 00000000-0000-0000-0000-000000000060
md"""## 5. Output path"""

# ╔═╡ 00000000-0000-0000-0000-000000000061
default_out = let
    base = isfile(arrow_path) ? splitext(basename(arrow_path))[1] : "lap"
    joinpath(dirname(@__DIR__), "out", "$(base)_lap$(lap_number).mp4")
end;

# ╔═╡ 00000000-0000-0000-0000-000000000062
@bind output_path TextField((80, 1); default = default_out)

# ╔═╡ 00000000-0000-0000-0000-000000000070
md"""## 6. Render"""

# ╔═╡ 00000000-0000-0000-0000-000000000071
@bind go Button("Render lap")

# ╔═╡ 00000000-0000-0000-0000-000000000072
render_result = let
    go  # take dependency on the button
    if !isfile(video_path) || !isfile(arrow_path) || lap_number === nothing
        md"_Set video, arrow, and lap above first._"
    else
        try
            generate_lap_video(
                video_path, arrow_path, lap_number;
                output_path     = output_path,
                track           = :auto,
                driver_label    = driver_label,
                event_label     = event_label,
                fps             = fps,
                audio_alignment = use_manual_offset ? Float64(manual_offset) : align_mode,
            )
        catch e
            md"**Render failed:** `$(sprint(showerror, e))`"
        end
    end
end

# ╔═╡ 00000000-0000-0000-0000-000000000073
render_result isa NamedTuple ? @htl("""
    <div style="background:#0e2a0e;color:#cfe;padding:10px;border-radius:6px;font-family:monospace">
      ✅ Rendered <b>$(render_result.output_path)</b><br>
      $(round(render_result.file_size_mb;digits=1)) MB • $(render_result.total_frames) frames • $(round(render_result.lap_time_s;digits=2)) s lap<br>
      encoder: $(render_result.encoder) ($(render_result.ffmpeg_backend))<br>
      audio offset: $(round(render_result.audio_offset_s;digits=2)) s
    </div>
    """) : render_result

# ╔═╡ 00000000-0000-0000-0000-000000000074
if render_result isa NamedTuple && isfile(render_result.output_path)
    LocalResource(render_result.output_path)
end

# ╔═╡ Cell order:
# ╟─00000000-0000-0000-0000-000000000010
# ╟─00000000-0000-0000-0000-000000000020
# ╠═00000000-0000-0000-0000-000000000021
# ╠═00000000-0000-0000-0000-000000000022
# ╟─00000000-0000-0000-0000-000000000025
# ╟─00000000-0000-0000-0000-000000000026
# ╟─00000000-0000-0000-0000-000000000027
# ╠═00000000-0000-0000-0000-000000000028
# ╟─00000000-0000-0000-0000-000000000029
# ╟─00000000-0000-0000-0000-000000000030
# ╟─00000000-0000-0000-0000-000000000031
# ╟─00000000-0000-0000-0000-000000000032
# ╟─00000000-0000-0000-0000-000000000033
# ╟─00000000-0000-0000-0000-000000000040
# ╠═00000000-0000-0000-0000-000000000041
# ╟─00000000-0000-0000-0000-000000000042
# ╟─00000000-0000-0000-0000-000000000043
# ╠═00000000-0000-0000-0000-000000000044
# ╟─00000000-0000-0000-0000-000000000050
# ╠═00000000-0000-0000-0000-000000000051
# ╠═00000000-0000-0000-0000-000000000052
# ╠═00000000-0000-0000-0000-000000000053
# ╠═00000000-0000-0000-0000-000000000054
# ╠═00000000-0000-0000-0000-000000000055
# ╠═00000000-0000-0000-0000-000000000056
# ╟─00000000-0000-0000-0000-000000000060
# ╟─00000000-0000-0000-0000-000000000061
# ╠═00000000-0000-0000-0000-000000000062
# ╟─00000000-0000-0000-0000-000000000070
# ╠═00000000-0000-0000-0000-000000000071
# ╠═00000000-0000-0000-0000-000000000072
# ╟─00000000-0000-0000-0000-000000000073
# ╠═00000000-0000-0000-0000-000000000074
# ╠═00000000-0000-0000-0000-000000000001
# ╠═00000000-0000-0000-0000-000000000002
