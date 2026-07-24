; ------------------------------------------------------------------
; tcpcli — client TCP pour Amstrad CPC + M4 Board
; Le CPC se CONNECTE au PC (mode client, le chemin firmware fiable),
; envoie un message de bienvenue, puis affiche ce qu'il recoit et
; repond "OK" a chaque paquet. ESC pour quitter.
;
; L'IP du PC est patchee dans le binaire par build_cli.cmd :
;   offset 2..5 = IP (4 octets), offset 6..7 = port (LE, defaut 6128)
; ------------------------------------------------------------------
		.module	tcpcli
		.area	_HEADER (ABS)
		.org	0x4000

DATAPORT	.equ	0xFE00
ACKPORT		.equ	0xFC00
txt_output	.equ	0xBB5A
km_read_char	.equ	0xBB09
kl_rom_select	.equ	0xB90F

C_NETSOCKET	.equ	0x4331
C_NETCONNECT	.equ	0x4332
C_NETCLOSE	.equ	0x4333
C_NETSEND	.equ	0x4334
C_NETRECV	.equ	0x4335

RECVMAX		.equ	200

start:		jr	real_start
pc_ip:		.db	1,1,168,192	; offset 2 : patche par build_cli.cmd
					; ATTENTION ordre firmware = octets INVERSES
					; (192.168.1.1 -> .db 1,1,168,192)
pc_port:	.dw	6128		; offset 6

