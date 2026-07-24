; ------------------------------------------------------------------
; tcpmirror — miroir d'ecran CPC -> PC via M4 Board (etape 2)
;
; Detourne le vecteur firmware TXT OUTPUT (&BB5A) : chaque caractere
; affiche a l'ecran est recopie vers le PC par TCP.
;
; Architecture de securite (lecons du debug NETAPI) :
;   - le HOOK ne fait QUE du RAM (empile le caractere dans un tampon),
;     aucune I/O M4, aucune lecture de la ROM M4 -> zero risque.
;   - toute l'I/O reseau (C_NETSEND) est dans la boucle principale,
;     en contexte foreground maitrise (comme tcpecho, qui fonctionne).
;
; Mode SERVEUR : le CPC ecoute sur le port 6128, le PC se connecte
; (python ..\pc\mirror_view.py <ip-du-cpc>).
; Le CPC affiche a l'ecran ce qu'on tape au clavier CPC -> mirroir PC.
; ESC pour quitter (retire proprement le hook).
; ------------------------------------------------------------------
		.module	tcpmirror
		.area	_HEADER (ABS)
		.org	0x4000

DATAPORT	.equ	0xFE00
ACKPORT		.equ	0xFC00
TXT_OUTPUT	.equ	0xBB5A		; vecteur firmware (JP xxxx)
TXT_OUT_ADDR	.equ	0xBB5B		; champ adresse du JP en &BB5A
KM_READ_CHAR	.equ	0xBB09		; lire touche (carry=char dispo)
kl_rom_select	.equ	0xB90F

C_NETSTAT	.equ	0x4323
C_NETSOCKET	.equ	0x4331
C_NETCLOSE	.equ	0x4333
C_NETSEND	.equ	0x4334
C_NETBIND	.equ	0x4338
C_NETLISTEN	.equ	0x4339
C_NETACCEPT	.equ	0x433A

PORT		.equ	6128
LINEBUF_SZ	.equ	128

