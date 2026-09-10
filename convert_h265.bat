@echo off
rem =====================================================
rem Batch convert all *.mp4 in the CURRENT directory (where you run it from):
rem   rotate + H.265 (Intel QSV) -> output dir, same filename
rem   video bitrate = source bitrate, capped at BRCAP kbps
rem   audio: auto gain to full scale, capped at MAXGAIN dB, no clipping
rem   cover art (attached_pic) follows the video: rotated + scaled and
rem   re-encoded as mjpeg when rotating, copied through untouched otherwise
rem   rotation: arg/prompt 1 = counter-clockwise 90, 2 = none, default = clockwise 90
rem
rem Encoder path is negotiated once on the first file, then locked in:
rem   MODE 1  full GPU : qsv decode -> vpp_qsv / scale_qsv -> hevc_qsv   (fastest)
rem   MODE 2  hybrid   : qsv decode -> hwdownload -> CPU filter -> hevc_qsv
rem   MODE 3  software : CPU decode -> CPU filter -> libx265             (always works)
rem Some ffmpeg 9 + older Intel driver combos cannot create the QSV textures
rem that vpp_qsv / scale_qsv need; those machines fall through to mode 2 or 3
rem automatically. Set FORCE_MODE to skip the negotiation.
rem
rem IMPORTANT for maintenance - two cmd traps bite here:
rem  1. every errorlevel test is kept OUTSIDE parentheses. cmd resolves
rem     %ERRORLEVEL% and `if errorlevel` when it parses a bracketed block, so
rem     testing them inside ( ) silently reports a stale value.
rem  2. `if errorlevel 1` means ">= 1". ffmpeg can exit with a LARGE NEGATIVE
rem     code (-1313558101 for the QSV texture failure), which reads as success.
rem     Always compare as text: if not "%ERRORLEVEL%"=="0"
rem =====================================================
setlocal EnableExtensions
rem preferred location; if not found there, falls back to ffmpeg/ffprobe on PATH
set "FF=D:/software/ffmpeg/bin/ffmpeg.exe"
set "FP=D:/software/ffmpeg/bin/ffprobe.exe"

rem ---------------- CONFIG ----------------
rem Output directory. Kept separate from the source dir on purpose: any stray
rem same-named file in the output dir would otherwise silently skip the video.
set "OUTDIR=%USERPROFILE%\Desktop\"
rem Resolution cap. max()/min() makes it orientation independent: the LONG side
rem is capped at MAXW and the SHORT side at MAXH, whichever way the source is.
set "MAXW=1920"
set "MAXH=1080"
rem Video bitrate cap in kbps
set "BRCAP=5000"
rem Fallback bitrate in kbps when the source bitrate cannot be probed
set "BRDEFAULT=3500"
rem Audio gain ceiling in dB. A near-silent source would otherwise be amplified
rem by 50-90 dB and its noise floor would end up at full scale.
set "MAXGAIN=24"
rem Software fallback quality (libx265 CRF, lower = better / bigger)
set "CRF=23"
rem -low_power 1 for the full-GPU path. Some older Intel drivers reject it with
rem "some encoding parameters are not supported by the QSV runtime"; set to 0 then.
set "LOWPOWER=1"
rem 1 = ask for the rotation mode when no argument is given.
rem set /p blocks forever on a non-interactive stdin (scheduled task, pipe, some
rem CI runners). Set ASK=0 - or always pass the mode as %1 - in those cases.
set "ASK=1"
rem 1 = keep the source cover art as attached_pic
set "KEEPCOVER=1"
rem Leave empty to auto-negotiate, or pin to 1 / 2 / 3
set "FORCE_MODE="
if defined FORCE_MODE if not "%FORCE_MODE%"=="1" if not "%FORCE_MODE%"=="2" if not "%FORCE_MODE%"=="3" (
    echo [ERROR] invalid FORCE_MODE "%FORCE_MODE%" ^(expected 1 / 2 / 3^)
    if "%ASK%"=="1" pause
    exit /b 1
)
rem ----------------------------------------

