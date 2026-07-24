@echo off
rem Bissection du reboot au retour au BASIC : T2A / T2B / T2C, ORG &8000
cd /d "%~dp0"
call :one t2a T2A || exit /b 1
call :one t2b T2B || exit /b 1
call :one t2c T2C || exit /b 1
echo.
echo OK : T2A.BIN T2B.BIN T2C.BIN
goto :eof

:one
sdasz80 -o %1.rel %1.s || exit /b 1
sdcc -o %1.ihx --no-std-crt0 -mz80 %1.rel || exit /b 1
python ..\m4rom\ihx2bin.py %1.ihx %1.raw || exit /b 1
python make_amsdos.py %1.raw %2.BIN 8000 8000 || exit /b 1
goto :eof
