#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cpcview — afficheur graphique fidele pour le terminal CPC.

Meme liaison que `cpcterm.py`, mais rendu dans une fenetre avec le VRAI
jeu de caracteres du CPC, aux bonnes proportions.

Pourquoi une fenetre plutot qu'une console : dans un terminal, c'est le
terminal qui choisit la police, et aucune police PC ne reproduit les
semi-graphiques, fleches et symboles du CPC — ils s'affichaient en
<NN>. Ici on dessine les matrices 8x8 du CPC lui-meme.

Le jeu de caracteres est demande UNE FOIS au CPC (commande hors-bande
&01 'F', 2 Ko) puis conserve dans `cpcfont.bin` : les lancements
suivants sont immediats, et l'afficheur reste utilisable meme si on
change de machine.

Proportions : le CPC affiche 320x200 (MODE 1) sur un ecran 4:3, ses
pixels ne sont donc pas carres. On rend l'image a sa taille native puis
on l'etire en 4:3 — d'ou des caracteres plus larges qu'en console.

    python cpcview.py <ip-du-cpc>
    python cpcview.py <ip-du-cpc> --refont     redemander le jeu au CPC
    python cpcview.py <ip-du-cpc> --zoom 3     fenetre plus grande
"""
import argparse
import os
import queue
import socket
import sys
import threading
import tkinter as tk

from PIL import Image, ImageTk

from cpcterm import (CMD_DUMP, CMD_ECHO, CMD_FONT, CPC_RGB, FONT_LEN,
                     CpcScreen, to_cpc)

FONT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "cpcfont.bin")
ROWS = 25
CELL = 8                        # un caractere CPC : 8 x 8 pixels


class Link:
    """Connexion au CPC (le CPC est serveur sur 6128)."""

    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.settimeout(None)
        self.lock = threading.Lock()

    def send(self, data):
        with self.lock:
            self.sock.sendall(data)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def load_font():
    """Jeu de caracteres en cache, ou None s'il faut le demander."""
    try:
        data = open(FONT_FILE, "rb").read()
    except OSError:
        return None
    return data if len(data) == FONT_LEN else None


def save_font(data):
    with open(FONT_FILE, "wb") as f:
        f.write(data)


def glyph_rows(font, code):
    """Les 8 octets du dessin d'un caractere (0 si police absente)."""
    if not font:
        return (0,) * CELL
    o = (code & 0xFF) * CELL
    return tuple(font[o:o + CELL])


