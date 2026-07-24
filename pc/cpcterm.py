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
import unicodedata

# Le CPC accumule les octets jusqu'au CR (tampon de ligne de 128 octets)
# et le shell interroge la carte a ~10 Hz : on peut envoyer une ligne
# d'un trait, sans cadencer caractere par caractere.
KEY_DELAY = 0.02
MAX_LINE = 100          # ne pas depasser le tampon de ligne du CPC


# ==================================================================
# Jeu de caracteres du CPC (version FRANCAISE) <-> Unicode
#
# Le CPC n'est pas en Latin-1. Deux ecarts, verifies sur la machine :
#
# 1. ASCII : le generateur de caracteres francais suit l'ISO-646-FR et
#    remplace @ \ { | } par a-grave, c-cedille, e-aigu, u-grave,
#    e-grave. Confirme par ASC("e-aigu") = 123, etc., et a l'ecran.
#    Consequence amusante : la barre des RSX (code 124) s'affiche « u »
#    accentue — d'ou le « uTERM » qu'on lit sur l'ecran du CPC.
#
# 2. Au-dela de 127, le CPC affiche ses propres symboles (blocs
#    semi-graphiques, lettres grecques, fleches) qui n'ont rien a voir
#    avec Latin-1.
#
# On traduit donc explicitement, dans les deux sens.
# ==================================================================
CPC_TO_UNI = {
    # --- substitutions ISO-646-FR (verifiees sur la machine) --------
    # Seules ces cinq positions sont substituees. Verifie a l'ecran :
    # 35, 91, 93, 96 et 126 affichent bien # [ ] ` ~ et NON les
    # £ ° § ¨ de l'ISO-646-FR complet. La table ASCII est donc close.
    0x40: "à", 0x5C: "ç", 0x7B: "é", 0x7C: "ù", 0x7D: "è",

    # --- symboles (releves sur la table imprimee par le CPC) --------
    0xA3: "£", 0xAB: "±", 0xAC: "÷", 0xAF: "¡",

    # --- lettres grecques (176-191) ---------------------------------
    0xB0: "α", 0xB1: "β", 0xB2: "γ", 0xB3: "δ", 0xB4: "ε", 0xB5: "θ",
    0xB6: "λ", 0xB7: "μ", 0xB8: "π", 0xB9: "σ", 0xBA: "φ", 0xBB: "ψ",
    0xBC: "χ", 0xBD: "ω", 0xBE: "Σ", 0xBF: "Ω",

    # --- blocs semi-graphiques (128-143) : equivalents Unicode ------
    0x80: "▘", 0x81: "▝", 0x82: "▀", 0x83: "▖", 0x84: "▌", 0x85: "▞",
    0x86: "▛", 0x87: "▗", 0x88: "▚", 0x89: "▐", 0x8A: "▜", 0x8B: "▄",
    0x8C: "▙", 0x8D: "▟", 0x8E: "█", 0x8F: "░",
    0x7F: "▒",
}
UNI_TO_CPC = {v: k for k, v in CPC_TO_UNI.items()}


def cpc_to_text(data):
    """Flux CPC -> texte lisible.

    CR seul -> saut de ligne. Les codes de controle (< 32) sont ecartes
    sauf CR/LF/TAB. Au-dela de 127, on traduit via la table ; ce qui n'y
    figure pas est rendu par <NN> plutot que d'etre affiche faux ou
    perdu en silence.
    """
    out = []
    for b in data:
        if b in (10, 13, 9):
            out.append(chr(b))
        elif b in CPC_TO_UNI:
            out.append(CPC_TO_UNI[b])
        elif 32 <= b < 127:
            out.append(chr(b))
        elif b >= 128:
            out.append("<%02X>" % b)     # symbole CPC non cartographie
        # les autres (codes de controle et leurs parametres) sont ignores
    return "".join(out).replace("\r\n", "\n").replace("\r", "\n")


def to_cpc(ch):
    """Traduit une frappe PC en code CPC. Rend b"" si le caractere
    n'existe pas sur le CPC (l'appelant le signale)."""
    if ch == "\n" or ch == "\r":
        return b"\r"                 # ENTER
    if ch == "\x7f" or ch == "\b":
        return b"\x7f"               # DEL
    if ch == "\x1b":
        return b"\xfc"               # ESC (code CPC)
    if ch in UNI_TO_CPC:             # accentuees et symboles CPC
        return bytes([UNI_TO_CPC[ch]])
    o = ord(ch)
    if 32 <= o < 127:                # ASCII simple
        return bytes([o])
    # Repli : oter l'accent plutot que de perdre le caractere. Le CPC
    # francais n'a que a-grave, c-cedille, e-aigu, u-grave, e-grave ;
    # un i-circonflexe deviendrait sinon un trou (« Nmes »). On rend
    # la lettre de base, ce qui donne « Nimes » — degrade mais lisible.
    base = unicodedata.normalize("NFD", ch)[0]
    if base != ch and 32 <= ord(base) < 127:
        return bytes([ord(base)])
    return b""                       # vraiment inconnu du CPC


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

            pieces = [(c, to_cpc(c)) for c in line]
            subst, lost = {}, set()
            for c, b in pieces:
                if c in "\r\n":
                    continue
                if not b:
                    lost.add(c)
                elif cpc_to_text(b) != c:
                    subst[c] = cpc_to_text(b)
            if subst:
                write("[remplace : %s]\n"
                      % "  ".join("%s>%s" % kv for kv in sorted(subst.items())))
            if lost:
                write("[ignore, absent du CPC : %s]\n" % " ".join(sorted(lost)))
            link.send_key(b"".join(b for _, b in pieces))
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
