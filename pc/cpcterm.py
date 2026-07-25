#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cpcterm — piloter le BASIC du CPC depuis Windows.

Cote CPC : le resident `cpc/cterm2.s`, livre en ROM (`cpc/termrom2.s`).
Il detourne l'editeur de ligne du BASIC (entree EDIT du jumpblock,
&BD5E) : la ligne qu'on envoie est deposee dans le tampon du BASIC, qui
l'execute comme une frappe. Aucun programme BASIC n'est necessaire —
l'espace programme reste entierement a l'utilisateur.

Le CPC est SERVEUR sur le port 6128 ; on lui envoie une ligne terminee
par CR, et toute sa sortie ecran remonte ici.

    (CPC)  |TERM                                     (ROM installee)
    (PC)   python cpcterm.py <ip-du-cpc>             console directe
           python cpcterm.py <ip-du-cpc> --telnet    relais telnet (2323)
           python cpcterm.py <ip-du-cpc> --width 80  si le CPC est en MODE 2
           python cpcterm.py <ip-du-cpc> --dump      relever l'ecran actuel

Commandes locales : `:aide`, `:get fichier.bas` … `:fin` pour capturer
un `list` dans un fichier propre.

En mode telnet, se connecter avec PuTTY (Raw ou Telnet) sur
127.0.0.1:2323. Le CPC ne renvoie pas d'echo des touches : laisser le
client faire son echo local (on ne negocie donc PAS WILL ECHO).

NOTE : l'injection de frappes PC->CPC s'est revelee impossible sur cette
carte (voir docs/09 §6) ; d'ou le detournement de l'editeur de ligne.
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


# Nombre de parametres de chaque code de controle CPC (0-31). Sans
# cette table, les parametres d'un code de controle (couleurs, fenetre,
# positionnement) ressortaient en charabia dans le texte.
CTRL_PARAMS = {
    0: 0, 1: 1, 2: 0, 3: 0, 4: 1, 5: 1, 6: 0, 7: 0,
    8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 0, 14: 1, 15: 1,
    16: 0, 17: 0, 18: 0, 19: 0, 20: 0, 21: 0, 22: 1, 23: 1,
    24: 0, 25: 9, 26: 4, 27: 0, 28: 3, 29: 2, 30: 0, 31: 2,
}
# Marqueurs emis par le resident (prefixe ESC). Necessaires parce que
# les commandes MODE / PEN / PAPER / INK du BASIC appellent le firmware
# directement : elles n'emettent RIEN dans le flux d'affichage, donc le
# PC ne peut pas les deviner en ecoutant les caracteres.
MODE_MARK = 0x4D            # ESC 'M' <chiffre>          -> MODE
COL_MARK = 0x43             # ESC 'C' <18 octets>        -> couleurs
CLS_MARK = 0x4C             # ESC 'L'                    -> effacement
FONT_MARK = 0x46            # ESC 'F' <2048 octets>      -> jeu de caracteres
FONT_LEN = 2048             # 256 caracteres x 8 octets

# Commandes hors-bande envoyees AU CPC : prefixe &01, puis une lettre.
# Le resident les intercepte au lieu de les passer au BASIC.
CMD_DUMP = b"\x01D"    # relever le contenu actuel de l'ecran
CMD_FONT = b"\x01F"    # envoyer le jeu de caracteres (2 Ko)
CMD_ECHO = b"\x01E"    # renvoyer l'echo des frappes
# Ces prefixes s'ecrivent \x01 et non en octet brut : un octet de
# controle pose directement dans le source est invisible a la relecture.
COL_LEN = 18                # encre, papier, 16 couleurs de palette
ESC_LEN = {MODE_MARK: 1, COL_MARK: COL_LEN, CLS_MARK: 0,
           FONT_MARK: FONT_LEN}

# Les 27 couleurs du CPC, en RVB. Chaque composante vaut 0, 128 ou 255.
CPC_RGB = [
    (0, 0, 0), (0, 0, 128), (0, 0, 255), (128, 0, 0),
    (128, 0, 128), (128, 0, 255), (255, 0, 0), (255, 0, 128),
    (255, 0, 255), (0, 128, 0), (0, 128, 128), (0, 128, 255),
    (128, 128, 0), (128, 128, 128), (128, 128, 255), (255, 128, 0),
    (255, 128, 128), (255, 128, 255), (0, 255, 0), (0, 255, 128),
    (0, 255, 255), (128, 255, 0), (128, 255, 128), (128, 255, 255),
    (255, 255, 0), (255, 255, 128), (255, 255, 255),
]
# Palette par defaut du CPC : encre 0 = bleu, encre 1 = jaune vif.
DEFAULT_INKS = [1, 24, 20, 6, 26, 0, 2, 8, 10, 12, 14, 16, 18, 22, 1, 16]
MODE_WIDTH = {0: 20, 1: 40, 2: 80}
SCREEN_HEIGHT = 25          # l'ecran texte du CPC : 25 lignes dans tous les modes