rem unique suffix so two instances running at once do not clobber each other
set "RND=%RANDOM%"
set "BRFILE=%TEMP%\h265_br_%RND%.txt"
set "VOLFILE=%TEMP%\h265_vol_%RND%.txt"
set "ABRFILE=%TEMP%\h265_abr_%RND%.txt"
set "V0FILE=%TEMP%\h265_v0_%RND%.txt"
set "OKCNT=0"
set "FAILCNT=0"
set "SKIPCNT=0"
rem negotiated encoder mode: empty = not probed yet, then 1 / 2 / 3
set "VMODE=%FORCE_MODE%"

rem --- prefer hardcoded path; only when missing there, fall back to ffmpeg/ffprobe on PATH
if exist "%FF%" if exist "%FP%" goto :tools_ok
where ffmpeg >nul 2>nul
if not "%ERRORLEVEL%"=="0" (
    echo [ERROR] ffmpeg not found: neither "%FF%" nor on PATH
    if "%ASK%"=="1" pause
    exit /b 1
)
where ffprobe >nul 2>nul
if not "%ERRORLEVEL%"=="0" (
    echo [ERROR] ffprobe not found: neither "%FP%" nor on PATH
    if "%ASK%"=="1" pause
    exit /b 1
)
set "FF=ffmpeg"
set "FP=ffprobe"
echo [INFO] hardcoded path missing, using ffmpeg/ffprobe from PATH
:tools_ok

rem --- refuse to run when the output dir is the source dir (would mass-SKIP)
for %%d in ("%OUTDIR%") do set "OUTDIR_FULL=%%~fd"
if /i "%CD%"=="%OUTDIR_FULL%" (
    echo [ERROR] source directory and output directory are the same: "%CD%"
    echo         every file would be skipped as "already converted".
    echo         Change OUTDIR or run the script from another folder.
    if "%ASK%"=="1" pause
    exit /b 1
)
if not exist "%OUTDIR%" md "%OUTDIR%"
if not "%ERRORLEVEL%"=="0" (
    echo [ERROR] cannot create output directory "%OUTDIR%"
    if "%ASK%"=="1" pause
    exit /b 1
)

rem --- rotation mode: 1 = counter-clockwise 90, 2 = none, default (Enter) = clockwise 90
set "ROT=%~1"
if not defined ROT if "%ASK%"=="0" set "ROT=0"
if not defined ROT set /p "ROT=Rotation: 1=counter-clockwise 90, 2=no rotation, Enter=clockwise 90 : "
if not defined ROT set "ROT=0"
if not "%ROT%"=="1" if not "%ROT%"=="2" if not "%ROT%"=="0" (
    echo [ERROR] invalid rotation "%ROT%" ^(expected 1 / 2 or Enter^)
    if "%ASK%"=="1" pause
    exit /b 1
)

rem --- scale factor: long side <= MAXW, short side <= MAXH, never upscale.
rem max()/min() keeps this correct for portrait AND landscape sources, for both
rem the vpp_qsv path (scales first, then transposes) and the CPU path
rem (transposes first, then scales).
set "SC=min(1,min(%MAXW%/max(iw,ih),%MAXH%/min(iw,ih)))"
set "WSC=floor(iw*%SC%/2)*2"
set "HSC=floor(ih*%SC%/2)*2"

set "ROTTXT=clockwise 90"
set "ROTQSV=clock"
set "ROTCPU=transpose=clock,"
if "%ROT%"=="1" set "ROTTXT=counter-clockwise 90"
if "%ROT%"=="1" set "ROTQSV=cclock"
if "%ROT%"=="1" set "ROTCPU=transpose=cclock,"
if "%ROT%"=="2" set "ROTTXT=none"
if "%ROT%"=="2" set "ROTQSV="
if "%ROT%"=="2" set "ROTCPU="

rem MODE 1 filters run on the GPU
if "%ROT%"=="2" (
    set "VF1=scale_qsv=w='%WSC%':h='%HSC%'"
) else (
    set "VF1=vpp_qsv=transpose=%ROTQSV%:w='%WSC%':h='%HSC%'"
)
rem MODE 2 / 3 filters run on the CPU (MODE 2 prepends hwdownload,format=nv12)
set "VFCPU=%ROTCPU%scale='%WSC%':'%HSC%'"

