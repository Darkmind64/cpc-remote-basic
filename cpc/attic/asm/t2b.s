; T2B — T2A + le balayage des 127 slots ROM pour trouver la M4,
; avec restauration par KL ROM DESELECT (&B918) et preservation IX/IY.
; Affiche "B" puis le numero de slot trouve, puis ret.
		.module	t2b
		.area	_HEADER (ABS)
		.org	0x8000

TXT_OUTPUT	.equ	0xBB5A
KL_ROM_SELECT	.equ	0xB90F
KL_ROM_DESELECT	.equ	0xB918

start:		push	ix
		push	iy
		ld	a,#66			; 'B'
		call	TXT_OUTPUT
		call	find_m4_rom
		call	disphex
		ld	a,#13
		call	TXT_OUTPUT
		ld	a,#10
		call	TXT_OUTPUT
		pop	iy
		pop	ix
		ret

find_m4_rom:	ld	c,#0
		call	KL_ROM_SELECT
		ld	(saved_rs),bc
		ld	iy,#m4name
		ld	d,#127
fm_loop:	push	de
		ld	c,d
		call	KL_ROM_SELECT
		ld	a,(#0xC000)
		cp	#1
		jr	nz, fm_next
		ld	hl,(#0xC004)
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

m4name:		.ascis	"M4 BOARD"
saved_rs:	.ds	2
