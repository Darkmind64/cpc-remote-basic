; ------------------------------------------------------------------
; probe — sonde de pagination M4 (etapes T2 / T3 de la nouvelle
; architecture, voir docs/09).
;
; But : prouver ou refuter l'hypothese centrale du redemarrage :
;   « on PEUT lire la ROM M4 en tache de fond, a condition de
;     (1) restaurer l'etat ROM avec KL ROM DESELECT (&B918) et non
;         KL ROM RESTORE (&B90C) — le bug de tcpres.s ;
;     (2) sortir l'ecran de &C000 pour supprimer le recouvrement. »
;
; POURQUOI EN RAM ET PAS EN ROM :
;   du code qui vit en &C000-&FFFF ne peut pas appeler KL ROM SELECT :
;   il se depagine lui-meme et le RET retombe sur une autre ROM.
;   &8000-&B0FF n'est recouvert par AUCUNE ROM : c'est la seule zone
;   ou du code peut paginer la M4. C'est aussi, avec MEMORY &3FFF,
;   une zone que le BASIC n'atteint jamais.
;
; Mode d'emploi (CPC) :
;     MEMORY &3FFF        <- obligatoire, une fois apres reset
;     (depuis m4term)  putrun ../cpc/PROBE.BIN
;     |SCRLO              ecran en &4000       |SCRHI  retour en &C000
;     |M4VER              une lecture paginee  -> version ROM M4
;     |PGTEST             20000 lectures d'affilee, SANS di (volontaire)
;     |PGASYNC            lecture paginee 50x/s en tache de fond (dur)
;     |PGSYNC             idem mais evenement synchrone (doux)
;     |PGOFF              retire l'evenement
;     |PGCNT              compteur de ticks + derniere version lue
; ------------------------------------------------------------------
		.module	probe
		.area	_HEADER (ABS)
		.org	0x8000

; --- firmware ------------------------------------------------------
TXT_OUTPUT	.equ	0xBB5A
SCR_SET_BASE	.equ	0xBC08
SCR_CLEAR	.equ	0xBC14
KL_LOG_EXT	.equ	0xBCD1
KL_ROM_SELECT	.equ	0xB90F		; C=ROM -> B=etat prec., C=ROM prec.
KL_ROM_DESELECT	.equ	0xB918		; B=etat prec., C=ROM prec.
KL_ADD_FRAME_FLY .equ	0xBCD7		; HL=bloc, B=classe, C=romsel, DE=routine
KL_DEL_FRAME_FLY .equ	0xBCDA		; HL=bloc

; classes d'evenement : bit7 express, bit6 adresse RAM, bit5 asynchrone
EV_SYNC		.equ	0x41		; RAM + synchrone, priorite 1
EV_ASYNC	.equ	0x60		; RAM + asynchrone (temps interruption)

; ==================================================================
; Installation : trouver la ROM M4, poser les RSX, rendre la main
; ==================================================================
; IX et IY appartiennent a l'appelant (BASIC / ROM M4) : find_m4_rom
; detruit IY, donc on encadre TOUT le programme. Rendre la main avec
; IY corrompu = reboot immediat.
start:		push	ix
		push	iy
		call	find_m4_rom
		cp	#0xFF
		jr	z, no_m4
		ld	(m4num),a

		ld	bc,#rsx_table
		ld	hl,#rsx_chain
		call	KL_LOG_EXT

		ld	hl,#msg_ready
		call	printz
		jr	st_exit

no_m4:		ld	hl,#msg_nom4
		call	printz
st_exit:	pop	iy
		pop	ix
		ret

; ==================================================================
; Table RSX
; ==================================================================
rsx_table:	.dw	name_table
		jp	rsx_scrlo
		jp	rsx_scrhi
		jp	rsx_m4ver
		jp	rsx_pgtest
		jp	rsx_pgsync
		jp	rsx_pgasync
		jp	rsx_pgoff
		jp	rsx_pgcnt

name_table:	.ascis	"SCRLO"
		.ascis	"SCRHI"
		.ascis	"M4VER"
		.ascis	"PGTEST"
		.ascis	"PGSYNC"
		.ascis	"PGASYNC"
		.ascis	"PGOFF"
		.ascis	"PGCNT"
		.db	0

; ==================================================================
; |SCRLO / |SCRHI — deplacer la memoire ecran
; ==================================================================
rsx_scrlo:	ld	a,#0x40
		jr	scr_set
rsx_scrhi:	ld	a,#0xC0
scr_set:	call	SCR_SET_BASE
		call	SCR_CLEAR
		scf
		ret

