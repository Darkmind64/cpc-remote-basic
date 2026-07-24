# Archive — clients PC obsolètes / Attic — superseded PC clients

**FR** — Conservés comme historique. Voir aussi `cpc/attic/` pour les programmes
CPC correspondants.

**EN** — Kept as history. See also `cpc/attic/` for the matching CPC programs.

| Fichier | Rôle / Purpose |
|---|---|
| `basicterm.py` | Client du **shell BASIC** (approche intermédiaire) : envoyait une ligne, le CPC la récupérait via `\|TERMIN` et l'exécutait par `CHAIN MERGE`. Remplacé par `pc/cpcterm.py` dès que le hook `EDIT` a rendu le shell inutile. / *Client for the intermediate BASIC-shell approach; superseded by `pc/cpcterm.py` once the `EDIT` hook made the shell unnecessary.* |

## Toujours dans `pc/` (encore utiles) / Still in `pc/` (still useful)

Ces clients accompagnent des programmes CPC antérieurs qui restent dans le dépôt :
*These clients pair with earlier CPC programs still present in the repository:*

- `mirror_view.py` ↔ `cpc/tcpmirror.s` — miroir d'écran CPC→PC / *screen mirror*
- `chat.py` ↔ `cpc/tcpterm.s` — terminal bidirectionnel en premier plan / *foreground bidirectional terminal*
- `echotest.py` ↔ `cpc/tcpecho.s` — serveur d'écho TCP sur le CPC / *TCP echo server on the CPC*
- `echoserv.py` ↔ `cpc/tcpcli.s` — le PC écoute, le CPC se connecte / *PC listens, CPC connects*
