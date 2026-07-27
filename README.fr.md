# CPC Remote BASIC — piloter un Amstrad CPC depuis son PC, par WiFi

*[English version](README.md)*

> **⚠️ Note de l'auteur**  
> Je ne suis pas développeur professionnel. Ce projet a été développé en « vibe-coding » avec l'aide de Claude Code, en explorant ce qui était possible plutôt que de suivre un plan strict. De ce fait, le code peut certainement être largement amélioré par des programmeurs expérimentés, et il peut contenir des bugs. C'est avant tout une **preuve de concept** qui s'est avérée suffisamment fonctionnelle pour être utile à la communauté des passionnés d'Amstrad CPC. Je la partage parce qu'elle pourrait aider d'autres personnes ayant des intérêts similaires. Les contributions, améliorations et rapports de bugs sont très bienvenues !

---

Tu tapes des commandes BASIC dans une fenêtre de ton PC ; elles s'exécutent sur un
vrai **Amstrad CPC** et sa sortie écran remonte aussitôt. Le clavier du CPC
continue de fonctionner en parallèle, et **ton espace programme BASIC reste
entièrement libre** — pas de programme résident, pas d'astuce de numéros de ligne.

```
PS> python pc/cpcterm.py 192.168.1.139
Connecté à 192.168.1.139:6128

Terminal actif.
Ready
10 print "bonjour"
20 for n=1 to 3:print n:next
list
10 PRINT "bonjour"
20 FOR n=1 TO 3:PRINT n:NEXT
Ready
run
bonjour
 1
 2
 3
Ready
```

Le tout passe par le WiFi de la **M4 Board**, l'extension WiFi/microSD/ROM pour
CPC conçue par Duke.

## Fonctionnalités

- **Miroir écran temps réel** — vois ce que le CPC affiche au fur et à mesure
- **Aucune consommation d'espace programme** — le terminal est une ROM de fond
- **Clavier dual** — clavier du CPC + clavier du PC fonctionnent simultanément
- **Afficheur graphique moderne** — vraie police 8×8 du CPC, proportions 4:3, fenêtre redimensionnable
- **Support multi-écran** — les dialogues se positionnent correctement en multi-moniteur
- **Gestionnaire de fichiers** — parcourir la SD, envoyer/récupérer des fichiers, lancer des programmes en GUI
- **Gestion des ROMs** — gérer les slots ROM de la M4 graphiquement
- **Traduction jeu de caractères** — support complet ISO-646-FR (accents français) bidirectionnel
- **Relais telnet** — compatible PuTTY
- **Plusieurs clients disponibles** — version console, graphique, ligne de commande

## Démarrage rapide

