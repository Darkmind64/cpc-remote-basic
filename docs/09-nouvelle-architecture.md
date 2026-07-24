# Contrôle du CPC depuis Windows — architecture repartie de zéro

Reprise du 22/07/2026, après la découverte de la cause racine qui bloquait le
projet. Ce document remplace `docs/08-terminal-resident.md`, conservé comme
historique.

---

## 1. Les deux bugs qui expliquent l'histoire du projet

### 1.1 `RUN` n'appelle pas, il lance

**Un binaire lancé par `RUN"prog.BIN"` ne peut pas revenir au BASIC** : il n'est
pas entré par un `CALL`, donc son `ret` dépile une adresse invalide → saut en
&0000 → redémarrage.

Démontré par `cpc/t2a.s` : 16 octets, affiche `A`, fait `ret`.

| Lancement | Résultat |
|---|---|
| `RUN"T2A.BIN"` | reboot |
| `LOAD"T2A.BIN"` puis `CALL &8000` | `A` puis `Ready` — normal |

Idem pour `putrun` côté PC, qui passe par `run2=` (« run file at startup ») et
**reset le CPC** avant d'exécuter — ce qui annule au passage tout `MEMORY`
tapé auparavant.

➡️ **Tout code résident se déploie par `LOAD` + `CALL`, jamais par `RUN`.**

Ce seul bug explique le §3.1 de `docs/08` (« le `RUN` reprend la mémoire au
retour »), l'échec du résident RAM à &4000 comme à &9E00, le détour par la ROM,
et une partie de l'impasse 3c. La RAM n'a jamais été reprise.

### 1.2 Mauvais appariement pour restaurer la ROM haute

| Appel | Entrée | Sortie |
|---|---|---|
| `&B90F` KL ROM SELECT | C = ROM voulue | C = ROM précédente, **B = état précédent** |
| `&B918` KL ROM **DESELECT** | **B = état, C = ROM** | — |
| `&B90C` KL ROM RESTORE | **A** = état | — |

