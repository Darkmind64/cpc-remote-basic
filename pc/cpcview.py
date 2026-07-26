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
import json
import os
import queue
import socket
import sys
import threading
import tkinter as tk
from tkinter import filedialog, ttk

from PIL import Image, ImageTk

from cpcterm import (CMD_DUMP, CMD_ECHO, CMD_FONT, CPC_RGB, FONT_LEN,
                     CpcScreen, to_cpc)
from m4term import M4                 # client HTTP de la carte M4 (reutilise)

FONT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "cpcfont.bin")
ROWS = 25
CELL = 8                        # un caractere CPC : 8 x 8 pixels
CONFIG_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cpcview_config.json")


class ConfigManager:
    """Gestion des paramètres persistants (config.json)."""

    @staticmethod
    def load():
        """Charger la config depuis le fichier."""
        defaults = {
            "last_host": "192.168.1.139",
            "zoom": 4,
            "theme": "dark",
            "window_geometry": "640x480",
            "recent_hosts": ["192.168.1.139"],
        }
        if not os.path.exists(CONFIG_FILE):
            return defaults
        try:
            with open(CONFIG_FILE, "r") as f:
                config = json.load(f)
                # Fusionner avec les defaults pour les clés manquantes
                return {**defaults, **config}
        except (json.JSONDecodeError, IOError):
            return defaults

    @staticmethod
    def save(config):
        """Sauvegarder la config dans le fichier."""
        try:
            with open(CONFIG_FILE, "w") as f:
                json.dump(config, f, indent=2)
        except IOError as e:
            print(f"Erreur sauvegarde config: {e}")

    @staticmethod
    def update_host(host):
        """Ajouter/mettre à jour l'host récent."""
        config = ConfigManager.load()
        if host not in config.get("recent_hosts", []):
            config.setdefault("recent_hosts", []).insert(0, host)
            config["recent_hosts"] = config["recent_hosts"][:10]  # Garder 10 derniers
        config["last_host"] = host
        ConfigManager.save(config)


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
        ctk.CTkButton(btn_frame, text="✓ OK", command=ok, width=90,
                     fg_color="#1060c0", hover_color="#1a90ff",
                     font=("Segoe UI", 10, "bold")).pack(side="left", padx=10, expand=True)
        ctk.CTkButton(btn_frame, text="✕ Annuler", command=cancel, width=90,
                     fg_color="#404040", hover_color="#606060",
                     font=("Segoe UI", 10, "bold")).pack(side="left", padx=10, expand=True)

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
        ctk.CTkButton(btn_frame, text="✓ Oui", command=yes, width=90,
                     fg_color="#00aa00", hover_color="#00cc00",
                     font=("Segoe UI", 10, "bold")).pack(side="left", padx=10, expand=True)
        ctk.CTkButton(btn_frame, text="✕ Non", command=no, width=90,
                     fg_color="#aa0000", hover_color="#cc0000",
                     font=("Segoe UI", 10, "bold")).pack(side="left", padx=10, expand=True)

        dialog.wait_window()
        return result[0]

    @staticmethod
    def showerror(title, message, parent=None):
        """Error dialog."""
        dialog = ctk.CTkToplevel(parent)
        dialog.title(title)
        dialog.geometry("400x180")
        dialog.configure(fg_color="#1a1a1a")
        dialog.resizable(False, False)

        ctk.CTkLabel(dialog, text=message, text_color="#ff6060",
                    font=("Segoe UI", 11), wraplength=350).pack(padx=15, pady=20)

        def ok():
            dialog.destroy()

        btn_frame = ctk.CTkFrame(dialog, fg_color="#1a1a1a")
        btn_frame.pack(fill="x", padx=15, pady=15)
        ctk.CTkButton(btn_frame, text="✓ OK", command=ok, width=90,
                     fg_color="#aa0000", hover_color="#cc0000",
                     font=("Segoe UI", 10, "bold")).pack(side="left", padx=10, expand=True)

        dialog.wait_window()

    @staticmethod
    def showwarning(title, message, parent=None):
        """Warning dialog."""
        dialog = ctk.CTkToplevel(parent)
        dialog.title(title)
        dialog.geometry("400x180")
        dialog.configure(fg_color="#1a1a1a")
        dialog.resizable(False, False)

        ctk.CTkLabel(dialog, text=message, text_color="#ffaa00",
                    font=("Segoe UI", 11), wraplength=350).pack(padx=15, pady=20)

        def ok():
            dialog.destroy()

        btn_frame = ctk.CTkFrame(dialog, fg_color="#1a1a1a")
        btn_frame.pack(fill="x", padx=15, pady=15)
        ctk.CTkButton(btn_frame, text="✓ OK", command=ok, width=90,
                     fg_color="#ff8800", hover_color="#ffaa00",
                     font=("Segoe UI", 10, "bold")).pack(side="left", padx=10, expand=True)

        dialog.wait_window()

    @staticmethod
    def askinteger(title, prompt, parent=None, minvalue=0, maxvalue=9999):
        """Integer input dialog — retourne l'entier ou None si annulé."""
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

        def ok():
            try:
                val = int(entry.get())
                if minvalue <= val <= maxvalue:
                    result[0] = val
                    dialog.destroy()
            except ValueError:
                pass

        def cancel():
            dialog.destroy()

        btn_frame = ctk.CTkFrame(dialog, fg_color="#1a1a1a")
        btn_frame.pack(fill="x", padx=15, pady=15)
        ctk.CTkButton(btn_frame, text="✓ OK", command=ok, width=90,
                     fg_color="#1060c0", hover_color="#1a90ff",
                     font=("Segoe UI", 10, "bold")).pack(side="left", padx=10, expand=True)
        ctk.CTkButton(btn_frame, text="✕ Annuler", command=cancel, width=90,
                     fg_color="#404040", hover_color="#606060",
                     font=("Segoe UI", 10, "bold")).pack(side="left", padx=10, expand=True)

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


