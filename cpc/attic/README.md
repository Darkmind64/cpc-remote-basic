# Archive — programmes BASIC de l'exploration / Attic — BASIC programs from the hunt

**FR** — Ces programmes ne sont plus nécessaires : la solution finale (hook de
l'éditeur de ligne `EDIT`, jumpblock &BD5E, dans `cpc/cterm2.s`) ne demande
**aucun programme BASIC**. Ils sont conservés parce qu'ils racontent la
progression et que plusieurs restent d'excellents outils de diagnostic si l'on
reprend le sujet.

**EN** — These programs are no longer needed: the final solution (hooking the
`EDIT` line-editor jumpblock entry at &BD5E, in `cpc/cterm2.s`) requires **no
BASIC program at all**. They are kept because they document how we got there, and
several remain useful diagnostic tools if the work is ever resumed.

## Le shell BASIC (approche intermédiaire) / The BASIC shell (intermediate approach)

Avant de découvrir que `EDIT` était accrochable, le sens PC→CPC passait par un
programme BASIC qui allait chercher la ligne reçue via la RSX `|TERMIO`,
l'écrivait dans `cmd.bas` puis l'exécutait par `CHAIN MERGE`.
*Before we found that `EDIT` was hookable, PC→CPC input went through a BASIC
program that fetched the received line via the `|TERMIO` RSX, wrote it to
`cmd.bas` and executed it with `CHAIN MERGE`.*

| Fichier | Rôle / Purpose |
|---|---|
| `SHELL.BAS` | Premier shell (`\|TERMIN` + `CHAIN MERGE`) — première version fonctionnelle du principe / *first working shell* |
| `SHELL2.BAS` | Shell pour `cterm2.s`, cadence douce (~10 Hz) / *shell for `cterm2.s`, gentle polling* |
| `SHELL2D.BAS` | Idem avec traces `GOT:` / `EXEC` — c'est lui qui a montré le premier `print 2+2` réussi / *same with progress traces; this one showed the first successful `print 2+2`* |
| `TERM.BAS` | Version aboutie : chargement intégré, `ON ERROR`, et **partition des numéros de ligne** (programme utilisateur 10-59899, shell en 60000+) pour que `LIST` ne montre que le programme de l'utilisateur / *most advanced version: self-loading, `ON ERROR`, and line-number partitioning so `LIST` shows only the user's program* |

**Pourquoi abandonné** : le shell occupait l'espace programme du BASIC. Impossible
d'écrire son propre programme sans cohabiter avec lui — c'est précisément ce qui a
motivé la recherche du hook `EDIT`.
*Why dropped: the shell lived in BASIC's single program space, so you could never
write your own program without it being mixed in — exactly what motivated the
search for the `EDIT` hook.*

## Outils de diagnostic / Diagnostic tools

Chacun a servi à isoler une cause précise. Ils restent utilisables avec
`cpc/cterm2.s` (les RSX `|TERMDBG` et `|TERMR` existent toujours).
*Each isolated one specific cause. They still work with `cpc/cterm2.s`
(the `|TERMDBG` and `|TERMR` RSXs are still there).*

| Fichier | Ce qu'il a permis de prouver / What it proved |
|---|---|
| `SHSTAT.BAS` | Affiche statut socket + compteur de reçus. **A prouvé que la M4 recevait bien les octets** (`R0006` pour « hello ») — le bug était donc dans notre lecture, pas dans la liaison / *proved the M4 really received the bytes; the bug was in our read, not the link* |
| `SHDMP2.BAS` | Dump hexa brut de la réponse M4. **Le diagnostic décisif** : `00 06 00 68 65 6C 6C 6F 0D` = la carte renvoyait les bons octets / *the decisive dump: the board was returning the right bytes all along* |
| `SHDUMP.BAS` | Version antérieure du dump / *earlier dump version* |
| `SHR.BAS` / `SHR2.BAS` | Réception seule (`\|TERMR`), sans envoi. `SHR2` (~5 Hz) **a révélé que la cadence 50 Hz déstabilisait la M4** / *receive-only; `SHR2` at ~5 Hz revealed that 50 Hz polling destabilised the M4* |
| `SHIO.BAS` | Écho bidirectionnel via `\|TERMIO` à cadence douce — première validation des deux sens / *first validation of both directions* |
| `SHRX.BAS` / `SHRX2.BAS` | Vidage brut du tampon d'entrée, avec longueur et code du 1er octet / *raw input drain with length and first-byte code* |
| `SHDBG.BAS` / `SHDBG2.BAS` | Écho des lignes reçues (`\|TERMIN` puis `\|TERMIO`) / *echo received lines* |

## Ce qu'il faut retenir / Key takeaways

1. **Ne jamais interroger la M4 à 50 Hz** — quelques secondes suffisent à la
   déstabiliser. ~10 Hz est stable et largement assez réactif.
   *Never poll the M4 at 50 Hz; ~10 Hz is stable and responsive enough.*
2. **Réinitialiser `a$=SPACE$(n)` avant chaque appel de RSX** qui remplit une
   chaîne : la RSX vide `a$` quand il n'y a rien, et la longueur réservée tombe
   alors à 0.
   *Re-init `a$=SPACE$(n)` before every RSX call that fills a string.*
3. Le dump hexa brut de la réponse de la carte est l'outil qui a débloqué la
   situation — à sortir tôt, pas en dernier recours.
   *A raw hex dump of the board's response is what unblocked everything — reach
   for it early, not as a last resort.*
