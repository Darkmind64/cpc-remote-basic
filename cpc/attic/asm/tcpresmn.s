; ------------------------------------------------------------------
; tcpresmn — test MINIMAL de residence (aucun reseau)
;
; Affiche un message AVANT la pose du hook, puis un APRES (qui passe
; donc par le hook), avec des pauses pour que ce soit bien visible.
; Puis rend la main au BASIC.
;
; Assemble en deux versions (voir build_resmn.cmd) :
;   TCPRESMN.BIN  charge en &9E00  -> faire  MEMORY &9DFF  avant
;   TCPRES40.BIN  charge en &4000  -> faire  MEMORY &3FFF  avant
; ------------------------------------------------------------------
		.module	tcpresmn
		.area	_HEADER (ABS)
		.org	ORGADDR

TXT_OUTPUT	.equ	0xBB5A
TXT_OUT_ADDR	.equ	0xBB5B

start:		; --- etape 1 : on tourne (hook PAS encore pose)
		ld	hl,#msg1
		call	printz			; via le TXT OUTPUT d'origine
		call	delay

		; --- etape 2 : poser le hook
		ld	hl,#TXT_OUTPUT
		ld	de,#tramp
		ld	bc,#3
		ldir
		ld	a,#0xC9
		ld	(tramp+3),a
		di
		ld	a,#0xC3
		ld	(TXT_OUTPUT),a
		ld	hl,#my_hook
		ld	(TXT_OUT_ADDR),hl
		ei

		; --- etape 3 : message PASSANT PAR LE HOOK
		ld	hl,#msg2
		call	printz
		call	delay

		; --- etape 4 : retour au BASIC, hook actif
		ret

; hook minimal : passe-plat vers le vrai TXT OUTPUT
my_hook:	call	tramp
		ret

printz:		ld	a,(hl)
		or	a
		ret	z
		push	hl
		call	TXT_OUTPUT
		pop	hl
		inc	hl
		jr	printz

delay:		ld	b,#25			; ~2 s, pour bien voir
dlo:		push	bc
		ld	hl,#0
dli:		dec	hl
		ld	a,h
		or	l
		jr	nz, dli
		pop	bc
		djnz	dlo
		ret

msg1:		.ascii	"ETAPE 1 : je tourne, hook pas encore pose."
		.db	13,10,0
msg2:		.ascii	"ETAPE 2 : hook pose, ce texte passe par lui."
		.db	13,10,0

tramp:		.ds	4