def cpc_char(b):
    """Un octet CPC affichable -> caractere Unicode."""
    if b in CPC_TO_UNI:
        return CPC_TO_UNI[b]
    if 32 <= b < 127:
        return chr(b)
    if b >= 128:
        return "<%02X>" % b          # symbole CPC non cartographie
    return ""


class CpcScreen:
    """Recompose l'affichage du CPC a partir du flux de caracteres.

    Le CPC passe a la ligne suivante quand le curseur atteint le bord de
    l'ecran, SANS emettre de CR/LF. Le flux est donc continu et tout se
    colle si on l'affiche tel quel — un CAT devenait illisible. On
    recompose donc les lignes a la largeur de l'ecran.

    Les codes de controle sont consommes avec leurs parametres (voir
    CTRL_PARAMS) ; le code 4 (MODE) ajuste la largeur automatiquement.
    """

    def __init__(self, width=40, colour=True):
        self.width = width
        self.col = 0
        self.pending = 0        # parametres restant a consommer
        self.ctrl = None        # code de controle en cours
        self.args = []
        self.last_cr = False
        self.wrapped = False    # on vient de replier : avaler un LF
        # --- couleurs
        self.colour = colour
        self.inks = list(DEFAULT_INKS)
        self.pen, self.paper = 1, 0
        self.shown = None       # dernier couple (encre, papier) rendu
        # Grille de cellules (code, encre, papier) par ligne : sert a
        # l'afficheur graphique, qui a besoin des couleurs case par
        # case et non d'un texte deja colore en ANSI.
        # Ecran FIXE facon CPC : une grille bornee a SCREEN_HEIGHT lignes,
        # avec une ligne-curseur. Un saut de ligne descend le curseur ; il
        # ne fait defiler (perdre la ligne du haut) QU'une fois arrive en
        # bas. Un simple scrollback illimite decalait l'affichage d'une
        # ligne (curseur = ligne en trop) et rognait le haut cote cpcview.
        self.cells = [[]]
        self.row = 0            # ligne du curseur dans la grille
        self.font = None        # 2048 octets, quand le CPC les envoie

    def _set_mode(self, mode):
        self.width = MODE_WIDTH.get(mode & 3, 40)
        self.col = 0

    def _clear(self, out):
        """Efface l'ecran, comme le CLS du CPC.

        On applique d'abord la couleur courante : la sequence ANSI
        d'effacement peint avec le fond actif, on obtient donc bien
        un ecran de la couleur du papier, comme sur le CPC.
        """
        if self.colour:
            self.shown = None
            self._ansi(out)
        out.append("\x1b[2J\x1b[H")
        self.col = 0
        self.wrapped = False
        self.cells = [[]]
        self.row = 0

    def _ansi(self, out):
        """Emet la sequence ANSI si l'encre ou le papier a change."""
        if not self.colour:
            return
        state = (self.pen, self.paper, tuple(self.inks))
        if state == self.shown:
            return
        self.shown = state
        fr, fg, fb = CPC_RGB[self.inks[self.pen & 15] % 27]
        br, bg, bb = CPC_RGB[self.inks[self.paper & 15] % 27]
        out.append("\x1b[38;2;%d;%d;%dm\x1b[48;2;%d;%d;%dm"
                   % (fr, fg, fb, br, bg, bb))

    def _newrow(self):
        # Descendre le curseur d'une ligne. On ne fait defiler (perdre la
        # ligne du haut) QUE si le curseur etait deja sur la derniere ligne
        # de l'ecran — exactement comme le CPC.
        self.row += 1
        if self.row >= SCREEN_HEIGHT:
            self.cells.append([])
            del self.cells[0]
            self.row = SCREEN_HEIGHT - 1
        elif self.row >= len(self.cells):
            self.cells.append([])

    def _newline(self, out):
        out.append("\n")
        self.col = 0
        self.wrapped = False
        self._newrow()

    def _putc(self, out, code):
        """Un caractere CPC : une cellule, une colonne.

        On compte une seule colonne meme quand la traduction Unicode
        occupe plusieurs signes (les <NN> non cartographies) : c'est la
        largeur du CPC qui fait foi pour le repliage.
        """
        out.append(cpc_char(code))
        # On ecrit A la colonne courante et non en fin de ligne : apres un
        # CHR$(8) le CPC recouvre le caractere, il ne l'ajoute pas.
        row = self.cells[self.row]
        while len(row) < self.col:
            row.append((32, self.pen, self.paper))
        if self.col < len(row):
            row[self.col] = (code, self.pen, self.paper)
        else:
            row.append((code, self.pen, self.paper))
        self.col += 1
        if self.col >= self.width:
            out.append("\n")
            self.col = 0
            self.wrapped = True
            self._newrow()

    def _done_ctrl(self, out):
        """Un code de controle et ses parametres sont complets."""
        c, a = self.ctrl, self.args
        if c == 1:                      # afficher le caractere tel quel
            self._putc(out, a[0])
        elif c == 4:                    # CHR$(4) : MODE
            self._set_mode(a[0])
            self._clear(out)
        elif c == 15:                   # CHR$(15) : encre
            self.pen = a[0] & 15
        elif c == 14:                   # CHR$(14) : papier
            self.paper = a[0] & 15
        elif c == 24:                   # echange encre / papier
            self.pen, self.paper = self.paper, self.pen
        elif c == 28:                   # CHR$(28) : redefinit une encre
            self.inks[a[0] & 15] = a[1] % 27
        elif c == 27:                   # marqueur du resident
            if a[0] == MODE_MARK:
                self._set_mode(a[1] - 0x30)
                self._clear(out)        # le CPC efface a chaque MODE
            elif a[0] == CLS_MARK:
                self._clear(out)
            elif a[0] == FONT_MARK:
                self.font = bytes(a[1:1 + FONT_LEN])
            elif a[0] == COL_MARK:
                self.pen, self.paper = a[1] & 15, a[2] & 15
                self.inks = [v % 27 for v in a[3:3 + 16]]
        self.ctrl, self.args = None, []

    def feed(self, data):
        out = []
        for b in data:
            # --- parametres d'un code de controle en cours
            if self.pending:
                self.args.append(b)
                self.pending -= 1
                if self.pending == 0:
                    self._done_ctrl(out)
                continue

            # --- ESC : marqueur du resident, longueur variable
            if self.ctrl == 27 and not self.args:
                self.args.append(b)
                self.pending = ESC_LEN.get(b, 0)
                if self.pending == 0:
                    self._done_ctrl(out)
                continue

            was_cr, self.last_cr = self.last_cr, False

            if b == 13:                          # CR
                self._newline(out)
                self.last_cr = True
            elif b == 10:                        # LF
                if not was_cr and not self.wrapped:
                    self._newline(out)
                self.wrapped = False
            elif b == 12:                        # effacement de fenetre
                self._clear(out)
            elif b == 8:                         # curseur a gauche
                if self.col > 0:                 # (recule sans effacer :
                    self.col -= 1                # l'effacement, c'est
                    out.append("\b")             # BS + espace + BS)
            elif b == 9:                         # curseur a droite
                self._putc(out, 32)
            elif b == 27:                        # marqueur du resident
                self.ctrl, self.pending, self.args = 27, 0, []
            elif b < 32:                         # autre code de controle
                n = CTRL_PARAMS.get(b, 0)
                if n:
                    self.ctrl, self.pending, self.args = b, n, []
                else:
                    self.ctrl, self.args = b, []
                    self._done_ctrl(out)
            else:
                self.wrapped = False
                self._ansi(out)
                self._putc(out, b)
        return "".join(out)