Il faut un Amstrad CPC équipé d'une [M4 Board](https://github.com/M4Duke/m4hardware)
sur ton WiFi, plus [SDCC](https://sdcc.sourceforge.net/) et Python 3 sur le PC.

### Étape 1 : installer le terminal sur le CPC

#### Recommandé : installer en ROM (boot en une commande)

Compile-le et envoie-le sur la M4 Board :

```bash
cd cpc && ./build_termrom2.cmd        # produit TERM2.ROM
```

**Méthode A : avec `m4term.py` (ligne de commande)**
```bash
python pc/m4term.py 192.168.1.139
put ../cpc/TERM2.ROM
rom ../cpc/TERM2.ROM 3 TERM
resetm4
```

**Méthode B : avec l'interface web de la M4 Board**
1. Ouvre `http://192.168.1.139` dans ton navigateur
2. Envoie `TERM2.ROM` via le gestionnaire de fichiers
3. Utilise le gestionnaire de ROM pour l'installer dans le slot 3
4. Clique sur « Reset M4 »

Ensuite, tape simplement sur le CPC :
```basic
|TERM
```

L'init de la ROM réserve automatiquement la mémoire au-dessus de `&8000` dès le boot.

#### Variante : charger comme binaire (manuel à chaque fois)

Si tu préfères ne pas occuper de slot ROM :

```bash
cd cpc && ./build_cterm2.cmd          # produit CTERM2.BIN
```

**Méthode A : avec `m4term.py` (ligne de commande)**
```bash
python pc/m4term.py 192.168.1.139
put ../cpc/CTERM2.BIN
```

**Méthode B : avec l'interface web de la M4 Board**
1. Ouvre `http://192.168.1.139` dans ton navigateur
2. Envoie `CTERM2.BIN` via le gestionnaire de fichiers

Puis sur le CPC :
```basic
MEMORY &7FFF:LOAD"cterm2.bin":CALL &8000:|TERM
```

### Étape 2 : choisir ton client PC

#### Client terminal (console)

```bash
python pc/cpcterm.py <ip-du-cpc>
```

**Commandes locales :** `:aide` pour l'aide, `:get prog.bas` pour télécharger, `:fin` pour fermer et sauvegarder le `list` en fichier.

**Mode relais telnet :**
```bash
python pc/cpcterm.py --telnet <ip-du-cpc>
```
Puis connecte-toi depuis PuTTY à `localhost:4242` — fonctionne avec n'importe quel client telnet.

#### Afficheur graphique (recommandé pour une utilisation quotidienne)

```bash
python pc/cpcview.py <ip-du-cpc>
```

**Fonctionnalités :**
- Aspect authentique du CPC — vraie police 8×8, proportions 4:3 correctes
- Jeu de caractères mis en cache pour un démarrage instantané
- Fenêtre redimensionnable (les caractères suivent la taille en gardant 4:3)
- Barre de statut affichant IP, état de connexion, MODE écran, position du curseur
- **Panneau de contrôle M4 complet :**
  - Navigateur graphique de la SD (envoyer/récupérer/supprimer/créer dossier/lancer)
  - Gestion des slots ROM
  - Resets CPC/M4 via boutons
- Interface moderne sombre avec customtkinter
- Support multi-écran (les dialogues apparaissent sur le bon écran)
- `--dump` pour capturer l'écran courant du CPC à la connexion

#### Outil de contrôle M4

Contrôle direct via l'API HTTP de la M4 :

```bash
python pc/m4term.py 192.168.1.139
```

Commandes : `ls`, `put`, `get`, `run`, `rom`, `reset`.

---

## Clients PC — comparaison détaillée

| Fonctionnalité | cpcterm.py | cpcview.py | m4term.py |
|---|---|---|---|
| **Type** | Terminal console | GUI graphique | Outil ligne de commande |
| **Style UI** | Texte | Moderne (customtkinter) | Commandes CLI |
| **Écran CPC** | Sortie texte uniquement | Police 8×8 authentique, ratio 4:3 | Non affiché |
| **Redimensionnable** | Non | Oui (mise à l'échelle proportionnelle) | N/A |
| **Relais telnet** | Mode `--telnet` | Non | Non |
| **Gestionnaire fichiers** | Manual `:get`/`:put` | Navigateur graphique complet | Commandes directes |
| **Gestion ROM** | Non | Panneau GUI complet | Commandes CLI |
| **Resets système** | Non | Boutons CPC & M4 | CLI: `reset` |
| **Multi-écran** | N/A | ✓ Positionnement correct | N/A |
| **Vitesse démarrage** | Instantané | Instantané (police en cache) | Instantané |
| **Meilleur pour** | Scripts, PuTTY | Utilisation interactive quotidienne | Automatisation, contrôle M4 |

---

## Principe

Deux détournements du firmware, quelques RSX et des scripts Python :

1. **Résident Z80** (`cpc/cterm2.s`) s'exécute en `&8000`. Embarqué dans une ROM de fond
   (`cpc/termrom2.s`) dont l'init réserve la RAM au-dessus de `&8000` dès le boot.
   Ouvre un serveur TCP sur le port 6128 via l'API réseau de la M4.

2. **Hook de capture de sortie** sur `TXT OUT ACTION` (indirection `&BDDA`) pour capturer
   chaque caractère affiché par le CPC dans un tampon circulaire. Le hook ne fait
   qu'empiler — il ne parle jamais à la carte directement.

3. **Hook de l'éditeur de ligne** sur l'entrée `EDIT` du jumpblock BASIC (`&BD5E`).
   Quand le BASIC réclame une ligne, le hook fournit soit une ligne du PC (carry armé —
   le BASIC l'exécute), soit enchaîne vers l'éditeur d'origine pour le clavier normal.

4. **Clients Python** se connectent au port 6128, affichent la sortie renvoyée et envoient les lignes tapées.

**Pourquoi `EDIT` est le bon point d'accroche :** Le BASIC réside en ROM *haute* et ne peut
appeler la ROM *basse* que via le jumpblock du firmware — ce qui rend `&BD5E` interceptable.
À l'inverse, `KM WAIT CHAR` / `KM READ CHAR` sont appelés en interne dans la ROM basse et
ne peuvent jamais être détournés depuis la RAM. Découvrir ce seul fait a demandé une traque
extensive du firmware (voir [docs/09-nouvelle-architecture.md](docs/09-nouvelle-architecture.md)).

---

## Jeu de caractères

Le CPC n'est pas en Latin-1. Le modèle français suit l'ISO-646-FR : les accentuées
prennent la place de `@ \ { | }`.

`cpcterm.py` et `cpcview.py` traduisent dans les deux sens :
- Tes caractères accentués → bons codes CPC
- Sortie du CPC → affichée fidèlement (lettres grecques, blocs semi-graphiques compris)
- Symbole CPC non cartographié → apparaît en `<NN>` plutôt que mal affiché
- Caractère absent du CPC → signalé au lieu d'être perdu

**Important :** `|` et `ù` sont le même caractère sur le CPC (code 124), tout comme `@` et `à`
(code 64). Un `LIST` contenant un appel RSX apparaît comme `ùTERM` — exactement ce que
l'écran du CPC affiche.

---

## Organisation du dépôt

| Chemin | Contenu |
|---|---|
| [`cpc/termrom2.s`](cpc/termrom2.s) | **La ROM** — ROM de fond embarquant le cœur ; son init réserve la RAM au-dessus de `&8000` ; expose `\|TERM` / `\|TERMOFF` dès le boot |
| [`cpc/cterm2.s`](cpc/cterm2.s) | **Le résident** — hook d'affichage, hook `EDIT`, I/O réseau M4, commandes RSX (`\|TERM`, `\|TERMOFF`, `\|TERMIO`) |
| [`pc/cpcterm.py`](pc/cpcterm.py) | **Terminal console** — client texte, mode relais telnet, capture d'écran vers fichier |
| [`pc/cpcview.py`](pc/cpcview.py) | **Afficheur graphique** — rend la vraie police 8×8 du CPC en fenêtre 4:3, police mise en cache dans `cpcfont.bin`, panneau de contrôle M4 complet, support multi-écran |
| [`pc/m4term.py`](pc/m4term.py) | **Outil de contrôle M4** — gestion fichiers/ROM via API HTTP de la M4 (`ls`, `put`, `get`, `run`, `rom`, `reset`) |
| [`cpc/keyscan.s`](cpc/keyscan.s) | Outil de sondage du firmware (`\|KFIND`, `\|KRAW`, `\|KDUMP`, `\|KPUSH`, `\|KFULL`) — photos mémoire pour exploration firmware |
| [`cpc/probe.s`](cpc/probe.s) | Sonde de pagination ROM M4 (`\|M4VER`, `\|PGTEST`, `\|PGASYNC`) |
| [`cpc/tcpecho.s`](cpc/tcpecho.s), [`cpc/tcpmirror.s`](cpc/tcpmirror.s), [`cpc/tcpterm.s`](cpc/tcpterm.s) | Prototypes antérieurs (tous fonctionnels) : écho TCP, miroir d'écran, terminal bidirectionnel. Clients PC : `pc/echotest.py`, `pc/mirror_view.py`, `pc/chat.py` |
| [`cpc/cterm.s`](cpc/cterm.s) | Premier résident (miroir de sortie + tentatives d'injection clavier) — remplacé, conservé comme historique |
| [`cpc/attic/`](cpc/attic/), [`pc/attic/`](pc/attic/) | Shell BASIC, outils de diagnostic et anciens clients PC — chacun documenté |
| [`docs/`](docs/) | Journal technique détaillé — compilation, découvertes firmware, impasses |

---

## Ce qu'on a appris à la dure

Ces points ont coûté des jours et ne sont documentés nulle part ailleurs. Détails complets
dans [docs/09-nouvelle-architecture.md](docs/09-nouvelle-architecture.md).

- **`RUN"prog.bin"` ne peut jamais rendre la main au BASIC.** Le binaire n'est pas entré par `CALL`, donc son `ret` dépile de la garbage et la machine redémarre. Il faut `LOAD` + `CALL`.
- **`KL ROM SELECT` (`&B90F`) se défait par `KL ROM DESELECT` (`&B918`)**, pas par `KL ROM RESTORE` (`&B90C`). Se tromper là, c'est restaurer l'état ROM haute au hasard.
- **Garder la ROM M4 sélectionnée pour toute une transaction.** Basculer entre envoyer une commande et lire sa réponse corrompt la réponse.
- **Lire avant d'envoyer.** La carte ne traite qu'une commande à la fois ; envoyer puis lire dans la foulée corrompt la lecture.
- **Ne jamais interroger la M4 à 50 Hz.** Quelques secondes d'interrogation serrée déstabilisent son firmware. ~10 Hz est stable et réactif.
- **L'injection de frappes est impossible.** Le tampon clavier du firmware stocke des *codes de touche*, pas de l'ASCII ; reproduire une vraie frappe octet par octet ne réveille jamais l'éditeur. Le hook `EDIT` contourne entièrement le problème.

---

## Historique des versions

- **v1.0.0** — Support multi-écran, UI customtkinter, amélioration du gestionnaire ROM, exécutable Windows
- Versions antérieures — Terminal console, afficheur graphique prototype

---

## Build sur Windows

Un workflow GitHub Actions compile automatiquement un exécutable Windows à chaque tag de release :

```bash
git tag -a v1.0.0 -m "Message de release"
git push origin v1.0.0
```

L'exécutable apparaît dans les [Releases](https://github.com/Darkmind64/cpc-remote-basic/releases).

---

## État et licence

Fonctionne et sert quotidiennement sur un CPC 6128 avec le firmware M4 v2.0.8.
Les adresses firmware (`&BD5E`, `&B65E`…) sont celles du 6128 / BASIC 1.1 ; sur un
464 ou un 664 il faudrait les revérifier — `cpc/keyscan.s` est précisément l'outil.

**Licence :** MIT avec Commons Clause — voir [LICENSE](LICENSE).
- ✓ Utilisation, modification, distribution libres
- ✓ Usage commercial interne
- ✓ Services de consulting/support
- ✗ Ne peut pas revendre le logiciel lui-même comme produit

---

## Crédits

- **Duke** ([spinpoint.org](https://www.spinpoint.org/)) — concepteur de la M4 Board.
  Production arrêtée le 30 septembre 2025, tous les fichiers libérés :
  [M4Duke/m4hardware](https://github.com/M4Duke/m4hardware),
  [m4rom](https://github.com/M4Duke/m4rom),
  [M4examples](https://github.com/M4Duke/M4examples),
  [cpcxfer](https://github.com/M4Duke/cpcxfer).
  Son `tcp.s` a servi de référence pour corriger notre dialogue avec la carte.
- **Bread80** — [CPCForRC2014](https://github.com/Bread80/CPCForRC2014),
  désassemblage du firmware CPC 6128. Nous a donné la structure du tampon clavier
  et la preuve que `KM WAIT CHAR` est appelé en interne.
- **Csaba Tóth** — M4 Extended User Manual.

Les dépôts tiers et la documentation sous droits d'auteur ne sont **volontairement pas**
inclus dans ce dépôt ; les liens ci-dessus renvoient aux originaux.
