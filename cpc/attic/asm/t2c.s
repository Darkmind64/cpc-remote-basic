; T2C — T2A + installation d'une RSX |PING par KL LOG EXT, puis ret.
; Pas de balayage ROM ici : on isole l'installation RSX toute seule.
; Apres retour au BASIC, taper  |PING  doit afficher PONG.
		.module	t2c
		.area	_HEADER (ABS)
		.org	0x8000

TXT_OUTPUT	.equ	0xBB5A
KL_LOG_EXT	.equ	0xBCD1

start:		push	ix
		push	iy
		ld	a,#67			; 'C'
		call	TXT_OUTPUT
		ld	bc,#rsx_table
		ld	hl,#rsx_chain
		call	KL_LOG_EXT
		ld	a,#13
		call	TXT_OUTPUT
		ld	a,#10
		call	TXT_OUTPUT
		pop	iy
		pop	ix
		ret

rsx_table:	.dw	name_table
		jp	rsx_ping
name_table:	.ascis	"PING"
		.db	0

rsx_ping:	ld	hl,#msg_pong
pz_loop:	ld	a,(hl)
		or	a
		jr	z, pz_end
		push	hl
		call	TXT_OUTPUT
		pop	hl
		inc	hl
		jr	pz_loop
pz_end:		scf
		ret

msg_pong:	.ascii	"PONG"
		.db	13,10,0

rsx_chain:	.ds	4
