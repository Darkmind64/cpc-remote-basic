# Firmware et utilisation

Référence complète : `downloads/m4info.txt` (officiel, Duke) et `downloads/M4_Extended_User_Manual.pdf` (Csaba Tóth). Firmware courant : **v2.0.8**.

## Configuration réseau initiale

Sur le CPC :

```
|netset,"name=CPC6128, ssid=MONRESEAU, pw=motdepasse, dhcp=1, dns1=8.8.8.8"
```

Paramètres : `name` (nom NetBIOS), `ssid` (sensible à la casse), `pw`, `dhcp` (1/0), `ip`/`gw`/`nm` (si statique), `dns1`/`dns2`, `ntp` (serveur de temps), `tz` (fuseau ±12), `start` (soumission multi-lignes).

La config est persistée dans `/m4/config.txt` sur la microSD (supprimer ce fichier pour réinitialiser le réseau). Un `AUTOEXEC.BAS` à la racine de la SD est exécuté au boot.

## Commandes RSX principales

**Fichiers/navigation** : `|CD` (y compris *dans* les DSK/CPR), `|DIR`, `|LS` (noms longs), `|MKDIR`, `|REN`, `|ERA`, `|COPYF`, `|DSKX` (extraction de DSK), jokers `*` et `?`.

**Médias** : `|SD` (microSD), `|DISC` (lecteur disquette AMSDOS), `|TAPE` (cassette), `|FCP` (copie SD↔disquette).

**ROMs** : `|ROMUP` (upload dans un slot), `|ROMSET` (enable/disable), `|ROMUPD` (application à chaud), `|ROMSOFF`, `|M4ROMOFF`, `|CTRUP`/`|CTR` (cartouches CPC+).

**Images** : `|SNA` (snapshots, y compris v3 compressés).

**Réseau** : `|NETSET`, `|NETSTAT`, `|HTTPGET` (options `@` silencieux, `>` redirection), `|HTTPMEM` (téléchargement en mémoire avec offset), `|WIFI` (on/off), `|TIME`, `|UPGRADE` (mise à jour OTA du firmware).

**Divers** : `|VERSION`, `|M4HELP`, `|GETPATH`, `|LONGNAME`, `|UDIR` (énumération pour programmes ASM).

## Slots ROM selon le modèle de CPC

| Modèle | Recommandation ROM M4 | Notes |
|---|---|---|
| CPC 464 | slot 7 | Slots 8–31 nécessitent lower ROM modifiée (FW316) ou booster ROM |
| CPC 664 / 464+ / 6128+ | slot 7 (ou 6 pour garder le disque) | Slot 7 = AMSDOS, remplaçable (PARADOS…) |
| CPC 6128 | slot 6 | Slot 7 AMSDOS généralement **non** remplaçable (sauf carte mère MC20C) |

Jusqu'à 32 slots ; slot 0 = BASIC (remplaçable) ; slots 16–31 nécessitent initialisation.

## Hack Menu

Bouton **IOS** (ou déclenchement logiciel) → NMI avec remap ROM/RAM : inspection/édition mémoire, pokes, fonctions type Multiface 2. Possibilité de charger un `NMIROM.BIN` personnalisé.

## API développeur (résumé)

- **Ports Z80** : données `0xFE00`, acquittement `0xFC00`. Commandes : octet de taille + commande 16 bits + données ; réponse au même format.
- **Table de liens ROM à `0xFF00`** : +0 version ROM, +2 pointeur buffer de réponse, +4 config interne, +6 structure sockets, +8 fonctions helpers.
- Commandes clés : `C_OPEN` (0x4301), `C_READ`/`C_WRITE`, `C_READDIR` (0x4306), `C_CD` (0x4308), `C_FSTAT` (0x4316), `C_HTTPGET` (0x4320), `C_SETNETWORK` (0x4321), `C_NETSTAT` (0x4323), et l'API sockets TCP complète (`C_NETSOCKET` … `C_NETACCEPT`, firmware ≥ v1.0.9).
- Depuis l'ASM : `|GETPATH` (A=255, DE=buffer), `|LONGNAME` (A=255, DE=buffer, IX=ptr RSX), `|UDIR` (callback HL=nom, B=flag répertoire).

Le détail octet par octet est dans `downloads/m4info.txt`.

## Historique firmware (jalons)

- **v1.0.0–1.0.5** : base ROM board + fichiers + RSX.
- **v1.0.6–1.0.9** : interface web stabilisée, API réseau non bloquante, `AUTOEXEC.BAS`, accès secteurs SD directs.
- **v2.0.0** : noms longs (`|LS`), navigation DSK, exécution distante, cartouches CPC+, ROMDOS.
- **v2.0.1–2.0.5** : upload multi-fichiers web, `|SNA`, Hack Menu, clavier AZERTY, NMI.
- **v2.0.6–2.0.8** : corrections (corruption fichiers, DNS, sockets).