real_start:	push	ix
		push	iy
		call	find_m4_rom
		cp	#0xFF
		jp	z, no_rom

		ld	hl,(#0xFF02)
		ld	(resp_ptr),hl
		ld	hl,(#0xFF06)
		ld	(sock_ptr),hl

		; NB : pas de fermeture preventive des sockets ici — C_NETCLOSE sur une
		; socket non ouverte plante le firmware v2.0.8 (constate). Faire un
		; reset M4 avant de lancer pour repartir d'une table de sockets propre.

		; marqueur de demarrage AVANT toute operation reseau
		ld	hl,#msg_start
		call	disptextz

		; etape 0 : netstat (valide l'IPC et l'etat de l'ESP)
		ld	hl,#cmd_netstat
		call	sendcmd
		ld	iy,(#resp_ptr)
		push	iy
		pop	hl
		inc	hl
		inc	hl
		inc	hl
		call	disptextz
		call	crlf

		; etape 1 : creation de socket, sur appui de touche
		ld	hl,#msg_step1
		call	disptextz
		call	0xBB06		; KM WAIT CHAR
		ld	hl,#cmd_socket
		call	sendcmd
		ld	a,#0x4B		; 'K' : C_NETSOCKET revenu
		call	txt_output
		ld	iy,(#resp_ptr)
		ld	a, 3(iy)
		cp	#0xFF
		jp	z, err_exit
		ld	(socknum),a
		call	disphex		; afficher le numero de socket obtenu
		call	crlf
		ld	a,(#socknum)
		ld	(cmd_conn+3),a
		ld	(cmd_close+3),a
		ld	(cmd_recv+3),a
		ld	(cmd_hello+3),a
		ld	(cmd_ok+3),a

		; entree sockinfo = base + socket*16
		ld	l,a
		ld	h,#0
		add	hl,hl
		add	hl,hl
		add	hl,hl
		add	hl,hl
		ld	de,(#sock_ptr)
		add	hl,de
		push	hl
		pop	ix

		; --- copier IP/port du header dans la commande connect
		ld	hl,#pc_ip
		ld	de,#cmd_conn+4
		ld	bc,#6
		ldir

		; etape 2 : connexion, sur appui de touche
		ld	hl,#msg_step2
		call	disptextz
		call	0xBB06		; KM WAIT CHAR
		ld	hl,#msg_conn
		call	disptextz
		ld	hl,#cmd_conn
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	a, 3(iy)
		cp	#0xFF		; erreur SEULEMENT si 255 (cf. M4EWEN) —
		jp	z, err_noclose	; 0 ou 1 = OK/en cours. Et surtout ne JAMAIS
					; fermer une socket en cours de connexion.

		; attendre la fin de connexion (statut 1 = connect en cours)
conn_wait:	call	esc_check
		jp	c, close_exit
		ld	a, 0(ix)
		cp	#1
		jr	z, conn_wait
		cp	#240
		jp	nc, err_exit
		ld	hl,#msg_connok
		call	disptextz

		; --- LE test : envoyer en mode client
		ld	a,#0x48		; 'H'
		call	txt_output
		ld	hl,#cmd_hello
		call	sendcmd
		ld	a,#0x68		; 'h'
		call	txt_output
		call	crlf

; ------------------------------------------------------------------
echo_loop:	call	esc_check
		jp	c, close_exit
		ld	a, 0(ix)
		cp	#3
		jp	z, remote_closed
		cp	#240
		jp	nc, err_exit
		ld	a, 2(ix)
		or	3(ix)
		jr	z, echo_loop
		; demander exactement ce qui est disponible (max RECVMAX)
		ld	a, 3(ix)
		or	a
		jr	nz, cap_max
		ld	a, 2(ix)
		cp	#RECVMAX+1
		jr	c, size_ok
cap_max:	ld	a,#RECVMAX
size_ok:	ld	(cmd_recv+4),a
		xor	a
		ld	(cmd_recv+5),a
		ld	hl,#cmd_recv
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	c, 4(iy)
		ld	b, 5(iy)
		ld	a,b
		or	c
		jr	z, echo_loop
		push	iy
		pop	hl
		ld	de,#6
		add	hl,de
		call	disptext
		; accuser reception
sendw:		ld	a, 0(ix)
		cp	#2
		jr	z, sendw
		ld	hl,#cmd_ok
		call	sendcmd
		jp	echo_loop

; ------------------------------------------------------------------
remote_closed:	ld	hl,#msg_closed
		call	disptextz
close_exit:	ld	hl,#cmd_close
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

err_exit:	push	af
		ld	hl,#msg_error
		call	disptextz
		pop	af
		call	disphex
		call	crlf
		jr	close_exit

; erreur sans fermeture de socket (socket dans un etat transitoire)
err_noclose:	push	af
		ld	hl,#msg_error
		call	disptextz
		pop	af
		call	disphex
		call	crlf
		ld	hl,#msg_bye
		call	disptextz
		pop	iy
		pop	ix
		ret

; ------------------------------------------------------------------
esc_check:	call	km_read_char
		ret	nc
		cp	#0xFC
		scf
		ret	z
		or	a
		ret

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

disptext:	ld	a,b
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

disptextz:	ld	a,(hl)
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
msg_start:	.ascii	"tcpcli demarre."
		.db	13,10,0
msg_step1:	.ascii	"Etape 1: touche = creer la socket"
		.db	13,10,0
msg_step2:	.db	13,10
		.ascii	"Etape 2: touche = connecter au PC"
		.db	13,10,0
msg_conn:	.ascii	"Connexion au PC... (ESC pour quitter)"
		.db	13,10,0
msg_connok:	.ascii	"Connecte !"
		.db	13,10,0
msg_closed:	.db	13,10
		.ascii	"Connexion fermee par le PC."
		.db	13,10,0
msg_bye:	.ascii	"tcpcli termine."
		.db	13,10,0
msg_norom:	.ascii	"ROM M4 introuvable !"
		.db	13,10,0
msg_error:	.ascii	"ERREUR code &"
		.db	0

cmd_netstat:	.db	2
		.dw	0x4323		; C_NETSTAT
cmd_socket:	.db	5
		.dw	C_NETSOCKET
		.db	0, 0, 6		; domain=0, type=0, protocole=6 (TCP) - convention firmware (cf. M4EWEN)
cmd_conn:	.db	9
		.dw	C_NETCONNECT
		.db	0		; socket (patche)
		.db	0,0,0,0		; ip (copie de pc_ip)
		.dw	0		; port (copie de pc_port)
cmd_close:	.db	3
		.dw	C_NETCLOSE
		.db	0
cmd_recv:	.db	5
		.dw	C_NETRECV
		.db	0
		.dw	RECVMAX
cmd_hello:	.db	21
		.dw	C_NETSEND
		.db	0		; socket (patche)
		.dw	16		; longueur
		.ascii	"HELLO FROM CPC"
		.db	13,10
cmd_ok:		.db	9
		.dw	C_NETSEND
		.db	0
		.dw	4
		.ascii	"OK"
		.db	13,10

m4_rom_name:	.ascis	"M4 BOARD"

resp_ptr:	.ds	2
sock_ptr:	.ds	2
socknum:	.ds	1
