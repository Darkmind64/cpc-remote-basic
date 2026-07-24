> ## ⚠️ CE DOCUMENT EST EN GRANDE PARTIE INVALIDÉ (22/07/2026)
>
> La cause racine de presque tous les « pièges » ci-dessous a été trouvée :
> **`RUN"prog.BIN"` ne rend pas la main** — le binaire n'est pas appelé par un
> `CALL`, donc son `ret` dépile une adresse invalide et la machine redémarre.
> Vérifié avec un programme de 16 octets qui affiche `A` puis fait `ret` :
> reboot avec `RUN`, retour normal au `Ready` avec `LOAD` + `CALL`.
>
> Conséquences : le §3.1 (« le `RUN` reprend la mémoire ») est **faux** — la RAM
> n'a jamais été reprise ; l'échec du résident RAM (&4000 comme &9E00), le détour
> par la ROM et une partie de l'impasse 3c reposent tous sur ce seul bug.
>
> Second bug établi par lecture du code : [tcpres.s:36](../cpc/tcpres.s:36) restaure
> l'état de la ROM haute avec `KL ROM RESTORE` (&B90C, qui lit **A**) en lui
> passant **BC**. Le bon appariement est `KL ROM SELECT` (&B90F, rend B=état,
> C=ROM) ↔ **`KL ROM DESELECT` (&B918)**. C'est très probablement l'origine du
> §3.7 bis (« écran en pointillés, irrattrapable »).
>
> Reprendre à partir de `docs/09-nouvelle-architecture.md`. Ce qui suit est
> conservé comme historique — ne pas s'en servir comme référence.

# Terminal distant CPC ↔ PC — architecture et pièges

Journal technique du développement d'un terminal permettant de voir la sortie du
CPC sur un PC et (à terme) de le piloter à distance, via la M4 Board.

Ce document consigne **ce qui marche, pourquoi, et surtout les impasses** — elles
ont coûté cher à identifier et ne sont documentées nulle part ailleurs.

---

## 1. État des lieux

| Étape | Contenu | État |
|---|---|---|
| 1 | Écho TCP bidirectionnel (`cpc/tcpecho.s`, `cpc/tcpcli.s`) | ✅ |
| 2 | Miroir d'écran CPC→PC, programme foreground (`cpc/tcpmirror.s`) | ✅ |
| 3a | Terminal bidirectionnel foreground (`cpc/tcpterm.s` + `pc/chat.py`) | ✅ |
| 3b | **Résident** : sortie du BASIC → PC (`cpc/termrom.s` + `cpc/tcpres.s`) | ✅ |
| 3c | Entrée PC → BASIC en résident | ❌ **impossible** (voir §5 ter) |

Côté PC : `pc/m4term.py` (pilotage HTTP), `pc/mirror_view.py`, `pc/chat.py`.

---

## 2. L'architecture résidente qui fonctionne

Le problème central : faire vivre du code qui survit au retour au BASIC, et
accrocher l'affichage sans casser la machine.

**La solution retenue** (après cinq architectures écartées, voir §4) :

1. Une **ROM de fond** dans un slot M4 libre (slot 2), dont l'init ne fait que
   `scf` / `ret` — elle n'installe rien au boot.
2. Une RSX **`|TERMON`** qui **recopie le cœur** (assemblé pour `&9800`) dans la
   zone réservée par `MEMORY &97FF`, puis l'appelle.
3. Le cœur ouvre la socket, attend le PC, puis détourne l'**indirection**
   `TXT OUT ACTION` (&BDDA) vers son propre hook, et rend la main au BASIC.

```
    ROM slot 2 (16 Ko)                RAM protégée par MEMORY
  ┌────────────────────┐            ┌──────────────────────────┐
  │ init: scf/ret      │            │ &9800  cœur (socket,     │
  │ |TERMON ───────────┼─ recopie ─▶│        hooks, envoi)     │
  │ |TERMOFF           │            │ &9Bxx  tampon 2 Ko       │
  │ |TERMHI            │            └──────────────────────────┘
  │ [blob du cœur]     │                       ▲
  └────────────────────┘            &BDDA ─────┘  (indirection)
```

