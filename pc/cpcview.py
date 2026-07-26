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
import customtkinter as ctk
import os
import queue
import socket
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk

from PIL import Image, ImageTk

from cpcterm import (CMD_DUMP, CMD_ECHO, CMD_FONT, CPC_RGB, FONT_LEN,
                     CpcScreen, to_cpc)
from m4term import M4                 # client HTTP de la carte M4 (reutilise)

FONT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "cpcfont.bin")
ROWS = 25
CELL = 8                        # un caractere CPC : 8 x 8 pixels


class DialogHelper:
    """Dialogs modernes avec customtkinter pour remplacer tkinter.simpledialog."""

    @staticmethod
    def askstring(title, prompt, parent=None, initialvalue=""):
        """Input dialog — retourne la chaîne saisie ou None si annulé."""
        dialog = ctk.CTkToplevel(parent)
        dialog.title(title)
        dialog.geometry("400x150")
        dialog.configure(fg_color="#1a1a1a")
        dialog.resizable(False, False)

        result = [None]

        ctk.CTkLabel(dialog, text=prompt, text_color="#e0e0e0",
                    font=("Segoe UI", 11)).pack(padx=15, pady=(15, 5))

        entry = ctk.CTkEntry(dialog, fg_color="#2a2a2a", border_color="#404040",
                            text_color="#e0e0e0", font=("Segoe UI", 11), width=300)
        entry.pack(padx=15, pady=5)
        entry.insert(0, initialvalue)

        def ok():
            result[0] = entry.get()
            dialog.destroy()

        def cancel():
            dialog.destroy()

        btn_frame = ctk.CTkFrame(dialog, fg_color="#1a1a1a")
        btn_frame.pack(fill="x", padx=15, pady=15)
        ctk.CTkButton(btn_frame, text="OK", command=ok, width=80,
                     fg_color="#1060c0", hover_color="#1a90ff").pack(side="left", padx=5)
        ctk.CTkButton(btn_frame, text="Annuler", command=cancel, width=80,
                     fg_color="#404040", hover_color="#606060").pack(side="left", padx=5)

        dialog.wait_window()
        return result[0]

    @staticmethod
    def askyesno(title, message, parent=None):
        """Confirmation dialog — retourne True/False."""
        dialog = ctk.CTkToplevel(parent)
        dialog.title(title)
        dialog.geometry("400x150")
        dialog.configure(fg_color="#1a1a1a")
        dialog.resizable(False, False)

        result = [False]

        ctk.CTkLabel(dialog, text=message, text_color="#e0e0e0",
                    font=("Segoe UI", 11), wraplength=350).pack(padx=15, pady=20)

        def yes():
            result[0] = True
            dialog.destroy()

        def no():
            dialog.destroy()

        btn_frame = ctk.CTkFrame(dialog, fg_color="#1a1a1a")
        btn_frame.pack(fill="x", padx=15, pady=15)
        ctk.CTkButton(btn_frame, text="✓ Oui", command=yes, width=80,
                     fg_color="#00aa00", hover_color="#00cc00").pack(side="left", padx=5)
        ctk.CTkButton(btn_frame, text="✕ Non", command=no, width=80,
                     fg_color="#aa0000", hover_color="#cc0000").pack(side="left", padx=5)

        dialog.wait_window()
        return result[0]


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


def parse_dir(text):
    """Analyse le dir.txt de la M4 : lignes 'nom,type,taille' (type 0 =
    dossier, 1 = fichier ; la 1re ligne est le chemin et n'a pas de virgules).
    Rend une liste (nom, est_dossier, taille), dossiers d'abord."""
    out = []
    for line in text.splitlines():
        parts = line.rstrip("\r").rsplit(",", 2)
        if len(parts) != 3:
            continue                        # ligne de chemin '//' ou vide
        name, typ, size = parts
        if not name or name in (".", ".."):
            continue
        out.append((name, typ.strip() == "0", size.strip()))
    out.sort(key=lambda e: (not e[1], e[0].lower()))
    return out


