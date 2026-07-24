; T2A — le plus petit programme possible qui RENDE LA MAIN.
; Affiche "A" et fait ret. Rien d'autre : pas de ROM, pas de RSX.
; S'il reboote, le probleme est le mecanisme de lancement/retour
; lui-meme, et tout le reste du journal en decoule.
		.module	t2a
		.area	_HEADER (ABS)
		.org	0x8000

TXT_OUTPUT	.equ	0xBB5A

start:		ld	a,#65			; 'A'
		call	TXT_OUTPUT
		ld	a,#13
		call	TXT_OUTPUT
		ld	a,#10
		call	TXT_OUTPUT
		ret
