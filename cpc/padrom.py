#!/usr/bin/env python3
"""Complete un binaire de ROM CPC a 16 Ko (une ROM doit faire exactement
16384 octets pour etre acceptee par la M4).

Usage: python padrom.py IN.raw OUT.ROM
"""
import sys

ROMSIZE = 16384

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
if len(data) > ROMSIZE:
    sys.exit("ERREUR: %d octets, la ROM depasse 16 Ko" % len(data))
open(dst, "wb").write(data + b"\xff" * (ROMSIZE - len(data)))
print("%s : %d octets utiles, complete a %d" % (dst, len(data), ROMSIZE))
