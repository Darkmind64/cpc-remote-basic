#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mirror_view — visualise le miroir d'ecran du CPC (etape 2).

Le CPC (tcpmirror) est SERVEUR sur le port 6128 ; ce script s'y connecte
et affiche tout ce que le CPC envoie (= ce qui s'ecrit sur son ecran).

Usage: python mirror_view.py <ip-du-cpc> [port]
"""
import socket
import sys

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(1)

host = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 6128

s = socket.create_connection((host, port), timeout=5)
s.settimeout(None)   # une fois connecte, attendre les donnees sans limite de temps
print("Connecte a %s:%d — affichage du miroir ecran du CPC (Ctrl+C pour quitter)\n"
      % (host, port))
print("---- ecran CPC ----")
try:
    while True:
        data = s.recv(4096)
        if not data:
            print("\n---- connexion fermee par le CPC ----")
            break
        # le CPC envoie du CR (0x0D) seul en fin de ligne : on normalise
        text = data.decode("latin-1").replace("\r\n", "\n").replace("\r", "\n")
        sys.stdout.write(text)
        sys.stdout.flush()
except KeyboardInterrupt:
    print("\nau revoir")
finally:
    s.close()
