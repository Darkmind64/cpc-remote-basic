; ------------------------------------------------------------------
; cterm2 — terminal resident CPC <-> PC, REECRIT sur le modele du code
; de reference de Duke (M4examples/tcp.s).
;
; Lecon centrale tiree du code de Duke : la ROM M4 doit rester
; SELECTIONNEE du debut de l'envoi de commande jusqu'a la lecture de
; sa reponse. Toggler la selection ROM entre les deux corrompt la
; reponse. Duke selectionne la M4 une fois et la garde selectionnee
; pour toute la transaction ; on fait pareil.
;
; Architecture (un seul interlocuteur avec la carte -> plus de §3.7) :
;   - le hook d'affichage (TXT OUT ACTION) EMPILE seulement, aucune I/O ;
;   - toute la communication M4 (envoi de la sortie + lecture de
;     l'entree) se fait dans la SEULE RSX |TERMIO, sous une unique
;     selection de la ROM M4, appelee en boucle par le shell BASIC.
;
; Deploiement (JAMAIS par RUN : un binaire lance par RUN ne peut pas
; revenir) :
;     MEMORY &7FFF
;     LOAD"CTERM2.BIN" : CALL &8000
; puis, cote CPC, lancer le shell BASIC (SHELL2.BAS) qui appelle
; |TERM (ouvre la socket, attend le PC) puis |TERMIO en boucle.
; ------------------------------------------------------------------
		.module	cterm2
		.area	_HEADER (ABS)
		.org	0x8000

; --- M4 (memes commandes que Duke) --------------------------------
DATAPORT	.equ	0xFE00
ACKPORT		.equ	0xFC00
C_NETSOCKET	.equ	0x4331
C_NETCLOSE	.equ	0x4333
C_NETSEND	.equ	0x4334
C_NETRECV	.equ	0x4335
C_NETBIND	.equ	0x4338
C_NETLISTEN	.equ	0x4339
C_NETACCEPT	.equ	0x433A

; --- firmware -----------------------------------------------------
TXT_OUTPUT	.equ	0xBB5A
TXT_OA_ADDR	.equ	0xBDDA		; champ adresse : indirection TXT OUT ACTION
KM_READ_CHAR	.equ	0xBB09
MC_WAIT_FLYBACK	.equ	0xBD19
KL_LOG_EXT	.equ	0xBCD1
KL_FIND_COMMAND	.equ	0xBCD4		; HL=nom -> carry si la RSX existe deja
KM_CHAR_RETURN	.equ	0xBB0C		; remet une touche (OK en premier plan)
EDIT_JB		.equ	0xBD5E		; jumpblock EDIT (editeur de ligne BASIC)
EDPACE		.equ	5		; interroger la M4 1 trame sur 5 (~10 Hz)
KL_ROM_SELECT	.equ	0xB90F		; C=ROM -> B=etat, C=ROM precedents
KL_ROM_DESELECT	.equ	0xB918		; B=etat, C=ROM

; --- reglages -----------------------------------------------------
PORT		.equ	6128
TXBUF		.equ	0x9000		; tampon de sortie (empile par le hook)
TXSIZE		.equ	0x1400		; 5 Ko : &9000-&A3FF
RXLINE		.equ	0xA400		; ligne d'entree en cours
RXMAXL		.equ	0x80		; 128 octets
CHUNK		.equ	180		; octets max par C_NETSEND

; ==================================================================
; CALL &8000 : installer les RSX, rendre la main
; ==================================================================
start:		push	ix
		push	iy
		xor	a
		ld	(active),a
		; Deja installe ? Relancer le chargeur sans ce test
		; enregistrerait les RSX une 2e fois et corromprait la
		; chaine du firmware.
		ld	hl,#probe_name
		call	KL_FIND_COMMAND
		jr	c, st_already
		ld	bc,#rsx_table
		ld	hl,#rsx_chain
		call	KL_LOG_EXT
		ld	hl,#msg_inst
		jr	st_end
st_already:	ld	hl,#msg_again
st_end:		call	printz
		pop	iy
		pop	ix
		ret

probe_name:	.ascis	"TERM"

rsx_table:	.dw	name_table
		jp	rsx_term
		jp	rsx_termoff
		jp	rsx_termio
		jp	rsx_termdbg
		jp	rsx_termr
name_table:	.ascis	"TERM"
		.ascis	"TERMOFF"
		.ascis	"TERMIO"
		.ascis	"TERMDBG"
		.ascis	"TERMR"
		.db	0

; ==================================================================
; |TERMR,@a$ — DIAGNOSTIC : reception SEULE (aucun envoi), pour
; isoler. Meme code recv que |TERMIO, sans la phase d'envoi.
; ==================================================================
rsx_termr:	push	ix
		push	iy
		ld	a,(active)
		or	a
		jp	z, io_out
		ld	l,0(ix)
		ld	h,1(ix)
		ld	(descr),hl
		ld	a,(hl)
		ld	(maxlen),a
		inc	hl
		ld	e,(hl)
		inc	hl
		ld	d,(hl)
		ld	(strbuf),de
		call	sel_m4
		call	io_recv			; partie recv commune
		call	desel_m4
		jp	io_finish		; rendre la ligne si prete

; ==================================================================
; |TERMDBG,@a$ — remplit a$ avec "Sxx Rxxxx Cxx" :
;   S = statut de la socket, R = compteur de reçus (sockinfo+2),
;   C = 1er octet reçu (data[3] apres un C_NETRECV) — pour voir si la
;   carte a bien nos octets, et si oui, ce qu'elle renvoie.
; ==================================================================
rsx_termdbg:	push	ix
		push	iy
		ld	l,0(ix)
		ld	h,1(ix)
		ld	(descr),hl
		inc	hl
		ld	e,(hl)
		inc	hl
		ld	d,(hl)
		ld	(strbuf),de

		call	sel_m4
		ld	hl,(sockstat_ptr)	; recu (sockinfo+2)
		inc	hl
		inc	hl
		ld	a,(hl)
		or	a
		jr	nz, dbg_recv
		inc	hl
		ld	a,(hl)
		or	a
		jr	z, dbg_none		; rien recu -> pas de C_NETRECV
dbg_recv:	ld	a,#8			; demander 8 octets
		ld	(cmd_recv+4),a
		xor	a
		ld	(cmd_recv+5),a
		ld	hl,#cmd_recv
		call	sendcmd
		ld	hl,(resp_ptr)		; copier 12 octets de reponse
		ld	de,#dbg_resp
		ld	bc,#12
		ldir
		ld	a,#1
		ld	(dbg_got),a
		jr	dbg_fin
dbg_none:	xor	a
		ld	(dbg_got),a
dbg_fin:	call	desel_m4

		; --- formater : "recu" flag + 11 octets de reponse en hexa
		ld	de,(strbuf)
		ld	a,(dbg_got)		; 1 = un C_NETRECV a eu lieu
		call	hexb
		ld	a,#0x2D			; '-'
		ld	(de),a
		inc	de
		ld	hl,#dbg_resp+3		; status, size, data...
		ld	b,#9
dbg_hx:		ld	a,(hl)
		call	hexb
		inc	hl
		djnz	dbg_hx
		ld	hl,(descr)
		ld	(hl),#21		; 2 + 1 + 9*2
		pop	iy
		pop	ix
		scf
		ret

hexb:		push	af
		rrca
		rrca
		rrca
		rrca
		call	hexb1
		pop	af
hexb1:		and	#0x0F
		add	a,#0x90
		daa
		adc	a,#0x40
		daa
		ld	(de),a
		inc	de
		ret

; ==================================================================
; |TERM — ouvrir la socket serveur, attendre le PC, poser le hook
; ==================================================================
rsx_term:	push	ix
		push	iy
		ld	a,(active)
		or	a
		jp	nz, tm_already

		ld	hl,#TXBUF		; tampons vides
		ld	(tx_head),hl
		ld	(tx_tail),hl
		xor	a
		ld	(rx_len),a
		ld	(line_rdy),a
		ld	(nomir),a

		call	find_m4_rom		; laisse la ROM appelante restauree
		cp	#0xFF
		jp	z, tm_norom
		ld	(m4num),a

		call	sel_m4			; selection M4 pour la sequence
		ld	hl,(#0xFF02)		; tampon de reponse
		ld	(resp_ptr),hl
		ld	hl,(#0xFF06)		; sockinfo
		ld	(sock_ptr),hl

		ld	hl,#cmd_socket		; socket / bind / listen / accept
		call	sendcmd
		ld	hl,(resp_ptr)		; data[0] a resp+3
		ld	de,#3
		add	hl,de
		ld	a,(hl)
		cp	#0xFF
		jp	z, tm_err_d
		ld	(socknum),a
		ld	(cmd_bind+3),a
		ld	(cmd_listen+3),a
		ld	(cmd_accept+3),a
		ld	(cmd_close+3),a
		ld	(cmd_recv+3),a
		ld	(cmd_send+3),a

		ld	l,a			; sockstat = sock_ptr + n*16
		ld	h,#0
		add	hl,hl
		add	hl,hl
		add	hl,hl
		add	hl,hl
		ld	de,(sock_ptr)
		add	hl,de
		ld	(sockstat_ptr),hl

		ld	hl,#cmd_bind
		call	sendcmd
		call	resp0
		or	a
		jr	nz, tm_err_d
		ld	hl,#cmd_listen
		call	sendcmd
		call	resp0
		or	a
		jr	nz, tm_err_d
		ld	hl,#cmd_accept
		call	sendcmd
		call	desel_m4

		ld	hl,#msg_wait
		call	printz

		; --- attendre le PC (sockstat != 4), ESC = abandon
tm_wait:	call	MC_WAIT_FLYBACK
		call	KM_READ_CHAR
		jr	nc, tm_stat
		cp	#0xFC
		jr	z, tm_abort
tm_stat:	call	sel_m4
		ld	hl,(sockstat_ptr)
		ld	a,(hl)
		call	desel_m4
		cp	#4			; 4 = attente de connexion
		jr	z, tm_wait
		cp	#240
		jr	nc, tm_err

		; --- poser le hook d'affichage (indirection = vrai JP)
		ld	hl,(#TXT_OA_ADDR)
		ld	(hook_chain+1),hl
		di
		ld	hl,#out_hook
		ld	(TXT_OA_ADDR),hl
		ei
		ld	a,#1
		ld	(active),a
		call	install_edit		; detourner l'editeur de ligne
		ld	hl,#msg_on
		jr	tm_end

tm_err_d:	call	desel_m4
tm_err:		ld	hl,#msg_err
		jr	tm_end
tm_already:	ld	hl,#msg_already
		jr	tm_end
tm_norom:	ld	hl,#msg_norom
		jr	tm_end
tm_abort:	ld	hl,#msg_abort
tm_end:		call	printz
		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; |TERMOFF — retirer le hook, fermer la socket
; ==================================================================
rsx_termoff:	push	ix
		push	iy
		ld	a,(active)
		or	a
		jr	z, off_none
		xor	a
		ld	(active),a
		call	remove_edit		; rendre l'editeur de ligne
		ld	hl,(hook_chain+1)	; rendre l'indirection
		di
		ld	(TXT_OA_ADDR),hl
		ei
		call	sel_m4
		ld	hl,#cmd_close
		call	sendcmd
		call	desel_m4
		ld	hl,#msg_off
		jr	off_end
off_none:	ld	hl,#msg_notact
off_end:	call	printz
		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; HOOK D'AFFICHAGE (TXT OUT ACTION) — A = caractere, JAMAIS modifie.
; EMPILE seulement dans TXBUF (anneau). Aucune I/O M4 ici.
; ==================================================================
out_hook:	push	af
		push	bc
		push	de
		push	hl
		ld	c,a			; sauver le caractere
		ld	a,(nomir)		; echo local d'une ligne du PC :
		or	a			; il s'affiche sur le CPC mais on
		jr	nz, oh_out		; ne le renvoie pas au PC (doublon)
		ld	hl,(tx_tail)		; case suivante avec bouclage
		inc	hl
		ld	de,#TXBUF+TXSIZE
		or	a
		sbc	hl,de
		jr	c, oh_nowrap
		ld	hl,#TXBUF
		jr	oh_test
oh_nowrap:	add	hl,de
oh_test:	ld	de,(tx_head)		; tampon plein ? (on jette)
		or	a
		sbc	hl,de
		jr	z, oh_out
		add	hl,de
		ex	de,hl
		ld	hl,(tx_tail)
		ld	(hl),c
		ex	de,hl
		ld	(tx_tail),hl
oh_out:		pop	hl
		pop	de
		pop	bc
		pop	af
hook_chain:	jp	0x0000			; -> TXT OUT ACTION d'origine

; ==================================================================
; |TERMIO,@a$ — LE point unique de dialogue avec la carte.
; Sous une SEULE selection de la ROM M4 (modele Duke) :
;   1. vide TXBUF vers la socket (sortie CPC -> PC) ;
;   2. lit la socket ; accumule dans RXLINE jusqu'a un CR ;
;   3. si une ligne complete est prete, la copie dans a$ (sinon vide).
; a$ doit etre pre-dimensionne (SPACE$).
; ==================================================================
rsx_termio:	push	ix
		push	iy
		ld	a,(active)
		or	a
		jp	z, io_out

		ld	l,0(ix)			; descripteur de a$
		ld	h,1(ix)
		ld	(descr),hl
		ld	a,(hl)
		ld	(maxlen),a
		inc	hl
		ld	e,(hl)
		inc	hl
		ld	d,(hl)
		ld	(strbuf),de

		call	sel_m4			; UNE selection pour tout
		call	io_recv			; 1. LIRE L'ENTREE D'ABORD

		; --- 2. vider la sortie ENSUITE (modele tcpecho : buffer
		; contigu [entete+donnees], envoye d'un bloc par sendcmd) -
		call	io_flushall
		jr	io_done

; --- io_flushall : vider TXBUF vers la socket (M4 deja selectionnee) -
io_flushall:	call	tx_used
		ld	a,h
		or	l
		ret	z			; plus rien a envoyer
		ld	hl,(tx_tail)		; taille du morceau contigu
		ld	de,(tx_head)
		or	a
		sbc	hl,de
		jr	nc, io_cap		; tail > head : contigu
		ld	hl,#TXBUF+TXSIZE
		ld	de,(tx_head)
		or	a
		sbc	hl,de
io_cap:		ld	a,h
		or	a
		jr	nz, io_max
		ld	a,l
		cp	#CHUNK+1
		jr	c, io_hdr
io_max:		ld	a,#CHUNK
io_hdr:		ld	c,a			; c = taille donnees (<= CHUNK)
		; construire sendbuf : [5+n][C_NETSEND][sock][n][0][data...]
		ld	a,c
		add	a,#5
		ld	(sendbuf+0),a		; taille commande
		ld	a,#<C_NETSEND
		ld	(sendbuf+1),a
		ld	a,#>C_NETSEND
		ld	(sendbuf+2),a
		ld	a,(socknum)
		ld	(sendbuf+3),a
		ld	a,c
		ld	(sendbuf+4),a		; taille (lo)
		xor	a
		ld	(sendbuf+5),a		; taille (hi)
		ld	hl,(tx_head)		; copier les donnees a sendbuf+6
		ld	de,#sendbuf+6
		ld	b,#0			; bc = n
		push	bc
		ldir				; hl avance jusqu'apres le morceau
		pop	bc
		push	hl			; hl = nouveau tx_head (avant wrap)
		ld	hl,#sendbuf
		call	sendcmd			; envoi d'un bloc, comme tcpecho
		pop	hl
		ld	de,#TXBUF+TXSIZE	; avancer tx_head (avec wrap)
		or	a
		sbc	hl,de
		jr	c, io_nw
		ld	hl,#TXBUF
io_seth:	ld	(tx_head),hl
		jr	io_flushall
io_nw:		add	hl,de
		jr	io_seth

io_done:	call	desel_m4

		; --- 3. rendre la ligne si prete -----------------------
io_finish:	ld	a,(line_rdy)
		or	a
		jr	z, io_empty
		ld	hl,#RXLINE		; copier RXLINE (len rx_len) dans a$
		ld	de,(strbuf)
		ld	a,(rx_len)
		ld	b,a
		ld	c,#0			; c = compteur copie
io_out2:	ld	a,b
		or	a
		jr	z, io_setlen
		ld	a,(maxlen)		; ne pas depasser a$
		cp	c
		jr	z, io_setlen
		ld	a,(hl)
		ld	(de),a
		inc	hl
		inc	de
		inc	c
		dec	b
		jr	io_out2
io_setlen:	ld	hl,(descr)
		ld	a,c
		ld	(hl),a			; longueur de a$
		xor	a			; ligne consommee
		ld	(rx_len),a
		ld	(line_rdy),a
		jr	io_out
io_empty:	ld	hl,(descr)
		ld	(hl),#0			; a$ = ""
io_out:		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; HOOK DE L'EDITEUR DE LIGNE (jumpblock EDIT, &BD5E)
;
; C'est LA solution propre : plus de programme shell BASIC, donc
; l'espace programme est entierement a l'utilisateur.
;
; Le BASIC est en ROM HAUTE : il ne peut pas appeler la ROM basse
; directement, il DOIT passer par le jumpblock. C'est ce qui rend cette
; entree accrochable, contrairement a KM WAIT CHAR / KM READ CHAR que
; le firmware appelle en interne (&1BBF -> &1BC5).
;
; Convention d'EDIT : HL = tampon de ligne (termine par 0) ;
; retour carry arme = ligne validee, carry efface = ESC.
; Sur cette machine : &BD5E = CF 02 AC = RST 1 + &AC02 -> ROM basse
; &2C02, exactement l'EDIT du desassemblage 6128 de Bread80.
;
; Notre hook, appele en PREMIER PLAN par le BASIC :
;   - une ligne est arrivee du PC  -> on la recopie dans le tampon,
;     carry arme : le BASIC l'execute comme si elle etait tapee ;
;   - une touche locale est pressee -> on la remet (KM CHAR RETURN,
;     qui marche en premier plan) et on enchaine vers l'EDIT d'origine ;
;   - sinon on boucle en vidant la sortie vers le PC.
; ==================================================================
edit_hook:	ld	a,(active)
		or	a
		jp	z, ed_tramp		; terminal arrete : editeur normal
		ld	(ed_buf),hl		; tampon fourni par le BASIC
		xor	a
		ld	(ed_tick),a

eh_loop:	call	KM_READ_CHAR		; une touche au clavier CPC ?
		jr	nc, eh_nokey
		call	KM_CHAR_RETURN		; la remettre pour l'editeur
		ld	hl,(ed_buf)
		jp	ed_tramp		; -> saisie locale normale

eh_nokey:	ld	a,(ed_tick)		; cadence douce : la M4 ne supporte
		inc	a			; pas d'etre interrogee a 50 Hz
		ld	(ed_tick),a
		cp	#EDPACE
		jr	c, eh_pause
		xor	a
		ld	(ed_tick),a
		call	sel_m4			; une transaction M4 complete
		call	io_recv			; lire l'entree...
		call	io_flushall		; ...puis vider la sortie
		call	desel_m4
		ld	a,(line_rdy)
		or	a
		jr	nz, eh_deliver
eh_pause:	call	MC_WAIT_FLYBACK
		jr	eh_loop

		; --- livrer la ligne du PC au BASIC
		; 1. l'afficher sur l'ecran du CPC (comme une frappe), mais
		;    SANS la renvoyer au PC : sa console l'affiche deja.
eh_deliver:	ld	a,#1
		ld	(nomir),a
		ld	hl,#RXLINE
		ld	a,(rx_len)
		ld	b,a
		or	a
		jr	z, eh_noecho
eh_echo:	ld	a,(hl)
		push	hl
		push	bc
		call	TXT_OUTPUT
		pop	bc
		pop	hl
		inc	hl
		djnz	eh_echo
eh_noecho:	xor	a
		ld	(nomir),a

		; 2. la deposer dans le tampon de ligne du BASIC
		ld	hl,#RXLINE
		ld	de,(ed_buf)
		ld	a,(rx_len)
		ld	b,a
		or	a
		jr	z, eh_term
eh_cp:		ld	a,(hl)
		ld	(de),a
		inc	hl
		inc	de
		djnz	eh_cp
eh_term:	xor	a
		ld	(de),a			; terminateur
		ld	(rx_len),a		; ligne consommee
		ld	(line_rdy),a
		ld	hl,(ed_buf)
		scf				; carry = ligne validee
		ret

; --- installer / retirer le detournement de &BD5E -----------------
install_edit:	ld	hl,#EDIT_JB		; sauver les 3 octets d'origine
		ld	de,#ed_tramp
		ld	bc,#3
		ldir
		ld	a,#0xC9			; ... suivis d'un RET
		ld	(ed_tramp+3),a
		di
		ld	a,#0xC3			; JP edit_hook
		ld	(EDIT_JB),a
		ld	hl,#edit_hook
		ld	(EDIT_JB+1),hl
		ei
		ret

remove_edit:	ld	a,(ed_tramp)		; rien a restaurer ?
		or	a
		ret	z
		di
		ld	hl,#ed_tramp
		ld	de,#EDIT_JB
		ld	bc,#3
		ldir
		ei
		ret

; --- io_recv : lire l'entree (M4 deja selectionnee). Ordre tcpecho :
;     recv AVANT tout envoi (l'inverse corrompt la reponse). ---------
io_recv:	ld	hl,(sockstat_ptr)	; octets recus (sockinfo+2)
		inc	hl
		inc	hl
		ld	e,(hl)
		inc	hl
		ld	d,(hl)
		ld	a,d
		or	e
		ret	z			; rien recu
		ld	a,d			; n = min(recu, 64)
		or	a
		jr	nz, ir_max
		ld	a,e
		cp	#64+1
		jr	c, ir_sz
ir_max:		ld	a,#64
ir_sz:		ld	(cmd_recv+4),a
		xor	a
		ld	(cmd_recv+5),a
		ld	hl,#cmd_recv
		call	sendcmd
		ld	hl,(resp_ptr)		; status resp+3, taille +4/5, data +6
		ld	de,#3
		add	hl,de
		ld	a,(hl)			; status
		or	a
		ret	nz
		inc	hl
		ld	c,(hl)			; taille (lo)
		inc	hl
		ld	b,(hl)			; (hi)
		inc	hl			; -> data[0]
		ld	a,b
		or	c
		ret	z
ir_cp:		ld	a,(hl)
		push	hl
		push	bc
		call	line_put		; empile dans RXLINE, detecte CR
		pop	bc
		pop	hl
		inc	hl
		dec	bc
		ld	a,b
		or	c
		jr	nz, ir_cp
		ret

; --- empiler un octet dans RXLINE ; CR (13) -> ligne prete ---------
line_put:	cp	#10			; ignorer LF
		ret	z
		cp	#13			; CR = fin de ligne
		jr	z, lp_eol
		ld	c,a			; sauver le caractere
		ld	a,(rx_len)
		cp	#RXMAXL
		ret	nc			; plein : jeter
		ld	e,a
		ld	d,#0
		ld	hl,#RXLINE
		add	hl,de
		ld	(hl),c			; ranger le caractere
		ld	a,(rx_len)
		inc	a
		ld	(rx_len),a
		ret
lp_eol:		ld	a,#1
		ld	(line_rdy),a
		ret

; --- attendre la fin d'un envoi en cours (statut socket != 2) ------
; M4 supposee deja selectionnee. Borne pour ne pas figer la machine.
wait_send:	ld	bc,#0x2000
ws_loop:	ld	hl,(sockstat_ptr)
		ld	a,(hl)
		cp	#2			; 2 = envoi en cours
		ret	nz
		dec	bc
		ld	a,b
		or	c
		jr	nz, ws_loop
		ret

; --- octets en attente dans TXBUF (HL) ----------------------------
tx_used:	ld	hl,(tx_tail)
		ld	de,(tx_head)
		or	a
		sbc	hl,de
		ret	nc
		ld	de,#TXSIZE
		add	hl,de
		ret

; ==================================================================
; Selection / deselection de la ROM M4 (modele Duke : selectionnee
; pendant toute la transaction). Interruptions coupees pour ne pas
; laisser un autre code paginer au milieu.
; ==================================================================
; |TERMIO et |TERM tournent en PREMIER PLAN (interruptions actives) :
; on coupe pendant la transaction M4, on retablit apres. Pas de hook
; d'interruption qui pagine -> pas besoin de preserver l'etat IFF.
sel_m4:		di
		ld	a,(m4num)
		ld	c,a
		call	KL_ROM_SELECT
		ld	(pg_bc),bc
		ret

desel_m4:	ld	bc,(pg_bc)
		call	KL_ROM_DESELECT
		ei
		ret

; --- octet data[0] de la reponse (resp+3), M4 supposee selectionnee -
resp0:		ld	hl,(resp_ptr)
		ld	de,#3
		add	hl,de
		ld	a,(hl)
		ret

; --- envoi d'un bloc commande [taille][cmd][args...] (Duke) --------
sendcmd:	ld	bc,#DATAPORT
		ld	d,(hl)
		inc	d
sc_loop:	inc	b
		outi
		dec	d
		jr	nz, sc_loop
		ld	bc,#ACKPORT
		out	(c),c
		ret

; --- recherche de la ROM M4 (restaure la ROM appelante) -----------
find_m4_rom:	ld	c,#0
		call	KL_ROM_SELECT
		ld	(saved_rs),bc
		ld	iy,#m4_rom_name
		ld	d,#127
fm_loop:	push	de
		ld	c,d
		call	KL_ROM_SELECT
		ld	a,(#0xC000)
		cp	#1
		jr	nz, fm_next
		ld	hl,(#0xC004)
		push	iy
		pop	de
fm_cmp:		ld	a,(de)
		xor	(hl)
		jr	nz, fm_next
		ld	a,(de)
		inc	hl
		inc	de
		and	#0x80
		jr	z, fm_cmp
		pop	de
		ld	a,d
		jr	fm_done
fm_next:	pop	de
		dec	d
		jr	nz, fm_loop
		ld	a,#0xFF
fm_done:	push	af
		ld	bc,(saved_rs)
		call	KL_ROM_DESELECT
		pop	af
		ret

; ==================================================================
; Affichage
; ==================================================================
printz:		ld	a,(hl)
		or	a
		ret	z
		push	hl
		call	TXT_OUTPUT
		pop	hl
		inc	hl
		jr	printz

; ==================================================================
; Commandes M4 (socket patche a l'offset 3)
; ==================================================================
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
		.db	0			; socket
		.dw	0			; taille demandee
cmd_send:	.db	5			; taille (patchee)
		.dw	C_NETSEND
		.db	0			; socket
		.dw	0			; taille donnees (patchee)

m4_rom_name:	.ascis	"M4 BOARD"

; ==================================================================
; Messages
; ==================================================================
msg_inst:	.ascii	"CTERM2 en &8000. RSX : TERM TERMOFF TERMIO"
		.db	13,10,0
msg_again:	.ascii	"CTERM2 deja installe."
		.db	13,10,0
msg_wait:	.ascii	"Attente du PC sur le port 6128 (ESC=abandon)..."
		.db	13,10,0
msg_on:		.ascii	"Terminal actif."
		.db	13,10,0
msg_off:	.ascii	"Terminal arrete."
		.db	13,10,0
msg_already:	.ascii	"Deja actif."
		.db	13,10,0
msg_notact:	.ascii	"Terminal inactif."
		.db	13,10,0
msg_norom:	.ascii	"ROM M4 introuvable."
		.db	13,10,0
msg_abort:	.ascii	"Abandon (power-cycle la M4)."
		.db	13,10,0
msg_err:	.ascii	"Erreur reseau M4."
		.db	13,10,0

; ==================================================================
; Variables
; ==================================================================
active:		.ds	1
m4num:		.ds	1
socknum:	.ds	1
resp_ptr:	.ds	2
sock_ptr:	.ds	2
sockstat_ptr:	.ds	2
saved_rs:	.ds	2
pg_bc:		.ds	2
tx_head:	.ds	2
tx_tail:	.ds	2
rx_len:		.ds	1
line_rdy:	.ds	1
descr:		.ds	2
strbuf:		.ds	2
maxlen:		.ds	1
dbg_got:	.ds	1
dbg_resp:	.ds	12
sendbuf:	.ds	CHUNK+8		; [entete 6][donnees jusqu'a CHUNK]
nomir:		.ds	1		; 1 = ne pas renvoyer l'affichage au PC
ed_buf:		.ds	2		; tampon de ligne fourni par le BASIC
ed_tick:	.ds	1		; cadenceur d'interrogation M4
ed_tramp:	.ds	4		; 3 octets d'origine de &BD5E + RET
rsx_chain:	.ds	4