class CTkListbox(ctk.CTkFrame):
    """Listbox personnalisée avec customtkinter — remplace tk.Listbox."""

    def __init__(self, parent, **kwargs):
        super().__init__(parent, fg_color="#2a2a2a", **kwargs)
        self.items = []
        self.selection = []
        self._double_click_callback = None
        self._return_callback = None

        # Scrollable container
        self.scroll_frame = ctk.CTkScrollableFrame(self, fg_color="#000030")
        self.scroll_frame.pack(fill="both", expand=True)

        self.item_widgets = []
        self.item_labels = []

    def insert(self, index, text):
        """Ajouter un item à la liste."""
        if index == "end":
            self.items.append(text)
        else:
            self.items.insert(index, text)
        self._refresh_display()

    def delete(self, start, end=None):
        """Supprimer des items."""
        if end is None:
            end = start
        if isinstance(start, int) and isinstance(end, int):
            del self.items[start:end+1]
        self._refresh_display()

    def curselection(self):
        """Retourner la sélection actuelle (tuple)."""
        return tuple(self.selection)

    def bind(self, sequence, callback):
        """Binder les événements."""
        if sequence == "<Double-Button-1>":
            self._double_click_callback = callback
        elif sequence == "<Return>":
            self._return_callback = callback

    def _refresh_display(self):
        """Rafraîchir l'affichage de la liste."""
        for widget in self.item_widgets:
            widget.destroy()
        self.item_widgets = []
        self.item_labels = []
        self.selection = []

        for idx, text in enumerate(self.items):
            item_frame = ctk.CTkFrame(self.scroll_frame, fg_color="#000030",
                                      cursor="hand2")
            item_frame.pack(fill="x", padx=0, pady=0)

            label = ctk.CTkLabel(item_frame, text=text, text_color="#e0e0e0",
                                font=("Consolas", 11), anchor="w", justify="left")
            label.pack(fill="x", padx=5, pady=3)

            def make_click_handler(i):
                def on_click(e):
                    self.selection = [i]
                    self._refresh_highlight()
                return on_click

            def make_dbl_click_handler(i):
                def on_dbl_click(e):
                    self.selection = [i]
                    self._refresh_highlight()
                    if self._double_click_callback:
                        self._double_click_callback(None)
                return on_dbl_click

            label.bind("<Button-1>", make_click_handler(idx))
            label.bind("<Double-Button-1>", make_dbl_click_handler(idx))
            item_frame.bind("<Button-1>", make_click_handler(idx))
            item_frame.bind("<Double-Button-1>", make_dbl_click_handler(idx))

            self.item_widgets.append(item_frame)
            self.item_labels.append(label)

        self._refresh_highlight()

    def _refresh_highlight(self):
        """Rafraîchir la surbrillance."""
        for idx, widget in enumerate(self.item_widgets):
            if idx in self.selection:
                widget.configure(fg_color="#1060c0")
            else:
                widget.configure(fg_color="#000030")


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

        # Charger la config
        self.config = ConfigManager.load()
        ConfigManager.update_host(self.host)

        # Appliquer thème sauvegardé
        self.theme = self.config.get("theme", "dark")
        ctk.set_appearance_mode(self.theme)

        root.title("CPC — %s" % self.host)
        root.configure(bg="black")
        # NOTE: géométrie appliquée par main() pour respecter la config sauvegardée

        # Sauvegarder la géométrie/zoom à la fermeture
        def on_closing():
            # Calculer le zoom RÉEL en fonction de la géométrie finale
            geom = root.geometry()  # Format: "WIDTHxHEIGHT+X+Y"
            try:
                width = int(geom.split('x')[0])
                actual_zoom = max(4, width // 160)  # Min zoom = 4 (640x480)
                self.config["zoom"] = actual_zoom
            except (ValueError, IndexError):
                self.config["zoom"] = zoom  # Fallback si erreur parsing

            self.config["window_geometry"] = geom
            self.config["theme"] = self.theme
            ConfigManager.save(self.config)
            root.destroy()
        root.protocol("WM_DELETE_WINDOW", on_closing)

        self._build_menu()

        # Barre d'outils (toolbar) avec actions rapides
        toolbar = ctk.CTkFrame(root, fg_color="#2a2a2a", height=40)
        toolbar.pack(side="top", fill="x", padx=0, pady=0)
        toolbar.pack_propagate(False)

        # Boutons de la toolbar
        btn_style = {"font": ("Segoe UI", 10), "fg_color": "#1060c0",
                    "hover_color": "#1a90ff", "text_color": "#ffff00"}
        ctk.CTkButton(toolbar, text="📁 Fichiers", command=self.m4_browse,
                     **btn_style).pack(side="left", padx=3, pady=6)
        ctk.CTkButton(toolbar, text="⚙️ Param", command=self.m4_settings,
                     **btn_style).pack(side="left", padx=3, pady=6)
        ctk.CTkButton(toolbar, text="💿 ROMs", command=self.m4_rom_manager,
                     **btn_style).pack(side="left", padx=3, pady=6)
        ctk.CTkButton(toolbar, text="▶️ Lancer", command=self.m4_run_dialog,
                     **btn_style).pack(side="left", padx=3, pady=6)
        ctk.CTkButton(toolbar, text="⏸ Pause", command=self.m4_pause,
                     **btn_style).pack(side="left", padx=3, pady=6)
        ctk.CTkButton(toolbar, text="🔌 Reset CPC", command=self.m4_reset_cpc,
                     **btn_style).pack(side="left", padx=3, pady=6)
        ctk.CTkButton(toolbar, text="🔄 Reset M4", command=self.m4_reset_m4,
                     **btn_style).pack(side="left", padx=3, pady=6)

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
        # Raccourcis clavier
        root.bind("<F1>", lambda e: self._show_help())
        root.bind("<F2>", lambda e: self.m4_settings())
        root.bind("<F3>", lambda e: self.m4_browse())
        root.bind("<F5>", lambda e: self.do_dump())
        root.bind("<Control-l>", lambda e: self.m4_run_dialog())
        root.bind("<Control-r>", lambda e: self.do_dump())
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

        # --- Fichier (avec hosts récents)
        f = tk.Menu(bar, tearoff=0)
        recent_hosts = self.config.get("recent_hosts", [])
        if recent_hosts:
            for host in recent_hosts[:5]:  # Afficher 5 derniers
                f.add_command(label="Reconnecter à %s" % host,
                             command=lambda h=host: self._reconnect(h))
            f.add_separator()
        f.add_command(label="Quitter", command=self.root.destroy)
        bar.add_cascade(label="Fichier", menu=f)

        m = tk.Menu(bar, tearoff=0)
        m.add_command(label="Relever l'ecran", command=self.do_dump,
                      accelerator="F5")
        m.add_command(label="Recharger la police du CPC", command=self.do_refont)
        m.add_separator()
        m.add_command(label="Quitter", command=self.root.destroy)
        bar.add_cascade(label="Ecran", menu=m)
        t = tk.Menu(bar, tearoff=0)
        for z in (4, 5, 6, 7, 8):
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

        # Sous-menu Fichiers
        m4_files = tk.Menu(m4, tearoff=0)
        m4_files.add_command(label="Navigateur de fichiers...", command=self.m4_browse,
                            accelerator="F3")
        m4_files.add_command(label="Envoyer un fichier vers la SD...",
                            command=self.m4_upload)
        m4_files.add_command(label="Telecharger un fichier...", command=self.m4_download)
        m4_files.add_command(label="Lancer un programme...", command=self.m4_run,
                            accelerator="Ctrl+L")
        m4_files.add_command(label="Lister un dossier...", command=self.m4_ls)
        m4.add_cascade(label="Fichiers", menu=m4_files)

        # Sous-menu Configuration
        m4_config = tk.Menu(m4, tearoff=0)
        m4_config.add_command(label="Parametres M4...", command=self.m4_settings,
                             accelerator="F2")
        m4_config.add_command(label="Gerer les ROMs...", command=self.m4_rom_manager)
        m4.add_cascade(label="Configuration", menu=m4_config)

        # Sous-menu Gestion
        m4_manage = tk.Menu(m4, tearoff=0)
        m4_manage.add_command(label="Nouveau dossier...", command=self.m4_mkdir)
        m4_manage.add_command(label="Supprimer un fichier/dossier...", command=self.m4_rm)
        m4.add_cascade(label="Gestion", menu=m4_manage)

        # Sous-menu Controle
        m4_control = tk.Menu(m4, tearoff=0)
        m4_control.add_command(label="Pause / reprise CPC", command=self.m4_pause)
        m4_control.add_command(label="Reset CPC", command=self.m4_reset_cpc)
        m4_control.add_command(label="Reset carte M4", command=self.m4_reset_m4)
        m4.add_cascade(label="Controle", menu=m4_control)

        bar.add_cascade(label="M4", menu=m4)

        # --- Menu Aide
        h = tk.Menu(bar, tearoff=0)
        h.add_command(label="Raccourcis clavier (F1)", command=self._show_help,
                     accelerator="F1")
        bar.add_cascade(label="Aide", menu=h)

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
            DialogHelper.showerror("M4", "%s : echec\n%s" % (label, e))

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

    def m4_run_dialog(self):
        """Alias pour la toolbar — demande le nom du fichier à lancer."""
        self.m4_run()

    def m4_ls(self):
        """Afficher le listing d'un dossier SD — version avec parcourir."""
        # Fallback dialog si le parcourir échoue
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
        slot = DialogHelper.askinteger("Installer une ROM", "Numero de slot (0-31) :",
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
        slot = DialogHelper.askinteger("Supprimer une ROM",
                                       "Numero de slot a vider (0-31) :",
                                       minvalue=0, maxvalue=31, parent=self.root)
        if slot is None:
            return
        if DialogHelper.askyesno("Supprimer une ROM", "Vider le slot %d ?" % slot):
            self._m4_async("Suppression ROM slot %d" % slot,
                           lambda: self.m4.rom_delete(slot))

    def _get_sd_space(self):
        """Récupérer l'estimation de l'espace utilisé sur la SD.
        Retourne (used_kb, total_kb) ou (0, 0) si erreur."""
        try:
            # Parser dir.txt pour calculer la taille totale
            dir_text = self.m4.ls("/")
            total_size = 0
            for line in dir_text.splitlines():
                parts = line.rstrip("\r").rsplit(",", 2)
                if len(parts) == 3:
                    try:
                        size_str = parts[2].strip()
                        if size_str.isdigit():
                            total_size += int(size_str)
                    except (ValueError, AttributeError):
                        pass
            # Retourner en KB, et estimer le total à 512MB (valeur typique M4)
            used_kb = total_size // 1024
            total_kb = 512 * 1024  # 512MB
            return used_kb, total_kb
        except Exception:
            return 0, 0

    def _fetch_m4_roms(self):
        """Récupérer l'état complet des ROMs en parsant roms.shtml.
        Retourne : (config_dict, roms_dict) où roms_dict[slot] = name"""
        import re
        html = self.m4._get("roms.shtml").decode("latin-1", "replace")

        # Parser les paramètres de configuration exactement comme le HTML
        config = {}

        # Enabled : checkbox m4en (cherche 'checked' avant name="m4en")
        m = re.search(r'name="m4en"[^>]*checked', html, re.IGNORECASE) or \
            re.search(r'checked[^>]*name="m4en"', html, re.IGNORECASE)
        config['enabled'] = bool(m)
        config['_enabled_param'] = 'm4en'
        config['_enabled_cgi'] = 'checkbox2.cgi'

        # Rom number : input value="X" name="m4rm"
        m = re.search(r'name="m4rm"[^>]*value="?([^">\s]+)"?', html, re.IGNORECASE) or \
            re.search(r'value="?([^">\s]+)"?[^>]*name="m4rm"', html, re.IGNORECASE)
        config['rom_number'] = m.group(1) if m else "6"
        config['_rom_number_param'] = 'm4rm'
        config['_rom_number_cgi'] = 'config.cgi'

        # Romboard start : input value="X" name="m4rb"
        m = re.search(r'name="m4rb"[^>]*value="?([^">\s]+)"?', html, re.IGNORECASE) or \
            re.search(r'value="?([^">\s]+)"?[^>]*name="m4rb"', html, re.IGNORECASE)
        config['romboard_start'] = m.group(1) if m else "0"
        config['_romboard_start_param'] = 'm4rb'
        config['_romboard_start_cgi'] = 'config.cgi'

        # Lower-rom Enabled : checkbox lwen
        m = re.search(r'name="lwen"[^>]*checked', html, re.IGNORECASE) or \
            re.search(r'checked[^>]*name="lwen"', html, re.IGNORECASE)
        config['lower_enabled'] = bool(m)
        config['_lower_enabled_param'] = 'lwen'
        config['_lower_enabled_cgi'] = 'checkbox3.cgi'

        # Lower-rom slot : input value="X" name="lwsl"
        m = re.search(r'name="lwsl"[^>]*value="?([^">\s]+)"?', html, re.IGNORECASE) or \
            re.search(r'value="?([^">\s]+)"?[^>]*name="lwsl"', html, re.IGNORECASE)
        config['lower_slot'] = m.group(1) if m else "31"
        config['_lower_slot_param'] = 'lwsl'
        config['_lower_slot_cgi'] = 'config.cgi'

        # Use only 16 slots : checkbox rs16
        m = re.search(r'name="rs16"[^>]*checked', html, re.IGNORECASE) or \
            re.search(r'checked[^>]*name="rs16"', html, re.IGNORECASE)
        config['use_16_slots'] = bool(m)
        config['_use_16_slots_param'] = 'rs16'
        config['_use_16_slots_cgi'] = 'checkbox4.cgi'

        # Parser les ROMs (chercher les lignes <tr><td>Rom slot N</td><td><!--#romn-->NAME</td>)
        roms = {}
        for i in range(32):
            roms[i] = ""  # nom vide par défaut

        # Chercher le pattern complet : <tr><td>Rom slot X</td><td><!--#romn-->ROMNAME</td>
        for match in re.finditer(r'<tr><td>\s*Rom\s+slot\s+(\d+)\s*</td><td>\s*<!--#romn-->\s*([^<]*)\s*</td>', html, re.IGNORECASE):
            slot_str, name = match.groups()
            try:
                slot = int(slot_str.strip())
                name = name.strip()
                if slot < 32:
                    roms[slot] = name  # Peut être vide string, c'est OK
            except (ValueError, AttributeError):
                pass

        return config, roms

    def m4_rom_manager(self):
        """Gestionnaire graphique des ROMs — interface inspirée du web (roms.shtml)."""
        win = ctk.CTkToplevel(self.root)
        win.title("Gestionnaire ROMs — M4 Board")
        win.geometry("1000x700")
        win.configure(fg_color="#1a1a1a")

        config = {}
        roms = {}

        # Titre
        title_lbl = ctk.CTkLabel(win, text="🎮 M4 Rom Config",
                                text_color="#ffff00", font=("Segoe UI", 14, "bold"))
        title_lbl.pack(pady=10)

        # === ESPACE DISQUE SD ===
        space_frame = ctk.CTkFrame(win, fg_color="#2a2a2a")
        space_frame.pack(fill="x", padx=15, pady=(0, 10))

        space_info_lbl = ctk.CTkLabel(space_frame, text="💾 SD Card Space: --",
                                     text_color="#ffff00", font=("Segoe UI", 10))
        space_info_lbl.pack(side="left", padx=10, pady=5)

        space_progress = ctk.CTkProgressBar(space_frame, fg_color="#1a1a1a",
                                           progress_color="#00aa00", width=300)
        space_progress.set(0.5)
        space_progress.pack(side="left", padx=10, pady=5, fill="x", expand=True)

        # === CONFIG SECTION (scrollable) ===
        config_frame = ctk.CTkFrame(win, fg_color="#2a2a2a")
        config_frame.pack(fill="x", padx=15, pady=(0, 15))

        # Grille des paramètres de config
        params = [
            ("Enabled", "enabled"),
            ("Rom number", "rom_number"),
            ("Romboard start", "romboard_start"),
            ("Lower-rom Enabled", "lower_enabled"),
            ("Lower-rom slot", "lower_slot"),
            ("Use only 16 slots", "use_16_slots"),
        ]

        config_widgets = {}  # key -> widget pour update

        for row, (label_text, key) in enumerate(params):
            lbl = ctk.CTkLabel(config_frame, text=label_text, text_color="#ffffff",
                              font=("Segoe UI", 10), anchor="w")
            lbl.grid(row=row, column=0, sticky="w", padx=10, pady=5)

            if "Enabled" in label_text or "only" in label_text:
                # Checkbox
                var = tk.BooleanVar()
                chk = ctk.CTkCheckBox(config_frame, text="", variable=var,
                                     fg_color="#1060c0", hover_color="#1a90ff")
                chk.grid(row=row, column=1, sticky="w", padx=10, pady=5)
                config_widgets[key] = (chk, var, "bool")
            else:
                # Input field
                entry = ctk.CTkEntry(config_frame, fg_color="#000030", border_color="#404040",
                                    text_color="#ffff00", font=("Consolas", 10), width=150)
                entry.grid(row=row, column=1, sticky="w", padx=10, pady=5)
                config_widgets[key] = (entry, entry, "text")

            # Set button
            def make_set_handler(k, widget_info):
                def h():
                    widget, var, typ = widget_info
                    # Récupérer la valeur depuis le widget
                    if typ == "bool":
                        value = var.get()
                        param_name = config.get(f'_{k}_param')
                        cgi_name = config.get(f'_{k}_cgi')
                        # Pour les checkboxes, envoyer "on" si coché, sinon rien
                        if value:
                            self._m4_async(f"Modification {k}",
                                          lambda: self.m4._get(cgi_name, **{param_name: "on"}),
                                          lambda r: refresh_all())
                        else:
                            self._m4_async(f"Modification {k}",
                                          lambda: self.m4._get(cgi_name, **{param_name: ""}),
                                          lambda r: refresh_all())
                    else:
                        value = widget.get()
                        param_name = config.get(f'_{k}_param')
                        cgi_name = config.get(f'_{k}_cgi')
                        if value:
                            self._m4_async(f"Modification {k}",
                                          lambda: self.m4._get(cgi_name, **{param_name: value}),
                                          lambda r: refresh_all())
                return h

            btn = ctk.CTkButton(config_frame, text="Set",
                               command=make_set_handler(key, config_widgets[key]),
                               width=60, font=("Segoe UI", 9), fg_color="#1060c0",
                               hover_color="#1a90ff")
            btn.grid(row=row, column=2, padx=10, pady=5)

        # === ROM BOARD SECTION ===
        board_lbl = ctk.CTkLabel(win, text="📋 Rom board",
                                text_color="#ffff00", font=("Segoe UI", 12, "bold"))
        board_lbl.pack(pady=(10, 5))

        # Scrollable list de ROMs
        board_frame = ctk.CTkFrame(win, fg_color="#2a2a2a")
        board_frame.pack(fill="both", expand=True, padx=15, pady=(0, 15))

        rom_display_frame = ctk.CTkScrollableFrame(board_frame, fg_color="#000030")
        rom_display_frame.pack(fill="both", expand=True)

        rom_widgets = {}  # slot -> (label_name_widget, remove_btn, upload_btn)

        def update_rom_display():
            """Rafraîchir l'affichage des ROMs."""
            # Nettoyer
            for widget in rom_display_frame.winfo_children():
                widget.destroy()
            rom_widgets.clear()

            # Afficher chaque slot
            for slot in range(32):
                slot_frame = ctk.CTkFrame(rom_display_frame, fg_color="#1a1a1a",
                                         corner_radius=3)
                slot_frame.pack(fill="x", pady=2)

                rom_name = roms.get(slot, "")

                # Slot label + name
                info_text = f"Rom slot {slot:2d}"
                if rom_name:
                    info_text += f"  {rom_name}"

                info_lbl = ctk.CTkLabel(slot_frame, text=info_text,
                                       text_color="#ffff00" if rom_name else "#888888",
                                       font=("Consolas", 10), anchor="w")
                info_lbl.pack(side="left", padx=10, pady=4, fill="x", expand=True)

                # Boutons Remove et Upload
                def make_remove_handler(s):
                    def h():
                        if DialogHelper.askyesno("Supprimer ROM",
                                                f"Vider le slot {s} ?", parent=win):
                            self._m4_async(f"Suppression ROM slot {s}",
                                          lambda: self.m4.rom_delete(s),
                                          lambda r: refresh_all())
                    return h

                def make_upload_handler(s):
                    def h():
                        local = filedialog.askopenfilename(
                            parent=win, title="ROM a charger",
                            filetypes=[("ROM", "*.rom *.bin"), ("All", "*.*")])
                        if not local:
                            return
                        default = os.path.splitext(os.path.basename(local))[0][:16].upper()
                        name = DialogHelper.askstring("Charger ROM", "Nom:",
                                                     initialvalue=default, parent=win)
                        if name:
                            self._m4_async(f"Installation ROM slot {s}",
                                          lambda: self.m4.rom_install(local, s, name),
                                          lambda r: refresh_all())
                    return h

                remove_btn = ctk.CTkButton(slot_frame, text="🗑️ Remove", width=80,
                                          command=make_remove_handler(slot),
                                          font=("Segoe UI", 9),
                                          fg_color="#aa0000", hover_color="#cc0000")
                remove_btn.pack(side="right", padx=3, pady=4)

                upload_btn = ctk.CTkButton(slot_frame, text="📥 Upload", width=80,
                                          command=make_upload_handler(slot),
                                          font=("Segoe UI", 9),
                                          fg_color="#0060aa", hover_color="#1a90ff")
                upload_btn.pack(side="right", padx=3, pady=4)

                rom_widgets[slot] = (info_lbl, remove_btn, upload_btn)

        def refresh_all():
            """Charger les données depuis la M4."""
            def load():
                nonlocal config, roms
                config, roms = self._fetch_m4_roms()
                space_data = [self._get_sd_space()]  # Retourner dans une liste pour nonlocal
                return space_data[0]

            def update_ui(space_info):
                # Mettre à jour les champs de config
                for key, (widget, var, typ) in config_widgets.items():
                    val = config.get(key, "")
                    if typ == "bool":
                        var.set(val if isinstance(val, bool) else False)
                    else:
                        widget.delete(0, "end")
                        widget.insert(0, str(val))

                # Mettre à jour l'affichage de l'espace disque
                if space_info:
                    used_kb, total_kb = space_info
                    if total_kb > 0:
                        percent = used_kb / total_kb
                        space_progress.set(percent)
                        # Couleur : vert < 70%, orange 70-90%, rouge > 90%
                        if percent < 0.7:
                            color = "#00aa00"
                        elif percent < 0.9:
                            color = "#ffaa00"
                        else:
                            color = "#aa0000"
                        space_progress.configure(progress_color=color)
                        used_mb = used_kb / 1024
                        total_mb = total_kb / 1024
                        space_info_lbl.configure(
                            text=f"💾 SD: {used_mb:.1f} MB / {total_mb:.1f} MB ({percent*100:.1f}%)")

                # Mettre à jour l'affichage des ROMs
                update_rom_display()
                self.set_status("ROMs et espace disque chargés")

            self._m4_async("Lecture des ROMs et espace SD", load, update_ui)

        # Charger au démarrage
        refresh_all()

        # Bouton Rafraîchir
        refresh_btn = ctk.CTkButton(win, text="🔄 Rafraîchir", command=refresh_all,
                                   font=("Segoe UI", 10), fg_color="#00aa00",
                                   hover_color="#00cc00")
        refresh_btn.pack(pady=10)

    def _browse_sd_path(self, title="Sélectionner un chemin", on_select=None):
        """Fenêtre graphique pour parcourir et sélectionner un chemin SD.
        Retourne le chemin sélectionné ou None si annulé."""
        win = ctk.CTkToplevel(self.root)
        win.title(title)
        win.geometry("600x400")
        win.configure(fg_color="#1a1a1a")
        path = ["/"]
        result = [None]

        lbl = ctk.CTkLabel(win, text="SD : /", anchor="w", text_color="#ffd000",
                          font=("Segoe UI", 11, "bold"))
        lbl.pack(fill="x", padx=10, pady=8)

        frame = ctk.CTkFrame(win, fg_color="#2a2a2a")
        frame.pack(fill="both", expand=True, padx=10, pady=(0, 10))
        lst = CTkListbox(frame)
        lst.pack(fill="both", expand=True)

        def join(base, name):
            p = base.rstrip("/") + "/" + name
            return "/" + "/".join(s for s in p.split("/") if s)

        def refresh():
            lbl.configure(text="SD : " + path[0])
            lst.items.clear()
            lst.item_widgets.clear()
            try:
                parsed = parse_dir(self.m4.ls(path[0]))
            except Exception as e:
                DialogHelper.showerror("SD", str(e), parent=win)
                return
            if path[0] != "/":
                lst.insert("end", "[..]")
            for name, is_dir, size in parsed:
                if is_dir:
                    lst.insert("end", "[ %s ]" % name)
                else:
                    lst.insert("end", "   %-22s %6s" % (name[:22], size))
            lst._refresh_display()

        def enter(_=None):
            s = lst.curselection()
            if not s:
                return
            name = parsed[s[0]][0] if s[0] < len(parsed) else ".."
            is_dir = parsed[s[0]][1] if s[0] < len(parsed) else True
            if name == ".." or not is_dir:
                if name == "..":
                    up = "/".join(path[0].strip("/").split("/")[:-1])
                    path[0] = "/" + up if up else "/"
                refresh()
            else:
                path[0] = join(path[0], name)
                refresh()

        def select_current():
            result[0] = path[0]
            win.destroy()

        parsed = []
        refresh()

        bar = ctk.CTkFrame(win, fg_color="#2a2a2a")
        bar.pack(fill="x", padx=10, pady=10)
        ctk.CTkButton(bar, text="✓ Sélectionner", command=select_current,
                     font=("Segoe UI", 10), fg_color="#00aa00",
                     hover_color="#00cc00").pack(side="left", padx=3)
        ctk.CTkButton(bar, text="✕ Annuler", command=win.destroy,
                     font=("Segoe UI", 10), fg_color="#aa0000",
                     hover_color="#cc0000").pack(side="left", padx=3)

        win.wait_window()
        return result[0]

    def _ask_sd_path_method(self, title="Chemin"):
        """Dialog pour choisir entre parcourir graphiquement ou saisir du texte."""
        dialog = ctk.CTkToplevel(self.root)
        dialog.title(title)
        dialog.geometry("400x180")
        dialog.configure(fg_color="#1a1a1a")
        dialog.resizable(False, False)

        result = [None]

        ctk.CTkLabel(dialog, text="Comment saisir le chemin ?",
                    text_color="#e0e0e0", font=("Segoe UI", 12, "bold")).pack(pady=15)

        btn_frame = ctk.CTkFrame(dialog, fg_color="#1a1a1a")
        btn_frame.pack(fill="x", padx=15, pady=15)

        def browse():
            result[0] = self._browse_sd_path(title=title)
            dialog.destroy()

        def type_manually():
            result[0] = DialogHelper.askstring(title, "Chemin :",
                                              initialvalue="/", parent=self.root)
            if result[0] is not None:
                dialog.destroy()

        ctk.CTkButton(btn_frame, text="📂 Parcourir graphiquement", command=browse,
                     fg_color="#1060c0", hover_color="#1a90ff",
                     font=("Segoe UI", 10, "bold")).pack(fill="x", pady=5)
        ctk.CTkButton(btn_frame, text="⌨️ Saisir du texte", command=type_manually,
                     fg_color="#00aa00", hover_color="#00cc00",
                     font=("Segoe UI", 10, "bold")).pack(fill="x", pady=5)

        dialog.wait_window()
        return result[0]

    def m4_mkdir(self):
        """Créer un dossier — choix du chemin via parcourir ou texte."""
        d = self._ask_sd_path_method("Créer un dossier")
        if d:
            self._m4_async("Creation de %s" % d, lambda: self.m4.mkdir(d))

    def m4_rm(self):
        """Supprimer un fichier/dossier — choix du chemin via parcourir ou texte."""
        t = self._ask_sd_path_method("Supprimer un fichier/dossier")
        if t and DialogHelper.askyesno("Supprimer", "Supprimer %s ?" % t, parent=self.root):
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
        lst = CTkListbox(frame)
        lst.pack(fill="both", expand=True)

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
                DialogHelper.showerror("SD", str(e), parent=win)
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

    def _show_help(self):
        """Afficher l'aide des raccourcis clavier."""
        help_text = """📖 CPCVIEW — Raccourcis clavier

Affichage :
  F5              Relever l'écran
  Ctrl+R          Relever l'écran (alternative)

Édition :
  Ctrl+V          Coller depuis le presse-papiers

M4 Board :
  F2              Ouvrir les paramètres
  F3              Ouvrir le navigateur de fichiers
  Ctrl+L          Lancer un programme

Toolbar :
  📁 Fichiers     Navigateur de fichiers
  ⚙️ Param        Paramètres M4
  ▶️ Lancer       Lancer un programme
  ⏸ Pause         Pause/Reprise du CPC
  🔌 Reset CPC    Redémarrer le CPC
  🔄 Reset M4     Redémarrer la carte M4"""
        self._show_text("Aide", help_text)

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
            DialogHelper.showwarning("Coller", "Presse-papiers vide ou inaccessible")
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
    p.add_argument("--zoom", type=int, default=None,
                   help="taille INITIALE de la fenetre (defaut: utilise config, ou 4) ; "
                        "la fenetre est ensuite redimensionnable a la souris")
    p.add_argument("--refont", action="store_true",
                   help="redemander le jeu de caracteres au CPC")
    p.add_argument("--dump", action="store_true",
                   help="relever l'ecran du CPC a la connexion (affichage "
                        "exact ; sans, l'ecran se reconstruit au fil de la sortie)")
    args = p.parse_args()

    # Charger la config AVANT de créer la fenêtre
    config = ConfigManager.load()

    # Déterminer le zoom : argument CLI > config > défaut
    # Minimum zoom = 4 (640x480)
    if args.zoom is not None:
        zoom = max(4, args.zoom)
    else:
        zoom = max(4, config.get("zoom", 4))

    font = None if args.refont else load_font()
    if font is None:
        print("Jeu de caracteres absent du cache : demande au CPC (2 Ko)...")

    link = Link(args.host, args.port)
    root = tk.Tk()

    # Créer le Viewer AVANT d'appliquer la géométrie
    # (la géométrie sera appliquée dans Viewer.__init__)
    Viewer(root, link, font, zoom, args.dump)

    # Appliquer la géométrie sauvegardée APRÈS le Viewer est créé
    # Utiliser update_idletasks() pour s'assurer que Tkinter a initialisé la fenêtre
    root.update_idletasks()
    saved_geometry = config.get("window_geometry")
    if saved_geometry:
        try:
            root.geometry(saved_geometry)
            print(f"✓ Géométrie restaurée: {saved_geometry}")
        except tk.TclError as e:
            print(f"Erreur géométrie: {e}")
            root.geometry("%dx%d" % (160 * zoom, 120 * zoom))
    else:
        root.geometry("%dx%d" % (160 * zoom, 120 * zoom))
    try:
        root.mainloop()
    finally:
        link.close()


if __name__ == "__main__":
    main()