Déploiement :
```
M4 /> rom ../cpc/TERM.ROM 2 TERM
M4 /> resetm4
```
puis sur le CPC : `MEMORY &97FF` → `|TERMON` → connecter `pc/mirror_view.py`.
Retrait : `|TERMOFF`, ou simple reset du CPC (rien n'est réinstallé au boot).

**Récupération d'urgence** : si la ROM bloque le CPC, `delrom 2` + `resetm4`
depuis m4term fonctionne **par WiFi, CPC planté** — c'est tout l'intérêt d'avoir
mis le code dans un slot séparé plutôt que dans la ROM M4.

---

## 3. Les sept pièges (chacun a coûté plusieurs cycles de test)

### 3.1 Le `RUN` d'un binaire reprend la mémoire
Un résident chargé par `RUN`/`putrun` est **écrasé au retour au BASIC**, même avec
`MEMORY` positionné. Ce n'est pas `MEMORY` qui est en cause : vérifié au
POKE/PEEK, la zone réservée par `MEMORY` est parfaitement stable. C'est le `RUN`
qui reprend la main sur la mémoire.
➡️ **Le code doit venir d'une ROM, jamais d'un binaire lancé.**

### 3.2 La réservation mémoire par l'init ROM n'est pas honorée
Le protocole standard (décrémenter `HL`, renvoyer le nouveau sommet, carry armé)
**ne protège rien** ici : un marqueur écrit dans le workspace est écrasé pendant
le boot. Testé avec `HL` et avec `DE`, en slot haut et en slot bas — toujours
écrasé.
➡️ **Utiliser la zone `MEMORY` à une adresse fixe, pas le workspace ROM.**

### 3.3 Jumpblock ≠ indirection
`&BB5A` (TXT OUTPUT) n'est **pas** un `JP` mais `CF FE 93` = **`RST 1` + adresse**
(far-call vers la ROM basse). Le remplacer par un `JP` **casse le retour au
BASIC** (reboot systématique), même avec un hook vide.
Les **indirections** sont de vrais `JP` et sont le point d'accroche prévu :
```
&BDCD  C3 4B 13   TXT DRAW CURSOR
&BDD3  C3 BE 13   TXT WRITE CHAR
&BDD9  C3 0A 14   TXT OUT ACTION   ← le bon point pour capturer la sortie
```
On patche le champ adresse (&BDDA) et on chaîne vers la cible d'origine.

### 3.4 Ne jamais modifier le caractère
`TXT OUT ACTION` voit passer **aussi les codes de contrôle et leurs paramètres**
(encre, fenêtres, définition de symboles). Un test « minuscules → MAJUSCULES »
transforme les octets de paramètre et provoque des couleurs et formes aberrantes.
➡️ **Le hook copie, il ne transforme jamais.**

### 3.5 Une init de ROM doit être silencieuse
Afficher quoi que ce soit dans l'init déclenche le hook qu'on vient de poser, en
plein boot ⇒ **boucle de reboot**.

### 3.6 Toute routine qui change la ROM sélectionnée doit la restaurer
`find_m4_rom` balaie les 127 slots et laisse la **ROM M4 sélectionnée**. Si on
revient à l'appelant sans restaurer, le `ret` retombe en &C0xx sur une **autre
ROM** → `Unknown error`, puis dispatch RSX faussé (`Missing arguments` au premier
`CAT`).
```asm
start:  call kl_curr_selection   ; &B912 -> A = ROM appelante
        ld (saved_rom),a
        ...
core_exit:
        ld a,(saved_rom)
        ld c,a
        call kl_rom_select       ; &B90F
        ret
```
Ce piège n'existait pas quand le cœur était lancé par `RUN` : la ROM M4 restaurait
elle-même la pagination. Il n'est apparu qu'en déplaçant le code dans notre ROM.

### 3.7 bis — On ne peut PAS paginer la ROM M4 en tâche de fond
La ROM M4 occupe la **même plage &C000-&FFFF que la mémoire écran**. La paginer
rend l'écran illisible : tout code qui lit l'écran pendant cette fenêtre (curseur
clignotant, défilement) récupère des octets de ROM et les recopie à l'écran ⇒
**caractères en pointillés aléatoires**.

Pire, c'est irrattrapable : `kl_rom_select` **active** la ROM haute, et aucun
appel firmware ne permet de connaître son état d'activation antérieur pour le
restaurer. Couper les interruptions ne suffit pas (le dessin du curseur qui suit
notre hook lit encore la ROM).

➡️ **En résident, on ne peut qu'ÉCRIRE vers la carte, jamais lire.** Donc pas de
synchronisation sur l'état de la socket : on espace les trames par temporisation.
(En programme *foreground* la lecture reste possible : on maîtrise tout le
contexte, personne d'autre n'accède à l'écran.)

### 3.7 Le protocole M4 n'est pas réentrant
La carte est **à la fois le lien réseau et le système disque**, avec un **tampon de
réponse unique**. Pendant un `CAT`, la ROM M4 lit sa réponse *tout en affichant* —
et chaque caractère affiché déclenche notre hook. Lui envoyer une commande à ce
moment **écrase le tampon en cours de lecture** ⇒ `Missing arguments`, exécution
qui déraille.
➡️ **Ne parler à la M4 que lorsqu'elle est au repos.**

---

## 4. Architectures écartées (et pourquoi)

| Approche | Verdict |
|---|---|
| Résident RAM chargé par `RUN` + `MEMORY` | Code écrasé au retour (§3.1) |
| Hook du jumpblock &BB5A (trampoline `RST 1`) | Casse le retour au BASIC (§3.3) |
| Hook exécuté **en ROM** via far-call `RST 3` | Convention incertaine, système figé |
| Workspace réservé par l'init ROM | Non honoré (§3.2) |
| Installation du hook **au boot** (init ROM) | Contexte trop fragile (§3.5) |

---

## 5. Le vidage du tampon — architecture finale (validée)

Trois règles, chacune tirée d'un échec :

1. **Le hook d'affichage n'empile que.** Aucune I/O, donc aucune concurrence
   possible et aucun risque de déranger la carte en pleine transaction disque.
2. **Un seul point de vidage nominal** : le hook curseur (`TXT DRAW CURSOR`),
   avec un **compteur de silence** réarmé à chaque caractère affiché. On ne vide
   qu'après plusieurs appels *sans aucun affichage* — donc jamais pendant un
   `CAT` ni un `LIST`. Un **vidage de secours** se déclenche à 1900 octets pour
   les sorties continues très longues (sans danger : un `LIST` ne sollicite pas
   la carte).
3. **Envoi par trames de 200 octets espacées d'une courte temporisation.**
   Surtout **pas** de lecture de l'état de la socket : cela imposerait de paginer
   la ROM M4, ce qui corrompt l'écran (§3.7 bis).

Un **verrou de réentrance** protège la routine, appelée potentiellement depuis le
premier plan (seuil haut) et depuis l'interruption (curseur).

**Limite connue** : une sortie continue dépassant le tampon de 2 Ko perd des
caractères. Atténuation : abaisser `MEMORY` pour agrandir le tampon.

## 5 ter. Étape 3c — conclusion : impossible en résident

**Résultat : sortie résidente et entrée résidente sont mutuellement exclusives
sur cette carte.** Quatre variantes ont été construites et testées, toutes se
soldent par un reboot du CPC dès la première commande :

| Variante testée | Résultat |
|---|---|
| Le PC dépose `cmd.bas` par HTTP pendant que le CPC interroge la carte | reboot |
| Le PC envoie la ligne par la socket, le CPC écrit `cmd.bas` lui-même | reboot |
| Idem + fenêtres de pagination minimales, interruptions coupées | reboot |
| Idem + verrou partagé entre `|TERMWAIT` et le vidage résident | reboot |

**Cause de fond** : la M4 n'accepte **qu'un seul interlocuteur à la fois**. La
sortie résidente fonctionne précisément parce qu'elle est seule. Dès qu'on ajoute
une lecture, on crée un second flux de commandes — peu importe qu'il vienne du PC,
du BASIC ou de notre propre hook curseur — et la carte décroche. Le verrou logiciel
ne suffit pas : le hook d'affichage est déclenché par le firmware à des instants
qu'on ne maîtrise pas.

➡️ **La bonne réponse est d'utiliser deux outils distincts** :
- `cpc/termrom.s` + `tcpres.s` — **résident, sortie seule** : observer une session
  BASIC depuis le PC (fonctionne parfaitement) ;
- `cpc/tcpterm.s` + `pc/chat.py` — **foreground, bidirectionnel** : dialogue dans
  les deux sens, au prix de ne pas faire tourner le BASIC.

La RSX `|TERMWAIT` est conservée dans la ROM mais **neutralisée** (elle affiche un
message au lieu de planter). Le code de réception reste dans `tcpres.s` pour qui
voudrait reprendre le sujet.

## 5 bis. Étape 3c (injection clavier) — pistes explorées

Le sens PC→CPC est **nettement plus dur** que CPC→PC, pour une raison structurelle :
recevoir suppose `C_NETRECV`, donc **lire** la réponse de la carte, donc **paginer
la ROM M4** — précisément ce qui est interdit en tâche de fond (§3.7 bis).

Pistes envisageables :
- faire lire par un court passage en **premier plan** (une RSX appelée
  périodiquement, ou un hook clavier qui s'exécute quand le BASIC attend une
  saisie et que rien n'est affiché) ;
- ou déporter la réception : le PC écrit dans un fichier sur la SD et le CPC le
  lit via la ROM M4 lors d'un moment maîtrisé.

À défaut, le **terminal foreground** (`cpc/tcpterm.s`, étape 3a) reste la solution
pleinement bidirectionnelle — au prix de ne pas faire tourner le BASIC.

---

## 6. Chaîne de compilation

```
cpc/tcpres.s   ──sdasz80──▶ cœur assemblé pour &9800
                     │
                     └──▶ blob.inc (.db) ─┐
cpc/termrom.s  ──────────────────────────┴──▶ TERM.ROM (16 Ko)
```
Le cœur est embarqué dans la ROM sous forme de données ; `|TERMON` le recopie en
RAM protégée. Les fichiers `blob.inc` et `chain.inc` sont **générés**, ne pas les
éditer à la main.

Rappels utiles :
- Nom de fichier CPC **8.3 obligatoire** — le remote-run de la M4 plante sur un
  nom plus long (voir `docs/03-fabrication.md`).
- Après tout plantage réseau : **power-cycle de la M4** (une socket orpheline
  survit à `resetm4`).
- Quitter proprement (ESC / `|TERMOFF`) pour libérer la socket.