; ------------------------------------------------------------------
start:		push	ix
		push	iy
		xor	a
		ld	(buf_len),a
		ld	(hooked),a

		ld	a,#0x31			; '1' : programme demarre
		call	TXT_OUTPUT

		call	find_m4_rom
		cp	#0xFF
		jp	z, no_rom

		ld	hl,(#0xFF02)
		ld	(resp_ptr),hl
		ld	hl,(#0xFF06)
		ld	(sock_ptr),hl

		ld	a,#0x32			; '2' : ROM+pointeurs OK
		call	TXT_OUTPUT

		; --- creer la socket TCP (params firmware 0,0,6)
		ld	hl,#cmd_socket
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	a, 3(iy)
		cp	#0xFF
		jp	z, err_exit
		ld	(socknum),a		; sauver d'abord
		push	af
		ld	a,#0x33			; '3' : socket creee
		call	TXT_OUTPUT
		pop	af
		call	disphex			; afficher le numero de socket
		ld	a,(socknum)
		ld	(cmd_bind+3),a
		ld	(cmd_listen+3),a
		ld	(cmd_accept+3),a
		ld	(cmd_close+3),a

		; sockstat_ptr = sock_ptr + socknum*16
		ld	l,a
		ld	h,#0
		add	hl,hl
		add	hl,hl
		add	hl,hl
		add	hl,hl
		ld	de,(#sock_ptr)
		add	hl,de
		ld	(sockstat_ptr),hl

		; --- bind / listen / accept
		ld	hl,#cmd_bind
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	a, 3(iy)
		or	a
		jp	nz, err_exit
		ld	a,#0x34			; '4' : bind OK
		call	TXT_OUTPUT
		ld	hl,#cmd_listen
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	a, 3(iy)
		or	a
		jp	nz, err_exit
		ld	a,#0x35			; '5' : listen OK
		call	TXT_OUTPUT
		ld	hl,#cmd_accept
		call	sendcmd
		ld	a,#0x36			; '6' : accept envoye
		call	TXT_OUTPUT

		; message local (hook pas encore installe -> non mirroir)
		ld	hl,#msg_wait
		call	disptextz

		; --- attendre le PC (statut 4 = wait incoming)
wait_client:	ld	hl,(#sockstat_ptr)
		ld	a,(hl)
		cp	#4
		jr	z, wait_client
		cp	#240
		jp	nc, err_exit

		ld	a,#0x37			; '7' : PC connecte, avant install hook (direct)
		call	TXT_OUTPUT

		; --- installer le hook TXT OUTPUT
		ld	a,(#TXT_OUTPUT)		; verifier que c'est bien un JP
		cp	#0xC3
		jp	nz, err_nojp
		ld	hl,(#TXT_OUT_ADDR)	; sauver l'adresse d'origine
		ld	(mo_orig+1),hl
		di
		ld	hl,#my_out
		ld	(TXT_OUT_ADDR),hl	; rediriger
		ei
		ld	a,#1
		ld	(hooked),a

		ld	a,#0x38			; '8' : 1er char VIA LE HOOK (teste mo_orig)
		call	TXT_OUTPUT
		ld	a,#0x39			; '9' : hook a affiche sans planter
		call	TXT_OUTPUT
		call	flush_to_pc		; teste l'envoi
		ld	a,#0x2A			; '*' : flush OK
		call	TXT_OUTPUT

		; a partir d'ici, tout affichage est mirroir vers le PC
		ld	hl,#msg_conn
		call	disptextz
		call	flush_to_pc
		ld	hl,#msg_help
		call	disptextz
		call	flush_to_pc

; ------------------------------------------------------------------
; boucle : clavier CPC -> ecran (mirroir) ; drain tampon -> PC
; ------------------------------------------------------------------
mainloop:	call	KM_READ_CHAR
		jr	nc, ml_flush
		cp	#0xFC			; ESC ?
		jp	z, quit
		push	af
		call	TXT_OUTPUT		; echo ecran (passe par le hook)
		pop	af
		cp	#0x0D			; ENTREE -> ajouter LF
		jr	nz, ml_flush
		ld	a,#0x0A
		call	TXT_OUTPUT
ml_flush:	call	flush_to_pc
		; connexion fermee par le PC ?
		ld	hl,(#sockstat_ptr)
		ld	a,(hl)
		cp	#3
		jp	z, remote_closed
		cp	#240
		jp	nc, remote_closed
		jr	mainloop

; ------------------------------------------------------------------
quit:
remote_closed:	call	flush_to_pc
		call	uninstall
		ld	hl,#cmd_close
		call	sendcmd
		ld	hl,#msg_bye
		call	disptextz
		pop	iy
		pop	ix
		ret

no_rom:		ld	hl,#msg_norom
		call	disptextz
		pop	iy
		pop	ix
		ret

err_nojp:	ld	hl,#msg_nojp
		call	disptextz
		pop	iy
		pop	ix
		ret

; erreur avant installation du hook : pas de close (socket transitoire)
err_exit:	push	af
		ld	hl,#msg_error
		call	disptextz
		pop	af
		call	disphex
		call	crlf
		pop	iy
		pop	ix
		ret

; ------------------------------------------------------------------
; retirer le hook (restaurer &BB5B)
uninstall:	ld	a,(hooked)
		or	a
		ret	z
		ld	hl,(mo_orig+1)
		di
		ld	(TXT_OUT_ADDR),hl
		ei
		xor	a
		ld	(hooked),a
		ret

; ------------------------------------------------------------------
; HOOK TXT OUTPUT — A = caractere. RAM uniquement, pas d'I/O M4.
my_out:		ld	(mo_char),a
		push	af
		push	bc
		push	de
		push	hl
		ld	a,(buf_len)
		cp	#LINEBUF_SZ		; tampon plein -> ne pas empiler
		jr	nc, mo_exit		; (l'ecran reste correct, mirroir saute)
		ld	l,a
		ld	h,#0
		ld	de,#linebuf
		add	hl,de
		ld	a,(mo_char)
		ld	(hl),a
		ld	a,(buf_len)
		inc	a
		ld	(buf_len),a
mo_exit:	pop	hl
		pop	de
		pop	bc
		pop	af
mo_orig:	jp	0x0000			; -> TXT OUTPUT d'origine (patche)

; ------------------------------------------------------------------
; envoyer le tampon vers le PC (C_NETSEND). Contexte foreground.
flush_to_pc:	ld	a,(buf_len)
		or	a
		ret	z
		; attendre fin d'un envoi precedent (statut 2)
fw1:		ld	hl,(#sockstat_ptr)
		ld	a,(hl)
		cp	#2
		jr	z, fw1
		; construire [size][cmd][sock][len16][data...]
		ld	a,(buf_len)
		ld	c,a			; c = longueur
		add	a,#5
		ld	(sendbuf+0),a
		ld	a,#<C_NETSEND
		ld	(sendbuf+1),a
		ld	a,#>C_NETSEND
		ld	(sendbuf+2),a
		ld	a,(socknum)
		ld	(sendbuf+3),a
		ld	a,c
		ld	(sendbuf+4),a		; len lo
		xor	a
		ld	(sendbuf+5),a		; len hi
		ld	hl,#linebuf
		ld	de,#sendbuf+6
		ld	b,#0
		ldir				; bc = longueur (c) -> copie
		ld	hl,#sendbuf
		call	sendcmd
		xor	a
		ld	(buf_len),a
		ret

; ------------------------------------------------------------------
; envoyer la commande M4 pointee par HL (octet 0 = taille)
sendcmd:	ld	bc,#DATAPORT
		ld	d,(hl)
		inc	d
sloop:		inc	b
		outi
		dec	d
		jr	nz, sloop
		ld	bc,#ACKPORT
		out	(c),c
		ret

; chercher la ROM M4, la laisser selectionnee
find_m4_rom:	ld	iy,#m4_rom_name
		ld	d,#127
romloop:	push	de
		ld	c,d
		call	kl_rom_select
		ld	a,(#0xC000)
		cp	#1
		jr	nz, not_this_rom
		ld	hl,(#0xC004)
		push	iy
		pop	de
cmp_loop:	ld	a,(de)
		xor	(hl)
		jr	nz, not_this_rom
		ld	a,(de)
		inc	hl
		inc	de
		and	#0x80
		jr	z, cmp_loop
		pop	de
		ld	a,d
		ret
not_this_rom:	pop	de
		dec	d
		jr	nz, romloop
		ld	a,#255
		ret

; affichage -------------------------------------------------------
disptextz:	ld	a,(hl)
		or	a
		ret	z
		push	hl
		call	TXT_OUTPUT
		pop	hl
		inc	hl
		jr	disptextz

crlf:		ld	a,#13
		call	TXT_OUTPUT
		ld	a,#10
		jp	TXT_OUTPUT

disphex:	push	af
		rrca
		rrca
		rrca
		rrca
		call	hexdigit
		pop	af
hexdigit:	and	#0x0F
		add	a,#0x90
		daa
		adc	a,#0x40
		daa
		jp	TXT_OUTPUT

; donnees ---------------------------------------------------------
msg_wait:	.ascii	"En attente du PC sur le port 6128..."
		.db	13,10,0
msg_conn:	.ascii	"PC connecte. Miroir ecran actif."
		.db	13,10,0
msg_help:	.ascii	"Tapez au clavier CPC (ESC pour quitter):"
		.db	13,10,0
msg_bye:	.db	13,10
		.ascii	"Miroir termine."
		.db	13,10,0
msg_norom:	.ascii	"ROM M4 introuvable !"
		.db	13,10,0
msg_nojp:	.ascii	"TXT OUTPUT n'est pas un JP - abandon."
		.db	13,10,0
msg_error:	.ascii	"ERREUR code &"
		.db	0

cmd_socket:	.db	5
		.dw	C_NETSOCKET
		.db	0, 0, 6			; convention firmware M4 (cf. M4EWEN)
cmd_bind:	.db	9
		.dw	C_NETBIND
		.db	0
		.db	0,0,0,0
		.dw	PORT
cmd_listen:	.db	3
		.dw	C_NETLISTEN
		.db	0
cmd_accept:	.db	3
		.dw	C_NETACCEPT
		.db	0
cmd_close:	.db	3
		.dw	C_NETCLOSE
		.db	0

m4_rom_name:	.ascis	"M4 BOARD"

; variables (RAM) -------------------------------------------------
resp_ptr:	.ds	2
sock_ptr:	.ds	2
sockstat_ptr:	.ds	2
socknum:	.ds	1
hooked:		.ds	1
mo_char:	.ds	1
buf_len:	.ds	1
linebuf:	.ds	LINEBUF_SZ
sendbuf:	.ds	LINEBUF_SZ+8
