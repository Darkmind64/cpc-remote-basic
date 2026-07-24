; ------------------------------------------------------------------
; termrom2 — ROM de fond qui embarque le terminal (cpc/cterm2.s).
;
; Une fois installee dans un slot de la M4, le CPC demarre avec les RSX
; |TERM et |TERMOFF disponibles : plus rien a charger ni a taper a part
; |TERM le jour ou l'on en a besoin.
;
; POURQUOI RECOPIER LE COEUR EN RAM :
; le coeur pagine la ROM M4 (sel_m4) pour dialoguer avec la carte. Du
; code qui vit en &C000-&FFFF ne peut pas faire ca — il se depaginerait
; lui-meme. On embarque donc le coeur en donnees et |TERM le recopie en
; &8000, zone qu'aucune ROM ne recouvre.
;
; POURQUOI &8000 EST PROTEGE SANS TAPER "MEMORY" :
; l'init d'une ROM de fond recoit HL = sommet de la memoire libre et le
; rend abaisse. On rend &7FFF, donc HIMEM <= &7FFF des le boot.
; Verifie sur cette machine : HIMEM = &7F7B (notre &7FFF, puis 132
; octets reclames par la ROM M4 en dessous). Le §3.2 de docs/08, qui
; affirmait que cette reservation n'etait pas honoree, etait une
; conclusion erronee de plus.
;
; Installation :
;   (m4term)  put ../cpc/TERM2.ROM
;             rom ../cpc/TERM2.ROM 3 TERM
;             resetm4
; Usage :  |TERM  pour ouvrir le terminal,  |TERMOFF  pour l'arreter.
; Retrait : delrom 3  puis  resetm4  (fonctionne meme CPC plante).
; ------------------------------------------------------------------
		.module	termrom2
		.area	_HEADER (ABS)
		.org	0xC000

TXT_OUTPUT	.equ	0xBB5A
CORE		.equ	0x8000		; adresse de recopie du coeur
CORE_TERM	.equ	CORE+3		; table de sauts de cterm2.s
CORE_TERMOFF	.equ	CORE+6
CORE_RESET	.equ	CORE+9

; --- en-tete de ROM de fond ---------------------------------------
		.db	0x01			; type : ROM de fond
		.db	1, 0, 0			; version 1.0.0
		.dw	name_table		; &C004
		jp	init			; &C006 : RSX 0 = initialisation
		jp	rsx_term		; &C009 : |TERM
		jp	rsx_termoff		; &C00C : |TERMOFF

; ATTENTION : le PREMIER nom est celui de la ROM (associe a l'init,
; RSX 0) — les noms de RSX ne viennent qu'ensuite. C'est la convention
; de la ROM M4 elle-meme ("M4 BOARD", puis "SD", "DISC"...), et c'est
; sur elle que s'appuie notre find_m4_rom. L'oublier decale toute la
; table : |TERM appelait l'init, qui rend la main sans rien afficher.
name_table:	.ascis	"CPCTERM"		; nom de la ROM (RSX 0 = init)
		.ascis	"TERM"			; RSX 1 -> &C009
		.ascis	"TERMOFF"		; RSX 2 -> &C00C
		.db	0

; ==================================================================
; Initialisation : reserver la RAM au-dessus de &8000, puis annoncer
; la ROM.
;
; Le §3.5 de docs/08 (« une init ROM doit etre silencieuse ») ne valait
; que pour une ROM qui posait un hook d'affichage dans son init et se
; declenchait donc elle-meme. Celle-ci ne pose aucun hook : elle peut
; parler, exactement comme la ROM M4 qui affiche « M4 Board v2.0.8 ».
;
; HL (nouveau sommet) et DE (bas) doivent etre rendus intacts a
; l'appelant : on les preserve autour de l'affichage.
; ==================================================================
init:		ld	a,h			; sommet deja sous &8000 ?
		cp	#0x80
		jr	c, init_ok		; oui : ne pas le remonter
		ld	hl,#0x7FFF		; sinon reserver &8000 et au-dessus
init_ok:	push	hl
		push	de
		ld	hl,#msg_banner
		call	printz
		pop	de
		pop	hl
		scf				; carry = ROM acceptee
		ret

; --- affichage d'une chaine terminee par 0 -------------------------
printz:		ld	a,(hl)
		or	a
		ret	z
		push	hl
		call	TXT_OUTPUT
		pop	hl
		inc	hl
		jr	printz

msg_banner:	.ascii	" ROM Terminal "
		.db	164			; © dans le jeu du CPC
		.ascii	"Davy EPRINCHARD"
		.db	13,10,0

; ==================================================================
; |TERM / |TERMOFF : s'assurer que le coeur est en RAM, puis sauter
; a son point d'entree. On saute (jp) au lieu d'appeler : le `ret` du
; coeur rend alors la main au dispatcheur RSX, qui restaure la ROM.
; ==================================================================
rsx_term:	call	ensure_core
		jp	CORE_TERM

rsx_termoff:	call	ensure_core
		jp	CORE_TERMOFF

; --- recopier le coeur s'il n'y est pas deja -----------------------
; On reconnait un coeur deja en place a sa table de sauts (deux `jp`
; consecutifs). Sans ce test, un second |TERM ecraserait l'etat d'une
; session en cours (socket ouverte, hooks poses).
ensure_core:	ld	a,(#CORE)
		cp	#0xC3			; opcode JP
		jr	nz, do_copy
		ld	a,(#CORE+3)
		cp	#0xC3
		ret	z			; deja en place : ne rien toucher
do_copy:	ld	hl,#core_blob
		ld	de,#CORE
		ld	bc,#core_end-core_blob
		ldir
		jp	CORE_RESET		; etat remis a zero, puis ret

; ==================================================================
; Le coeur (cterm2.raw, assemble pour &8000), embarque en donnees.
; Genere par bin2inc.py — ne pas editer.
; ==================================================================
core_blob:
		.include "cterm2_blob.inc"
core_end:
