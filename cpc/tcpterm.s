; ------------------------------------------------------------------
; tcpterm — terminal bidirectionnel CPC <-> PC via M4 Board (etape 3a)
;
; - Clavier CPC -> ecran CPC (via hook TXT OUTPUT) -> mirroir vers le PC.
; - Reception PC -> affichee sur l'ecran CPC (sans re-mirroir).
;
; Regle d'or (crash resolu en etape 2) : ne JAMAIS lire la ROM M4 en
; boucle serree. La reception PC (C_NETRECV) est CADENCEE (une fois
; toutes les ~PACE iterations). Au repos on ne fait que sonder le clavier.
;
; Mode SERVEUR : le CPC ecoute sur le port 6128, le PC se connecte
; (python ..\pc\chat.py <ip-du-cpc>). ESC pour quitter.
; ------------------------------------------------------------------
		.module	tcpterm
		.area	_HEADER (ABS)
		.org	0x4000

DATAPORT	.equ	0xFE00
ACKPORT		.equ	0xFC00
TXT_OUTPUT	.equ	0xBB5A		; vecteur firmware (JP xxxx)
TXT_OUT_ADDR	.equ	0xBB5B		; champ adresse du JP en &BB5A
KM_READ_CHAR	.equ	0xBB09		; lire touche (carry=char dispo)
MC_WAIT_FLYBACK	.equ	0xBD19		; attendre le balayage ecran (cadence 50 Hz)
kl_rom_select	.equ	0xB90F

C_NETSTAT	.equ	0x4323
C_NETSOCKET	.equ	0x4331
C_NETCLOSE	.equ	0x4333
C_NETSEND	.equ	0x4334
C_NETRECV	.equ	0x4335
C_NETBIND	.equ	0x4338
C_NETLISTEN	.equ	0x4339
C_NETACCEPT	.equ	0x433A

PORT		.equ	6128
LINEBUF_SZ	.equ	128
RECVMAX		.equ	64		; octets max par C_NETRECV
PACE		.equ	200		; reception PC toutes les 200 iterations