rem --- nothing to do?
set "TOTAL=0"
for %%f in ("%CD%\*.mp4") do set /a TOTAL+=1
if "%TOTAL%"=="0" (
    echo [WARN] no *.mp4 files found in "%CD%\"
    goto :summary
)

echo Source : "%CD%\"
echo FFmpeg : "%FF%"
echo Output : "%OUTDIR%"
echo Rotate : %ROTTXT%
echo Cap    : long side %MAXW% / short side %MAXH%, bitrate cap %BRCAP%k
echo Audio  : auto max no-clip gain, ceiling %MAXGAIN% dB
echo Cover  : %KEEPCOVER% ^(1 = keep attached_pic, rotated with the video^)
echo ----------------------------------------
rem the path is passed to :process via the IN variable, NOT as a call
rem argument: `call` re-parses its arguments and doubles every ^ in them,
rem so a filename like "a ^ b.mp4" would no longer match the file on disk.
for %%f in ("%CD%\*.mp4") do (
    set "IN=%%~ff"
    call :process
)

:summary
echo.
echo ----------------------------------------
if defined VMODE (set "MODEDISP=%VMODE%") else (set "MODEDISP=-")
echo All done. OK=%OKCNT%  FAIL=%FAILCNT%  SKIP=%SKIPCNT%  ^(encoder mode %MODEDISP%^)
del "%BRFILE%" "%VOLFILE%" "%ABRFILE%" "%V0FILE%" 2>nul
rem only hold the window open when running interactively (ASK=0 = unattended)
if "%ASK%"=="1" pause
exit /b 0

rem ===================================================================
rem  negotiate the encoder path on the first file, BY encoding it:
rem  enc1/enc2/enc3 run with the full production arguments, so a
rem  successful try IS file 1's real output - the first file is only
rem  encoded once. A failed try leaves a stub that :process deletes.
rem  The first path that succeeds is locked in for the whole batch.
rem ===================================================================
:probe
echo [PROBE] negotiating encoder path on the first file...
call :enc1
if "%ERRORLEVEL%"=="0" (
    set "VMODE=1"
    echo [PROBE] mode 1 locked: full GPU ^(qsv decode, vpp_qsv, hevc_qsv^)
    exit /b 0
)
call :enc2
if "%ERRORLEVEL%"=="0" (
    set "VMODE=2"
    echo [PROBE] mode 2 locked: hybrid ^(qsv decode, CPU filter, hevc_qsv^)
    exit /b 0
)
call :enc3
if "%ERRORLEVEL%"=="0" (
    set "VMODE=3"
    echo [PROBE] mode 3 locked: software ^(CPU decode, CPU filter, libx265^)
    exit /b 0
)
echo [PROBE] all encoder paths failed on the first file
exit /b 1

rem ===================================================================
rem  process one file
rem ===================================================================
:process
rem IN is set by the caller; derive NAME from it
for %%I in ("%IN%") do set "NAME=%%~nxI"
if exist "%OUTDIR%\%NAME%" (
    echo [SKIP] "%NAME%" ^(already in output dir^)
    set /a SKIPCNT+=1
    goto :eof
)

rem --- probe video stream bitrate, fallback to container bitrate, then default
set "BR="
"%FP%" -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "%IN%" > "%BRFILE%" 2>nul
set /p BR=<"%BRFILE%"
if not defined BR goto :fallback
if "%BR%"=="N/A" goto :fallback
goto :havebr
:fallback
set "BR="
"%FP%" -v error -show_entries format=bit_rate -of csv=p=0 "%IN%" > "%BRFILE%" 2>nul
set /p BR=<"%BRFILE%"
if not defined BR set "BR=N/A"
if "%BR%"=="N/A" set "BR=%BRDEFAULT%000" & echo [WARN] "%NAME%" : bitrate unknown, use %BRDEFAULT%k
:havebr
set /a KB=%BR%/1000
if %KB% GTR %BRCAP% (
    set /a KB=%BRCAP%
    echo [WARN] "%NAME%" : source %BR% bps ^> %BRCAP%k, capped
)
set /a MAXKB=KB*12/10
set /a BUFKB=KB*2

