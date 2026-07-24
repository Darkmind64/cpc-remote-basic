@echo off
rem Build du terminal resident CTERM2 (modele Duke) -> CTERM2.BIN, ORG &8000
cd /d "%~dp0"
sdasz80 -o cterm2.rel cterm2.s || exit /b 1
sdcc -o cterm2.ihx --no-std-crt0 -mz80 cterm2.rel || exit /b 1
python ..\m4rom\ihx2bin.py cterm2.ihx cterm2.raw || exit /b 1
python make_amsdos.py cterm2.raw CTERM2.BIN 8000 8000 || exit /b 1
echo.
echo OK : put ../cpc/CTERM2.BIN puis  MEMORY ^&7FFF : LOAD"CTERM2.BIN" : CALL ^&8000
