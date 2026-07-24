#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""m4term — terminal PC pour Amstrad CPC + M4 Board.

Pilote la carte M4 via son API HTTP (les mêmes points d'entrée que cpcxfer
et l'interface web). Python 3 pur, aucune dépendance externe.

Usage :
    python m4term.py              (utilise la dernière IP mémorisée)
    python m4term.py 192.168.1.27
    python m4term.py cpc6128

Tape 'help' dans le terminal pour la liste des commandes.
"""

import json
import os
import shlex
import sys
import urllib.parse
import urllib.request
import uuid

CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "m4term.json")
TIMEOUT = 8


class M4:
    """Client HTTP minimal pour l'API de la M4 Board."""

    def __init__(self, host):
        self.host = host

    def _get(self, path, **params):
        url = "http://%s/%s" % (self.host, path)
        if params:
            # quote_via=quote : espaces en %20 (pas en '+', que le firmware ne décode pas)
            url += "?" + urllib.parse.urlencode(params, quote_via=urllib.parse.quote)
        req = urllib.request.Request(url, headers={"User-Agent": "m4term"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.read()

    def _post_multipart(self, path, field, filename, data, extra=None):
        boundary = "----m4term%s" % uuid.uuid4().hex
        body = b""
        for k, v in (extra or {}).items():
            body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                     % (boundary, k, v)).encode()
        body += ("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
                 "Content-Type: application/octet-stream\r\n\r\n"
                 % (boundary, field, filename)).encode()
        body += data + ("\r\n--%s--\r\n" % boundary).encode()
        req = urllib.request.Request(
            "http://%s/%s" % (self.host, path), data=body,
            headers={"User-Agent": "m4term",
                     "Content-Type": "multipart/form-data; boundary=%s" % boundary})
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read()

    # --- opérations -------------------------------------------------
    def ls(self, folder):
        self._get("config.cgi", ls=folder)
        return self._get("sd/m4/dir.txt").decode("latin-1", "replace")

    def upload(self, local, dest_dir):
        with open(local, "rb") as f:
            data = f.read()
        remote = (dest_dir.rstrip("/") + "/" + os.path.basename(local)).replace("//", "/")
        self._post_multipart("upload.html", "upfile", remote, data)
        return remote, len(data)

    def download(self, remote):
        return self._get("sd/" + urllib.parse.quote(remote.lstrip("/")))

    def run(self, cpcfile):
        self._get("config.cgi", run2=cpcfile)

    def cd_cpc(self, folder):
        self._get("config.cgi", cd2=folder)

    def mkdir(self, folder):
        self._get("config.cgi", mkdir=folder if folder.startswith("/") else "/" + folder)

    def rm(self, target):
        self._get("config.cgi", rm=target)

    def reset_cpc(self):
        self._get("config.cgi?cres")

    def reset_m4(self):
        self._get("config.cgi?mres")

    def pause(self):
        self._get("config.cgi", chlt="CPC Pause")

    def rom_install(self, local, slot, name):
        with open(local, "rb") as f:
            data = f.read()
        self._post_multipart("roms.shtml", "uploadedfile", "rom.bin", data,
                             extra={"slotnum": str(slot), "slotname": name})

    def rom_delete(self, slot):
        self._get("roms.shtml", rmsl=str(slot))


HELP = """\
Commandes (chemins relatifs au repertoire courant du terminal) :
  ls [dossier]          liste un repertoire de la SD
  cd <dossier>          change le repertoire courant du terminal (.. et / acceptes)
  cdc [dossier]         change le repertoire courant SUR LE CPC (defaut: celui du terminal)
  put <fichier> [dest]  envoie un fichier PC -> SD
  get <fichier> [local] telecharge SD -> PC
  run <fichier>         lance un programme sur le CPC
  putrun <fichier>      put + run en une commande (dev workflow)
  type <fichier>        affiche un fichier texte de la SD
  mkdir <dossier>       cree un repertoire sur la SD
  rm <fichier|dossier>  supprime (dossier vide seulement)
  rom <fichier> <slot> [nom]   installe une ROM dans un slot (0-31)
  delrom <slot>         supprime la ROM du slot
  pause                 met le CPC en pause (repeter pour reprendre)
  reset                 reset du CPC        resetm4   reboot de la M4
  ip <adresse>          change l'IP/nom de la carte (memorise)
  help                  cette aide          quit      sortir
"""


def norm(cwd, path):
    """Résout un chemin relatif au cwd du terminal en chemin absolu SD."""
    if not path:
        return cwd
    p = path if path.startswith("/") else cwd.rstrip("/") + "/" + path
    parts = []
    for seg in p.split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if parts:
                parts.pop()
        else:
            parts.append(seg)
    return "/" + "/".join(parts)


def main():
    host = None
    if len(sys.argv) > 1:
        host = sys.argv[1]
        if host in ("-h", "--help"):
            print(__doc__)
            print(HELP)
            return
    if not host and os.path.exists(CONFIG):
        host = json.load(open(CONFIG)).get("host")
    if not host:
        host = input("Adresse IP (ou nom netbios) de la M4 : ").strip()
    json.dump({"host": host}, open(CONFIG, "w"))

    m4 = M4(host)
    cwd = "/"
    print("m4term — connecte a http://%s   ('help' pour l'aide)" % host)
    try:
        print(m4.ls(cwd))
    except Exception as e:
        print("! Carte injoignable (%s) — verifie l'IP et l'alimentation. 'ip <adresse>' pour corriger." % e)

    while True:
        try:
            line = input("M4 %s> " % cwd).strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line:
            continue
        try:
            # antislash Windows -> slash (shlex traiterait \ comme echappement ;
            # open() et l'API M4 acceptent les / partout)
            args = shlex.split(line.replace("\\", "/"))
        except ValueError as e:
            print("! erreur de syntaxe:", e)
            continue
        cmd, rest = args[0].lower(), args[1:]

        try:
            if cmd in ("quit", "exit", "q"):
                break
            elif cmd == "help":
                print(HELP)
            elif cmd == "ip":
                host = rest[0]
                m4 = M4(host)
                json.dump({"host": host}, open(CONFIG, "w"))
                print("-> http://%s" % host)
            elif cmd == "ls":
                print(m4.ls(norm(cwd, rest[0] if rest else "")))
            elif cmd == "cd":
                cwd = norm(cwd, rest[0] if rest else "/")
            elif cmd == "cdc":
                target = norm(cwd, rest[0] if rest else "")
                m4.cd_cpc(target)
                print("CPC -> %s" % target)
            elif cmd == "put":
                dest = norm(cwd, rest[1] if len(rest) > 1 else "")
                remote, size = m4.upload(rest[0], dest)
                print("%s -> %s (%d octets)" % (rest[0], remote, size))
            elif cmd == "get":
                remote = norm(cwd, rest[0])
                data = m4.download(remote)
                local = rest[1] if len(rest) > 1 else os.path.basename(remote)
                open(local, "wb").write(data)
                print("%s -> %s (%d octets)" % (remote, local, len(data)))
            elif cmd == "type":
                print(m4.download(norm(cwd, rest[0])).decode("latin-1", "replace"))
            elif cmd == "run":
                target = norm(cwd, rest[0])
                m4.run(target)
                print("RUN %s" % target)
            elif cmd == "putrun":
                remote, size = m4.upload(rest[0], cwd)
                m4.run(remote)
                print("%s -> %s (%d octets) + RUN" % (rest[0], remote, size))
            elif cmd == "mkdir":
                m4.mkdir(norm(cwd, rest[0]))
            elif cmd == "rm":
                m4.rm(norm(cwd, rest[0]))
            elif cmd == "rom":
                name = rest[2] if len(rest) > 2 else os.path.splitext(os.path.basename(rest[0]))[0]
                m4.rom_install(rest[0], int(rest[1]), name)
                print("ROM %s -> slot %s (%s) — reset M4 pour appliquer" % (rest[0], rest[1], name))
            elif cmd == "delrom":
                m4.rom_delete(int(rest[0]))
                print("slot %s vide — reset M4 pour appliquer" % rest[0])
            elif cmd == "pause":
                m4.pause()
            elif cmd == "reset":
                m4.reset_cpc()
                print("reset CPC envoye")
            elif cmd == "resetm4":
                m4.reset_m4()
                print("reboot M4 envoye")
            else:
                print("? commande inconnue ('help')")
        except IndexError:
            print("! argument manquant ('help' pour la syntaxe)")
        except FileNotFoundError as e:
            print("! fichier local introuvable:", e.filename)
        except Exception as e:
            print("! erreur:", e)


if __name__ == "__main__":
    main()
