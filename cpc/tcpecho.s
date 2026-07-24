; ------------------------------------------------------------------
; tcpecho — serveur d'echo TCP pour Amstrad CPC + M4 Board
; Etape 1 du projet "terminal interactif"
;
; Ecoute sur le port 6128. Tout ce que le client envoie est affiche
; sur l'ecran du CPC et renvoye tel quel (echo). ESC pour quitter.
;
; Assemblage : sdasz80 (voir build.cmd). Charge en 0x4000, RUN"TCPECHO.BIN
; Protocole M4 : commandes via port 0xFE00 + ACK 0xFC00 (synchrone),
; reponse via pointeur 0xFF02 de la ROM M4, statuts sockets via 0xFF06.
; D'apres l'exemple lookup.s de Duke (M4examples).
; ------------------------------------------------------------------
		.module	tcpecho
		.area	_HEADER (ABS)
		.org	0x4000

DATAPORT	.equ	0xFE00
ACKPORT		.equ	0xFC00
txt_output	.equ	0xBB5A		; firmware : afficher A
km_read_char	.equ	0xBB09		; firmware : lire touche (carry si dispo)
kl_rom_select	.equ	0xB90F		; firmware : selection ROM haute

C_NETSTAT	.equ	0x4323
C_NETSOCKET	.equ	0x4331
C_NETCLOSE	.equ	0x4333
C_NETSEND	.equ	0x4334
C_NETRECV	.equ	0x4335
C_NETBIND	.equ	0x4338
C_NETLISTEN	.equ	0x4339
C_NETACCEPT	.equ	0x433A

PORT		.equ	6128		; port d'ecoute
RECVMAX		.equ	200		; taille max demandee par C_NETRECV