[tcpres.s:36](../cpc/tcpres.s:36) appelle `&B90C` en lui passant **BC** : l'état
de la ROM haute était restauré au hasard à chaque dépagination. C'est le
candidat principal pour le §3.7 bis de `docs/08` (« écran en pointillés,
irrattrapable, aucun moyen de connaître l'état antérieur »).

➡️ **`KL ROM SELECT` se défait par `KL ROM DESELECT`, avec BC.**

---

## 2. La carte mémoire retenue

```
&0000 ┌──────────────────┐
      │ BASIC : programme + variables + pile   (HIMEM = &3FFF)
&4000 ├──────────────────┤
      │ ÉCRAN (SCR SET BASE &40)               16 Ko
&8000 ├──────────────────┤
      │ RÉSIDENT : code, tampons, sockets      ~9,6 Ko
&A67C ├──────────────────┤
      │ workspace AMSDOS + ROM M4 (alloué au boot, MEMORY ne le déplace pas)
&B100 ├──────────────────┤
      │ firmware (jumpblocks, indirections)
&C000 ├──────────────────┤
      │ ROM haute quand elle est paginée (ROM M4) — sinon RAM libre
&FFFF └──────────────────┘
```

Deux propriétés qui font tout l'intérêt de cette disposition :

1. **&8000-&A67B n'est recouvert par aucune ROM.** C'est la seule zone d'où du
   code peut appeler `KL ROM SELECT` sans se dépaginer lui-même (le piège 3.6 de
   `docs/08` : du code en &C000 qui pagine la M4 disparaît sous ses propres pieds).
2. **L'écran n'est plus en &C000.** Paginer la ROM M4 ne peut donc plus corrompre
   l'affichage, quel que soit le code qui lit l'écran au même moment (curseur,
   défilement). Le §3.7 bis disparaît par construction et non par précaution.

Coût : le BASIC descend de ~42 Ko à ~15,6 Ko de programme. Validé (T1).

Mise en place : `MEMORY &3FFF` puis `SCR SET BASE` avec A=&40 (`|SCRLO` de la
sonde, ou le POKE de T1).

---

## 3. Les trois principes de l'architecture

1. **Un seul point d'exécution en tâche de fond : l'événement frame-fly du
   firmware** (`KL ADD FRAME FLY`, &BCD7), et non les hooks d'affichage. C'est le
   mécanisme officiel de tâche de fond du CPC ; il ne s'exécute pas au milieu
   d'une transaction de la carte. Les hooks d'affichage restent, réduits à leur
   seul rôle sûr : empiler un octet.
2. **Une seule fonction parle à la M4**, avec verrou et machine à états, une
   transaction par tick au maximum. La non-réentrance de la carte (tampon de
   réponse unique, partagé avec le système disque) devient une propriété
   respectée par construction.
3. **Contrôle de flux d'entrée par écho** : le PC n'envoie le caractère suivant
   qu'après l'avoir vu revenir par le canal de sortie. Le miroir d'écran sert
   d'acquittement — plus aucune temporisation à l'aveugle.

---

## 4. Étapes de validation

| # | Test | Outil | État |
|---|---|---|---|
| T1 | Écran en &4000, BASIC/CAT/LIST/MODE stables | BASIC (POKE) | ✅ |
| — | Un binaire peut revenir au BASIC | `cpc/t2a.s` | ✅ (`LOAD`+`CALL`) |
| T2 | Pagination M4 en boucle, écran en &C000 puis &4000 | `\|PGTEST` | ✅ |
| T3 | Lecture M4 paginée en tâche de fond pendant `CAT`/`LIST` | `\|PGASYNC` | ✅ |
| A | Sortie CPC→PC résidente, `CAT` complet sans intervention | `cpc/cterm.s` | ✅ |
| B | **Contrôle bidirectionnel : shell BASIC piloté du PC** | `cpc/cterm2.s` + `SHELL2.BAS` | ✅ |

## 6. Étape B — contrôle du CPC depuis Windows (VALIDÉ 23/07/2026)

`print 2+2` tapé dans une fenêtre Windows s'exécute sur le CPC et le `4` remonte
au PC. Le BASIC reste vivant. Solution : `cpc/cterm2.s` (résident, réécrit sur le
modèle de Duke) + un shell BASIC (`SHELL2.BAS`) + `pc/cpcterm.py`.

### Architecture retenue

- **Un seul interlocuteur avec la M4** : la RSX `|TERMIO`. Le hook d'affichage
  (`TXT OUT ACTION`) n'empile que dans un tampon, zéro I/O. Toute la
  communication réseau se fait dans `|TERMIO`, appelée par la boucle shell.
- **Le shell BASIC** : boucle qui lit une ligne via `|TERMIO`, l'écrit dans
  `cmd.bas` (`1000 <ligne>` + `1010 GOTO 10`), puis l'exécute par
  `CHAIN MERGE"cmd.bas",1000`. L'éditeur BASIC n'intervient jamais.

Déploiement :
```
(m4term) put ../cpc/CTERM2.BIN : put ../cpc/SHELL2.BAS
(CPC)    MEMORY &7FFF : LOAD"CTERM2.BIN" : CALL &8000 : RUN"shell2.bas"
(PC)     python pc/cpcterm.py <ip-du-cpc>
```

### Les cinq pièges qui ont coûté cette étape (chacun durement acquis)

1. **L'injection clavier directe est impossible sur cette carte.** Écrire dans la
   case de rappel de `KM CHAR RETURN` (&B62A), dans le tampon clavier (&B65E, +
   compteurs &B686/&B687/&B688/&B68A localisés par mesure) ou reproduire l'état
   d'une vraie frappe **ne réveille jamais l'éditeur** : il ne lit le tampon que
   sur une vraie frappe matérielle. Le firmware appelle `KM WAIT CHAR` →
   `KM READ CHAR` **directement en ROM basse** (&1BBF/&1BC5), jamais par le
   jumpblock — donc aucun hook possible. Voir [[cpc-inject-keys-km-read-char]].
   ➡️ On contourne l'éditeur : le sens PC→CPC passe par un **programme BASIC**
   qui va chercher la ligne dans notre RSX.

2. **La ROM M4 doit rester sélectionnée du `sendcmd` jusqu'à la lecture de la
   réponse** (modèle de Duke, `M4examples/tcp.s`). Toggler la sélection ROM entre
   l'envoi et la lecture corrompt la réponse (données renvoyées en **espaces**).
   Notre `tcpecho.s` (validé) ne pagine jamais car il est lancé *par* la M4
   (`run2=`), qui garde sa ROM sélectionnée. Un résident, lui, doit paginer —
   d'où `sel_m4`/`desel_m4` autour de toute la transaction.

3. **Ordre recv puis send.** La M4 ne traite qu'une commande à la fois : envoyer
   la sortie puis lire l'entrée dans la foulée corrompt la réponse du recv.
   `tcpecho` fait toujours recv **puis** send ; nous aussi.

4. **L'envoi doit être un bloc contigu** `[entête+données]` envoyé par un seul
   `sendcmd` (comme `tcpecho`), pas un en-tête puis des données en deux boucles
   `OUT` séparées — le découpage désynchronise la carte.

5. **Ne jamais interroger la M4 à 50 Hz.** `CALL &BD19` (attente flyback) dans la
   boucle déstabilise le firmware M4 en quelques secondes (déjà noté :
   « lire sockstat en boucle serrée déstabilise la carte »). Cadence douce
   `FOR i=1 TO 100:NEXT` (~10 Hz) : largement assez réactif, et stable.

6. **Piège BASIC** : réinitialiser `a$=SPACE$(255)` **avant chaque** appel de
   `|TERMIO`. La RSX vide `a$` (longueur 0) quand rien n'arrive ; au tour suivant
   elle lit la longueur réservée = 0 et ne peut plus rien stocker. La boucle
   d'attente doit donc reboucler sur la ligne du `SPACE$`, pas sur le `|TERMIO`.

### Diagnostic décisif

`|TERMDBG` (dump hexa brut de la réponse M4) a montré `00 06 00 68 65 6C 6C 6F 0D`
= status 0, taille 6, « hello »+CR : la carte renvoyait les BONS octets. Toute la
difficulté était donc dans l'enchaînement des commandes M4 (pièges 2-5), pas dans
la lecture elle-même. Sans ce dump, on cherchait au mauvais endroit.

### Ancienne étape A (historique)

`cpc/cterm.s` (sortie seule + tentatives d'injection clavier) est conservé comme
historique. `cterm2.s` le remplace pour l'usage courant.

**T2 a tranché** : 20000 paginations d'affilée, interruptions actives, **écran encore
en &C000**, affichage intact. Le §3.7 bis de `docs/08` était donc bien causé par le
mauvais appariement `&B90C`, pas par le recouvrement écran/ROM. **Déplacer l'écran
en &4000 n'est pas nécessaire** — on garde les 42 Ko de BASIC. `|SCRLO` reste dans
la sonde comme réserve.

Sonde : `cpc/probe.s` → `PROBE.BIN` (`build_probe.cmd`), chargée par
`LOAD"PROBE.BIN"` + `CALL &8000`. RSX : `|SCRLO` `|SCRHI` `|M4VER` `|PGTEST`
`|PGSYNC` `|PGASYNC` `|PGOFF` `|PGCNT`.

Bissection du retour au BASIC : `cpc/t2a.s` (ret nu), `t2b.s` (+ balayage ROM),
`t2c.s` (+ `KL LOG EXT`), via `build_t2.cmd`.

---

## 4 bis. Étape A — le résident de sortie (`cpc/cterm.s`)

Déploiement, **sans ROM custom** :

```
(m4term)  put ../cpc/CTERM.BIN
(CPC)     MEMORY &7FFF : LOAD"CTERM.BIN" : CALL &8000
          |TERM
(PC)      python pc/mirror_view.py <ip-du-cpc>
```

RSX : `|TERM` `|TERMOFF` `|TERMST` (compteurs) `|TERMF` (vidage forcé).
Tampon circulaire de 5,6 Ko en &9000 ; le hook écrit `tx_tail`, le vidage écrit
`tx_head`, chacun par un `ld (nn),hl` indivisible — aucune section critique.

### Les deux horloges

`KL ADD FRAME FLY` **ne bat pas au repos** sur cette machine : mesuré à ~6,6 Hz, et
uniquement pendant qu'une commande s'exécute. Le battement du repos est donc le
**hook `TXT DRAW CURSOR`** (&BDCD), qui se déclenche justement quand le BASIC
attend une saisie. Les deux appellent la même routine `pump`, sérialisée par un
verrou : un seul chemin parle à la carte.

### Ce qui retenait le dernier morceau

Symptôme : la fin d'un `CAT` n'arrivait qu'à la commande suivante. Trois causes
successives, chacune écartée par la mesure (`|TERMST` compte les refus par motif) :

1. **Compteur de silence** (hérité de `tcpres.s`) — ne retombait jamais à zéro,
   91 refus sur 92. Supprimé.
2. **Garde-fou trop strict** — `do_send` renonçait au premier « carte occupée ».
   `|TERMF`, qui *attend* la carte, sortait les octets intacts : la preuve que les
   données étaient bien côté CPC et que seul le moment d'envoi était en cause.
3. **Correctif retenu** : compteur d'inactivité remis à zéro à chaque caractère ;
   après 3 passages sans affichage, vidage **volontaire** (`do_drain`) qui attend
   la carte à chaque morceau, borné à 8 morceaux par passage. Pendant une sortie
   continue, l'envoi reste opportuniste pour ne pas figer le CPC.

Garde-fous conservés, tous deux **mesurés** : la ROM M4 n'est pas la ROM
sélectionnée (`KL CURR SELECTION` — elle exécute une commande, son tampon de
réponse est unique, §3.7), et la socket n'émet pas déjà.

### Piège réintroduit puis corrigé

`page_m4`/`unpage_m4` tournent **interruptions coupées**. Sans cela, le hook
curseur (contexte interruption) pouvait paginer au milieu d'une pagination du
premier plan et écraser `pg_bc` — l'état de la ROM aurait été restauré de travers,
soit exactement le défaut d'origine du projet, entré par une autre porte.

## 5. Acquis conservés du projet précédent

- ROM déployée dans un **slot M4 séparé** (pas la ROM M4) : `delrom N` +
  `resetm4` récupère la machine **par WiFi, CPC planté**.
- Noms de fichiers CPC **8.3 obligatoires** (le remote-run de la M4 plante au-delà).
- Après tout plantage réseau : **power-cycle de la M4** (`resetm4` ne suffit pas,
  une socket orpheline survit).
- Règles NETAPI : `C_NETSOCKET` attend `0,0,6` ; les IP s'envoient en ordre
  d'octets inversé ; `C_NETCONNECT` ne signale une erreur que sur 0xFF (1 =
  en cours).
- Un hook d'affichage ne doit **jamais modifier** le caractère (`TXT OUT ACTION`
  voit aussi les codes de contrôle et leurs paramètres).
- **IX et IY appartiennent à l'appelant** — les préserver avant de rendre la main.