; ==================================================================
; page_read — LE cœur de la demonstration.
; Pagine la ROM M4, lit le mot de version (table de liens &FF00),
; depagine en restaurant ROM *et* etat d'activation.
; Volontairement SANS di : on veut savoir si une interruption qui
; tombe pendant la fenetre casse quelque chose.
; ==================================================================
page_read:	ld	a,(m4num)
		ld	c,a
		call	KL_ROM_SELECT		; B=etat prec., C=ROM prec.
		push	bc
		ld	hl,(#0xFF00)		; version de la ROM M4
		ld	(lastver),hl
		pop	bc
		call	KL_ROM_DESELECT		; <- l'appel que tcpres.s ratait
		ret

; ==================================================================
; |M4VER — une seule lecture
; ==================================================================
rsx_m4ver:	call	page_read
		call	show_ver
		scf
		ret

; ==================================================================
; |PGTEST — 20000 lectures d'affilee (premier plan, sans di)
; ==================================================================
rsx_pgtest:	ld	hl,#20000
pt_loop:	push	hl
		call	page_read
		pop	hl
		dec	hl
		ld	a,h
		or	l
		jr	nz, pt_loop
		call	show_ver
		ld	hl,#msg_done
		call	printz
		scf
		ret

; ==================================================================
; |PGSYNC / |PGASYNC — lecture paginee en tache de fond, 50 Hz
; ==================================================================
rsx_pgsync:	ld	b,#EV_SYNC
		jr	ev_install
rsx_pgasync:	ld	b,#EV_ASYNC
ev_install:	ld	a,(ev_armed)
		or	a
		jr	nz, ev_already
		ld	hl,#0
		ld	(tickcnt),hl
		ld	hl,#ev_block
		ld	c,#0
		ld	de,#tick
		call	KL_ADD_FRAME_FLY
		ld	a,#1
		ld	(ev_armed),a
		ld	hl,#msg_on
		jr	ev_end
ev_already:	ld	hl,#msg_already
ev_end:		call	printz
		scf
		ret

rsx_pgoff:	ld	a,(ev_armed)
		or	a
		jr	z, off_none
		ld	hl,#ev_block
		call	KL_DEL_FRAME_FLY
		xor	a
		ld	(ev_armed),a
		ld	hl,#msg_off
		jr	off_end
off_none:	ld	hl,#msg_none
off_end:	call	printz
		scf
		ret

; --- la routine d'evenement (adresse RAM, appelee 50x/s) ----------
tick:		push	af
		push	bc
		push	de
		push	hl
		call	page_read
		ld	hl,(tickcnt)
		inc	hl
		ld	(tickcnt),hl
		pop	hl
		pop	de
		pop	bc
		pop	af
		ret

; ==================================================================
; |PGCNT — etat
; ==================================================================
rsx_pgcnt:	ld	hl,#msg_cnt
		call	printz
		ld	a,(tickcnt+1)
		call	disphex
		ld	a,(tickcnt)
		call	disphex
		call	crlf
		call	show_ver
		scf
		ret

; ==================================================================
; Recherche de la ROM M4 — restaure proprement ROM et etat
; ==================================================================
find_m4_rom:	ld	c,#0
		call	KL_ROM_SELECT		; recupere l'etat courant
		ld	(saved_rs),bc
		ld	iy,#m4name
		ld	d,#127
fm_loop:	push	de
		ld	c,d
		call	KL_ROM_SELECT
		ld	a,(#0xC000)		; type de ROM
		cp	#1			; 1 = ROM de fond
		jr	nz, fm_next
		ld	hl,(#0xC004)		; -> table de noms
		push	iy
		pop	de
fm_cmp:		ld	a,(de)
		xor	(hl)
		jr	nz, fm_next
		ld	a,(de)
		inc	hl
		inc	de
		and	#0x80
		jr	z, fm_cmp
		pop	de
		ld	a,d
		jr	fm_done
fm_next:	pop	de
		dec	d
		jr	nz, fm_loop
		ld	a,#0xFF
fm_done:	push	af
		ld	bc,(saved_rs)
		call	KL_ROM_DESELECT
		pop	af
		ret

; ==================================================================
; Affichage
; ==================================================================
show_ver:	ld	hl,#msg_ver
		call	printz
		ld	a,(lastver+1)
		call	disphex
		ld	a,(lastver)
		call	disphex
crlf:		ld	hl,#msg_crlf
printz:		ld	a,(hl)
		or	a
		ret	z
		push	hl
		call	TXT_OUTPUT
		pop	hl
		inc	hl
		jr	printz

disphex:	push	af
		rrca
		rrca
		rrca
		rrca
		call	hexdig
		pop	af
hexdig:		and	#0x0F
		add	a,#0x90
		daa
		adc	a,#0x40
		daa
		jp	TXT_OUTPUT

; ==================================================================
; Donnees
; ==================================================================
m4name:		.ascis	"M4 BOARD"
msg_ready:	.ascii	"PROBE en &8000. RSX : SCRLO SCRHI M4VER"
		.db	13,10
		.ascii	"PGTEST PGSYNC PGASYNC PGOFF PGCNT"
		.db	13,10,0
msg_nom4:	.ascii	"ROM M4 introuvable."
		.db	13,10,0
msg_ver:	.ascii	"Version ROM M4 = &"
		.db	0
msg_done:	.ascii	"PGTEST : 20000 lectures OK."
		.db	13,10,0
msg_on:		.ascii	"Evenement arme."
		.db	13,10,0
msg_off:	.ascii	"Evenement retire."
		.db	13,10,0
msg_already:	.ascii	"Deja arme (faire |PGOFF)."
		.db	13,10,0
msg_none:	.ascii	"Rien a retirer."
		.db	13,10,0
msg_cnt:	.ascii	"Ticks = &"
		.db	0
msg_crlf:	.db	13,10,0

m4num:		.ds	1
lastver:	.ds	2
tickcnt:	.ds	2
saved_rs:	.ds	2
ev_armed:	.ds	1
ev_block:	.ds	16		; bloc d'evenement (7 octets utiles)
rsx_chain:	.ds	4
