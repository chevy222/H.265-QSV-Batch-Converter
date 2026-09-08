@echo off
rem =====================================================
rem Batch convert all *.mp4 in the CURRENT directory (where you run it from):
rem   rotate + H.265 (Intel QSV) -> Desktop, same filename
rem   video bitrate = source bitrate, capped at 5000 kbps, fps kept
rem   audio: auto gain to full scale, max amplification without clipping
rem   audio bitrate = source audio bitrate, clamped to 64-192k
rem   rotation: arg/prompt 1 = counter-clockwise 90 deg, 2 = no rotation, default = clockwise 90 deg
rem =====================================================
setlocal
rem preferred location; if not found there, falls back to ffmpeg/ffprobe on PATH (see checks below)
set "FF=D:/software/ffmpeg/bin/ffmpeg.exe"
set "FP=D:/software/ffmpeg/bin/ffprobe.exe"
set "OUTDIR=%USERPROFILE%\Desktop"
set "BRFILE=%TEMP%\h265_br.txt"
set "VOLFILE=%TEMP%\h265_vol.txt"
set "ABRFILE=%TEMP%\h265_abr.txt"
set "OKCNT=0"
set "FAILCNT=0"
set "SKIPCNT=0"

rem --- prefer hardcoded path; only when missing there, fall back to ffmpeg/ffprobe on PATH
if exist "%FF%" if exist "%FP%" goto :tools_ok
where ffmpeg >nul 2>nul
if errorlevel 1 (
    echo [ERROR] ffmpeg not found: neither "%FF%" nor on PATH
    pause
    exit /b 1
)
where ffprobe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] ffprobe not found: neither "%FP%" nor on PATH
    pause
    exit /b 1
)
set "FF=ffmpeg"
set "FP=ffprobe"
echo [INFO] hardcoded path missing, using ffmpeg/ffprobe from PATH
:tools_ok

rem --- rotation mode: 1 = counter-clockwise 90, 2 = none, default (Enter) = clockwise 90
set "ROT=%~1"
if not defined ROT set /p "ROT=Rotation: 1=counter-clockwise 90, 2=no rotation, Enter=clockwise 90 : "
if not defined ROT set "ROT=0"
if not "%ROT%"=="1" if not "%ROT%"=="2" if not "%ROT%"=="0" (
    echo [ERROR] invalid rotation "%ROT%" ^(expected 1 / 2 or Enter^)
    pause
    exit /b 1
)
set "VF=vpp_qsv=transpose=clock:w='floor(iw*min(1,min(1080/ih,1920/iw))/2)*2':h='floor(ih*min(1,min(1080/ih,1920/iw))/2)*2'"
set "ROTTXT=clockwise 90"
if "%ROT%"=="1" set "VF=vpp_qsv=transpose=cclock:w='floor(iw*min(1,min(1080/ih,1920/iw))/2)*2':h='floor(ih*min(1,min(1080/ih,1920/iw))/2)*2'"
if "%ROT%"=="1" set "ROTTXT=counter-clockwise 90"
if "%ROT%"=="2" set "VF=scale_qsv=w='floor(iw*min(1,min(1080/iw,1920/ih))/2)*2':h='floor(ih*min(1,min(1080/iw,1920/ih))/2)*2'"
if "%ROT%"=="2" set "ROTTXT=none"

echo Source : %CD%\
echo FFmpeg : %FF%
echo Output : %OUTDIR%
echo Rotate : %ROTTXT%
echo Audio  : auto max no-clip gain
echo ----------------------------------------
for %%f in ("%CD%\*.mp4") do call :process "%%~ff"

echo.
echo ----------------------------------------
echo All done. OK=%OKCNT%  FAIL=%FAILCNT%  SKIP=%SKIPCNT%
del "%BRFILE%" "%VOLFILE%" "%ABRFILE%" 2>nul
exit /b 0

:process
set "IN=%~1"
set "NAME=%~nx1"
if exist "%OUTDIR%\%NAME%" (
    echo [SKIP] "%NAME%" ^(already on Desktop^)
    set /a SKIPCNT+=1
    goto :eof
)

rem --- probe video stream bitrate, fallback to container bitrate, then 3500k
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
if not defined BR set "BR=3500000" & echo [WARN] "%NAME%" : bitrate unknown, use 3500k
if "%BR%"=="N/A" set "BR=3500000" & echo [WARN] "%NAME%" : bitrate unknown, use 3500k
:havebr
set /a KB=%BR%/1000
if %KB% GTR 5000 (
    set /a KB=5000
    echo [WARN] "%NAME%" : source %BR% bps ^> 5000k, capped
)
set /a MAXKB=KB*12/10
set /a BUFKB=KB*2

rem --- scan audio peak level, compute max no-clip gain (amplify to 0 dBFS)
rem note: no -v error here on purpose, volumedetect prints at info level
set "AUD=-c:a copy"
set "AUDTXT=copy"
set "MAXVOL="
set "GI=0"
"%FF%" -hide_banner -nostats -nostdin -i "%IN%" -vn -af volumedetect -f null NUL 2>&1 | find "max_volume" > "%VOLFILE%"
for /f "usebackq tokens=5" %%a in ("%VOLFILE%") do set "MAXVOL=%%a"
if not defined MAXVOL goto :haveaud
set "GAIN=%MAXVOL:-=%"
for /f "delims=." %%i in ("%GAIN%") do set "GI=%%i"
if "%GI%"=="0" goto :haveaud

rem --- audio bitrate = source audio bitrate, clamped to 64-192k
set "ABR="
"%FP%" -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "%IN%" > "%ABRFILE%" 2>nul
set /p ABR=<"%ABRFILE%"
if not defined ABR set "ABR=128000"
if "%ABR%"=="N/A" set "ABR=128000"
set /a ABK=%ABR%/1000
if %ABK% LSS 64 set /a ABK=64
if %ABK% GTR 192 set /a ABK=192
set "AUD=-af volume=%GAIN%dB -c:a aac -b:a %ABK%k"
set "AUDTXT=+%GAIN%dB @ %ABK%k"
:haveaud
echo [CONV] "%NAME%" : bitrate %KB%k ^(peak %MAXKB%k^), rotate %ROTTXT%, audio %AUDTXT%

rem --- full QSV pipeline: hw decode (hwaccel qsv + hwaccel_output_format qsv keep frames on GPU) + single-filter rotate+scale (aspect kept, no upscale, even dims) + H.265 QSV encode (low_power + veryfast ~1.8x speed, extended BRC), audio auto gain, fps kept, faststart
rem --- NOTE: -look_ahead_depth intentionally omitted (causes "Invalid FrameType:0"/exit 183 on this QSV driver). Source must be h264/hevc; MPEG4 etc. will fail silently (frame=0, exit 0).
"%FF%" -v error -stats -nostdin -y -hwaccel qsv -hwaccel_output_format qsv -i "%IN%" -vf "%VF%" -c:v hevc_qsv -low_power 1 -preset veryfast -extbrc 1 -b:v %KB%k -maxrate %MAXKB%k -bufsize %BUFKB%k %AUD% -movflags +faststart "%OUTDIR%\%NAME%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo [FAIL] "%NAME%" ^(exit code %RC%^)
    if exist "%OUTDIR%\%NAME%" del "%OUTDIR%\%NAME%"
    set /a FAILCNT+=1
) else (
    echo [OK] "%NAME%"
    set /a OKCNT+=1
)
goto :eof