rem --- locate the real video stream. Cover art can sit at v:0 (yt-dlp often
rem writes it first) and must never be fed through the rotate/scale filter.
rem Probed even when KEEPCOVER=0: the real stream must still be located, or a
rem cover-first file would encode its cover as the only video stream.
set "MAINV=0"
set "OTHERV=1"
set "V0C="
"%FP%" -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "%IN%" > "%V0FILE%" 2>nul
set /p V0C=<"%V0FILE%"
if /i "%V0C%"=="mjpeg" set "MAINV=1" & set "OTHERV=0"
if /i "%V0C%"=="png"   set "MAINV=1" & set "OTHERV=0"
if /i "%V0C%"=="bmp"   set "MAINV=1" & set "OTHERV=0"
if /i "%V0C%"=="gif"   set "MAINV=1" & set "OTHERV=0"

rem --- scan audio peak level, compute max no-clip gain (amplify to 0 dBFS)
rem note: no -v error here on purpose, volumedetect prints at info level.
rem findstr (not find) because Git Bash / Cygwin put their own find on PATH.
set "AUD=-c:a:0 copy"
set "AUDTXT=copy"
set "MAXVOL="
set "GI=0"
"%FF%" -hide_banner -nostats -nostdin -noautorotate -i "%IN%" -vn -af volumedetect -f null NUL 2>&1 | findstr /c:"max_volume" > "%VOLFILE%"
for /f "usebackq tokens=5" %%a in ("%VOLFILE%") do set "MAXVOL=%%a"
if not defined MAXVOL goto :haveaud
rem A positive or zero peak means the source already clips; amplifying would only
rem clip harder. This sign check must happen before the minus sign is stripped.
if not "%MAXVOL:~0,1%"=="-" (
    echo [WARN] "%NAME%" : peak %MAXVOL% dB, already at or over full scale, audio copied
    goto :haveaud
)
set "GAIN=%MAXVOL:-=%"
for /f "delims=." %%i in ("%GAIN%") do set "GI=%%i"
if "%GI%"=="0" goto :haveaud
rem GTR alone would miss GI == MAXGAIN with a fraction on top (a -24.7 dB
rem peak with MAXGAIN=24); GEQ catches that. The second test spares an exact
rem MAXGAIN.0 peak, which needs no capping.
if %GI% GEQ %MAXGAIN% if not "%GAIN%"=="%MAXGAIN%.0" (
    set "GAIN=%MAXGAIN%"
    echo [WARN] "%NAME%" : peak %MAXVOL% dB needs more than %MAXGAIN% dB, gain capped
)

rem --- audio bitrate = source audio bitrate, clamped to 64-192k
set "ABR="
"%FP%" -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "%IN%" > "%ABRFILE%" 2>nul
set /p ABR=<"%ABRFILE%"
if not defined ABR set "ABR=128000"
if "%ABR%"=="N/A" set "ABR=128000"
set /a ABK=%ABR%/1000
if %ABK% LSS 64 set /a ABK=64
if %ABK% GTR 192 set /a ABK=192
set "AUD=-af volume=%GAIN%dB -c:a:0 aac -b:a %ABK%k"
set "AUDTXT=+%GAIN%dB @ %ABK%k"
:haveaud
echo [CONV] "%NAME%" : bitrate %KB%k ^(peak %MAXKB%k^), rotate %ROTTXT%, audio %AUDTXT%

set "LPOPT="
if "%LOWPOWER%"=="1" set "LPOPT=-low_power 1"
rem When rotating, the cover must follow the video. -hwaccel qsv hw-decodes
rem the cover (mjpeg/png) into QSV frames that CPU filters cannot consume, so
rem the cover is taken from a second software-only input (DIN) and re-encoded
rem as high-quality mjpeg - a filtered stream cannot be stream-copied.
rem NOTE: the DIN line intentionally uses the UNQUOTED set form. The quoted
rem form set "DIN=-i "%IN%"" nests quotes, leaving the expanded path in an
rem unquoted region - a filename with ( ) or & then corrupts the block
rem ("\file was unexpected at this time") or silently truncates DIN. With
rem set DIN=-i "%IN%" the path sits inside one quoted region and parens,
rem ampersands and spaces all survive. Verified by test.
set "DIN="
if "%KEEPCOVER%"=="1" (
    if "%ROT%"=="2" (
        set "MAPS=-map 0:v:%MAINV% -map 0:v:%OTHERV%? -map 0:a:0?"
        set "COVER=-c:v:1 copy -disposition:v:1 attached_pic"
    ) else (
        set "MAPS=-map 0:v:%MAINV% -map 1:v:%OTHERV%? -map 0:a:0?"
        set "COVER=-filter:v:1 %VFCPU% -c:v:1 mjpeg -q:v:1 2 -disposition:v:1 attached_pic"
        set DIN=-i "%IN%"
    )
) else (
    set "MAPS=-map 0:v:%MAINV% -map 0:a:0?"
    set "COVER="
)

