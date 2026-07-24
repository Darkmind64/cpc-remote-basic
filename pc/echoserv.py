#!/usr/bin/env python3
"""Serveur de test pour tcpcli (CPC + M4 Board) — le PC ecoute, le CPC se connecte.
Usage: python echoserv.py [port]     (6128 par defaut)

Ce que le CPC envoie s'affiche ici ; ce que tu tapes part vers le CPC.
Ctrl+C pour quitter."""
import os
import socket
import sys
import threading
import unicodedata


SPECIALS = {
    "œ": "oe", "Œ": "OE",   # œ Œ
    "€": "EUR", "°": "deg", # € °
    "«": '"', "»": '"',     # « »
    "‘": "'", "’": "'",     # ' '
    "“": '"', "”": '"',     # " "
    "–": "-", "—": "-",     # – —
    "…": "...",                   # …
}


def to_cpc(text):
    """Translittère vers l'ASCII affichable par le CPC (é->e, ç->c, etc.)."""
    for k, v in SPECIALS.items():
        text = text.replace(k, v)
    norm = unicodedata.normalize("NFKD", text)
    out = []
    for ch in norm:
        if unicodedata.combining(ch):
            continue                      # accents décomposés : on les jette
        out.append(ch if " " <= ch <= "~" else "?")
    return "".join(out)

port = int(sys.argv[1]) if len(sys.argv) > 1 else 6128

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("", port))
srv.listen(1)
print("En attente du CPC sur le port %d... (lance TCPCLI.BIN sur le CPC)" % port)

conn, addr = srv.accept()
print("CPC connecte depuis %s:%d — tape du texte, il s'affichera sur le CPC" % addr)


def reader():
    while True:
        try:
            data = conn.recv(4096)
        except OSError:
            break
        if not data:
            print("\n(connexion fermee par le CPC)")
            os._exit(0)
        print("CPC> %s" % data.decode("latin-1", "replace"), end="", flush=True)


threading.Thread(target=reader, daemon=True).start()

try:
    while True:
        line = input()
        conn.sendall((to_cpc(line) + "\r\n").encode("ascii"))
except (KeyboardInterrupt, EOFError):
    print("\nau revoir")
finally:
    conn.close()
    srv.close()