; ------------------------------------------------------------------
start:		push	ix
		push	iy
		xor	a
		ld	(conn_flag),a
		call	find_m4_rom
		cp	#0xFF
		jp	z, no_rom

		ld	hl,(#0xFF02)	; pointeur buffer de reponse
		ld	(resp_ptr),hl
		ld	hl,(#0xFF06)	; pointeur table sockets
		ld	(sock_ptr),hl

		; afficher l'etat reseau (contient l'IP de la carte)
		ld	hl,#cmd_netstat
		call	sendcmd
		ld	iy,(#resp_ptr)
		push	iy
		pop	hl
		inc	hl
		inc	hl
		inc	hl		; -> chaine de statut
		call	disptextz
		call	crlf

		; --- creer la socket TCP
		ld	hl,#cmd_socket
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	a, 3(iy)		; numero de socket ou 0xFF
		cp	#0xFF
		jp	z, err_exit
		ld	(socknum),a
		ld	(cmd_bind+3),a	; patcher le no de socket dans les commandes
		ld	(cmd_listen+3),a
		ld	(cmd_accept+3),a
		ld	(cmd_close+3),a
		ld	(cmd_recv+3),a

		; adresse de l'entree sockinfo : base + socket*16
		ld	l,a
		ld	h,#0
		add	hl,hl
		add	hl,hl
		add	hl,hl
		add	hl,hl
		ld	de,(#sock_ptr)
		add	hl,de
		push	hl
		pop	ix		; IX -> entree sockinfo de notre socket

		; --- bind (0.0.0.0:PORT) puis listen puis accept
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

		ld	hl,#msg_listen
		call	disptextz

		; --- attendre un client (statut 4 = wait incoming)
wait_client:	call	esc_check
		jp	c, close_exit
		ld	a, 0(ix)		; statut socket
		cp	#4
		jr	z, wait_client
		cp	#240			; >= 240 : erreur
		jp	nc, err_exit
		; client connecte : afficher son IP:port
		ld	a,#1
		ld	(conn_flag),a	; socket etablie -> close autorise a la sortie
		ld	hl,#msg_client
		call	disptextz
		ld	l, 7(ix)
		call	dispdec
		call	dispdot
		ld	l, 6(ix)
		call	dispdec
		call	dispdot
		ld	l, 5(ix)
		call	dispdec
		call	dispdot
		ld	l, 4(ix)
		call	dispdec
		call	crlf

; ------------------------------------------------------------------
; boucle d'echo
; ------------------------------------------------------------------
echo_loop:	call	esc_check
		jp	c, close_exit
		ld	a, 0(ix)
		cp	#3			; connexion fermee par le client ?
		jp	z, remote_closed
		cp	#240
		jp	nc, err_exit
		; des donnees recues ?
		ld	a, 2(ix)
		or	3(ix)
		jr	z, echo_loop
		; les lire
		ld	hl,#cmd_recv
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	c, 4(iy)		; taille recue (16 bits, ici <= 200)
		ld	b, 5(iy)
		ld	a,b
		or	c
		jr	z, echo_loop
		push	bc
		; afficher sur l'ecran du CPC
		push	iy
		pop	hl
		ld	de,#6
		add	hl,de		; -> donnees recues
		push	hl
		call	disptext
		pop	hl
		pop	bc
		; construire la commande echo : [5+len][C_NETSEND][sock][len][data]
		ld	de,#sendbuf+6
		push	bc
		ldir
		pop	bc
		ld	a,c
		add	a,#5
		ld	(sendbuf),a	; taille commande (len<=200 donc pas de retenue)
		ld	a,#<C_NETSEND
		ld	(sendbuf+1),a
		ld	a,#>C_NETSEND
		ld	(sendbuf+2),a
		ld	a,(#socknum)
		ld	(sendbuf+3),a
		ld	a,c
		ld	(sendbuf+4),a
		ld	a,b
		ld	(sendbuf+5),a
		; attendre la fin d'un envoi precedent (statut 2 = send en cours)
send_wait:	ld	a, 0(ix)
		cp	#2
		jr	z, send_wait
		ld	hl,#sendbuf
		call	sendcmd
		jr	echo_loop

; ------------------------------------------------------------------
remote_closed:	ld	hl,#msg_closed
		call	disptextz
close_exit:	ld	a,(#conn_flag)	; ne fermer que si la connexion a ete etablie
		or	a		; (C_NETCLOSE sur socket en ecoute/transitoire
		jr	z, skip_close	;  = crash firmware constate)
		ld	hl,#cmd_close
		call	sendcmd
skip_close:	ld	hl,#msg_bye
		call	disptextz
		pop	iy
		pop	ix
		ret

no_rom:		ld	hl,#msg_norom
		call	disptextz
		pop	iy
		pop	ix
		ret

err_exit:	push	af
		ld	hl,#msg_error
		call	disptextz
		pop	af
		call	disphex
		call	crlf
		jr	close_exit

; ------------------------------------------------------------------
; ESC presse ? retourne carry si oui
esc_check:	call	km_read_char
		ret	nc
		cp	#0xFC		; code clavier ESC
		scf
		ret	z
		or	a		; autre touche : ignorer
		ret

; envoyer la commande pointee par HL (octet 0 = taille)
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

; chercher la ROM M4 (127 -> 1), la laisser selectionnee
; retourne A = numero de rom, ou 0xFF si introuvable
find_m4_rom:	ld	iy,#m4_rom_name
		ld	d,#127
romloop:	push	de
		ld	c,d
		call	kl_rom_select
		ld	a,(#0xC000)
		cp	#1
		jr	nz, not_this_rom
		ld	hl,(#0xC004)	; table des noms RSX
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
		pop	de		; trouve : D = numero
		ld	a,d
		ret
not_this_rom:	pop	de
		dec	d
		jr	nz, romloop
		ld	a,#255
		ret

; affichage -------------------------------------------------------
disptext:	ld	a,b		; HL = texte, BC = longueur
		or	c
		ret	z
		ld	a,(hl)
		push	bc
		push	hl
		call	txt_output
		pop	hl
		pop	bc
		inc	hl
		dec	bc
		jr	disptext

disptextz:	ld	a,(hl)		; HL = texte termine par 0
		or	a
		ret	z
		push	hl
		call	txt_output
		pop	hl
		inc	hl
		jr	disptextz

crlf:		ld	a,#13
		call	txt_output
		ld	a,#10
		jp	txt_output

dispdot:	ld	a,#0x2E
		jp	txt_output

; L = nombre 0-255 en decimal
dispdec:	ld	h,#0
		ld	bc,#0xFF9C	; -100
		call	Num1
		ld	e,a
		cp	#0x30
		call	nz, txt_output
		ld	c,#0xF6		; -10
		call	Num1
		cp	#0x30
		jr	nz, nextnum
		cp	e
nextnum:	call	nz, txt_output
		ld	c,b		; -1
		call	Num1
		jp	txt_output
Num1:		ld	a,#0x2F
Num2:		inc	a
		add	hl,bc
		jr	c, Num2
		sbc	hl,bc
		ret

; A = octet en hexa
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
		jp	txt_output

; donnees ---------------------------------------------------------
msg_listen:	.ascii	"En ecoute sur le port 6128... (ESC pour quitter)"
		.db	13,10,0
msg_client:	.ascii	"Client connecte : "
		.db	0
msg_closed:	.db	13,10
		.ascii	"Connexion fermee par le client."
		.db	13,10,0
msg_bye:	.ascii	"tcpecho termine."
		.db	13,10,0
msg_norom:	.ascii	"ROM M4 introuvable !"
		.db	13,10,0
msg_error:	.ascii	"ERREUR code &"
		.db	0

cmd_netstat:	.db	2
		.dw	C_NETSTAT
cmd_socket:	.db	5
		.dw	C_NETSOCKET
		.db	0, 0, 6	; params firmware M4 (cf. M4EWEN)		; AF_INET, SOCK_STREAM, 0
cmd_bind:	.db	9
		.dw	C_NETBIND
		.db	0		; socket (patche a l'execution)
		.db	0,0,0,0		; 0.0.0.0 = toutes interfaces
		.dw	PORT
cmd_listen:	.db	3
		.dw	C_NETLISTEN
		.db	0		; socket (patche)
cmd_accept:	.db	3
		.dw	C_NETACCEPT
		.db	0		; socket (patche)
cmd_close:	.db	3
		.dw	C_NETCLOSE
		.db	0		; socket (patche)
cmd_recv:	.db	5
		.dw	C_NETRECV
		.db	0		; socket (patche)
		.dw	RECVMAX

m4_rom_name:	.ascis	"M4 BOARD"

; variables (RAM, non emises dans le binaire si en fin de fichier)
resp_ptr:	.ds	2
sock_ptr:	.ds	2
socknum:	.ds	1
conn_flag:	.ds	1
sendbuf:	.ds	256
