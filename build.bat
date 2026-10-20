@echo off
rem Builds out\ObjectMotionBlur.addon64 (shaders with dxc, add-on with MSVC). Does not install anything.
setlocal
cd /d "%~dp0"
call "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set DXC="C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\dxc.exe"
set EXT=external
if not exist out mkdir out
set GEN=out\shaders_gen.h
type nul > %GEN%
for %%E in (TileMax NeighborMax Gather) do (
  %DXC% -nologo -T cs_6_0 -E %%E -O3 -Qstrip_debug -Qstrip_reflect -Vn g_cs_%%E -Fh out\cs_%%E.h shaders\omb.hlsl || exit /b 1
  type out\cs_%%E.h >> %GEN%
)
cl /nologo /LD /EHsc /O2 /MD /W3 /std:c++20 /D_CRT_SECURE_NO_WARNINGS /I%EXT%\reshade\include /I%EXT%\imgui /Iout /Foout\ /Fdout\ src\motion_blur.cpp /link /OUT:out\ObjectMotionBlur.addon64 /IMPLIB:out\motion_blur.lib kernel32.lib user32.lib || exit /b 1
echo Built out\ObjectMotionBlur.addon64
endlocal