rem :probe already encodes the first file with the winning encN, so only
rem dispatch when a mode is already locked. Nothing inside the parens reads
rem ERRORLEVEL, per the trap note at the top of this file.
if defined VMODE (
    if "%VMODE%"=="1" call :enc1
    if "%VMODE%"=="2" call :enc2
    if "%VMODE%"=="3" call :enc3
) else (
    call :probe
)
if not "%ERRORLEVEL%"=="0" (set "RC=1") else (set "RC=0")

rem guard against the silent "frame=0 but exit 0" case: a failed run can still
rem leave an empty or truncated file, so check the size, not just ERRORLEVEL
set "OSIZE=0"
if exist "%OUTDIR%\%NAME%" for %%A in ("%OUTDIR%\%NAME%") do set "OSIZE=%%~zA"
if "%RC%"=="0" if %OSIZE% LSS 1024 (
    echo [FAIL] "%NAME%" ^(output is only %OSIZE% bytes, encoder reported success^)
    set "RC=1"
)
if not "%RC%"=="0" (
    echo [FAIL] "%NAME%" ^(exit code %RC%^)
    if exist "%OUTDIR%\%NAME%" del "%OUTDIR%\%NAME%"
    set /a FAILCNT+=1
) else (
    echo [OK] "%NAME%" ^(%OSIZE% bytes^)
    set /a OKCNT+=1
)
goto :eof

rem ===================================================================
rem  enc1 / enc2 / enc3 - one ffmpeg call each, exit code left in ERRORLEVEL
rem  %MAPS% %COVER% %DIN% %LPOPT% must already be set (done in :process)
rem ===================================================================
:enc1
rem full GPU: qsv decode -> vpp_qsv / scale_qsv -> hevc_qsv
"%FF%" -v error -stats -nostdin -y -noautorotate -hwaccel qsv -hwaccel_output_format qsv -i "%IN%" %DIN% ^
    %MAPS% -filter:v:0 "%VF1%" ^
    -c:v:0 hevc_qsv %LPOPT% -preset veryfast -extbrc 1 ^
    -b:v %KB%k -maxrate %MAXKB%k -bufsize %BUFKB%k -tag:v:0 hvc1 ^
    %COVER% %AUD% -movflags +faststart "%OUTDIR%\%NAME%"
exit /b

:enc2
rem hybrid: qsv decode -> hwdownload -> CPU filter -> hevc_qsv
rem -hwaccel qsv hands QSV frames to the filter graph even without
rem -hwaccel_output_format qsv, so hwdownload is mandatory before CPU filters.
"%FF%" -v error -stats -nostdin -y -noautorotate -hwaccel qsv -i "%IN%" %DIN% ^
    %MAPS% -filter:v:0 "hwdownload,format=nv12,%VFCPU%" ^
    -c:v:0 hevc_qsv -preset veryfast -extbrc 1 ^
    -b:v %KB%k -maxrate %MAXKB%k -bufsize %BUFKB%k -tag:v:0 hvc1 ^
    %COVER% %AUD% -movflags +faststart "%OUTDIR%\%NAME%"
exit /b

:enc3
rem software fallback: CPU decode -> CPU filter -> libx265
"%FF%" -v error -stats -nostdin -y -noautorotate -i "%IN%" %DIN% ^
    %MAPS% -filter:v:0 "%VFCPU%" ^
    -c:v:0 libx265 -crf %CRF% -preset medium -tag:v:0 hvc1 ^
    %COVER% %AUD% -movflags +faststart "%OUTDIR%\%NAME%"
exit /b
