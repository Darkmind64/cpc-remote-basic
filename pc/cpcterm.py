#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cpcterm — piloter le BASIC du CPC depuis Windows.

Cote CPC : le resident `cpc/cterm2.s` + le shell BASIC `TERM.BAS`. Le CPC
est SERVEUR sur le port 6128. On lui envoie une LIGNE de commande BASIC
terminee par CR ; le shell la recupere (RSX |TERMIO), l'ecrit dans
cmd.bas et l'execute par CHAIN MERGE. Toute la sortie ecran du CPC
remonte ici.

    (CPC)  MEMORY &7FFF : RUN"term.bas"      <- tout-en-un
    (PC)   python cpcterm.py <ip-du-cpc>             console directe
           python cpcterm.py <ip-du-cpc> --telnet    relais telnet (2323)

En mode telnet, se connecter avec PuTTY (Raw ou Telnet) sur
127.0.0.1:2323. Le shell CPC ne renvoie pas d'echo des touches : laisser
le client faire son echo local (on ne negocie donc PAS WILL ECHO).

NOTE : l'injection clavier PC->CPC s'est revelee impossible sur cette
carte (voir docs/09 §6) ; c'est pourquoi on pilote un shell BASIC ligne
par ligne plutot que de simuler des frappes.
"""
import argparse
import socket
import sys
import threading
import time

# Le CPC accumule les octets jusqu'au CR (tampon de ligne de 128 octets)
# et le shell interroge la carte a ~10 Hz : on peut envoyer une ligne
# d'un trait, sans cadencer caractere par caractere.
KEY_DELAY = 0.02
MAX_LINE = 100          # ne pas depasser le tampon de ligne du CPC


def cpc_to_text(data):
    """Rend lisible le flux CPC : CR seul -> saut de ligne, codes de
    controle ecartes sauf CR/LF/TAB."""
    out = []
    for b in data:
        if b in (10, 13, 9):
            out.append(chr(b))
        elif 32 <= b < 127:
            out.append(chr(b))
        elif b >= 128:
            out.append(chr(b))       # jeu de caracteres CPC : on laisse passer
        # les autres (codes de controle et leurs parametres) sont ignores
    return "".join(out).replace("\r\n", "\n").replace("\r", "\n")


def to_cpc(ch):
    """Traduit une frappe PC en code CPC."""
    if ch == "\n" or ch == "\r":
        return b"\r"                 # ENTER
    if ch == "\x7f" or ch == "\b":
        return b"\x7f"               # DEL
    if ch == "\x1b":
        return b"\xfc"               # ESC (code CPC)
    b = ch.encode("latin-1", "ignore")
    return b if len(b) == 1 else b""


class Link:
    """Connexion au CPC, avec envoi cadence."""

    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.settimeout(None)
        self.lock = threading.Lock()
        self.eat_nl = False     # avaler le saut de ligne suivant

    def send_key(self, data):
        with self.lock:
            # Le BASIC emet un saut de ligne juste apres la commande,
            # alors que la console locale est deja passee a la ligne
            # quand on a appuye sur Entree : on avale ce premier saut
            # pour ne pas afficher une ligne blanche a chaque commande.
            if data.endswith(b"\r"):
                self.eat_nl = True
            for i in range(0, len(data), MAX_LINE):
                self.sock.sendall(data[i:i + MAX_LINE])
                time.sleep(KEY_DELAY)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Capture:
    """Enregistre la sortie du CPC dans un fichier local.

    Sert a extraire un programme PROPRE : le shell vit en lignes 60000+,
    `list` n'affiche que les lignes de l'utilisateur (10-59899), et on
    enregistre ce listing ici. Le .bas obtenu ne contient donc AUCUNE
    ligne du terminal et peut tourner seul.
    """

    def __init__(self):
        self.fh = None
        self.path = None

    def start(self, path):
        self.stop()
        self.fh = open(path, "w", encoding="latin-1", newline="\r\n")
        self.path = path

    def feed(self, text):
        if self.fh:
            self.fh.write(text)

    def stop(self):
        if self.fh:
            self.fh.close()
            done, self.fh, self.path = self.path, None, None
            return done
        return None


def pump_output(link, write, capture=None):
    """Boucle de lecture : ecran du CPC -> sortie locale (+ capture)."""
    while True:
        data = link.sock.recv(4096)
        if not data:
            write("\n---- connexion fermee par le CPC ----\n")
            return
        text = cpc_to_text(data)
        if link.eat_nl and text.startswith("\n"):
            text = text[1:]         # saut de ligne d'apres-commande
            link.eat_nl = False
        elif text.strip():
            link.eat_nl = False
        if capture:
            capture.feed(text)
        write(text)


# --------------------------------------------------------------- console
def run_console(host, port):
    link = Link(host, port)
    cap = Capture()
    print("Connecte a %s:%d — commandes CPC, ou :aide (Ctrl+C pour quitter)\n"
          % (host, port))

    def write(text):
        sys.stdout.write(text)
        sys.stdout.flush()

    t = threading.Thread(target=pump_output, args=(link, write, cap),
                         daemon=True)
    t.start()
    try:
        while t.is_alive():
            line = sys.stdin.readline()
            if not line:
                break
            cmd = line.strip()

            # --- commandes locales (cote PC), prefixees par ':'
            if cmd == ":aide":
                write(":get <fichier>  enregistre la suite dans un .bas\n"
                      ":fin            arrete l'enregistrement\n"
                      "Pour extraire ton programme PROPRE :\n"
                      "  :get prog.bas  puis  list  puis  :fin\n")
                continue
            if cmd.startswith(":get "):
                cap.start(cmd[5:].strip())
                write("[enregistrement -> %s ; tape 'list' puis ':fin']\n"
                      % cap.path)
                continue
            if cmd == ":fin":
                done = cap.stop()
                write("[enregistre : %s]\n" % done if done
                      else "[aucun enregistrement en cours]\n")
                continue

            out = b"".join(to_cpc(c) for c in line)
            link.send_key(out)
    except KeyboardInterrupt:
        pass
    finally:
        cap.stop()
        link.close()
        print("\nau revoir")


# ---------------------------------------------------------------- telnet
def run_telnet(host, port, listen_port):
    link = Link(host, port)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", listen_port))
    srv.listen(1)
    print("Relais telnet pret : connecte-toi sur 127.0.0.1:%d "
          "(PuTTY, mode Telnet ou Raw)" % listen_port)
    print("CPC : %s:%d — Ctrl+C pour arreter" % (host, port))

    try:
        while True:
            cli, addr = srv.accept()
            print("client %s:%d connecte" % addr)
            # On ne negocie PAS WILL ECHO : le shell CPC ne renvoie pas
            # les touches, c'est au client de faire son echo local.
            # WILL SGA seulement (pas de mode ligne cote serveur).
            cli.sendall(b"\xff\xfb\x03")

            stop = threading.Event()

            def to_client():
                try:
                    while not stop.is_set():
                        data = link.sock.recv(4096)
                        if not data:
                            break
                        cli.sendall(cpc_to_text(data).encode("latin-1", "replace"))
                except OSError:
                    pass
                finally:
                    stop.set()

            t = threading.Thread(target=to_client, daemon=True)
            t.start()
            try:
                while not stop.is_set():
                    data = cli.recv(256)
                    if not data:
                        break
                    data = data.replace(b"\xff\xfd", b"").replace(b"\xff\xfb", b"")
                    out = b"".join(to_cpc(chr(b)) for b in data if b != 0)
                    if out:
                        link.send_key(out)
            except OSError:
                pass
            finally:
                stop.set()
                cli.close()
                print("client deconnecte")
    except KeyboardInterrupt:
        print("\nau revoir")
    finally:
        srv.close()
        link.close()


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("host", help="adresse IP du CPC")
    p.add_argument("port", nargs="?", type=int, default=6128)
    p.add_argument("--telnet", action="store_true",
                   help="exposer un serveur telnet local au lieu de la console")
    p.add_argument("--listen", type=int, default=2323,
                   help="port du relais telnet (defaut 2323)")
    args = p.parse_args()

    if args.telnet:
        run_telnet(args.host, args.port, args.listen)
    else:
        run_console(args.host, args.port)


if __name__ == "__main__":
    main()
