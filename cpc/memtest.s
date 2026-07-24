; ------------------------------------------------------------------
; memtest — ROM de fond MINIMALE dont l'init reserve la memoire
; au-dessus de &8000, et rien d'autre.
;
; But : verifier si la reservation memoire par l'init d'une ROM est
; honoree sur cette machine. docs/08 §3.2 affirme que non, mais ce
; constat date d'avant la decouverte RUN/CALL qui a invalide plusieurs
; conclusions de la meme periode — et la ROM M4 officielle, elle,
; utilise ce mecanisme (init_rom : IY = HL - 276, puis rend HL abaisse).
;
; Convention (relevee dans m4rom/M4ROM.s) :
;   Entree : HL = sommet de la memoire libre, DE = bas
;   Sortie : carry arme = ROM acceptee, HL = nouveau sommet
;
; L'init doit etre SILENCIEUSE (docs/08 §3.5 : afficher quoi que ce
; soit pendant l'init provoque une boucle de reboot).
;
; Test :
;   (m4term)  rom ../cpc/MEMTEST.ROM 3 MEMTEST
;             resetm4
;   (CPC)     PRINT HEX$(HIMEM)
;   Attendu : 7FFF (ou moins). Si on lit A67B ou similaire, la
;   reservation n'est pas honoree et il faudra garder MEMORY &7FFF.
;
; Retrait : depuis m4term,  delrom 3  puis  resetm4
; ------------------------------------------------------------------
		.module	memtest
		.area	_HEADER (ABS)
		.org	0xC000

; --- en-tete de ROM de fond ---------------------------------------
		.db	0x01			; type : ROM de fond
		.db	1, 0, 0			; version 1.0.0
		.dw	name_table		; &C004 : table des noms
		jp	init			; &C006 : RSX 0 = initialisation
		jp	rsx_memchk		; &C009 : |MEMCHK

name_table:	.ascis	"MEMCHK"
		.db	0

; --- initialisation : reserver tout ce qui est au-dessus de &8000 --
init:		ld	a,h			; sommet deja sous &8000 ?
		cp	#0x80
		jr	c, init_ok		; oui : ne pas le remonter
		ld	hl,#0x7FFF		; sinon, reserver &8000 et au-dessus
init_ok:	scf				; carry = ROM acceptee
		ret

; --- |MEMCHK : ecrire un temoin en &8000 pour verifier la protection
rsx_memchk:	ld	hl,#0x8000
		ld	(hl),#0xA5
		inc	hl
		ld	(hl),#0x5A
		scf
		ret

; Le bourrage a 16 Ko est fait par le script de build (padrom.py).
