@echo off
rem Build de tcpcli : usage  build_cli.cmd <ip-du-PC>   ex: build_cli.cmd 192.168.1.50
if "%~1"=="" (
    echo Usage : build_cli.cmd ^<ip-du-PC^>    ex : build_cli.cmd 192.168.1.50
    exit /b 1
)
cd /d "%~dp0"
sdasz80 -o tcpcli.rel tcpcli.s || exit /b 1
sdcc -o tcpcli.ihx --no-std-crt0 -mz80 tcpcli.rel
if not exist tcpcli.ihx exit /b 1
python ..\m4rom\ihx2bin.py tcpcli.ihx tcpcli.raw || exit /b 1
python -c "import sys;d=bytearray(open('tcpcli.raw','rb').read());d[2:6]=bytes(int(x) for x in reversed(sys.argv[1].split('.')));open('tcpcli.raw','wb').write(bytes(d));print('IP du PC patchee :',sys.argv[1])" %1 || exit /b 1
python make_amsdos.py tcpcli.raw TCPCLI.BIN 4000 4000 || exit /b 1
echo.
echo OK : 1^) lancer  python ..\pc\echoserv.py   sur le PC
echo      2^) depuis m4term :  putrun ../cpc/TCPCLI.BIN
