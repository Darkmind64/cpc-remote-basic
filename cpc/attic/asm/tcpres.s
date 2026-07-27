; ------------------------------------------------------------------
; tcpres — coeur du terminal resident (sortie BASIC -> PC)
;
; Assemble pour &9800. Recopie dans la zone protegee par MEMORY &97FF
; par la RSX |TERMON de notre ROM, puis appele. JAMAIS lance par RUN
; (le RUN reprend la memoire au retour au BASIC).
;
; REFONTE du vidage (voir docs/08-terminal-resident.md) :
;   1. le hook d'affichage n'empile QUE (aucune I/O, aucune concurrence)
;   2. un seul point de vidage nominal : le hook curseur, avec compteur
;      de silence -> on n'envoie jamais pendant un CAT ni un LIST
;   3. vidage RAPIDE : vraie synchro avec la carte (attente "envoi
;      termine") au lieu de temporisations aveugles
;
; Regles M4 (durement acquises) :
;   - ne parler a la carte que lorsqu'elle est au repos (tampon de
;     reponse partage avec le systeme disque)
;   - toute routine qui change la ROM selectionnee doit la restaurer
;   - ne jamais modifier le caractere (codes de controle + parametres)
; ------------------------------------------------------------------
		.module	tcpres
		.area	_HEADER (ABS)
		.org	0x9800

DATAPORT	.equ	0xFE00
ACKPORT		.equ	0xFC00
TXT_OUTPUT	.equ	0xBB5A
TXT_OA_ADDR	.equ	0xBDDA		; champ adresse : TXT OUT ACTION
TXT_DC_ADDR	.equ	0xBDCE		; champ adresse : TXT DRAW CURSOR
KM_READ_CHAR	.equ	0xBB09
MC_WAIT_FLYBACK	.equ	0xBD19
kl_rom_select	.equ	0xB90F
kl_curr_selection .equ	0xB912
kl_rom_restore	.equ	0xB90C
C_NETRECV	.equ	0x4335
kl_rom_restore	.equ	0xB90C	; restaure ROM *et* etat d'activation

C_NETSOCKET	.equ	0x4331
C_NETCLOSE	.equ	0x4333
C_NETSEND	.equ	0x4334
C_NETBIND	.equ	0x4338
C_NETLISTEN	.equ	0x4339
C_NETACCEPT	.equ	0x433A

PORT		.equ	6128
LBSIZE		.equ	1600		; tampon sortie
CHUNK		.equ	200		; max par trame (taille = 1 octet)
HIWATER		.equ	1450		; secours : vidage avant debordement
SYNCMAX		.equ	1500		; borne de l'attente "envoi termine"
QUIET		.equ	2		; appels curseur sans affichage avant vidage

; ==================================================================
; Table de sauts (adresses fixes, appelees par les RSX de la ROM)
;   &9800 : |TERMON   installation
;   &9803 : |TERMWAIT attente d'un octet du PC
; ==================================================================
		jp	start
		jp	do_wait

