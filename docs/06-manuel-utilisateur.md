# Manuel utilisateur M4 Board — CPC 6128 (firmware v2.0.8)

Manuel pratique en français, condensé de la documentation officielle (`downloads/m4info.txt`) et du manuel étendu de Csaba Tóth (`downloads/M4_Extended_User_Manual.pdf`), adapté à ta configuration : CPC 6128, ROM M4 en slot 6, carte alimentée par USB.

---

## 1. Au quotidien

- **Ordre d'allumage** : M4 alimentée d'abord (laisse le chargeur USB branché en permanence), puis le CPC.
- **LEDs** : ON (bleue) = alimentation ; DD = clignote lors des accès microSD.
- **Boutons** : SW1 = reset de la M4 · SW2 = reset du CPC (pratique : il ne fait pas perdre le répertoire courant de la M4) · SW3 = IOS/Hack Menu.
- **La règle d'or** : ne jamais brancher/débrancher la carte CPC allumé.

## 2. La microSD comme lecteur natif

Dès le boot, la microSD **remplace le disque** pour toutes les commandes BASIC habituelles :

```
CAT                    ' cataloguer le répertoire courant
LOAD"prog              ' extensions .bas/.bin/. ajoutées automatiquement
RUN"jeu
SAVE"monprog           ' un .bak est créé si le fichier existait
OPENIN / OPENOUT       ' fonctionnent aussi
```

- Noms affichés en **8.3** pour compatibilité ; les répertoires sont précédés de `>`.
- `|LS` affiche les **noms longs** (15 caractères en mode 0, 35 en mode 1, 75 en mode 2).
- `|LONGNAME,"ROMCON~1.BIN"` révèle le nom complet d'une entrée tronquée.
- **ÉCHAP** interrompt un `CAT`/`|DIR` trop long.

### Démarrage automatique

