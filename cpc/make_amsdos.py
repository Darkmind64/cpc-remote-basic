#!/usr/bin/env python3
"""Ajoute un en-tête AMSDOS (128 octets) à un binaire CPC.
Usage: python make_amsdos.py IN.BIN OUT.BIN LOAD EXEC   (adresses en hexa, ex 4000)"""
import os
import sys

src, dst = sys.argv[1], sys.argv[2]
load = int(sys.argv[3], 16)
exec_ = int(sys.argv[4], 16)

data = open(src, "rb").read()
name, ext = (os.path.basename(dst).upper().split(".") + [""])[:2]
if len(name) > 8 or len(ext) > 3:
    sys.exit("ERREUR: nom non conforme 8.3 (%s.%s). Le remote-run de la M4 "
             "plante sur les noms > 8 caracteres. Choisis un nom plus court."
             % (name, ext))

h = bytearray(128)
h[0] = 0                                   # user
h[1:9] = name[:8].ljust(8).encode()        # nom
h[9:12] = ext[:3].ljust(3).encode()        # extension
h[18] = 2                                  # type : binaire
h[19:21] = len(data).to_bytes(2, "little") # longueur bloc
h[21:23] = load.to_bytes(2, "little")      # adresse de chargement
h[23] = 0xFF                               # premier bloc
h[24:26] = len(data).to_bytes(2, "little") # longueur logique
h[26:28] = exec_.to_bytes(2, "little")     # point d'entree
h[64:67] = len(data).to_bytes(3, "little") # longueur reelle (24 bits)
h[67:69] = (sum(h[:67]) & 0xFFFF).to_bytes(2, "little")  # checksum

open(dst, "wb").write(bytes(h) + data)
print("%s : %d octets (+128 d'en-tete AMSDOS), load=&%04X exec=&%04X"
      % (dst, len(data), load, exec_))