def cpc_to_text(data):
    """Conversion sans etat, pour les verifications ponctuelles."""
    return CpcScreen().feed(data)


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


def pump_output(link, write, capture=None, screen=None):
    """Boucle de lecture : ecran du CPC -> sortie locale (+ capture)."""
    screen = screen or CpcScreen()
    while True:
        data = link.sock.recv(4096)
        if not data:
            write("\n---- connexion fermee par le CPC ----\n")
            return
        text = screen.feed(data)
        if link.eat_nl and text.startswith("\n"):
            text = text[1:]         # saut de ligne d'apres-commande
            link.eat_nl = False
        elif text.strip():
            link.eat_nl = False
        if capture:
            capture.feed(text)
        write(text)


# --------------------------------------------------------------- console
def run_console(host, port, width=40, colour=True, dump=False):
    link = Link(host, port)
    cap = Capture()
    screen = CpcScreen(width, colour)
    if dump:
        link.send_key(CMD_DUMP)
    print("Connecte a %s:%d — commandes CPC, ou :aide (Ctrl+C pour quitter)\n"
          % (host, port))

    def write(text):
        sys.stdout.write(text)
        sys.stdout.flush()

    t = threading.Thread(target=pump_output, args=(link, write, cap, screen),
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
                elif cpc_char(b[0]) != c:
                    subst[c] = cpc_char(b[0])
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
        if screen.colour:
            sys.stdout.write("\x1b[0m")     # rendre ses couleurs au terminal
        print("\nau revoir")


# ---------------------------------------------------------------- telnet
def run_telnet(host, port, listen_port, width=40, colour=True,
               dump=False):
    link = Link(host, port)
    screen = CpcScreen(width, colour)
    if dump:
        link.send_key(CMD_DUMP)
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
                        cli.sendall(screen.feed(data).encode("latin-1", "replace"))
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
    p.add_argument("--dump", action="store_true",
                   help="a la connexion, relever l'ecran actuel du CPC "
                        "(prend un instant : le firmware reconnait chaque "
                        "caractere d'apres son dessin)")
    p.add_argument("--mono", action="store_true",
                   help="ne pas reproduire les couleurs du CPC")
    p.add_argument("--width", type=int, default=40,
                   help="largeur de l'ecran CPC (20/40/80 ; defaut 40, ajustee automatiquement si le CPC change de MODE)")
    p.add_argument("--listen", type=int, default=2323,
                   help="port du relais telnet (defaut 2323)")
    args = p.parse_args()

    if args.telnet:
        run_telnet(args.host, args.port, args.listen, args.width,
                   not args.mono, args.dump)
    else:
        run_console(args.host, args.port, args.width, not args.mono,
                    args.dump)


if __name__ == "__main__":
    main()
