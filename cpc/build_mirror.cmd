@echo off
rem Build de tcpmirror (serveur, pas d'IP a patcher)
cd /d "%~dp0"
sdasz80 -o tcpmirror.rel tcpmirror.s || exit /b 1
sdcc -o tcpmirror.ihx --no-std-crt0 -mz80 tcpmirror.rel
if not exist tcpmirror.ihx exit /b 1
python ..\m4rom\ihx2bin.py tcpmirror.ihx tcpmirror.raw || exit /b 1
python make_amsdos.py tcpmirror.raw TCPMIR.BIN 4000 4000 || exit /b 1
echo.
echo OK : 1^) sur le PC   python ..\pc\mirror_view.py ^<ip-du-cpc^>
echo      2^) depuis m4term  putrun ../cpc/TCPMIR.BIN
