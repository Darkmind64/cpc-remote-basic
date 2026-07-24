#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""basicterm — BASIC distant : tape des commandes ici, elles s'executent
sur le CPC et leur sortie revient (via le terminal resident).

Principe (aucune injection clavier, que des mecanismes eprouves) :
  1. le CPC tourne un mini shell BASIC :   10 |TERMWAIT
                                           20 RUN"cmd.bas"
  2. ce script envoie par la SOCKET le contenu de cmd.bas (ta commande
     PUIS un RUN"shell.bas" pour relancer la boucle), termine par 0x1A ;
  3. |TERMWAIT recoit, ecrit cmd.bas lui-meme via l'API fichier de la
     carte, et rend la main -> le BASIC execute, puis se remet en attente.

Un seul maitre parle a la carte a la fois : c'est la regle d'or de la M4.

Prealables sur le CPC :
    MEMORY &97FF
    |TERMON              (puis connecter ce script)
    RUN"shell.bas"

Usage : python basicterm.py <ip-du-cpc>
"""
import socket
import sys
import threading
import unicodedata
import urllib.parse
import urllib.request
import uuid

SHELL = 'shell.bas'
CMDFILE = 'cmd.bas'


def to_cpc(text):
    """Translittere vers l'ASCII affichable par le CPC."""
    out = []
    for ch in unicodedata.normalize("NFKD", text):
        if unicodedata.combining(ch):
            continue
        out.append(ch if " " <= ch <= "~" else "?")
    return "".join(out)


def upload(host, name, data):
    """Depose un fichier a la racine de la SD (meme API que m4term)."""
    boundary = "----bt%s" % uuid.uuid4().hex
    body = ("--%s\r\nContent-Disposition: form-data; name=\"upfile\"; "
            "filename=\"/%s\"\r\nContent-Type: application/octet-stream\r\n\r\n"
            % (boundary, name)).encode() + data + ("\r\n--%s--\r\n" % boundary).encode()
    req = urllib.request.Request(
        "http://%s/upload.html" % host, data=body,
        headers={"User-Agent": "basicterm",
                 "Content-Type": "multipart/form-data; boundary=%s" % boundary})
    urllib.request.urlopen(req, timeout=20).read()


def ascii_bas(lines):
    """Programme BASIC au format ASCII : texte brut, lignes terminees par
    CR LF, marqueur de fin 0x1A.

    IMPORTANT : un .BAS ASCII se depose SANS en-tete AMSDOS. C'est
    justement l'absence d'en-tete valide qui fait traiter le fichier
    comme du texte ; avec en-tete, le BASIC le lit comme du tokenise et
    sort "Syntax error" sur un numero de ligne aberrant."""
    return ("\r\n".join(lines) + "\r\n\x1a").encode("ascii")


if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(1)
host = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 6128

# --- shell resident cote CPC (a deposer une fois)
shell = ascii_bas(["10 |TERMWAIT", '20 RUN"%s"' % CMDFILE])
print("Depot de %s ..." % SHELL)
upload(host, SHELL, shell)

s = socket.create_connection((host, port), timeout=5)
s.settimeout(None)
print("Connecte a %s:%d\n" % (host, port))
print('Sur le CPC :  RUN"%s"   puis tape tes commandes ici.\n' % SHELL)


def reader():
    while True:
        try:
            data = s.recv(4096)
        except OSError:
            break
        if not data:
            print("\n(connexion fermee par le CPC)")
            break
        sys.stdout.write(data.decode("latin-1").replace("\r\n", "\n").replace("\r", "\n"))
        sys.stdout.flush()


threading.Thread(target=reader, daemon=True).start()

try:
    while True:
        line = to_cpc(input()).strip()
        if not line:
            continue
        # On envoie le CONTENU de cmd.bas par la SOCKET : c'est le CPC
        # (|TERMWAIT) qui ecrit le fichier lui-meme. Surtout PAS d'upload
        # HTTP ici : la carte serait sollicitee par le PC pendant que le
        # CPC l'interroge -> deux maitres a la fois, et ca plante.
        s.sendall(ascii_bas(["1 " + line, '2 RUN"%s"' % SHELL]))
except (KeyboardInterrupt, EOFError):
    print("\nau revoir")
finally:
    s.close()
