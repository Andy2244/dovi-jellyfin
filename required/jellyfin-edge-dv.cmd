@echo off
setlocal enabledelayedexpansion
REM Relaunch self minimized so the console isn't in the foreground.
if not "%~1"=="min" (
  start "" /min cmd /c "%~f0" min
  exit /b
)
REM Start the OPTIONAL HDR gate service if present and not already up. Path is relative
REM to this script (repo layout); without the gate DV still works -- you manage HDR yourself.
REM Gate options (e.g. -RefreshOnly, -DefaultHdr, -DisplayId 2) go into GATE_ARGS.
set "GATE=%~dp0..\optional\jf-hdr-gate.ps1"
set "GATE_ARGS="
if exist "%GATE%" curl -s -m 2 http://127.0.0.1:17999/health >nul 2>&1 || start "" /min pwsh -ExecutionPolicy Bypass -File "%GATE%" %GATE_ARGS%
REM Launch Edge with the Dolby Vision feature flags, fullscreen at the Jellyfin web UI.
REM Edge must be closed first or the flags are ignored, so close any running instance
REM and wait until every msedge.exe is gone (a straggler swallows the flags).
REM Graceful close first (no /F) or Edge complains about an unclean shutdown; force
REM only the stragglers after 6s.
taskkill /IM msedge.exe >nul 2>&1
set /a tries=0
:waitkill
tasklist /FI "IMAGENAME eq msedge.exe" | find /I "msedge.exe" >nul || goto launch
set /a tries+=1
if !tries! equ 6 taskkill /F /IM msedge.exe >nul 2>&1
if !tries! geq 10 goto launch
timeout /t 1 /nobreak >nul
goto waitkill
:launch
start "" "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" --enable-features=AllowClearDolbyVisionViaMFT,AllowClearDolbyVisionInMseWhenPlatformEncryptedDvEnabled,PlatformEncryptedDolbyVision,MediaFoundationClearPlayback --start-fullscreen --autoplay-policy=no-user-gesture-required "http://localhost:8096/web/"
REM cursor-refresh workaround: a fresh Edge window needs one real mouse event before it can hide
REM the arrow; nudge a few times so a slow jellyfin boot can't outrun a one-shot
for /l %%i in (1,1,3) do (
  timeout /t 6 /nobreak >nul
  curl -s -m 2 -X POST http://127.0.0.1:17999/nudge >nul 2>&1
)
