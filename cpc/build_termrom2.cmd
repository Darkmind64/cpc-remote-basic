@echo off
rem Build de la ROM de fond TERM2.ROM : compile le coeur cterm2 (ORG &8000),
rem l'embarque en donnees, puis assemble la ROM et la complete a 16 Ko.
cd /d "%~dp0"

echo [1/4] coeur cterm2 (ORG ^&8000)
sdasz80 -o cterm2.rel cterm2.s || exit /b 1
sdcc -o cterm2.ihx --no-std-crt0 -mz80 cterm2.rel
if not exist cterm2.ihx exit /b 1
python ..\m4rom\ihx2bin.py cterm2.ihx cterm2.raw || exit /b 1

echo [2/4] embarquement du coeur
python bin2inc.py cterm2.raw cterm2_blob.inc CORESIZE || exit /b 1

echo [3/4] assemblage de la ROM
sdasz80 -o termrom2.rel termrom2.s || exit /b 1
sdcc -o termrom2.ihx --no-std-crt0 -mz80 termrom2.rel
if not exist termrom2.ihx exit /b 1
python ..\m4rom\ihx2bin.py termrom2.ihx termrom2.raw || exit /b 1

echo [4/4] completion a 16 Ko
python padrom.py termrom2.raw TERM2.ROM || exit /b 1

echo.
echo OK : depuis m4term
echo   put ../cpc/TERM2.ROM
echo   rom ../cpc/TERM2.ROM 3 TERM
echo   resetm4
echo puis sur le CPC : ^|TERM