class Viewer:
    def __init__(self, root, link, font, zoom, want_dump):
        self.root, self.link, self.font = root, link, font
        self.zoom = zoom
        self.screen = CpcScreen(colour=True)
        self.queue = queue.Queue()
        self.dirty = True
        self._closed = False
        self.tiles = {}             # cache (code, encre, papier) -> Image
        self.photo = None
        self.host = link.sock.getpeername()[0]
        self.m4 = M4(self.host)     # meme carte, API HTTP (port 80)
        self.theme = "dark"         # thème actuel (dark/light)

        root.title("CPC — %s" % self.host)
        root.configure(bg="black")
        root.geometry("%dx%d" % (160 * zoom, 120 * zoom))   # taille de depart
        self._build_menu()
        # Barre de statut en bas (empilee AVANT le canvas pour qu'elle garde
        # sa place, le canvas prenant tout le reste).
        self.status_msg = "connecte"
        # Barre de statut modernisée avec customtkinter
        statusbar_frame = ctk.CTkFrame(root, fg_color="#2a2a2a", height=35)
        statusbar_frame.pack(side="bottom", fill="x", padx=0, pady=0)
        self.statusbar = ctk.CTkLabel(statusbar_frame, text="", anchor="w",
                                     text_color="#d0d0d0", font=("Segoe UI", 9))
        self.statusbar.pack(fill="x", padx=10, pady=8)
        self.canvas = tk.Canvas(root, highlightthickness=0, bg="black")
        self.canvas.pack(side="top", fill="both", expand=True)
        root.bind("<Key>", self.on_key)
        root.bind("<F5>", lambda e: self.do_dump())
        root.bind("<Control-v>", lambda e: self.paste())
        # Redimensionnement : on marque juste "a redessiner" ; la boucle
        # tick() redessine dans les 50 ms a la nouvelle taille (evite de
        # recalculer l'image a chaque pixel pendant qu'on tire la fenetre).
        self.canvas.bind("<Configure>", lambda e: setattr(self, "dirty", True))

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

    # --- thème (dark/light) ------------------------------------------------
    def get_theme_colors(self):
        """Retourner les couleurs selon le thème actuel."""
        if self.theme == "dark":
            return {
                "bg": "#1a1a1a",
                "fg": "#e0e0e0",
                "accent": "#1060c0",
                "button_hover": "#1a90ff",
                "success": "#00ff00",
                "label": "#ffd000"
            }
        else:  # light
            return {
                "bg": "#f5f5f5",
                "fg": "#1a1a1a",
                "accent": "#0050cc",
                "button_hover": "#3366ff",
                "success": "#00aa00",
                "label": "#ff8800"
            }

    def toggle_theme(self):
        """Basculer entre thème sombre et clair."""
        self.theme = "light" if self.theme == "dark" else "dark"
        colors = self.get_theme_colors()
        ctk.set_appearance_mode("light" if self.theme == "light" else "dark")

    # --- menus -----------------------------------------------------
    def _build_menu(self):
        bar = tk.Menu(self.root)
        m = tk.Menu(bar, tearoff=0)
        m.add_command(label="Relever l'ecran", command=self.do_dump,
                      accelerator="F5")
        m.add_command(label="Recharger la police du CPC", command=self.do_refont)
        m.add_separator()
        m.add_command(label="Quitter", command=self.root.destroy)
        bar.add_cascade(label="Ecran", menu=m)
        t = tk.Menu(bar, tearoff=0)
        for z in (2, 3, 4, 5, 6):
            t.add_command(label="x%d  (%dx%d)" % (z, 160 * z, 120 * z),
                          command=lambda z=z: self.set_size(z))
        bar.add_cascade(label="Taille", menu=t)

        # --- Affichage
        v = tk.Menu(bar, tearoff=0)
        v.add_command(label="Basculer thème (Dark/Light)", command=self.toggle_theme)
        bar.add_cascade(label="Affichage", menu=v)

        # --- Édition
        ed = tk.Menu(bar, tearoff=0)
        ed.add_command(label="Coller", command=self.paste, accelerator="Ctrl+V")
        bar.add_cascade(label="Édition", menu=ed)

        # --- carte M4 : les fonctions de l'interface web, via son API HTTP
        m4 = tk.Menu(bar, tearoff=0)
        m4.add_command(label="Navigateur de fichiers...", command=self.m4_browse)
        m4.add_command(label="Parametres...", command=self.m4_settings)
        m4.add_separator()
        m4.add_command(label="Envoyer un fichier vers la SD...",
                       command=self.m4_upload)
        m4.add_command(label="Telecharger un fichier...", command=self.m4_download)
        m4.add_command(label="Lancer un programme...", command=self.m4_run)
        m4.add_command(label="Lister un dossier...", command=self.m4_ls)
        m4.add_separator()
        m4.add_command(label="Installer une ROM...", command=self.m4_rom_install)
        m4.add_command(label="Supprimer une ROM...", command=self.m4_rom_delete)
        m4.add_separator()
        m4.add_command(label="Nouveau dossier...", command=self.m4_mkdir)
        m4.add_command(label="Supprimer un fichier/dossier...", command=self.m4_rm)
        m4.add_separator()
        m4.add_command(label="Pause / reprise CPC", command=self.m4_pause)
        m4.add_command(label="Reset CPC", command=self.m4_reset_cpc)
        m4.add_command(label="Reset carte M4", command=self.m4_reset_m4)
        bar.add_cascade(label="M4", menu=m4)
        self.root.config(menu=bar)

    # --- carte M4 (API HTTP) : operations en tache de fond -------------
    def _m4_async(self, label, fn, on_ok=None):
        """Lancer un appel M4 dans un thread (le reseau peut etre lent) et
        rendre le resultat sur le thread tkinter (after) : succes -> barre de
        statut, erreur -> pop-up (plus une trace dans la barre)."""
        self.set_status(label + "...")

        def done_ok(res):
            if on_ok:
                on_ok(res)
            self.set_status(label + " : OK")

        def done_err(e):
            self.set_status(label + " : echec")
            messagebox.showerror("M4", "%s : echec\n%s" % (label, e))

        def worker():
            try:
                res = fn()
            except Exception as e:            # reseau, HTTP, fichier...
                self.root.after(0, lambda e=e: done_err(e))
                return
            self.root.after(0, lambda: done_ok(res))
        threading.Thread(target=worker, daemon=True).start()

    def m4_upload(self):
        local = filedialog.askopenfilename(title="Fichier a envoyer vers la SD")
        if not local:
            return
        dest = DialogHelper.askstring("Envoyer", "Dossier destination sur la SD :",
                                      initialvalue="/", parent=self.root)
        if dest is None:
            return
        self._m4_async("Envoi de %s" % os.path.basename(local),
                       lambda: self.m4.upload(local, dest or "/"))

    def m4_download(self):
        remote = DialogHelper.askstring("Telecharger",
                                        "Fichier sur la SD (chemin CPC) :",
                                        parent=self.root)
        if not remote:
            return
        local = filedialog.asksaveasfilename(
            title="Enregistrer sous", initialfile=os.path.basename(remote))
        if not local:
            return

        def do():
            data = self.m4.download(remote)
            with open(local, "wb") as f:
                f.write(data)
            return len(data)
        self._m4_async("Telechargement de %s" % remote, do)

    def m4_run(self, name=None):
        """Lancer un programme en INJECTANT RUN"..." dans le terminal, et non
        via le run2 de la M4 : ce dernier fait un chargement bas-niveau qui
        ecrase notre resident (terminal muet). Par le terminal, le programme
        tourne sous BASIC, sa sortie est renvoyee, et la main revient au
        terminal quand il se termine (pour ceux qui rendent la main)."""
        if name is None:
            name = DialogHelper.askstring("Lancer",
                                          "Programme a lancer (RUN\"...\") :",
                                          parent=self.root)
        if not name:
            return
        self.link.send(('RUN"%s"\r' % name).encode("latin-1", "replace"))
        self.set_status('RUN"%s"' % name)

    def m4_ls(self):
        d = DialogHelper.askstring("Lister", "Dossier de la SD a lister :",
                                   initialvalue="/", parent=self.root)
        if d is None:
            return
        self._m4_async("Listing de %s" % (d or "/"),
                       lambda: self.m4.ls(d or "/"),
                       lambda txt: self._show_text("SD : %s" % (d or "/"), txt))

    def m4_rom_install(self):
        local = filedialog.askopenfilename(
            title="ROM a installer",
            filetypes=[("ROM CPC", "*.rom *.ROM *.bin *.BIN"), ("Tous", "*.*")])
        if not local:
            return
        slot = simpledialog.askinteger("Installer une ROM", "Numero de slot (0-31) :",
                                       minvalue=0, maxvalue=31, parent=self.root)
        if slot is None:
            return
        default = os.path.splitext(os.path.basename(local))[0][:16].upper()
        name = DialogHelper.askstring("Installer une ROM", "Nom de la ROM :",
                                      initialvalue=default, parent=self.root)
        if not name:
            return
        self._m4_async("Installation ROM slot %d" % slot,
                       lambda: self.m4.rom_install(local, slot, name))

    def m4_rom_delete(self):
        slot = simpledialog.askinteger("Supprimer une ROM",
                                       "Numero de slot a vider (0-31) :",
                                       minvalue=0, maxvalue=31, parent=self.root)
        if slot is None:
            return
        if DialogHelper.askyesno("Supprimer une ROM", "Vider le slot %d ?" % slot):
            self._m4_async("Suppression ROM slot %d" % slot,
                           lambda: self.m4.rom_delete(slot))

    def m4_mkdir(self):
        d = DialogHelper.askstring("Nouveau dossier", "Chemin du dossier a creer :",
                                   parent=self.root)
        if d:
            self._m4_async("Creation de %s" % d, lambda: self.m4.mkdir(d))

    def m4_rm(self):
        t = DialogHelper.askstring("Supprimer",
                                   "Fichier ou dossier (vide) a supprimer :",
                                   parent=self.root)
        if t and DialogHelper.askyesno("Supprimer", "Supprimer %s ?" % t):
            self._m4_async("Suppression de %s" % t, lambda: self.m4.rm(t))

    def m4_pause(self):
        self._m4_async("Pause/reprise CPC", self.m4.pause)

    def m4_reset_cpc(self):
        if DialogHelper.askyesno("Reset CPC", "Redemarrer le CPC ?"):
            self._m4_async("Reset CPC", self.m4.reset_cpc)

    def m4_reset_m4(self):
        if DialogHelper.askyesno(
                "Reset carte M4",
                "Redemarrer la carte M4 ?\n(la connexion du terminal sera coupee)"):
            self._m4_async("Reset carte M4", self.m4.reset_m4)

    def _show_text(self, title, text):
        """Afficher du texte dans une fenêtre modernisée avec customtkinter."""
        colors = self.get_theme_colors()
        win = ctk.CTkToplevel(self.root)
        win.title(title)
        win.geometry("800x600")
        win.configure(fg_color=colors["bg"])

        # Barre de titre
        header = ctk.CTkFrame(win, fg_color=colors["accent"])
        header.pack(fill="x", padx=0, pady=0)
        ctk.CTkLabel(header, text=title, text_color="#ffffff",
                    font=("Segoe UI", 13, "bold")).pack(padx=15, pady=8)

        # TextBox moderne avec customtkinter
        txt = ctk.CTkTextbox(win, fg_color="#2a2a2a" if self.theme == "dark" else "#ffffff",
                            text_color=colors["fg"], font=("Consolas", 11),
                            border_color=colors["accent"], border_width=1)
        txt.pack(fill="both", expand=True, padx=10, pady=10)
        txt.insert("1.0", text)
        txt.configure(state="disabled")

        # Bouton fermer en bas
        btn_frame = ctk.CTkFrame(win, fg_color=colors["bg"])
        btn_frame.pack(fill="x", padx=10, pady=10)
        ctk.CTkButton(btn_frame, text="✕ Fermer", command=win.destroy,
                     fg_color=colors["accent"], text_color="#ffffff",
                     hover_color=colors["button_hover"],
                     font=("Segoe UI", 11, "bold")).pack(side="right")

    # --- panneau de parametres de la M4 (generique et extensible) ------
    def m4_settings(self):
        """Afficher les parametres de la M4 dans un panneau avec onglets.
        Recupere les valeurs actuelles via HTTP, affiche un formulaire, et
        permet de soumettre les modifications. Interface modernisée avec customtkinter."""
        win = ctk.CTkToplevel(self.root)
        win.title("Parametres M4")
        win.geometry("700x550")
        win.configure(fg_color="#1a1a1a")

        # Definition des parametres par section (extensible)
        # Clés correspond aux noms d'attributs name= du HTML /settings.shtml
        sections = {
            "General": [
                ("Timezone", "zone", "text"),
                ("NTP server", "ntp", "text"),
                ("Netbios name", "navn", "text"),
                ("SSID", "ssid", "text"),
                ("Password", "pw", "text"),
            ],
            "Network": [
                ("Use DHCP", "dhcp", "checkbox"),
                ("IP number", "ip", "text"),
                ("Subnet", "nm", "text"),
                ("Gateway", "gw", "text"),
                ("DNS 1", "dns1", "text"),
                ("DNS 2", "dns2", "text"),
            ],
        }

        # Creation des onglets avec customtkinter
        tabview = ctk.CTkTabview(win, fg_color="#2a2a2a", segmented_button_fg_color="#1060c0")
        tabview.pack(fill="both", expand=True, padx=10, pady=10)

        fields = {}

        for section_name, params in sections.items():
            # Créer un onglet
            tabview.add(section_name)
            tab = tabview.tab(section_name)
            tab.configure(fg_color="#1a1a1a")

            # ScrollBar pour les longs formulaires
            scrollable_frame = ctk.CTkScrollableFrame(tab, fg_color="#1a1a1a")
            scrollable_frame.pack(fill="both", expand=True, padx=10, pady=10)

            # Ajouter les champs
            for label, key, ftype in params:
                row = ctk.CTkFrame(scrollable_frame, fg_color="#1a1a1a")
                row.pack(fill="x", padx=5, pady=6)

                lbl = ctk.CTkLabel(row, text=label + ":", text_color="#e0e0e0",
                                  font=("Segoe UI", 11), width=150, anchor="w")
                lbl.pack(side="left", padx=5)

                if ftype == "text":
                    entry = ctk.CTkEntry(row, fg_color="#2a2a2a", border_color="#404040",
                                        text_color="#e0e0e0", placeholder_text="",
                                        font=("Consolas", 11), width=250)
                    entry.pack(side="left", fill="x", expand=True, padx=5)
                    fields[key] = ("entry", entry)
                elif ftype == "checkbox":
                    var = tk.BooleanVar(value=False)
                    # Utiliser un CTkButton toggle
                    btn = ctk.CTkButton(row, text="OFF", width=70,
                                       fg_color="#404040", text_color="#ffffff",
                                       hover_color="#00ff00", font=("Segoe UI", 10, "bold"))

                    def make_toggle(v=var, b=btn):
                        def toggle():
                            v.set(not v.get())
                            b.configure(text="ON " if v.get() else "OFF",
                                       fg_color="#00ff00" if v.get() else "#404040",
                                       text_color="#000000" if v.get() else "#ffffff")
                        return toggle

                    btn.configure(command=make_toggle())
                    btn.pack(side="left", padx=5)
                    fields[key] = ("checkbox", (var, btn))

        # Boutons d'action en bas
        action_frame = ctk.CTkFrame(win, fg_color="#2a2a2a")
        action_frame.pack(fill="x", padx=10, pady=10)

        def reload_values():
            """Recharger les valeurs actuelles de la M4."""
            self.set_status("Chargement des parametres...")
            self._m4_async("Lecture des parametres",
                          lambda: self._fetch_m4_settings(),
                          lambda vals: update_form(vals))

        def update_form(values):
            """Remplir le formulaire avec les valeurs recuperees."""
            for key, (ftype, widget) in fields.items():
                if key in values:
                    val = values[key]
                    if ftype == "entry":
                        widget.delete(0, "end")
                        widget.insert(0, str(val))
                    elif ftype == "checkbox":
                        var, btn = widget
                        is_checked = str(val).lower() in ("1", "true", "yes", "on")
                        var.set(is_checked)
                        btn.configure(text="ON " if is_checked else "OFF",
                                     fg_color="#00ff00" if is_checked else "#404040",
                                     text_color="#000000" if is_checked else "#ffffff")
            self.set_status("Parametres charges")

        def apply_changes():
            """Soumettre les modifications a la M4."""
            data = {}
            for key, (ftype, widget) in fields.items():
                if ftype == "entry":
                    data[key] = widget.get()
                elif ftype == "checkbox":
                    var, btn = widget
                    data[key] = "1" if var.get() else "0"
            self._m4_async("Application des parametres",
                          lambda: self._submit_m4_settings(data))

        ctk.CTkButton(action_frame, text="🔄 Actualiser", command=reload_values,
                     fg_color="#1060c0", text_color="#ffff00", hover_color="#1a90ff",
                     font=("Segoe UI", 11, "bold")).pack(side="left", padx=5)
        ctk.CTkButton(action_frame, text="✓ Appliquer", command=apply_changes,
                     fg_color="#1060c0", text_color="#ffff00", hover_color="#1a90ff",
                     font=("Segoe UI", 11, "bold")).pack(side="left", padx=5)
        ctk.CTkButton(action_frame, text="✕ Fermer", command=win.destroy,
                     fg_color="#404040", text_color="#c0c0c0", hover_color="#606060",
                     font=("Segoe UI", 11, "bold")).pack(side="right", padx=5)

        # Charger les donnees
        reload_values()

    def _fetch_m4_settings(self):
        """Recuperer les parametres actuels de la M4 via HTTP."""
        import re
        html = self.m4._get("settings.shtml").decode("latin-1", "replace")
        values = {}
        # Extraire chaque tag <input ... >
        for tag in re.finditer(r'<input[^>]*?>', html, re.IGNORECASE):
            tag_str = tag.group(0)
            # Extraire name
            name_match = re.search(r'name\s*=\s*["\']?(\w+)["\']?', tag_str, re.IGNORECASE)
            if not name_match:
                continue
            name = name_match.group(1)
            # Extraire value (optionnel, avec ou sans guillemets; accepte valeurs vides)
            value_match = re.search(r'value\s*=\s*["\']?([^"\'\s>]*)["\']?', tag_str, re.IGNORECASE)
            if value_match:
                values[name] = value_match.group(1)
            # Si checked, c'est un checkbox (implicite à 1)
            elif 'checked' in tag_str.lower():
                values[name] = "1"
        return values

    def _submit_m4_settings(self, data):
        """Soumettre les modifications de parametres a la M4."""
        self.m4._get("config.cgi", **data)
        return "OK"

    # --- navigateur de fichiers graphique de la SD (version modernisée) -----
    def m4_browse(self):
        win = ctk.CTkToplevel(self.root)
        win.title("SD du CPC — M4 Board")
        win.geometry("600x600")
        win.configure(fg_color="#1a1a1a")
        path = ["/"]                        # chemin courant (mutable -> closures)
        rows = []                           # (nom, est_dossier, taille) affiches

        lbl = ctk.CTkLabel(win, text="SD : /", anchor="w", text_color="#ffd000",
                          font=("Segoe UI", 12, "bold"))
        lbl.pack(fill="x", padx=10, pady=8)

        frame = ctk.CTkFrame(win, fg_color="#2a2a2a")
        frame.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        sb = tk.Scrollbar(frame)
        sb.pack(side="right", fill="y")
        lst = tk.Listbox(frame, activestyle="none", font=("Consolas", 11),
                         bg="#000030", fg="#e0e0e0", selectbackground="#1060c0",
                         highlightthickness=0, yscrollcommand=sb.set)
        lst.pack(side="left", fill="both", expand=True)
        sb.config(command=lst.yview)

        def join(base, name):
            p = base.rstrip("/") + "/" + name
            return "/" + "/".join(s for s in p.split("/") if s)

        def refresh():
            lbl.configure(text="SD : " + path[0])
            lst.delete(0, "end")
            del rows[:]
            try:
                parsed = parse_dir(self.m4.ls(path[0]))
            except Exception as e:
                messagebox.showerror("SD", str(e), parent=win)
                return
            if path[0] != "/":
                lst.insert("end", "[..]")
                rows.append(("..", True, ""))
            for name, is_dir, size in parsed:
                if is_dir:
                    lst.insert("end", "[ %s ]" % name)
                else:
                    lst.insert("end", "   %-22s %6s" % (name[:22], size))
                rows.append((name, is_dir, size))
            self.set_status("SD : %s (%d entrees)" % (path[0], len(parsed)))

        def sel():
            s = lst.curselection()
            return rows[s[0]] if s else None

        def enter(_=None):
            e = sel()
            if not e or not e[1]:
                return
            if e[0] == "..":
                up = "/".join(path[0].strip("/").split("/")[:-1])
                path[0] = "/" + up if up else "/"
            else:
                path[0] = join(path[0], e[0])
            refresh()
        lst.bind("<Double-Button-1>", enter)
        lst.bind("<Return>", enter)

        def do_upload():
            local = filedialog.askopenfilename(parent=win,
                                               title="Envoyer vers " + path[0])
            if local:
                self._m4_async("Envoi de %s" % os.path.basename(local),
                               lambda: self.m4.upload(local, path[0]),
                               lambda r: refresh())

        def do_download():
            e = sel()
            if not e or e[1]:
                return
            local = filedialog.asksaveasfilename(parent=win, initialfile=e[0])
            if not local:
                return
            remote = join(path[0], e[0])

            def d():
                data = self.m4.download(remote)
                with open(local, "wb") as f:
                    f.write(data)
                return len(data)
            self._m4_async("Telechargement de %s" % e[0], d)

        def do_run():
            e = sel()
            if not e or e[1]:
                return
            name, folder = e[0], path[0]

            def go():                       # placer le CPC dans le dossier, puis RUN
                try:
                    self.m4.cd_cpc(folder)
                except Exception:
                    pass
                self.root.after(0, lambda: self.m4_run(name))
            threading.Thread(target=go, daemon=True).start()

        def do_delete():
            e = sel()
            if not e or e[0] == "..":
                return
            target = join(path[0], e[0])
            if DialogHelper.askyesno("Supprimer", "Supprimer %s ?" % target,
                                   parent=win):
                self._m4_async("Suppression de %s" % e[0],
                               lambda: self.m4.rm(target), lambda r: refresh())

        def do_mkdir():
            name = DialogHelper.askstring("Nouveau dossier", "Nom du dossier :",
                                          parent=win)
            if name:
                self._m4_async("Creation de %s" % name,
                               lambda: self.m4.mkdir(join(path[0], name)),
                               lambda r: refresh())

        bar = ctk.CTkFrame(win, fg_color="#2a2a2a")
        bar.pack(fill="x", padx=10, pady=10)
        buttons = [("📁 Entrer", enter), ("📤 Envoyer", do_upload),
                   ("📥 Telecharger", do_download), ("▶️ Lancer", do_run),
                   ("🗑️ Supprimer", do_delete), ("📂 Nouv. dossier", do_mkdir),
                   ("🔄 Actualiser", refresh)]
        for text, cmd in buttons:
            ctk.CTkButton(bar, text=text, command=cmd, font=("Segoe UI", 10),
                         fg_color="#1060c0", text_color="#ffff00",
                         hover_color="#1a90ff").pack(side="left", padx=3)
        refresh()

    def do_dump(self):
        """Relever l'ecran actuel du CPC (comme --dump, a la demande)."""
        self.link.send(CMD_DUMP)

    def do_refont(self):
        """Redemander le jeu de caracteres au CPC."""
        self.screen.font = None         # force le re-enregistrement au retour
        self.link.send(CMD_FONT)

    def set_size(self, z):
        self.root.geometry("%dx%d" % (160 * z, 120 * z))

    # --- barre de statut -------------------------------------------
    def _update_status(self):
        mode = {20: "0", 40: "1", 80: "2"}.get(self.screen.width, "?")
        etat = "deconnecte" if self._closed else "connecte"
        self.statusbar.configure(
            text="%s : %s    MODE %s    L%02d C%02d    |    %s"
            % (self.host, etat, mode, self.screen.row + 1, self.screen.col + 1,
               self.status_msg))

    def set_status(self, msg):
        self.status_msg = msg
        self._update_status()

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

    def paste(self):
        """Lire le presse-papiers et envoyer le texte ligne par ligne au CPC.
        Chaque ligne est envoyee avec un delai entre elles pour laisser le
        BASIC traiter et afficher le prompt."""
        try:
            text = self.root.clipboard_get()
        except tk.TclError:
            messagebox.showwarning("Coller", "Presse-papiers vide ou inaccessible")
            return

        # Normaliser et decouper par lignes
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        lines = text.split("\n")
        lines = [l for l in lines if l]  # ignorer les lignes vides

        def send_line(index):
            if index >= len(lines):
                self.set_status("Colle : %d lignes terminees" % len(lines))
                return
            line = lines[index]
            # Envoyer les caracteres de la ligne
            for ch in line:
                b = to_cpc(ch)
                if b:
                    self.link.send(b)
            # Puis CR (Entree) pour executer la ligne
            self.link.send(b"\r")
            # Planifier l'envoi de la ligne suivante avec 250ms de delai
            # (laisser le BASIC traiter la ligne, afficher le resultat, remonter)
            self.root.after(250, lambda: send_line(index + 1))

        self.set_status("Collage de %d lignes en cours..." % len(lines))
        send_line(0)

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
        # Adapter a la fenetre : on etire l'image dans le plus grand
        # rectangle 4:3 qui tient dans le canvas (les pixels du CPC ne sont
        # pas carres -> proportions d'ecran 4:3), puis on centre (bandes
        # noires si la fenetre n'est pas exactement au ratio). Les
        # caracteres suivent donc la taille de la fenetre.
        cw = self.canvas.winfo_width()
        ch = self.canvas.winfo_height()
        if cw < 8 or ch < 8:                        # fenetre pas encore mesuree
            cw, ch = 160 * self.zoom, 120 * self.zoom
        if cw * 3 >= ch * 4:                        # plus large que 4:3
            dh, dw = ch, ch * 4 // 3
        else:                                       # plus haut que 4:3
            dw, dh = cw, cw * 3 // 4
        out = frame.resize((max(dw, 1), max(dh, 1)), Image.NEAREST)
        self.photo = ImageTk.PhotoImage(out)
        self.canvas.delete("all")
        self.canvas.create_image(cw // 2, ch // 2, anchor="center",
                                 image=self.photo)

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
            self._closed = True
            self.set_status("connexion fermee")
            self.root.title(self.root.title() + " — deconnecte")
            return
        self._update_status()
        self.root.after(50, self.tick)


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("host", help="adresse IP du CPC")
    p.add_argument("port", nargs="?", type=int, default=6128)
    p.add_argument("--zoom", type=int, default=4,
                   help="taille INITIALE de la fenetre (defaut 4 = 640x480) ; "
                        "la fenetre est ensuite redimensionnable a la souris")
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