; ==================================================================
; Entree : appelee par |TERMON (donc depuis la RAM protegee)
; ==================================================================
start:		push	ix
		push	iy
		call	kl_curr_selection	; ROM appelante (la notre)
		ld	(saved_rom),a
		ld	hl,#0
		ld	(buf_len),hl
		xor	a
		ld	(busy),a
		ld	(quiet),a

		call	find_m4_rom
		cp	#0xFF
		jp	z, no_rom
		ld	(m4_rom_num),a		; pour repaginer la M4 au vidage
		ld	hl,(#0xFF02)
		ld	(resp_ptr),hl
		ld	hl,(#0xFF06)
		ld	(sock_ptr),hl

		; --- socket / bind / listen / accept
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

		ld	l,a			; sockstat = sock_ptr + socknum*16
		ld	h,#0
		add	hl,hl
		add	hl,hl
		add	hl,hl
		add	hl,hl
		ld	de,(#sock_ptr)
		add	hl,de
		ld	(sockstat_ptr),hl

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

		ld	hl,#msg_wait
		call	printz

		; --- attendre le PC (cadence 50 Hz, ESC = abandon)
wait_client:	call	MC_WAIT_FLYBACK
		call	KM_READ_CHAR
		jr	nc, wc_stat
		cp	#0xFC
		jr	z, wc_abort
wc_stat:	ld	hl,(#sockstat_ptr)
		ld	a,(hl)
		cp	#4
		jr	z, wait_client
		cp	#240
		jp	nc, err_exit

		; --- poser les deux hooks (indirections = vrais JP)
		ld	hl,(#TXT_OA_ADDR)
		ld	(my_chain+1),hl
		ld	hl,(#TXT_DC_ADDR)
		ld	(cur_chain+1),hl
		di
		ld	hl,#my_hook
		ld	(TXT_OA_ADDR),hl
		ld	hl,#cur_hook
		ld	(TXT_DC_ADDR),hl
		ei

		ld	hl,#msg_on
		call	printz
		call	do_flush
		jr	core_exit

wc_abort:	ld	hl,#msg_abort
		call	printz
		jr	core_exit
no_rom:		ld	hl,#msg_norom
		call	printz
		jr	core_exit
err_exit:	push	af
		ld	hl,#msg_err
		call	printz
		pop	af
		call	disphex
		call	crlf

; sortie commune : RESTAURER la ROM appelante (find_m4_rom l'a changee)
core_exit:	ld	a,(saved_rom)
		ld	c,a
		call	kl_rom_select
		pop	iy
		pop	ix
		ret

; ==================================================================
; |TERMWAIT — attend qu'au moins un octet arrive du PC, le consomme,
; puis rend la main. Appelee en PREMIER PLAN depuis le BASIC : lire la
; carte y est permis, MAIS on ne pagine que par tres brefs instants
; (interruptions coupees), sinon l'ecran se corrompt.
; ==================================================================
do_wait:	push	ix
		push	iy
		; PRENDRE LE VERROU : sinon le hook curseur (sur interruption)
		; appelle do_flush et envoie ses trames a la carte pendant que
		; nous l'interrogeons -> deux flux de commandes entrelaces.
		ld	a,#1
		ld	(busy),a
		ld	hl,#rxbuf		; position d'ecriture courante
		ld	(rx_ptr),hl
dw_loop:	call	MC_WAIT_FLYBACK		; cadence 50 Hz
		call	KM_READ_CHAR
		jr	nc, dw_poll
		cp	#0xFC			; ESC -> abandon
		jr	z, dw_end
dw_poll:	call	rx_fetch		; A=1 quand le marqueur de fin arrive
		or	a
		jr	z, dw_loop
		call	write_cmd		; ecrire cmd.bas depuis rxbuf
dw_end:		xor	a
		ld	(busy),a		; verrou rendu
		pop	iy
		pop	ix
		ret

; --- recuperer les octets dispos ; A=1 si 0x1A (fin) recu ----------
rx_fetch:	call	page_m4
		ld	hl,(sockstat_ptr)
		inc	hl
		inc	hl			; offset 2 = compteur "received"
		ld	a,(hl)
		inc	hl
		or	(hl)
		jr	nz, rf_get
		call	unpage_m4
		xor	a
		ret
rf_get:		ld	hl,#cmd_recv
		call	sendcmd
		ld	iy,(#resp_ptr)
		ld	c, 4(iy)		; longueur recue
		ld	b, 5(iy)
		ld	a,b
		or	c
		jr	z, rf_done
		push	iy
		pop	hl
		ld	de,#6
		add	hl,de			; -> donnees recues
		ld	de,(rx_ptr)
		ldir				; recopier en RAM
		ld	(rx_ptr),de
rf_done:	call	unpage_m4
		ld	hl,#rxbuf		; chercher le marqueur de fin
		ld	de,(rx_ptr)
rf_scan:	ld	a,l
		cp	e
		jr	nz, rf_cmp
		ld	a,h
		cp	d
		jr	z, rf_no
rf_cmp:		ld	a,(hl)
		cp	#0x1A
		jr	z, rf_yes
		inc	hl
		jr	rf_scan
rf_no:		xor	a
		ret
rf_yes:		ld	a,#1
		ret

; --- pagination BREVE de la M4, interruptions coupees --------------
page_m4:	ld	a,i
		jp	po, pg_off
		ld	a,#1
		jr	pg_set
pg_off:		xor	a
pg_set:		ld	(pg_iff),a
		di
		ld	a,(m4_rom_num)
		ld	c,a
		call	kl_rom_select
		ld	(pg_bc),bc		; ancienne ROM + son etat
		ret

unpage_m4:	ld	bc,(pg_bc)
		call	kl_rom_restore		; restaure ROM *et* etat
		ld	a,(pg_iff)
		or	a
		ret	z
		ei
		ret

; --- ecrire cmd.bas avec ce qui a ete recu -------------------------
write_cmd:	ld	hl,(rx_ptr)		; longueur = rx_ptr - rxbuf
		ld	de,#rxbuf
		or	a
		sbc	hl,de
		ld	a,l
		ld	(wr_len),a

		ld	hl,#cmd_open		; C_OPEN "cmd.bas"
		call	sendcmd
		call	page_m4
		ld	iy,(#resp_ptr)
		ld	a, 3(iy)		; descripteur de fichier
		ld	(filefd),a
		call	unpage_m4

		ld	a,(wr_len)		; C_WRITE : [taille][03 43][fd][data]
		add	a,#3
		ld	(wbuf+0),a
		ld	a,#0x03
		ld	(wbuf+1),a
		ld	a,#0x43
		ld	(wbuf+2),a
		ld	a,(filefd)
		ld	(wbuf+3),a
		ld	hl,#rxbuf
		ld	de,#wbuf+4
		ld	a,(wr_len)
		ld	c,a
		ld	b,#0
		ldir
		ld	hl,#wbuf
		call	sendcmd

		ld	a,(filefd)		; C_CLOSE
		ld	(cmd_closef+3),a
		ld	hl,#cmd_closef
		call	sendcmd
		ret

; ==================================================================
; HOOK AFFICHAGE (TXT OUT ACTION) — A = caractere, JAMAIS modifie.
; Empilage seul : aucune I/O ici, donc aucune concurrence avec le
; vidage et aucun risque de deranger la M4 en pleine transaction.
; ==================================================================
my_hook:	push	af
		push	bc
		push	de
		push	hl
		ld	c,a
		ld	a,#QUIET		; ca parle -> on repousse le vidage
		ld	(quiet),a
		di				; serialiser la mise a jour du compteur
		ld	hl,(buf_len)
		ld	de,#LBSIZE
		or	a
		sbc	hl,de
		jr	nc, mh_full		; tampon plein -> caractere perdu
		ld	hl,(buf_len)
		ld	de,#linebuf
		add	hl,de
		ld	(hl),c
		ld	hl,(buf_len)
		inc	hl
		ld	(buf_len),hl
		ei
		; secours : sortie continue tres longue (LIST) -> vider avant
		; debordement. Sans danger : un LIST ne sollicite pas la carte.
		ld	de,#HIWATER
		or	a
		sbc	hl,de
		jr	c, mh_out
		call	do_flush
		jr	mh_out
mh_full:	ei
mh_out:		pop	hl
		pop	de
		pop	bc
		pop	af
my_chain:	jp	0x0000			; -> TXT OUT ACTION d'origine

; ==================================================================
; HOOK CURSEUR (TXT DRAW CURSOR) — point de vidage nominal.
; On ne vide qu'apres QUIET appels SANS aucun affichage : la machine
; est alors au repos, donc la M4 est libre.
; ==================================================================
cur_hook:	push	af
		push	bc
		push	de
		push	hl
		ld	a,(quiet)
		or	a
		jr	z, ch_flush		; silence confirme -> vidage sur
		dec	a
		ld	(quiet),a
		jr	ch_out
ch_flush:	call	do_flush
ch_out:		pop	hl
		pop	de
		pop	bc
		pop	af
cur_chain:	jp	0x0000			; -> TXT DRAW CURSOR d'origine

; ==================================================================
; VIDAGE — synchro REELLE avec la carte (plus de pause aveugle).
; Pagine la ROM M4 le temps de lire l'etat de la socket, puis la
; restaure : sinon le retour se ferait sur la mauvaise ROM.
; ==================================================================
do_flush:	ld	a,(busy)		; verrou premier plan / interruption
		or	a
		ret	nz
		ld	hl,(buf_len)
		ld	a,h
		or	l
		ret	z
		ld	a,#1
		ld	(busy),a
		ld	(bl_rem),hl
		ld	hl,#linebuf
		ld	(bl_ptr),hl

		; PAS de pagination de la M4 ici — VERIFIE : elle occupe la meme
		; plage &C000-&FFFF que l'ecran, et meme avec kl_rom_restore
		; (qui restaure pourtant ROM + etat d'activation) l'affichage
		; se corrompt et le CAT fait rebooter. En resident on ne peut
		; donc qu'ECRIRE vers la carte, jamais lire.
		; -> on espace les trames au lieu de lire son etat.

df_chunk:	ld	hl,(bl_rem)		; morceau = min(reste, CHUNK)
		ld	a,h
		or	a
		jr	nz, df_max
		ld	a,l
		cp	#CHUNK+1
		jr	c, df_sz
df_max:		ld	a,#CHUNK
df_sz:		ld	c,a
		add	a,#5
		ld	(hdr+0),a		; taille commande
		ld	a,#<C_NETSEND
		ld	(hdr+1),a
		ld	a,#>C_NETSEND
		ld	(hdr+2),a
		ld	a,(socknum)
		ld	(hdr+3),a
		ld	a,c
		ld	(hdr+4),a		; longueur des donnees
		xor	a
		ld	(hdr+5),a

		ld	bc,#DATAPORT		; en-tete (6 octets)
		ld	hl,#hdr
		ld	d,#6
df_h:		inc	b
		outi
		dec	d
		jr	nz, df_h
		ld	hl,(bl_ptr)		; donnees, directement du tampon
		ld	a,(hdr+4)
		ld	d,a
df_d:		inc	b
		outi
		dec	d
		jr	nz, df_d
		ld	(bl_ptr),hl
		ld	bc,#ACKPORT
		out	(c),c

		ld	de,#2000		; ~5 ms : laisser la carte digerer
df_pause:	dec	de
		ld	a,d
		or	e
		jr	nz, df_pause

		ld	hl,(bl_rem)		; reste -= morceau
		ld	a,(hdr+4)
		ld	e,a
		ld	d,#0
		or	a
		sbc	hl,de
		ld	(bl_rem),hl
		ld	a,h
		or	l
		jr	nz, df_chunk

df_end:		ld	hl,#0
		ld	(buf_len),hl
		xor	a
		ld	(busy),a
		ret

; ------------------------------------------------------------------
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

printz:		ld	a,(hl)
		or	a
		ret	z
		push	hl
		call	TXT_OUTPUT
		pop	hl
		inc	hl
		jr	printz

crlf:		ld	a,#13
		call	TXT_OUTPUT
		ld	a,#10
		jp	TXT_OUTPUT

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

; ------------------------------------------------------------------
msg_wait:	.ascii	"Attente du PC sur le port 6128..."
		.db	13,10,0
msg_on:		.ascii	"Terminal actif : sortie BASIC -> PC."
		.db	13,10,0
msg_abort:	.ascii	"Abandon (power-cycle la M4 avant de relancer)."
		.db	13,10,0
msg_norom:	.ascii	"ROM M4 introuvable !"
		.db	13,10,0
msg_err:	.ascii	"ERREUR code &"
		.db	0

cmd_socket:	.db	5
		.dw	C_NETSOCKET
		.db	0, 0, 6
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
		.dw	180
cmd_open:	.db	11
		.dw	0x4301			; C_OPEN
		.db	0x8A			; creation + ecriture, mode reel
		.ascii	"cmd.bas"
		.db	0
cmd_closef:	.db	3
		.dw	0x4304			; C_CLOSE
		.db	0

m4_rom_name:	.ascis	"M4 BOARD"

; --- variables ----------------------------------------------------
resp_ptr:	.ds	2
sock_ptr:	.ds	2
sockstat_ptr:	.ds	2
socknum:	.ds	1
saved_rom:	.ds	1
m4_rom_num:	.ds	1
flush_rom:	.ds	1
busy:		.ds	1
quiet:		.ds	1
buf_len:	.ds	2
bl_ptr:		.ds	2
bl_rem:		.ds	2
hdr:		.ds	6
rx_ptr:		.ds	2
pg_iff:		.ds	1
pg_bc:		.ds	2
wr_len:		.ds	1
filefd:		.ds	1
rxbuf:		.ds	200
wbuf:		.ds	208
linebuf:	.ds	LBSIZE
