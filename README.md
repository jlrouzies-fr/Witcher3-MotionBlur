# Object Motion Blur (Witcher 3 Remastered, ReShade add-on)

Per-pixel motion blur for The Witcher 3 Remastered 5.0 (DirectX 12): characters, creatures, weapons and the camera blur
along the motion vectors the game already computes for DLSS. The blur runs inside the render pipeline, before bloom,
tonemapping and the UI.

Requirements: ReShade 6.x with full add-on support, DirectX 12, DLSS upscaling. Release builds: Nexus Mods.

## Build
1. Visual Studio 2022+ Build Tools (MSVC, x64) and the Windows SDK `dxc.exe`.
2. Edit the `vcvars64.bat` and `dxc.exe` paths at the top of `build.bat`.
3. Run `build.bat` -> `out\ObjectMotionBlur.addon64`; copy it next to ReShade in `bin\x64_dx12`.

ReShade add-on (DirectX 12) for The Witcher 3 Remastered 5.0: per-pixel motion blur from the game's DLSS motion vectors.

## Layout
- `src/motion_blur.cpp` - the add-on: hooks, resource tracking, the 3 compute passes, ReShade overlay settings.
- `shaders/omb.hlsl` - TileMax -> NeighborMax -> Gather (McGuire 2012 / Jimenez 2014 style reconstruction).
- `build.bat` - dxc (cs_6_0) + MSVC; edit the vcvars64.bat and dxc.exe paths for your machine.
- `external/` - ReShade API headers (BSD-3 / MIT) and Dear ImGui headers (MIT), unmodified.

## How it finds things (per frame)
1. ConvertMotionVectors compute shader (DXBC CRC32 0x9F1C32F1) writes the motion vectors (r16g16_float, render resolution).
   The game runs it once (its own motion blur option off) or twice (on).
2. The MV texture and the depth (r32_g8_typeless) are copied into the add-on's own textures at the next
   draw / dispatch / copy, or when the MV leaves UAV state (the game reuses that memory after DLSS).
3. When the DLSS output leaves UAV state (DLSS done, before any post-process or UI pass reads it), it is copied to a
   scratch texture and the blur passes write the result back into the DLSS output in place.
   Accepted formats: r16g16b16a16_float (seen in SDR and HDR), r11g11b10_float, r10g10b10a2_unorm, r8g8b8a8_unorm.
4. The game's compute state (pipeline, root signature, tables, root CBVs, constants) is rebound afterwards.
   If the command list has no compute tables, a game descriptor table seen earlier is bound once to switch the
   shader-visible heap back.

## Log: bin\x64_dx12\ObjectMotionBlur.log
- `DLSS output found: ...` - injection point found (format shown as fNN = reshade::api::format).
- `first blurred frame` / `frames with blur so far: N` - working.
- `blur skipped (n): <reason>` - first 20, then every 1000th:
  - `DLSS output without this frame's depth` - normal on loading screens; constant = depth not found.
  - `no game descriptor table seen yet (heap restore)` - the command list state could not be restored safely.
  - `DLSS output without UAV usage` - the DLSS output cannot be written by compute.
- `skipped upscaled UAV texture (unsupported format): ...` - a candidate DLSS output in a format not handled yet.

## Diagnostics (environment variables, set before starting the game)
- `MB_TRACE_FRAMES=700` (comma list) - dumps every barrier / draw / dispatch / copy of those frames into the log.
- `OMB_DEBUG=1` - debug view on at start (also a checkbox in the overlay): hue = direction, brightness = length.
- `OMB_PROBE=1` - every 15th frame, reads back one row of motion vectors / depth and logs the values.
- `OMB_TEST_CYCLE_MS=1000` - alternates blur off / on every N ms (logged), for A/B captures.
