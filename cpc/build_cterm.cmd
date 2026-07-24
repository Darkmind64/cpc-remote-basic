@echo off
rem Build du terminal resident CTERM -> CTERM.BIN, ORG &8000
cd /d "%~dp0"
sdasz80 -o cterm.rel cterm.s || exit /b 1
sdcc -o cterm.ihx --no-std-crt0 -mz80 cterm.rel || exit /b 1
python ..\m4rom\ihx2bin.py cterm.ihx cterm.raw || exit /b 1
python make_amsdos.py cterm.raw CTERM.BIN 8000 8000 || exit /b 1
echo.
echo OK : depuis m4term  put ../cpc/CTERM.BIN
echo      sur le CPC     MEMORY ^&7FFF : LOAD"CTERM.BIN" : CALL ^&8000