; ------------------------------------------------------------------
start:		push	ix
		push	iy
		xor	a
		ld	(buf_len),a
		ld	(hooked),a
		ld	a,#PACE
		ld	(recv_pace),a

		call	find_m4_rom
		cp	#0xFF
		jp	z, no_rom

		ld	hl,(#0xFF02)
		ld	(resp_ptr),hl
		ld	hl,(#0xFF06)
		ld	(sock_ptr),hl

		; --- creer la socket TCP (params firmware 0,0,6)
		ld	hl,#cmd_socket
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	a, 3(iy)
		cp	#0xFF
		jp	z, err_exit
		ld	(socknum),a
		ld	(cmd_bind+3),a
		ld	(cmd_listen+3),a
		ld	(cmd_accept+3),a
		ld	(cmd_close+3),a
		ld	(cmd_recv+3),a

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
		ld	hl,#cmd_listen
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	a, 3(iy)
		or	a
		jp	nz, err_exit
		ld	hl,#cmd_accept
		call	sendcmd

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

		; --- installer le hook TXT OUTPUT (methode trampoline)
		; l'entree &BB5A est "RST 1 + adresse" (far-call ROM basse),
		; PAS un JP : on copie les 3 octets d'origine et on les rejoue.
		ld	hl,#TXT_OUTPUT		; copier les 3 octets d'origine
		ld	de,#tramp		; -> trampoline
		ld	bc,#3
		ldir
		ld	a,#0xC9			; RET de securite en fin de trampoline
		ld	(tramp+3),a
		di
		ld	a,#0xC3			; ecrire "JP my_hook" en &BB5A
		ld	(TXT_OUTPUT),a
		ld	hl,#my_hook
		ld	(TXT_OUT_ADDR),hl
		ei
		ld	a,#1
		ld	(hooked),a

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
; Boucle terminal cadencee a 50 Hz (temps reel, sans marteler la M4).
mainloop:	call	MC_WAIT_FLYBACK		; 1 tour = 1 frame = 20 ms
		call	KM_READ_CHAR
		jr	nc, ml_recv		; pas de touche -> tester la reception
		cp	#0xFC			; ESC ?
		jp	z, quit
		push	af
		call	TXT_OUTPUT		; echo ecran (via le hook -> mirroir PC)
		pop	af
		cp	#0x0D			; ENTREE -> ajouter LF
		jr	nz, ml_send
		ld	a,#0x0A
		call	TXT_OUTPUT
ml_send:	call	flush_to_pc		; envoyer le(s) caractere(s) tape(s)
ml_recv:	call	check_pc_recv		; 1 fois par frame = 50 Hz max
		jr	mainloop

; ------------------------------------------------------------------
; Reception PC : si des donnees sont dispo, les afficher a l'ecran
; (via tramp = sans repasser par le hook, donc PAS de re-mirroir).
check_pc_recv:	ld	hl,(#sockstat_ptr)
		inc	hl
		inc	hl			; -> compteur "received" (offset 2)
		ld	a,(hl)
		inc	hl
		or	(hl)			; octet bas | octet haut
		ret	z			; rien recu
		ld	hl,#cmd_recv
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	c, 4(iy)		; longueur recue
		ld	b, 5(iy)
		ld	a,b
		or	c
		ret	z
		push	iy
		pop	hl
		ld	de,#6
		add	hl,de			; -> donnees recues
cpr_loop:	ld	a,(hl)
		push	hl
		push	bc
		call	tramp			; afficher sans mirroir
		pop	bc
		pop	hl
		inc	hl
		dec	bc
		ld	a,b
		or	c
		jr	nz, cpr_loop
		ret

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
		di
		ld	hl,#tramp		; restaurer les 3 octets d'origine
		ld	de,#TXT_OUTPUT
		ld	bc,#3
		ldir
		ei
		xor	a
		ld	(hooked),a
		ret

; ------------------------------------------------------------------
; HOOK TXT OUTPUT — A = caractere.
; Sur : coupe les interruptions autour du vrai TXT OUTPUT (evite
; l'imbrication d'interruptions quand le hook est declenche depuis une
; interruption), et restaure l'etat d'interruption d'origine.
my_hook:	ld	(mo_char),a
		push	af
		push	bc
		push	de
		push	hl
		ld	a,i			; P/V = etat interruptions (IFF2)
		push	af			; memoriser
		di				; pas d'imbrication pendant la sortie
		; empiler le caractere dans le tampon (si place)
		ld	a,(buf_len)
		cp	#LINEBUF_SZ
		jr	nc, mh_skip
		ld	l,a
		ld	h,#0
		ld	de,#linebuf
		add	hl,de
		ld	a,(mo_char)
		ld	(hl),a
		ld	a,(buf_len)
		inc	a
		ld	(buf_len),a
mh_skip:	ld	a,(mo_char)		; A = caractere pour le vrai TXT OUTPUT
		call	tramp			; sortie reelle (interruptions coupees)
		di				; forcer coupees (tramp a pu les reactiver)
		pop	af			; P/V = etat d'origine
		jp	po, mh_noei		; PO = P/V nul = etaient coupees -> laisser
		ei				; sinon reactiver
mh_noei:	pop	hl
		pop	de
		pop	bc
		pop	af
		ret

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
msg_conn:	.ascii	"PC connecte. Terminal bidirectionnel."
		.db	13,10,0
msg_help:	.ascii	"Tapez ici ou sur le PC (ESC pour quitter):"
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
cmd_recv:	.db	5
		.dw	C_NETRECV
		.db	0			; socket (patche)
		.dw	RECVMAX

m4_rom_name:	.ascis	"M4 BOARD"

; variables (RAM) -------------------------------------------------
resp_ptr:	.ds	2
sock_ptr:	.ds	2
sockstat_ptr:	.ds	2
socknum:	.ds	1
hooked:		.ds	1
mo_char:	.ds	1
buf_len:	.ds	1
recv_pace:	.ds	1
tramp:		.ds	4			; 3 octets TXT OUTPUT d'origine + RET
linebuf:	.ds	LINEBUF_SZ
sendbuf:	.ds	LINEBUF_SZ+8
