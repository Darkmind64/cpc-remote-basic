; ------------------------------------------------------------------
; tcpresi — test de residence via l'INDIRECTION TXT OUT ACTION (&BDD9)
;
; Les indirections firmware sont de vrais "JP addr" (C3 xx xx) et sont
; LE point d'accroche prevu pour intercepter l'affichage (contrairement
; au jumpblock &BB5A, entree RST 1 de far-call, qu'il ne faut pas
; remplacer par un JP : ca casse le retour au BASIC).
;
; Le hook met les minuscules en MAJUSCULES : si le BASIC affiche
; "READY" au lieu de "Ready", le hook est actif ET le BASIC survit.
;
; Sur le CPC :  MEMORY &3FFF   puis   putrun ../cpc/TCPRESI.BIN
; Pour desinstaller : rebooter le CPC.
; ------------------------------------------------------------------
		.module	tcpresi
		.area	_HEADER (ABS)
		.org	0x4000

TXT_OUTPUT	.equ	0xBB5A		; pour nos propres affichages
TXT_OUT_ACTION	.equ	0xBDD9		; indirection : JP xxxx
TXT_OA_ADDR	.equ	0xBDDA		; champ adresse de ce JP

start:		ld	hl,#msg1
		call	printz
		call	delay

		; --- poser le hook sur l'indirection
		ld	hl,(#TXT_OA_ADDR)	; adresse d'origine (&140A)
		ld	(my_jp+1),hl		; pour chainer dessus
		di
		ld	hl,#my_hook
		ld	(TXT_OA_ADDR),hl	; l'opcode C3 reste en place
		ei

		ld	hl,#msg2
		call	printz
		call	delay
		ret				; -> retour au BASIC

; ------------------------------------------------------------------
; HOOK TXT OUT ACTION — A = caractere.
; NB : appele avec la ROM BASSE pagine ; notre code est en &4000+,
; donc hors de &0000-&3FFF : pas de conflit.
my_hook:	cp	#0x61			; 'a'
		jr	c, mh_pass
		cp	#0x7B			; 'z'+1
		jr	nc, mh_pass
		sub	#0x20			; minuscule -> MAJUSCULE
mh_pass:
my_jp:		jp	0x0000			; -> TXT OUT ACTION d'origine (patche)

; ------------------------------------------------------------------
printz:		ld	a,(hl)
		or	a
		ret	z
		push	hl
		call	TXT_OUTPUT
		pop	hl
		inc	hl
		jr	printz

delay:		ld	b,#25
dlo:		push	bc
		ld	hl,#0
dli:		dec	hl
		ld	a,h
		or	l
		jr	nz, dli
		pop	bc
		djnz	dlo
		ret

msg1:		.ascii	"Etape 1 : avant le hook (minuscules normales)."
		.db	13,10,0
msg2:		.ascii	"Etape 2 : hook pose, ce texte doit etre en MAJUSCULES."
		.db	13,10,0
