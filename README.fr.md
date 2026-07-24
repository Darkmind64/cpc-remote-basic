# CPC Remote BASIC — piloter un Amstrad CPC depuis son PC, par WiFi

*[English version](README.md)*

Tu tapes des commandes BASIC dans une fenêtre de ton PC ; elles s'exécutent sur un
vrai **Amstrad CPC** et sa sortie écran remonte aussitôt. Le clavier du CPC
continue de fonctionner en parallèle, et **ton espace programme BASIC reste
entièrement libre** — pas de programme résident, pas d'astuce de numéros de ligne.

```
PS> python pc/cpcterm.py 192.168.1.139
Connecte a 192.168.1.139:6128

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

## Principe

Deux détournements, une RSX et un script Python :

1. Un petit résident Z80 (`cpc/cterm2.s`) est chargé en `&8000`, protégé par
   `MEMORY &7FFF`. Il ouvre une socket TCP serveur sur le port 6128 via l'API
   réseau de la M4.
2. Il détourne **`TXT OUT ACTION`** (indirection `&BDDA`) pour capturer chaque
   caractère affiché par le CPC dans un tampon circulaire. Ce hook ne fait
   qu'empiler — il ne parle jamais à la carte.
3. Il détourne l'**éditeur de ligne du BASIC**, entrée `EDIT` du jumpblock en
   **`&BD5E`**. Quand le BASIC réclame une ligne, le hook lui fournit soit une
   ligne reçue du PC (carry armé — le BASIC l'exécute exactement comme une
   frappe), soit il enchaîne vers l'éditeur d'origine pour que le clavier local
   se comporte normalement.
4. `pc/cpcterm.py` se connecte, affiche la sortie écran renvoyée et transmet les
   lignes tapées. Il propose aussi un relais telnet local (`--telnet`) pour
   piloter le CPC depuis PuTTY.

**Pourquoi `EDIT` est le bon point d'accroche.** Le BASIC réside en ROM *haute* et
ne peut pas appeler la ROM *basse* directement : il doit passer par le jumpblock du
firmware. C'est ce qui rend `&BD5E` interceptable. À l'inverse, `KM WAIT CHAR` et
`KM READ CHAR` sont appelés en interne dans la ROM basse (`&1BBF` → `&1BC5`) et ne
peuvent jamais être détournés depuis la RAM. Ce seul fait rend tout le projet
possible ; le trouver a demandé une longue traque (voir
[docs/09](docs/09-nouvelle-architecture.md)).

## Démarrage rapide

Il faut un Amstrad CPC équipé d'une [M4 Board](https://github.com/M4Duke/m4hardware)
sur ton WiFi, plus [SDCC](https://sdcc.sourceforge.net/) et Python 3 sur le PC.

```bash
cd cpc && ./build_cterm2.cmd          # produit CTERM2.BIN
python ../pc/m4term.py                # envoi sur la SD : put ../cpc/CTERM2.BIN
```

Sur le CPC, une seule ligne :

```basic
MEMORY &7FFF:LOAD"cterm2.bin":CALL &8000:|TERM
```

Puis sur le PC :

```bash
python pc/cpcterm.py <ip-du-cpc>
```

Commandes locales de `cpcterm.py` : `:aide` pour l'aide, `:get prog.bas` … `:fin`
pour capturer un `list` dans un fichier `.bas` propre côté PC.

Pour arrêter et rendre ses hooks au firmware : `|TERMOFF` sur le CPC.

## Organisation du dépôt

| Chemin | Contenu |
|---|---|
| [`cpc/cterm2.s`](cpc/cterm2.s) | **Le résident** — hook d'affichage, hook `EDIT`, I/O réseau M4, RSX `\|TERM` `\|TERMOFF` `\|TERMIO` |
| [`pc/cpcterm.py`](pc/cpcterm.py) | **Le terminal PC** — console ou relais telnet, capture d'écran vers fichier |
| [`pc/m4term.py`](pc/m4term.py) | Transfert et pilotage via l'API HTTP de la M4 (`ls`, `put`, `get`, `run`, `rom`, `reset`) |
| [`cpc/keyscan.s`](cpc/keyscan.s) | Outil de sondage du firmware né de la traque (`\|KFIND` `\|KRAW` `\|KDUMP` `\|KPUSH` `\|KFULL`) — photo/comparaison mémoire, utile pour toute exploration de firmware CPC |
| [`cpc/probe.s`](cpc/probe.s) | Sonde de pagination de la ROM M4 (`\|M4VER` `\|PGTEST` `\|PGASYNC`) |
| [`cpc/tcpecho.s`](cpc/tcpecho.s), [`cpc/tcpterm.s`](cpc/tcpterm.s) | Serveur d'écho TCP et terminal bidirectionnel, en premier plan (étapes antérieures) |
| [`cpc/cterm.s`](cpc/cterm.s) | Premier résident (miroir de sortie + tentatives d'injection clavier) — remplacé, conservé comme historique |
| [`cpc/attic/`](cpc/attic/) | Shell BASIC et programmes de diagnostic de l'approche intermédiaire, chacun documenté |
| [`docs/`](docs/) | Journal technique détaillé — fabrication, découvertes firmware, impasses |

## Ce qu'on a appris à la dure

Ces points ont coûté des jours et ne sont documentés nulle part ailleurs. Détail
complet dans [docs/09-nouvelle-architecture.md](docs/09-nouvelle-architecture.md).

- **`RUN"prog.bin"` ne peut jamais rendre la main au BASIC.** Le binaire n'est pas
  entré par un `CALL`, donc son `ret` dépile une adresse invalide et la machine
  redémarre. Il faut `LOAD` + `CALL`. Ce seul bug avait engendré toute une chaîne
  de fausses conclusions.
- **`KL ROM SELECT` (`&B90F`) se défait par `KL ROM DESELECT` (`&B918`)**, et non
  par `KL ROM RESTORE` (`&B90C`, qui lit l'état dans `A`). Se tromper là, c'est
  restaurer l'état de la ROM haute au hasard.
- **Garder la ROM M4 sélectionnée pendant toute une transaction.** Basculer la
  sélection entre l'envoi d'une commande et la lecture de sa réponse corrompt la
  réponse — la carte renvoie des espaces. Le `tcp.s` de Duke ne bascule jamais.
- **Lire avant d'envoyer.** La carte ne traite qu'une commande à la fois :
  envoyer la sortie puis lire l'entrée dans la foulée corrompt la lecture.
- **Ne jamais interroger la M4 à 50 Hz.** Quelques secondes d'interrogation
  serrée déstabilisent son firmware. ~10 Hz est stable et largement assez réactif.
- **L'injection de frappes est impossible dans cette configuration.** Le tampon
  clavier du firmware (`&B65E`, compteurs en `&B686`/`&B687`/`&B688`/`&B68A`)
  stocke des *codes de touche*, pas de l'ASCII ; et reproduire une vraie frappe
  octet par octet ne réveille jamais l'éditeur. Le hook `EDIT` contourne
  entièrement le problème.

## Crédits

- **Duke** ([spinpoint.org](https://www.spinpoint.org/)) — concepteur de la M4
  Board. La production s'est arrêtée le 30 septembre 2025 et tous les fichiers de
  fabrication ont été libérés :
  [M4Duke/m4hardware](https://github.com/M4Duke/m4hardware),
  [m4rom](https://github.com/M4Duke/m4rom),
  [M4examples](https://github.com/M4Duke/M4examples),
  [cpcxfer](https://github.com/M4Duke/cpcxfer). Son `tcp.s` a servi de référence
  pour corriger notre dialogue avec la carte.
- **Bread80** — [CPCForRC2014](https://github.com/Bread80/CPCForRC2014),
  désassemblage et adaptation du firmware CPC 6128. Il nous a donné la structure
  du tampon clavier et, surtout, la preuve que `KM WAIT CHAR` est appelé en
  interne dans la ROM basse.
- **Csaba Tóth** — le M4 Extended User Manual (non redistribué ici).

Les dépôts tiers et la documentation sous droits d'auteur ne sont
**volontairement pas** inclus dans ce dépôt ; les liens ci-dessus renvoient aux
originaux.

## État et licence

Fonctionne et sert quotidiennement sur un CPC 6128 avec le firmware M4 v2.0.8.
Les adresses firmware (`&BD5E`, `&B65E`…) sont celles du 6128 / BASIC 1.1 ; sur un
464 ou un 664 il faudrait les revérifier — `cpc/keyscan.s` est précisément
l'outil pour ça.

Publié sous licence MIT — voir [LICENSE](LICENSE).
