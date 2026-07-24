# Développer sa ROM M4 custom (côté Z80)

Le firmware M4 charge **`M4ROM.BIN`** depuis la racine de la microSD s'il existe, **à la place de la ROM embarquée** (fonction officielle depuis v1.0.8). C'est le point d'extension idéal : zéro flash, zéro risque — pour revenir en arrière, on supprime le fichier de la SD.

## Environnement (déjà en place sur ce PC)

- **SDCC 4.0.0** (`C:\Program Files\SDCC`) : fournit `sdasz80` (assembleur) et `sdcc` (édition de liens).
- Sources clonées : `m4rom/` (la ROM Z80, open source) et `M4examples/` (exemples d'utilisation de l'API).
- `m4rom/ihx2bin.py` : convertisseur Intel HEX → binaire (remplace le `hex2bin.exe` du Makefile, absent sous Windows).
- `make` n'est pas installé → utiliser **`m4rom\build.cmd`** qui enchaîne les 3 étapes :

```
sdasz80 -o M4ROM.rel M4ROM.s
sdcc -o M4ROM.ihx --no-std-crt0 -mz80 M4ROM.rel
python ihx2bin.py M4ROM.ihx      → M4ROM.BIN (16384 octets, org 0xC000)
```

## Déploiement / retour arrière

1. Copier `M4ROM.BIN` **à la racine** de la microSD (par l'interface web ou en retirant la carte).
2. **Reset M4** (bouton SW1) — le firmware recharge la ROM, le CPC redémarre.
3. Tester : `|HELLO` et `|HELLO,3`.
4. **Rollback** : supprimer `M4ROM.BIN` de la SD, reset M4 → ROM embarquée restaurée.

⚠️ Notes :
- Le dépôt `m4rom` public correspond à la ROM **v2.06** (mot à `0xFF00` = `0x0206`), légèrement antérieure à celle embarquée dans le firmware 2.0.8. Pour l'expérimentation c'est sans conséquence ; garde juste en tête que ta ROM custom peut ne pas contenir les tout derniers correctifs de la 2.0.8.
- Espace libre : ~2,4 Ko entre la fin du code actuel (~0xF460) et la zone sockets (0xFE00). Surveille la taille si tu ajoutes beaucoup de code.

## Anatomie d'une RSX (l'exemple |HELLO ajouté)

Deux tables appariées **par position** en tête de ROM (`M4ROM.s`) :

```asm
; 1) le bloc de sauts (un jp par commande)...
  			jp	romsoff
  			jp	hello_cmd		; |HELLO  (RSX custom)
rsx_commands:
; 2) ...et la table des noms, DANS LE MEME ORDRE
			.ascis "ROMSOFF"
			.ascis "HELLO"		; .ascis met le bit 7 sur le dernier caractère (convention CPC)
			.db 0				; fin de table
```

Le premier nom (`M4 BOARD`) est le nom de la ROM (associé à `init_rom`) ; chaque nom suivant correspond au `jp` de même rang.

Le handler, placé en fin de zone code (avant `.org sock_status`) :

```asm
; Entree RSX : A = nombre de parametres, IX -> parametres (2 octets chacun, le
; DERNIER parametre tape est en 0(ix)). Ex : |HELLO,5 -> A=1, 0(ix)=5.
hello_cmd:	ld	hl,#hello_msg
			or	a			; A = nombre de parametres
			jr	z, hello_once
			ld	b, 0(ix)		; octet bas du parametre
			inc	b			; 0 -> traite comme 1
			dec	b
			jr	nz, hello_loop
hello_once:	ld	b,#1
hello_loop:	push	bc
			push	hl
			call	disp_msg		; helper existant : affiche la chaine (HL), terminee par 0
			pop	hl
			pop	bc
			djnz	hello_loop
			ret
hello_msg:	.ascii "Bonjour depuis la ROM M4 custom !"
			.db	13,10,0		; CR LF, terminateur
```

## Boîte à outils pour la suite

- **`disp_msg`** : affiche une chaîne terminée par 0 via le firmware (`txt_output` = 0xBB5A).
- **Parler au STM32** : le motif standard (voir `wifi_power` dans le source) :
  ```asm
  		ld	iy,(#rom_workspace)
  		ld	1(iy),#C_XXXX		; commande (voir m4cmds.i)
  		ld	2(iy),#C_XXXX>>8
  		ld	3(iy),a			; octets de donnees...
  		ld	(iy),#3			; taille (cmd 2 octets + donnees)
  		call	send_command_iy
  ```
  Toutes les commandes `C_*` (fichiers, HTTP, sockets TCP) sont listées dans `m4cmds.i` et documentées dans `downloads/m4info.txt`, section « Developer information ».
- **La réponse** du STM32 se lit dans le buffer pointé par `0xFF02`.
- **Exemples complets** dans `M4examples/` : `httpget.s`, `getdir.s`, `fastcopy.s`… et un `main.c` montrant qu'on peut aussi écrire des **programmes CPC en C** (SDCC -mz80) qui utilisent l'API.

## Idées de RSX suivantes (ordre de difficulté)

1. `|WGETRUN,"url"` — enchaîner `C_HTTPGET` + lancement du fichier téléchargé.
2. `|SCREENSHOT` — dumper &C000–&FFFF dans un fichier sur SD (C_OPEN/C_WRITE), horodaté via C_TIME.
3. Le serveur « CPC-VNC » : boucle `C_NETBIND/LISTEN/ACCEPT/SEND` qui streame l'écran — à prototyper d'abord en programme autonome (plus simple à déboguer qu'en ROM) sur le modèle du sample tcpecho de `M4examples`.
