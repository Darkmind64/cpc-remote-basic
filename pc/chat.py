#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""chat — terminal bidirectionnel PC <-> CPC via M4 Board (etape 3a).

Le CPC (tcpterm) est SERVEUR sur le port 6128 ; ce script s'y connecte.
- Ce que tu tapes ici (+ Entree) est envoye au CPC et s'affiche sur son ecran.
- Ce qui s'affiche a l'ecran du CPC arrive ici.

Usage: python chat.py <ip-du-cpc> [port]
"""
import socket
import sys
import threading
import unicodedata

SPECIALS = {
    "œ": "oe", "Œ": "OE", "€": "EUR", "°": "deg",
    "«": '"', "»": '"', "‘": "'", "’": "'",
    "“": '"', "”": '"', "–": "-", "—": "-", "…": "...",
}


def to_cpc(text):
    """Translittere vers l'ASCII affichable par le CPC (e->e, c->c...)."""
    for k, v in SPECIALS.items():
        text = text.replace(k, v)
    out = []
    for ch in unicodedata.normalize("NFKD", text):
        if unicodedata.combining(ch):
            continue
        out.append(ch if " " <= ch <= "~" else "?")
    return "".join(out)


if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(1)

host = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 6128

s = socket.create_connection((host, port), timeout=5)
s.settimeout(None)
print("Connecte a %s:%d — tape du texte (Entree pour envoyer, Ctrl+C pour quitter)\n"
      % (host, port))


def reader():
    while True:
        try:
            data = s.recv(4096)
        except OSError:
            break
        if not data:
            print("\n(connexion fermee par le CPC)")
            break
        text = data.decode("latin-1").replace("\r\n", "\n").replace("\r", "\n")
        sys.stdout.write(text)
        sys.stdout.flush()


threading.Thread(target=reader, daemon=True).start()

try:
    while True:
        line = input()
        s.sendall((to_cpc(line) + "\r\n").encode("ascii"))
except (KeyboardInterrupt, EOFError):
    print("\nau revoir")
finally:
    s.close()
