@echo off
rem Build de tcpecho : assemblage -> liens -> binaire -> en-tete AMSDOS
cd /d "%~dp0"
sdasz80 -o tcpecho.rel tcpecho.s || exit /b 1
sdcc -o tcpecho.ihx --no-std-crt0 -mz80 tcpecho.rel
if not exist tcpecho.ihx exit /b 1
python ..\m4rom\ihx2bin.py tcpecho.ihx tcpecho.raw || exit /b 1
python make_amsdos.py tcpecho.raw TCPECHO.BIN 4000 4000 || exit /b 1
echo.
echo OK : depuis m4term, faire   putrun TCPECHO.BIN
