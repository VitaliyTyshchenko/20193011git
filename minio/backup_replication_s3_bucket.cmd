

::   image: pgsty/minio:RELEASE.2026-08-04T00-00-00Z

:: S3 SILO is S3 Interface Libre Object PGSTY is a MinIO fork maintained by PGSTY

:: replication S3 from one bucket to another with batch including object versions
:: Amazon S3 Batch Replication S3 Batch Replication job

:: ID                                      TYPE            USER    STARTED         STATUS
:: replicate-3RhsHzsq2zgeu4P6n9SZMk:-1     replicate       111     3 hours ago     completed
:: replicate-CdVkrVuhQA7zvgPE82qBFm:-1     replicate       111     2 hours ago     completed
:: replicate-K96BvPioSmX2np6ce2NN5r:-1     replicate       111     3 hours ago     completed
:: replicate-SVdkoc62oiujAgxa49vpms:-1     replicate       111     35 minutes ago  completed
:: replicate-TvALUKKHaBVRs7XuPRmbxf:-1     replicate       111     now             in-progress

::   mcli.exe ls --versions local/2234/minioswarm.yaml
:: [2026-10-26 21:56:21 EET]   481B STANDARD 6b8c2330-6deb-4af6-897e-0aba405b7353 v3 PUT minioswarm.yaml
:: [2026-10-26 19:30:06 EET]   461B STANDARD a22b96de-bacb-4bc4-9f72-9dbe9d218347 v2 PUT minioswarm.yaml
:: [2026-10-26 19:27:50 EET]   460B STANDARD 727bdd7f-3744-4b73-90d3-fe3509b184d9 v1 PUT minioswarm.yaml

:: mcli.exe
:: https://silo.pgsty.com/download/#client-binary



@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

if not exist logs mkdir logs

rem Generate one timestamp for both log files
for /f "delims=" %%T in ('powershell -NoProfile -Command "Get-Date -Format 'ddd-MM-dd-yyyy-HH-mm-ss.ff'"') do set "STAMP=%%T"

set "LOG=logs\replication-%STAMP%.log"
set "VERSIONS=logs\replication-source-version-%STAMP%.log"
set "YAML=replicate.yaml"

if not exist "%YAML%" (
    echo ERROR: %YAML% not found.
    pause
    exit /b 1
)

rem Read source and target bucket names from YAML
set "SOURCE="
set "TARGET="
set /a COUNT=0

for /f "tokens=2 delims=:" %%A in ('findstr /r /c:"^[ ]*bucket:" "%YAML%"') do (
    set "VALUE=%%A"
    for /f "tokens=* delims= " %%B in ("!VALUE!") do set "VALUE=%%~B"
    set "VALUE=!VALUE:"=!"
    set /a COUNT+=1
    if !COUNT! EQU 1 set "SOURCE=!VALUE!"
    if !COUNT! EQU 2 set "TARGET=!VALUE!"
)

if not defined SOURCE (
    echo ERROR: Could not read source bucket from %YAML%.
    pause
    exit /b 1
)
if not defined TARGET (
    echo ERROR: Could not read target bucket from %YAML%.
    pause
    exit /b 1
)

rem Record start timestamp and monotonic elapsed-time baseline
for /f "delims=" %%T in ('powershell -NoProfile -Command "[DateTimeOffset]::Now.ToUnixTimeMilliseconds()"') do set "START_MS=%%T"

echo Started: %DATE% %TIME% > "%LOG%"
echo Source: local/!SOURCE! >> "%LOG%"
echo Target: local/!TARGET! >> "%LOG%"
echo Config: %YAML% >> "%LOG%"
echo Version inventory: %VERSIONS% >> "%LOG%"

echo Source: local/!SOURCE!
echo Target: local/!TARGET!
echo Log: %LOG%

echo.
echo [1/3] Recording source objects and versions...
mcli.exe ls --recursive --versions "local/!SOURCE!" > "%VERSIONS%" 2>&1
echo Inventory exit code: !ERRORLEVEL! >> "%LOG%"
echo Inventory saved: %VERSIONS% >> "%LOG%"

echo.
echo [2/3] Starting replication...
mcli.exe batch start local/ "%YAML%" >> "%LOG%" 2>&1
set "RC=!ERRORLEVEL!"

echo Batch start exit code: !RC! >> "%LOG%"
echo Submission finished: %DATE% %TIME% >> "%LOG%"

echo.
echo [3/3] Listing batch jobs...
mcli.exe batch list local/ >> "%LOG%" 2>&1

rem Calculate elapsed time for this script in seconds, minutes and hours
for /f "tokens=1-4 delims=," %%A in ('powershell -NoProfile -Command "$ms = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - %START_MS%; Write-Output ($ms.ToString() + [char]44 + [math]::Round($ms/1000,2) + [char]44 + [math]::Round($ms/60000,2) + [char]44 + [math]::Round($ms/3600000,4))"') do (
    set "ELAPSED_MS=%%A"
    set "ELAPSED_SEC=%%B"
    set "ELAPSED_MIN=%%C"
    set "ELAPSED_HOURS=%%D"
)

echo. >> "%LOG%"
echo ========== SUMMARY ========== >> "%LOG%"
echo Source: local/!SOURCE! >> "%LOG%"
echo Target: local/!TARGET! >> "%LOG%"
echo Finished: %DATE% %TIME% >> "%LOG%"
echo Elapsed milliseconds: !ELAPSED_MS! >> "%LOG%"
echo Elapsed seconds: !ELAPSED_SEC! >> "%LOG%"
echo Elapsed minutes: !ELAPSED_MIN! >> "%LOG%"
echo Elapsed hours: !ELAPSED_HOURS! >> "%LOG%"
echo Batch start exit code: !RC! >> "%LOG%"
echo ============================= >> "%LOG%"

echo.
echo Elapsed: !ELAPSED_SEC! seconds / !ELAPSED_MIN! minutes / !ELAPSED_HOURS! hours
echo Main log: %LOG%
echo Source inventory: %VERSIONS%
echo.
echo NOTE: This elapsed time measures script execution,
echo not the complete background replication duration.
echo Check the final job status to verify replication completion.


mcli.exe batch list local/



endlocal
pause


