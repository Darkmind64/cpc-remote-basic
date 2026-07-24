@echo off
rem Build de la sonde de pagination M4 (T2 / T3) -> PROBE.BIN, ORG &8000
cd /d "%~dp0"
sdasz80 -o probe.rel probe.s || exit /b 1
sdcc -o probe.ihx --no-std-crt0 -mz80 probe.rel
if not exist probe.ihx exit /b 1
python ..\m4rom\ihx2bin.py probe.ihx probe.raw || exit /b 1
python make_amsdos.py probe.raw PROBE.BIN 8000 8000 || exit /b 1
echo.
echo OK : sur le CPC   MEMORY ^&3FFF
echo      depuis m4term putrun ../cpc/PROBE.BIN
