#!/usr/bin/env python3
"""Transforme un binaire en directives .db pour l'inclure dans une ROM.

Sert a embarquer le coeur resident (cterm2.raw, assemble pour &8000)
dans la ROM de fond, qui le recopiera en RAM a l'appel de |TERM.

Usage: python bin2inc.py IN.raw OUT.inc SYMBOLE_TAILLE
"""
import sys

src, dst, sizesym = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(src, "rb").read()

with open(dst, "w") as f:
    f.write("; GENERE par bin2inc.py — NE PAS EDITER A LA MAIN\n")
    f.write("; source : %s (%d octets)\n" % (src, len(data)))
    f.write("%s\t.equ\t%d\n\n" % (sizesym, len(data)))
    for i in range(0, len(data), 16):
        row = ",".join("0x%02X" % b for b in data[i:i + 16])
        f.write("\t\t.db\t%s\n" % row)

print("%s : %d octets embarques" % (dst, len(data)))