class Viewer:
    def __init__(self, root, link, font, zoom, want_dump):
        self.root, self.link, self.font = root, link, font
        self.zoom = zoom
        self.screen = CpcScreen(colour=True)
        self.queue = queue.Queue()
        self.dirty = True
        self.tiles = {}             # cache (code, encre, papier) -> Image
        self.photo = None

        root.title("CPC — %s" % link.sock.getpeername()[0])
        root.configure(bg="black")
        self.canvas = tk.Canvas(root, highlightthickness=0, bg="black")
        self.canvas.pack(fill="both", expand=True)
        root.bind("<Key>", self.on_key)

        # Contrairement a la console, cette fenetre n'a aucun echo local :
        # c'est au CPC de nous renvoyer ce qu'on tape, sinon la frappe
        # reste invisible jusqu'a l'execution de la commande.
        self.link.send(CMD_ECHO)
        if self.font is None:
            self.link.send(CMD_FONT)        # premiere fois : la demander
        # --dump releve l'ecran du CPC a la connexion : indispensable pour un
        # affichage exact, car partant d'une fenetre vide on ne peut pas
        # reconstituer ce qui etait affiche avant (sinon decalage d'une ligne).
        if want_dump:
            self.link.send(CMD_DUMP)

        threading.Thread(target=self.reader, daemon=True).start()
        self.tick()

    # --- reseau ----------------------------------------------------
    def reader(self):
        try:
            while True:
                data = self.link.sock.recv(4096)
                if not data:
                    break
                self.queue.put(data)
        except OSError:
            pass
        self.queue.put(None)

    # --- clavier ---------------------------------------------------
    def on_key(self, ev):
        if ev.keysym in ("Return", "KP_Enter"):
            self.link.send(b"\r")
            return
        if ev.keysym == "BackSpace":
            self.link.send(b"\x7f")
            return
        if ev.keysym == "Escape":
            self.link.send(b"\xfc")
            return
        if ev.char:
            b = to_cpc(ev.char)
            if b:
                self.link.send(b)

    # --- rendu -----------------------------------------------------
    def tile(self, code, pen, paper):
        """Image 8x8 d'un caractere, mise en cache."""
        key = (code, pen, paper)
        img = self.tiles.get(key)
        if img is not None:
            return img
        inks = self.screen.inks
        fg = CPC_RGB[inks[pen & 15] % 27]
        bg = CPC_RGB[inks[paper & 15] % 27]
        img = Image.new("RGB", (CELL, CELL), bg)
        px = img.load()
        for y, bits in enumerate(glyph_rows(self.font, code)):
            for x in range(CELL):
                if bits & (0x80 >> x):
                    px[x, y] = fg
        self.tiles[key] = img
        return img

    def render(self):
        w = self.screen.width
        rows = self.screen.cells[-ROWS:]
        inks = self.screen.inks
        bg = CPC_RGB[inks[self.screen.paper & 15] % 27]
        frame = Image.new("RGB", (w * CELL, ROWS * CELL), bg)
        for r, line in enumerate(rows):
            for c, (code, pen, paper) in enumerate(line[:w]):
                frame.paste(self.tile(code, pen, paper), (c * CELL, r * CELL))
        # Le curseur : sur CPC c'est un pave plein, pas un trait clignotant.
        # On l'inverse a la position courante (ligne du curseur, colonne).
        cr, cc = self.screen.row, self.screen.col
        if 0 <= cr < ROWS and cc < w:
            code, pen, paper = 32, self.screen.pen, self.screen.paper
            if cc < len(rows[cr]):
                code, pen, paper = rows[cr][cc]
            frame.paste(self.tile(code, paper, pen), (cc * CELL, cr * CELL))
        # Etirement en 4:3 : les pixels du CPC ne sont pas carres.
        out = frame.resize((160 * self.zoom, 120 * self.zoom), Image.NEAREST)
        self.photo = ImageTk.PhotoImage(out)
        self.canvas.config(width=out.width, height=out.height)
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)

    # --- boucle ----------------------------------------------------
    def tick(self):
        closed = False
        while True:
            try:
                data = self.queue.get_nowait()
            except queue.Empty:
                break
            if data is None:
                closed = True
                break
            had_font = self.screen.font
            self.screen.feed(data)          # met a jour cellules et couleurs
            if self.screen.font and not had_font:
                self.font = self.screen.font
                save_font(self.font)
                self.tiles.clear()
            self.dirty = True
        if self.dirty:
            self.dirty = False
            self.render()
        if closed:
            self.root.title(self.root.title() + " — deconnecte")
            return
        self.root.after(50, self.tick)


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("host", help="adresse IP du CPC")
    p.add_argument("port", nargs="?", type=int, default=6128)
    p.add_argument("--zoom", type=int, default=4,
                   help="taille de la fenetre (defaut 4 = 640x480)")
    p.add_argument("--refont", action="store_true",
                   help="redemander le jeu de caracteres au CPC")
    p.add_argument("--dump", action="store_true",
                   help="relever l'ecran du CPC a la connexion (affichage "
                        "exact ; sans, l'ecran se reconstruit au fil de la sortie)")
    args = p.parse_args()

    font = None if args.refont else load_font()
    if font is None:
        print("Jeu de caracteres absent du cache : demande au CPC (2 Ko)...")

    link = Link(args.host, args.port)
    root = tk.Tk()
    Viewer(root, link, font, args.zoom, args.dump)
    try:
        root.mainloop()
    finally:
        link.close()


if __name__ == "__main__":
    main()
