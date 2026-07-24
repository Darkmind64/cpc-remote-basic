; ------------------------------------------------------------------
; keyscan — localiser le TAMPON CLAVIER du firmware par la mesure.
;
; Pourquoi : KM CHAR RETURN (&BB0C) ne remplit qu'une « case de rappel »
; que l'editeur BASIC ne consulte QUE lorsqu'une frappe reelle le
; reveille (mesure : 770 injections, zero consommee, puis toutes
; delivrees d'un coup a la premiere touche pressee). Pour injecter des
; touches il faut ecrire dans le tampon que remplit le BALAYAGE
; clavier, dont l'adresse depend de la version de ROM.
;
; Principe : pendant qu'une RSX s'execute, le BASIC ne lit pas le
; clavier ; la touche pressee RESTE dans le tampon du firmware. On
; photographie la memoire et on compare.
;
; Acquis : chercher le code ASCII 'Z' ne donne rien -> le firmware
; range le CODE DE TOUCHE BRUT. |KFIND (filtre par apprentissage du
; bruit) a designe &B654 (02>07).
;
;     MEMORY &3FFF
;     LOAD"KEYSCAN.BIN" : CALL &8000
;     |KNOISE       3 fois, SANS RIEN TOUCHER (apprend le bruit)
;     |KFIND        une frappe sur Z -> ce qui a change en plus
;     |KRAW,&B600   meme mesure SANS filtre, sur 256 octets
;     |KDUMP,&B650  16 octets a partir d'une adresse
;     |KCLR         remet l'apprentissage a zero
;
; Photo en &4000, masque de bruit en &5A00 (768 o).
; ------------------------------------------------------------------
		.module	keyscan
		.area	_HEADER (ABS)
		.org	0x8000

TXT_OUTPUT	.equ	0xBB5A
MC_WAIT_FLYBACK	.equ	0xBD19
KL_LOG_EXT	.equ	0xBCD1
KM_CHAR_RETURN	.equ	0xBB0C

SNAP		.equ	0x4000		; copie de reference
NOISE		.equ	0x5A00		; masque de bruit : 1 bit par octet
ZONE		.equ	0xA700		; zone examinee par |KFIND
ZLEN		.equ	0x1800		; ... jusqu'a &BEFF
NLEN		.equ	ZLEN/8
WAITF		.equ	250		; ~5 s d'attente
MAXHIT		.equ	24

start:		push	ix
		push	iy
		ld	bc,#rsx_table
		ld	hl,#rsx_chain
		call	KL_LOG_EXT
		call	clr_noise
		ld	hl,#msg_inst
		call	printz
		pop	iy
		pop	ix
		ret

rsx_table:	.dw	name_table
		jp	rsx_kfind
		jp	rsx_knoise
		jp	rsx_kclr
		jp	rsx_kdump
		jp	rsx_kraw
		jp	rsx_kpush
		jp	rsx_kfull
name_table:	.ascis	"KFIND"
		.ascis	"KNOISE"
		.ascis	"KCLR"
		.ascis	"KDUMP"
		.ascis	"KRAW"
		.ascis	"KPUSH"
		.ascis	"KFULL"
		.db	0

; ==================================================================
; |KFULL,&adresse — photo COMPLETE de 48 octets, avant et apres une
; frappe. Les differences isolees ne suffisent plus : il faut les
; valeurs inchangees pour comprendre la structure (index, compteurs,
; contenu du tampon).
; ==================================================================
rsx_kfull:	push	ix
		push	iy
		cp	#1
		jr	nz, kfu_bad
		ld	l,0(ix)
		ld	h,1(ix)
		ld	(rawadr),hl
		ld	hl,#msg_press
		call	printz
		ld	hl,(rawadr)		; photo avant
		ld	de,#SNAP
		ld	bc,#48
		ldir
		call	wait_key
		ld	hl,(rawadr)		; photo apres (figee tout de suite)
		ld	de,#SNAP+48
		ld	bc,#48
		ldir

		ld	hl,#msg_before
		call	printz
		ld	hl,#SNAP
		call	dump48
		ld	hl,#msg_after
		call	printz
		ld	hl,#SNAP+48
		call	dump48
kfu_end:	pop	iy
		pop	ix
		scf
		ret
kfu_bad:	ld	hl,#msg_args
		call	printz
		jr	kfu_end

dump48:		ld	b,#48
du_loop:	push	bc
		ld	a,(hl)
		push	hl
		call	disphex
		pop	hl
		inc	hl
		pop	bc
		djnz	du_loop
		jp	crlf

; ==================================================================
; |KPUSH — sonde DETERMINISTE : on appelle soi-meme KM CHAR RETURN
; avec &5A et on regarde quel octet a bouge. Pas d'attente, donc
; presque pas de bruit, et aucune dependance au minutage d'une frappe.
; Localise la « case de rappel » — et donc la zone de variables du
; gestionnaire clavier, ou doit se trouver le vrai tampon.
; ==================================================================
rsx_kpush:	push	ix
		push	iy
		ld	hl,#ZONE
		ld	de,#SNAP
		ld	bc,#ZLEN
		ldir
		ld	a,#0x5A			; 'Z'
		call	KM_CHAR_RETURN

		xor	a
		ld	(nhit),a
		ld	hl,#ZONE
		ld	de,#SNAP
		ld	bc,#0
kp_loop:	ld	a,(de)
		cp	(hl)
		jr	z, kp_next
		call	rec_hit
kp_next:	inc	hl
		inc	de
		inc	bc
		ld	a,b
		cp	#>ZLEN
		jr	nz, kp_loop
		ld	a,c
		cp	#<ZLEN
		jr	nz, kp_loop
		jp	kf_report

; ==================================================================
; Attente — aucun appel clavier ici : la touche doit RESTER dans le
; tampon du firmware pour qu'on puisse l'y voir.
; ==================================================================
wait_key:	ld	b,#WAITF
wk_loop:	push	bc
		call	MC_WAIT_FLYBACK
		pop	bc
		djnz	wk_loop
		ret

; ==================================================================
; |KNOISE — apprendre ce qui bouge tout seul. Cumulatif.
; ==================================================================
rsx_knoise:	push	ix
		push	iy
		ld	hl,#msg_noise
		call	printz
		ld	hl,#ZONE
		ld	de,#SNAP
		ld	bc,#ZLEN
		ldir
		call	wait_key

		ld	hl,#ZONE
		ld	de,#SNAP
		ld	bc,#0
kn_loop:	ld	a,(de)
		cp	(hl)
		jr	z, kn_next
		push	hl
		push	de
		push	bc
		call	set_noise
		pop	bc
		pop	de
		pop	hl
kn_next:	inc	hl
		inc	de
		inc	bc
		ld	a,b
		cp	#>ZLEN
		jr	nz, kn_loop
		ld	a,c
		cp	#<ZLEN
		jr	nz, kn_loop

		ld	hl,#msg_nok
		call	printz
		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; |KFIND — mesure avec frappe, filtree par l'apprentissage
; ==================================================================
rsx_kfind:	push	ix
		push	iy
		ld	hl,#msg_press
		call	printz
		ld	hl,#ZONE
		ld	de,#SNAP
		ld	bc,#ZLEN
		ldir
		call	wait_key

		xor	a
		ld	(nhit),a
		ld	hl,#ZONE
		ld	de,#SNAP
		ld	bc,#0
kf_loop:	ld	a,(de)
		cp	(hl)
		jr	z, kf_next
		push	hl
		push	de
		push	bc
		call	tst_noise		; deja connu comme bruit ?
		pop	bc
		pop	de
		pop	hl
		jr	nz, kf_next
		call	rec_hit
kf_next:	inc	hl
		inc	de
		inc	bc
		ld	a,b
		cp	#>ZLEN
		jr	nz, kf_loop
		ld	a,c
		cp	#<ZLEN
		jr	nz, kf_loop
		jr	kf_report

; ==================================================================
; |KRAW,&adresse — 256 octets, SANS filtre de bruit
; ==================================================================
rsx_kraw:	push	ix
		push	iy
		cp	#1
		jr	nz, kr_bad
		ld	l,0(ix)
		ld	h,1(ix)
		ld	(rawadr),hl
		ld	hl,#msg_press
		call	printz
		ld	hl,(rawadr)
		ld	de,#SNAP
		ld	bc,#256
		ldir
		call	wait_key

		xor	a
		ld	(nhit),a
		ld	hl,(rawadr)
		ld	de,#SNAP
		ld	b,#0
kr_loop:	ld	a,(de)
		cp	(hl)
		jr	z, kr_next
		call	rec_hit
kr_next:	inc	hl
		inc	de
		djnz	kr_loop
		jr	kf_report
kr_bad:		ld	hl,#msg_args
		call	printz
		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; Rapport commun : adresse:avant>apres
; ==================================================================
kf_report:	ld	a,(nhit)
		or	a
		jr	z, kf_none
		ld	hl,#msg_found
		call	printz
		ld	a,(nhit)
		ld	b,a
		ld	iy,#hits
kf_show:	push	bc
		ld	l,2(iy)
		ld	h,3(iy)
		call	disphl
		ld	a,#58			; ':'
		call	TXT_OUTPUT
		ld	a,0(iy)
		call	disphex
		ld	a,#62			; '>'
		call	TXT_OUTPUT
		ld	a,1(iy)
		call	disphex
		ld	a,#32
		call	TXT_OUTPUT
		ld	de,#4
		add	iy,de
		pop	bc
		djnz	kf_show
		call	crlf
		jr	kf_end
kf_none:	ld	hl,#msg_nofind
		call	printz
kf_end:		pop	iy
		pop	ix
		scf
		ret

; --- enregistrer un ecart. HL = zone, DE = photo ; les deux sont
;     rendus intacts (c'etait le defaut de la version precedente).
rec_hit:	ld	a,(nhit)
		cp	#MAXHIT
		ret	nc
		ld	(curz),hl
		ld	(curs),de
		ld	l,a			; slot = hits + nhit*4
		ld	h,#0
		add	hl,hl
		add	hl,hl
		ld	de,#hits
		add	hl,de
		ld	de,(curs)
		ld	a,(de)
		ld	(hl),a			; avant
		inc	hl
		ld	de,(curz)
		ld	a,(de)
		ld	(hl),a			; apres
		inc	hl
		ld	(hl),e			; adresse
		inc	hl
		ld	(hl),d
		ld	a,(nhit)
		inc	a
		ld	(nhit),a
		ld	hl,(curz)
		ld	de,(curs)
		ret

; ==================================================================
; Masque de bruit : 1 bit par octet. BC = index. Detruit BC/DE.
; ==================================================================
set_noise:	call	noise_ptr
		or	(hl)
		ld	(hl),a
		ret

tst_noise:	call	noise_ptr
		and	(hl)			; Z = inconnu, NZ = bruit connu
		ret

noise_ptr:	ld	a,c
		and	#7
		inc	a			; 1..8 tours
		ld	d,a
		ld	a,#1
np_shift:	dec	d
		jr	z, np_done
		add	a,a
		jr	np_shift
np_done:	ld	d,a			; masque du bit
		ld	h,b			; hl = index / 8
		ld	l,c
		srl	h
		rr	l
		srl	h
		rr	l
		srl	h
		rr	l
		ld	bc,#NOISE
		add	hl,bc
		ld	a,d
		ret

clr_noise:	ld	hl,#NOISE
		ld	de,#NOISE+1
		ld	bc,#NLEN-1
		ld	(hl),#0
		ldir
		ret

rsx_kclr:	call	clr_noise
		ld	hl,#msg_clr
		call	printz
		scf
		ret

; ==================================================================
; |KDUMP,&adresse — 16 octets a partir de l'adresse
; ==================================================================
rsx_kdump:	push	ix
		push	iy
		cp	#1
		jr	nz, kd_bad
		ld	l,0(ix)
		ld	h,1(ix)
		ld	b,#16
kd_loop:	push	bc
		push	hl
		call	disphl
		ld	a,#58
		call	TXT_OUTPUT
		pop	hl
		ld	a,(hl)
		call	disphex
		ld	a,#32
		call	TXT_OUTPUT
		inc	hl
		pop	bc
		djnz	kd_loop
		call	crlf
		jr	kd_end
kd_bad:		ld	hl,#msg_args
		call	printz
kd_end:		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
disphl:		ld	a,h
		call	disphex
		ld	a,l
		jr	disphex

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
msg_inst:	.ascii	"KEYSCAN. |KNOISE (x3) puis |KFIND."
		.db	13,10
		.ascii	"|KRAW,&B600  |KDUMP,&B650  |KCLR"
		.db	13,10,0
msg_noise:	.ascii	"Apprentissage : NE TOUCHE A RIEN..."
		.db	13,10,0
msg_nok:	.ascii	"Bruit appris."
		.db	13,10,0
msg_press:	.ascii	"Appuie UNE FOIS sur Z, puis attends..."
		.db	13,10,0
msg_found:	.ascii	"adr:avant>apres : "
		.db	0
msg_nofind:	.ascii	"Rien de nouveau."
		.db	13,10,0
msg_clr:	.ascii	"Apprentissage remis a zero."
		.db	13,10,0
msg_args:	.ascii	"Usage : |KRAW,&B600"
		.db	13,10,0
msg_before:	.ascii	"AVANT "
		.db	0
msg_after:	.ascii	"APRES "
		.db	0
msg_crlf:	.db	13,10,0

nhit:		.ds	1
curz:		.ds	2
curs:		.ds	2
rawadr:		.ds	2
hits:		.ds	MAXHIT*4	; avant, apres, adresse
rsx_chain:	.ds	4
