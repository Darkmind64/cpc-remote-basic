; ------------------------------------------------------------------
; termrom — ROM de fond : hook resident installe par RSX (etape 3b)
;
; Enseignements des tests precedents :
;   - la reservation memoire par l'init ROM n'est PAS honoree ici
;     (marqueur ecrase, quels que soient HL/DE et le slot) ;
;   - en revanche la zone reservee par MEMORY est STABLE (verifie) ;
;   - c'est le RUN d'un binaire qui reprenait la memoire au retour,
;     d'ou tous les echecs du resident RAM.
; => On installe donc le hook depuis une RSX (pas de RUN, pas de boot),
;    dans la zone reservee par MEMORY, a une adresse FIXE.
;
; Mode d'emploi sur le CPC :
;     MEMORY &9DFF     (une fois apres chaque reset)
;     |TERMON          installe le hook
;     ... utiliser le BASIC normalement ...
;     |TERMHI          affiche le nombre de caracteres captures
;     |TERMOFF         retire le hook
;
; Installation ROM :  rom ../cpc/TERM.ROM 2 TERM   puis  resetm4
; ------------------------------------------------------------------
		.module	termrom
		.area	_HEADER (ABS)
		.org	0xC000

txt_output	.equ	0xBB5A
TXT_OA_ADDR	.equ	0xBDDA		; champ adresse du JP de TXT OUT ACTION
COREADDR	.equ	0x9800		; zone protegee par MEMORY &9DFF
CHAINADDR	.equ	0x9E00+CHAINOFS+1  ; operande du JP de chainage du coeur

; --- en-tete de ROM de fond -------------------------------------
		.db	1
		.db	1, 0, 0
		.dw	name_table
		jp	init			; &C006
		jp	rsx_on			; &C009  |TERMON
		jp	rsx_off			; &C00C  |TERMOFF
		jp	rsx_hi			; &C00F  |TERMHI
		jp	rsx_wait		; &C012  |TERMWAIT

name_table:	.ascis	"TERM ROM"
		.ascis	"TERMON"
		.ascis	"TERMOFF"
		.ascis	"TERMHI"
		.ascis	"TERMWAIT"
		.db	0

; --- init : on accepte, sans rien reserver ni installer ----------
init:		scf
		ret

; --- |TERMON : recopier le coeur en zone protegee, puis l'appeler ---
; C'est ici que tout se joue : le code arrive de la ROM (pas d'un RUN),
; donc la memoire reservee par MEMORY &9DFF n'est jamais reprise.
rsx_on:		ld	hl,#core_blob
		ld	de,#COREADDR
		ld	bc,#CORELEN
		ldir
		call	COREADDR		; -> socket, accept, pose du hook
		scf				; carry arme = commande traitee
		ret

; --- |TERMWAIT : attendre un signal du PC (premier plan) ----------
; Le coeur expose une table de sauts : &9800 = install, &9803 = wait.
; NON FONCTIONNEL : lire la carte pendant que le hook resident lui
; envoie la sortie fait planter le CPC (deux flux de commandes sur une
; carte non reentrante). Conserve pour memoire, neutralise.
rsx_wait:	ld	hl,#msg_nowait
		jr	rsx_end

; --- |TERMOFF : restaurer l'indirection d'origine -----------------
rsx_off:	ld	hl,(#TXT_OA_ADDR)	; pointe sur le hook du coeur ?
		ld	a,h
		cp	#0x98
		jr	nz, off_bad
		ld	hl,(#CHAINADDR)	; cible d'origine memorisee par le coeur
		ld	a,h
		or	a
		jr	z, off_bad
		cp	#0x40
		jr	nc, off_bad
		di
		ld	(TXT_OA_ADDR),hl
		ei
		ld	hl,#msg_off
		jr	rsx_end
off_bad:	ld	hl,#msg_bad
rsx_end:	call	printz
		scf
		ret

; --- |TERMHI : etat -----------------------------------------------
rsx_hi:		ld	hl,(#TXT_OA_ADDR)
		ld	a,h
		cp	#0x98
		jr	z, hi_on
		ld	hl,#msg_hi_off
		jr	rsx_end2
hi_on:		ld	hl,#msg_hi_on
rsx_end2:	call	printz
		scf
		ret

; --- utilitaires --------------------------------------------------
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
		jp	txt_output

printz:		ld	a,(hl)
		or	a
		ret	z
		push	hl
		call	txt_output
		pop	hl
		inc	hl
		jr	printz

msg_off:	.ascii	"Hook retire."
		.db	13,10,0
msg_bad:	.ascii	"Rien a retirer (hook absent)."
		.db	13,10,0
msg_nowait:	.ascii	"TERMWAIT indisponible (voir docs/08)."
		.db	13,10,0
msg_hi_on:	.ascii	"Terminal : ACTIF."
		.db	13,10,0
msg_hi_off:	.ascii	"Terminal : inactif."
		.db	13,10,0
msg_crlf:	.db	13,10,0

		.include "chain.inc"
		.include "blob.inc"

		.org	0xFFFF
		.db	0xFF
