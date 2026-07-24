#!/usr/bin/env python3
"""Client de test pour tcpecho (CPC + M4 Board).
Usage: python echotest.py <ip-du-cpc> [port]     (port 6128 par defaut)

Tape du texte : il s'affiche sur l'ecran du CPC et revient en echo ici.
Ctrl+C pour quitter."""
import socket
import sys
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
            continue
        out.append(ch if " " <= ch <= "~" else "?")
    return "".join(out)

host = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 6128

s = socket.create_connection((host, port), timeout=5)
s.settimeout(2)
print("Connecte a %s:%d — tape du texte (Ctrl+C pour quitter)" % (host, port))

try:
    while True:
        line = input("> ")
        s.sendall((to_cpc(line) + "\r\n").encode("ascii"))
        try:
            data = s.recv(4096)
            if not data:
                print("(connexion fermee par le CPC)")
                break
            print("echo: %r" % data.decode("latin-1"))
        except socket.timeout:
            print("(pas d'echo recu — le CPC est-il dans la boucle ?)")
except (KeyboardInterrupt, EOFError):
    print("\nau revoir")
finally:
    s.close()