Un fichier **`AUTOEXEC.BAS`** à la racine de la SD est lancé à chaque boot — idéal pour tes réglages (mode écran, couleurs, voire lancement d'un menu) :

```
10 MODE 2
20 INK 1,26
SAVE"autoexec.bas
```

⚠️ À créer **sur le CPC** (pas dans Notepad : il faut l'en-tête AMSDOS).

## 3. Naviguer dans l'arborescence

```
|CD,"games"            ' entrer dans un sous-répertoire
|CD,"games/batman"     ' chemin direct
|CD,".."               ' remonter d'un niveau
|CD,"/"                ' retour à la racine
|GETPATH               ' afficher le chemin courant
|DIR,"*.bas"           ' catalogue avec jokers (* et ?)
|DIR,"games/b?t*.dsk"  ' jokers + chemin
|MKDIR,"games/discs"   ' créer un répertoire
```

Jokers : `*.*` pour les fichiers (ils ont des extensions), `*` seul pour les répertoires.

## 4. Jeux et images disque

### Les .DSK se comportent comme des dossiers ✨

C'est LA fonction phare : n'importe quelle image DSK d'émulateur s'utilise directement :

```
|CD,"robocop.dsk"      ' « entrer » dans l'image
CAT                    ' voir son contenu
RUN"robocop            ' jouer !
|CD,".."               ' ressortir
```

- Les DSK sont **en lecture seule**.
- Formats supportés : DSK standard, **ROMDOS** (D1/D2/D10/D20/D40), **PARADOS 80**, et les « converted GX4000 » (CPR dsk).
- Un `*` après un nom = fichier en lecture seule ; les fichiers système sont masqués (les cat-arts s'affichent mieux !).
- `|DSKX,"somedisk.dsk","/mypath"` **extrait** tous les fichiers d'une image vers un répertoire de la SD.

### Snapshots

```
|SNA,"frankie.sna"     ' lance un snapshot d'émulateur (v3 compressés supportés)
```

### Où trouver les jeux

Télécharge les DSK depuis le PC (interface web, glisser-déposer) ou directement **depuis le CPC** via WiFi (`|HTTPGET`, voir §7). Plus de 1300 jeux testés — liste de compatibilité sur le forum CPCWiki.

## 5. Disquettes réelles : cohabitation et copies

Avec la ROM M4 en **slot 6** et l'AMSDOS en slot 7, le lecteur de disquettes reste accessible :

```
|DISC                  ' basculer sur le lecteur de disquettes (AMSDOS)
CAT                    ' on est sur la disquette A:
|SD                    ' revenir à la microSD
|TAPE                  ' basculer sur le lecteur de cassettes (464/interface)
```

### Copier disquette ↔ microSD : |FCP

Lettres de lecteur : `A:`/`B:` = disquettes, `C:` = microSD (répertoire courant).

```
|FCP,"MYFILE.BIN","A:"     ' microSD → disquette A
|FCP,"A:MYFILE.BIN","C:"   ' disquette A → microSD (répertoire courant)
|FCP,"A:*","C:"            ' TOUTE la disquette → microSD
|FCP,"*","A:"              ' tout le répertoire courant SD → disquette
```

C'est l'outil parfait pour **archiver tes disquettes** vieillissantes sur SD… et pour régénérer des disquettes fraîches depuis tes sauvegardes.

### Copies internes à la SD

```
|COPYF,"source.bin","dest.bin"        ' copier (chemins acceptés)
|REN,"games/robocop.dsk","robocop.dsk" ' renommer… ou DÉPLACER vers un dossier
|ERA,"*.bak"                          ' effacer (jokers OK, sensible à la casse)
|ERA,"games/r*.d?k"
```

## 6. L'interface web — ton pont avec le PC

Une fois le WiFi configuré (§7), ouvre `http://IP-de-la-carte` (ou `http://CPC6128`) dans un navigateur :

- **File browser** : upload **multi-fichiers** par glisser-déposer, téléchargement, suppression, création de dossiers — y compris *à l'intérieur* des images DSK/CPR.
- **Remote run** : double-clic sur un programme dans le navigateur → il se lance **sur le CPC** ! Combiné avec « CD ON CPC » (change aussi le répertoire courant du CPC).
- **M4 Rom Config** : gestion des 32 slots ROM (upload, activation, slot de la ROM M4, lower ROM).
- **Control** : reset M4, reset CPC, pause, Hack Menu — à distance.
- Astuce scriptable : `http://IP/config.cgi?cd2=/DEMOS` change le répertoire courant via une simple requête HTTP (wget/curl) — même dans un DSK.

## 7. Réseau et Internet

### Configuration (une fois)

```
|NETSET,"name=CPC6128, ssid=TonReseau, pw=MotDePasse, dhcp=1, dns1=8.8.8.8, dns2=8.8.4.4"
|NETSTAT               ' état de la connexion + adresse IP
```

Paramètres utiles : `ntp=pool.ntp.org` et `tz=2` (heure d'été FR) pour l'horloge ; `dhcp=0` + `ip=`/`gw=`/`nm=` pour une **IP statique — recommandé, connexion quasi instantanée au boot**. Config persistée dans `/m4/config.txt` (éditable au PC). `|WIFI,0` / `|WIFI,1` coupe/rallume le WiFi.

### Télécharger depuis le CPC

```
|HTTPGET,"spinpoint.org/battro.dsk"          ' télécharge dans le rép. courant
|HTTPGET,"@site.com/fichier.txt"             ' @ = mode silencieux
|HTTPGET,"site.com/doc.txt>local.txt"        ' > = renommer à l'arrivée
|HTTPMEM,"site.com/FIST.BIN",&C000,&4000     ' télécharger EN MÉMOIRE (max 16 Ko/appel)
|HTTPMEM,"site.com/x.dsk, offset=0x10000",&8000,&1000   ' lecture par morceaux avec offset
|TIME                  ' heure NTP
|UPGRADE               ' télécharge la dernière mise à jour firmware (puis reset M4)
```

Port 80 par défaut (`site.com:8080/...` pour un autre port). HTTP uniquement (pas de HTTPS — machine de 1985 oblige 🙂).

## 8. La carte ROM virtuelle (32 slots)

La M4 émule une carte ROM complète. Sur **ton 6128** :

| Slot | Contenu | Notes |
|---|---|---|
| 0 | BASIC interne | remplaçable uniquement par un autre BASIC |
| 1–6 | **libres** | ROM M4 en **6** (ta config) |
| 7 | AMSDOS interne | **ne pas utiliser** sur 6128 (non recouvrable, sauf carte mère MC20C) |
| 8–15 | libres | |
| 16–31 | libres mais non initialisés par le système | nécessitent lower ROM modifiée ou « booster rom » |

```
|ROMUP,"UTOPIA.ROM",15    ' uploader une ROM (depuis la SD) dans le slot 15
|ROMUPD                   ' appliquer les changements À CHAUD (sans reboot)
|ROMSET,15,0              ' désactiver le slot 15  (,1 pour réactiver)
|ROMSOFF                  ' tout désactiver jusqu'au prochain reset
|ROMSOFF,6,1              ' tout désactiver SAUF le slot 6, puis reset
|M4HELP                   ' lister les 32 ROMs   |M4HELP,n : commandes de la ROM n
|M4ROMOFF                 ' désactiver la ROM M4 jusqu'au prochain cycle
```

ROMs à essayer : **Protext** (traitement de texte), **Maxam** (assembleur), **Utopia** (utilitaires), **PARADOS** (formats disque étendus — slot 1–6, pas 7 !). Beaucoup sont sur cpcwiki (ROM List).

Astuce compatibilité jeux : si certains jeux posent problème avec la ROM M4 en slot 6, la solution officielle 6128 est la **lower ROM modifiée** (à uploader en slot 31 + « Enable lower-rom » dans l'interface web) — voir la page CPCWiki M4 Board, section fichiers.

## 9. Le Hack Menu (fonctions type Multiface 2)

Déclenchement : bouton **IOS** de la carte, ou interface web (*Control* → Hack Menu). Un **NMI** interrompt le programme en cours et affiche le menu :

- **Snapshots en pleine partie** : sauvegarde l'état complet du jeu sur SD, rechargeable par `|SNA` — le « save state » d'émulateur, sur machine réelle.
- **Pokes** (vies infinies…), **inspection/dump mémoire**.
- Support clavier **AZERTY** détecté automatiquement.
- Reprise du jeu là où il en était.
- Extensible : un fichier `NMIROM.BIN` à la racine de la SD remplace le menu interne par le tien (sources : github.com/M4Duke/m4hackmenu).

## 10. Outils compagnons (PC, mobile)

| Outil | Usage |
|---|---|
| **cpcxfer** (github.com/M4Duke/cpcxfer) | transfert PC→CPC en ligne de commande via WiFi — parfait pour un workflow de dev croisé |
| **M4FE** (Abalore) | front-end graphique de lancement sur CPC |
| **RulezCharge** (hERMOL) | front-end + téléchargement direct depuis CPC-Rulez |
| **YANCC** (SOS) | clone de Norton Commander pour gérer ses fichiers sur CPC |
| **SymbOS** | OS multitâche fenêtré avec support M4 : IRC, transferts, etc. |
| App Android (Frange, github.com/Frange/Amstrad-M4-Board) | naviguer et lancer les jeux depuis le téléphone |
| Clients **telnet** (M4EWEN…) | se connecter à des BBS depuis le CPC |

## 11. Dépannage et bonnes pratiques

- **Tout est cassé après un changement de config ?** SD dans le PC → supprimer le contenu du dossier `m4/` → carte hors tension → réinsérer, reconfigurer. C'est le « reset usine ».
- **Resets, freezes, glitches graphiques** → nettoyer le connecteur bord de carte (cause n° 1 selon Duke).
- `|ERA`/`|REN` sont **sensibles à la casse**.
- Les fichiers créés sur PC pour être `RUN` doivent avoir un en-tête AMSDOS valide (les outils comme iDSK/CPCDiskXP savent l'ajouter).
- Mises à jour : `|UPGRADE` par WiFi, ou dézipper `M4FIRM_vXXX.zip` à la racine de la SD et redémarrer (~20 s).
- Sauvegarde régulièrement ta SD sur le PC — c'est toute ta ludothèque.

### Spécifique à ta carte (fabrication maison)

- Alimentation par **USB** (jumper côté USB) : allumer la M4 avant le CPC ; le chargeur peut rester branché en permanence.
- Régulateur HT7133 (30 mA) encore en place → à remplacer par un **HT7536** ; en attendant, des instabilités lors des gros transferts WiFi ne seraient pas surprenantes.
- Le bootloader est protégé en écriture (secteurs 0–1) : les mises à jour firmware par SD/`|UPGRADE` ne le touchent pas, tout va bien.
