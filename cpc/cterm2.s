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
; Le sens PC -> CPC passe par le detournement de l'editeur de ligne du
; BASIC (entree EDIT du jumpblock, &BD5E) : la ligne recue est deposee
; dans le tampon du BASIC, qui l'execute comme une frappe. Aucun
; programme BASIC n'est necessaire, l'espace programme reste libre.
;
; Deploiement recommande : la ROM cpc/termrom2.s (|TERM des le boot).
; Sinon, a la main — JAMAIS par RUN, un binaire lance par RUN ne peut
; pas revenir :
;     MEMORY &7FFF
;     LOAD"CTERM2.BIN" : CALL &8000 : |TERM
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
SCR_GET_MODE	.equ	0xBC11		; A = mode ecran courant (0..2)
TXT_GET_PEN	.equ	0xBB93		; A = encre courante
TXT_GET_PAPER	.equ	0xBB99		; A = papier courant
SCR_GET_INK	.equ	0xBC35		; A = encre -> B = couleur (0..26)
EDIT_JB		.equ	0xBD5E		; jumpblock EDIT (editeur de ligne BASIC)
TXTCLS_JB	.equ	0xBB6C		; jumpblock TXT CLEAR WINDOW (CLS)
TXT_RD_CHAR	.equ	0xBB60		; lit le caractere sous le curseur
TXT_SET_CURSOR	.equ	0xBB75		; H = colonne, L = ligne
TXT_GET_CURSOR	.equ	0xBB78		; -> H = colonne, L = ligne
TXT_GET_MATRIX	.equ	0xBBA5		; A = caractere -> HL = matrice 8 octets
KL_L_ROM_ENABLE	.equ	0xB906		; les matrices sont en ROM basse
KL_L_ROM_DISABLE .equ	0xB909
TXT_CUR_ON	.equ	0xBB81		; curseur visible pendant l'attente
TXT_CUR_OFF	.equ	0xBB84
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
; Table de sauts a adresses FIXES — permet a une ROM de fond
; (cpc/termrom2.s) de recopier ce coeur en &8000 et d'appeler ses
; points d'entree sans connaitre la disposition interne.
;   &8000 : installation des RSX (usage LOAD + CALL &8000)
;   &8003 : demarrer le terminal   (= |TERM)
;   &8006 : arreter le terminal    (= |TERMOFF)
;   &8009 : remise a zero de l'etat (apres une recopie depuis la ROM)
; ==================================================================
		jp	start
		jp	rsx_term
		jp	rsx_termoff
		jp	core_reset

core_reset:	xor	a
		ld	(active),a
		ret

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
		ld	a,#0xFF			; force l'envoi du MODE au demarrage
		ld	(lastmode),a
		ld	(colprev),a		; ... et des couleurs
		ld	a,#4			; 1er tour = transition (client deja la)
		ld	(laststat),a
		xor	a
		ld	(newconn),a
		ld	(cmdmode),a
		ld	(dumpreq),a
		ld	(fontreq),a
		ld	(mirecho),a
		ld	(echo_from),a
		ld	(in_m4),a		; verrou libre au demarrage

		call	find_m4_rom		; laisse la ROM appelante restauree
		cp	#0xFF
		jp	z, tm_norom
		ld	(m4num),a

		call	sel_m4			; selection M4 pour la sequence
		ld	hl,(#0xFF02)		; tampon de reponse
		ld	(resp_ptr),hl
		ld	hl,(#0xFF06)		; sockinfo
		ld	(sock_ptr),hl

		call	net_open		; socket / bind / listen / accept
		or	a
		jp	nz, tm_err_d
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
		call	install_cls		; ... et les effacements d'ecran
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
		call	remove_cls		; ... et TXT CLEAR WINDOW
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
		ld	a,c
		call	tx_put

		; --- affichage progressif : sur un retour-chariot, vider TXBUF
		; vers le PC PENDANT l'execution d'une commande (list, print...)
		; au lieu d'attendre le retour dans l'editeur. Cadence par ligne.
		; Le cat garde la socket occupee (statut 2) par ses lectures
		; disque et tourne SOUS la ROM M4 : dans ces deux cas on n'insiste
		; pas, la sortie partira au Ready (le cat se groupe, le list defile).
		ld	a,c
		cp	#13			; seulement en fin de ligne
		jr	nz, oh_out
		ld	a,(in_m4)		; transaction M4 deja en cours ?
		or	a
		jr	nz, oh_out
		ld	a,(active)
		or	a
		jr	z, oh_out
		ld	a,(laststat)		; un client est-il au bout ?
		cp	#4
		jr	z, oh_out
		cp	#3
		jr	z, oh_out
		cp	#240
		jr	nc, oh_out
		call	sel_m4
		ld	a,(pg_bc)		; ROM active avant = M4 ? (cat/disque)
		ld	hl,#m4num
		cp	(hl)
		jr	z, oh_busy
		ld	hl,(sockstat_ptr)	; socket disponible ?
		ld	a,(hl)
		cp	#2			; 2 = envoi en cours (M4 au disque)
		jr	z, oh_busy
		call	io_flushall
oh_busy:	call	desel_m4
oh_out:		pop	hl
		pop	de
		pop	bc
		pop	af
hook_chain:	jp	0x0000			; -> TXT OUT ACTION d'origine

; --- empiler un octet (A) dans TXBUF, avec bouclage ---------------
tx_put:		push	bc
		push	de
		push	hl
		ld	c,a
		ld	hl,(tx_tail)		; case suivante avec bouclage
		inc	hl
		ld	de,#TXBUF+TXSIZE
		or	a
		sbc	hl,de
		jr	c, tp_nowrap
		ld	hl,#TXBUF
		jr	tp_test
tp_nowrap:	add	hl,de
tp_test:	ld	de,(tx_head)		; tampon plein ? (on jette)
		or	a
		sbc	hl,de
		jr	z, tp_out
		add	hl,de
		ex	de,hl
		ld	hl,(tx_tail)
		ld	(hl),c
		ex	de,hl
		ld	(tx_tail),hl
tp_out:		pop	hl
		pop	de
		pop	bc
		ret

; ==================================================================
; Signaler au PC un changement de MODE ecran.
;
; La commande MODE du BASIC appelle SCR SET MODE directement : elle
; n'emet PAS CHR$(4);CHR$(2) dans le flux d'affichage. Le PC ne peut
; donc pas deviner la largeur en ecoutant les caracteres. On lit donc
; le mode courant et, quand il change, on insere un marqueur
; ESC 'M' <chiffre> dans le flux — le PC y ajuste sa largeur.
; ==================================================================
; ==================================================================
; Signaler au PC l'etat des couleurs : encre, papier et les 16 entrees
; de la palette. Comme pour le MODE, les commandes PEN / PAPER / INK
; du BASIC appellent le firmware directement sans rien emettre dans le
; flux d'affichage : c'est donc au resident de les relever.
;
; Marqueur : ESC 'C' <encre> <papier> <ink0..ink15> (18 octets).
; Emis uniquement quand quelque chose a change.
; ==================================================================
send_colours:	call	TXT_GET_PEN		; A = encre courante
		ld	(colbuf),a
		call	TXT_GET_PAPER		; A = papier courant
		ld	(colbuf+1),a
		ld	hl,#colbuf+2
		xor	a
sc_ink:		push	af			; A = numero d'encre 0..15
		push	hl
		call	SCR_GET_INK		; -> B = 1re couleur (0..26)
		ld	a,b
		pop	hl
		ld	(hl),a
		inc	hl
		pop	af
		inc	a
		cp	#16
		jr	nz, sc_ink

		ld	hl,#colbuf		; identique au dernier envoi ?
		ld	de,#colprev
		ld	b,#18
sc_cmp:		ld	a,(de)
		cp	(hl)
		jr	nz, sc_send
		inc	hl
		inc	de
		djnz	sc_cmp
		ret				; rien n'a bouge

sc_send:	ld	hl,#colbuf		; memoriser l'etat envoye
		ld	de,#colprev
		ld	bc,#18
		ldir
		ld	a,#0x1B			; ESC
		call	tx_put
		ld	a,#0x43			; 'C'
		call	tx_put
		ld	hl,#colbuf
		ld	b,#18
sc_emit:	ld	a,(hl)
		push	hl
		push	bc
		call	tx_put
		pop	bc
		pop	hl
		inc	hl
		djnz	sc_emit
		ret

send_mode:	call	SCR_GET_MODE		; A = mode courant (0..2)
		ld	hl,#lastmode
		cp	(hl)
		ret	z			; inchange
		ld	(hl),a
		push	af
		ld	a,#0x1B			; ESC
		call	tx_put
		ld	a,#0x4D			; 'M'
		call	tx_put
		pop	af
		add	a,#0x30			; '0' + mode
		call	tx_put
		ret

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
		call	wait_send		; l'envoi precedent est-il fini ?
		ld	hl,#sendbuf		; (cadence les flushs rapproches du
		call	sendcmd			; streaming, sinon ils s'ecrasent)
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
		; L'editeur d'origine ne tourne plus : c'est a nous d'allumer
		; le curseur, sinon le CPC parait fige pendant l'attente.
		call	TXT_CUR_ON

eh_loop:	call	KM_READ_CHAR		; une touche au clavier CPC ?
		jr	nc, eh_nokey
		call	KM_CHAR_RETURN		; la remettre pour l'editeur
		call	TXT_CUR_OFF
		ld	hl,(ed_buf)
		; On APPELLE l'editeur d'origine (au lieu de sauter dedans) :
		; il gere la saisie locale complete (curseur, COPY, correction)
		; puis nous rend la main. On peut alors renvoyer la ligne tapee
		; au PC, avant de la laisser au BASIC. La frappe caractere par
		; caractere n'est pas accrochable (l'editeur lit le clavier en
		; interne), mais la LIGNE validee, si.
		call	ed_tramp		; -> retour : carry=validee, HL=ligne
		push	af			; conserver le carry pour le BASIC
		jr	nc, eh_lk_ret		; ESC : ne rien renvoyer au PC
		ld	hl,(ed_buf)
		call	mirror_line		; renvoyer la ligne locale au PC
eh_lk_ret:	pop	af
		ld	hl,(ed_buf)		; le BASIC attend HL = tampon de ligne
		ret				; rendre la main au BASIC

; --- renvoyer au PC une ligne tapee au clavier du CPC (HL = ligne
; terminee par 0). L'editeur l'a deja affichee a l'ecran ; on l'empile
; seulement vers le PC (tx_put, sans repasser par l'ecran) puis on vide.
		; Pas de CR/LF ajoute : le CPC en emet un apres Entree, renvoye
		; par le hook d'affichage. En ajouter un ici ferait une ligne
		; vide en trop cote PC.
mirror_line:	ld	a,(hl)
		or	a
		jr	z, ml_eol
		call	tx_put			; tx_put preserve HL
		inc	hl
		jr	mirror_line
ml_eol:		call	sel_m4
		call	io_flushall
		call	desel_m4
		ret

eh_nokey:	ld	a,(ed_tick)		; cadence douce : la M4 ne supporte
		inc	a			; pas d'etre interrogee a 50 Hz
		ld	(ed_tick),a
		cp	#EDPACE
		jp	c, eh_pause
		xor	a
		ld	(ed_tick),a
		call	send_mode		; MODE change ? prevenir le PC
		call	send_colours		; couleurs changees ?
		ld	a,(rx_len)		; ce qui arrivera apres sera echo
		ld	(echo_from),a
		call	sel_m4			; une transaction M4 complete
		ld	hl,(sockstat_ptr)	; etat de la socket
		ld	a,(hl)
		cp	#3			; 3 = ferme par le distant
		jr	z, eh_lost
		cp	#240			; 240+ = erreur
		jr	nc, eh_lost
		ld	hl,#laststat		; transition attente -> connecte ?
		ld	b,(hl)
		ld	(hl),a
		cp	#4			; 4 = en attente d'un client :
		jr	z, eh_m4done		; ne rien emettre ni lire
		ld	a,b
		cp	#4
		jr	z, eh_conn		; il vient d'arriver -> releve d'ecran
		call	io_recv			; lire l'entree...
		call	io_flushall		; ...puis vider la sortie
		jr	eh_m4done
eh_lost:	call	net_restart		; refermer et se remettre en ecoute
		ld	a,#1
		ld	(relisten),a
		ld	a,#4			; de nouveau en ecoute
		ld	(laststat),a
		jr	eh_m4done
eh_conn:	ld	a,#1			; un client vient de se connecter
		ld	(newconn),a
eh_m4done:	call	desel_m4
		; Le curseur du CPC est un pave plein : ecrire a l'ecran
		; pendant qu'il est affiche le laisserait derriere nous. On
		; l'eteint le temps des sorties, on le rallume avant l'attente.
		call	TXT_CUR_OFF

		ld	a,(newconn)		; nouveau client : lui envoyer le MODE,
		or	a			; les couleurs et l'ecran tel qu'il est
		jr	z, eh_noconn
		xor	a
		ld	(newconn),a
		dec	a			; 0xFF : forcer le renvoi
		ld	(lastmode),a
		ld	(colprev),a
		call	send_mode
		call	send_colours
eh_noconn:	ld	a,(relisten)		; prevenir sur l'ecran du CPC, sans
		or	a			; l'envoyer (plus personne au bout)
		jr	z, eh_nomsg
		xor	a
		ld	(relisten),a
		inc	a
		ld	(nomir),a
		ld	hl,#msg_relist
		call	printz
		xor	a
		ld	(nomir),a
		; --- echo des caracteres recus : le CPC les affiche comme
		; une frappe. mirecho decide si le PC les revoit aussi (oui
		; pour l'afficheur graphique, non pour la console qui a deja
		; son propre echo local).
		; L'ecran doit finir par montrer les rx_len caracteres de la
		; ligne en cours ; il en montre echo_from. La difference dit
		; tout : positive on affiche la suite, negative on efface.
eh_nomsg:	ld	a,(rx_len)
		ld	hl,#echo_from
		sub	(hl)
		jr	z, eh_noecho
		push	af
		ld	a,(mirecho)
		xor	#1			; nomir = l'inverse de mirecho
		ld	(nomir),a
		pop	af
		jr	nc, eh_add
		neg				; combien de caracteres en trop
		ld	b,a
eh_del:		push	bc			; reculer, blanchir, reculer
		ld	a,#8
		call	TXT_OUTPUT
		ld	a,#32
		call	TXT_OUTPUT
		ld	a,#8
		call	TXT_OUTPUT
		pop	bc
		djnz	eh_del
		jr	eh_endec
eh_add:		ld	b,a			; b = nombre de caracteres nouveaux
		ld	a,(echo_from)
		ld	e,a
		ld	d,#0
		ld	hl,#RXLINE
		add	hl,de
eh_ec:		ld	a,(hl)
		push	hl
		push	bc
		call	TXT_OUTPUT
		pop	bc
		pop	hl
		inc	hl
		djnz	eh_ec
eh_endec:	xor	a
		ld	(nomir),a
eh_noecho:	ld	a,(fontreq)		; le PC a demande le jeu de caracteres ?
		or	a
		jr	z, eh_nofont
		xor	a
		ld	(fontreq),a
		call	send_font
eh_nofont:	ld	a,(dumpreq)		; le PC a demande un releve d'ecran ?
		or	a
		jr	z, eh_nodump
		xor	a
		ld	(dumpreq),a
		call	screen_dump		; M4 depaginee : le bitmap est lisible
eh_nodump:	ld	a,(line_rdy)
		or	a
		jr	nz, eh_deliver
eh_pause:	call	TXT_CUR_ON
		call	MC_WAIT_FLYBACK
		jp	eh_loop

		; --- livrer la ligne du PC au BASIC
eh_deliver:	; La ligne a deja ete affichee au fil de la frappe : on
		; la depose simplement dans le tampon de ligne du BASIC.
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
		ld	(echo_from),a
		ld	(line_rdy),a
		ld	hl,(ed_buf)
		scf				; carry = ligne validee
		ret

; ==================================================================
; send_font — envoyer au PC le jeu de caracteres du CPC : les 256
; matrices de 8 octets, soit 2 Ko.
;
; TXT GET MATRIX ne rend pas les octets mais un POINTEUR, et pour les
; caracteres standard il pointe dans la ROM BASSE. Il faut donc
; l'activer le temps de la copie (KL L ROM ENABLE). Notre resident vit
; en &8000 et le tampon en &9000 : ni l'un ni l'autre n'est recouvert
; par la ROM basse (&0000-&3FFF), la copie est donc sans danger.
;
; Interet : le PC affiche alors les VRAIES formes du CPC — y compris
; les semi-graphiques et les symboles qu'on ne savait pas traduire en
; Unicode — et suit automatiquement la ROM francaise comme les
; caracteres redefinis par SYMBOL.
; ==================================================================
send_font:	ld	a,#0x1B			; ESC 'F' + 2048 octets
		call	tx_put
		ld	a,#0x46
		call	tx_put
		ld	c,#0			; code du caractere
sf_char:	push	bc
		ld	a,c
		call	TXT_GET_MATRIX		; -> HL = adresse de la matrice
		push	hl
		call	KL_L_ROM_ENABLE
		pop	hl
		ld	b,#8
sf_byte:	ld	a,(hl)			; tx_put preserve BC et HL
		call	tx_put
		inc	hl
		djnz	sf_byte
		call	KL_L_ROM_DISABLE
		pop	bc
		inc	c
		jr	nz, sf_char		; 256 caracteres
		ret

; ==================================================================
; screen_dump — envoyer au PC le contenu ACTUEL de l'ecran du CPC.
;
; La memoire ecran est un BITMAP, pas du texte : on ne peut pas la lire
; directement. Mais le firmware sait reconnaitre un caractere d'apres
; son dessin (TXT RD CHAR — c'est ce qui fait marcher la touche COPY).
; On parcourt donc l'ecran case par case.
;
; Appele quand un client vient de se connecter : il voit ainsi l'ecran
; tel qu'il est, au lieu d'une fenetre vide.
;
; Les espaces de fin de ligne sont supprimes — un ecran presque vide ne
; coute alors que quelques dizaines d'octets au lieu de 1000.
; ==================================================================
screen_dump:	ld	a,#0x1B			; ESC 'L' : le PC efface d'abord
		call	tx_put
		ld	a,#0x4C
		call	tx_put

		call	SCR_GET_MODE		; largeur selon le mode courant
		and	#3
		ld	e,a
		ld	d,#0
		ld	hl,#modew
		add	hl,de
		ld	a,(hl)
		ld	(scr_w),a

		call	TXT_GET_CURSOR		; H = colonne, L = ligne
		push	hl
		ld	d,#1			; d = ligne courante
sd_row:		ld	e,#1			; e = colonne courante
		ld	hl,#dumpline
sd_col:		push	de
		push	hl
		ld	h,e			; positionner le curseur
		ld	l,d
		call	TXT_SET_CURSOR
		call	TXT_RD_CHAR		; carry + A = caractere reconnu
		jr	c, sd_got
		ld	a,#32			; case non reconnue -> espace
sd_got:		pop	hl
		ld	(hl),a
		inc	hl
		pop	de
		inc	e
		ld	a,(scr_w)
		cp	e
		jr	nc, sd_col

		push	de			; --- oter les espaces de fin
		ld	a,(scr_w)
		ld	b,a
		ld	e,a
		ld	d,#0
		ld	hl,#dumpline
		add	hl,de
		dec	hl
sd_trim:	ld	a,(hl)
		cp	#32
		jr	nz, sd_emit
		dec	hl
		djnz	sd_trim
sd_emit:	ld	hl,#dumpline		; --- emettre la ligne utile
		ld	a,b
		or	a
		jr	z, sd_eol
sd_ec:		ld	a,(hl)			; tx_put preserve BC/DE/HL
		call	tx_put
		inc	hl
		djnz	sd_ec
sd_eol:		pop	de			; d = numero de ligne (1..25)
		ld	a,d
		cp	#25			; derniere ligne : PAS de CR/LF final,
		jr	z, sd_nonl		; sinon une 26e ligne vide decalerait
		ld	a,#13			; l'affichage PC (perte de la 1re ligne)
		call	tx_put
		ld	a,#10
		call	tx_put
sd_nonl:	inc	d
		ld	a,#25
		cp	d
		jr	nc, sd_row

		pop	hl			; rendre le curseur ou il etait
		jp	TXT_SET_CURSOR

modew:		.db	20,40,80,40		; largeur selon le MODE

; ==================================================================
; HOOK DE TXT CLEAR WINDOW (&BB6C) — signaler les effacements d'ecran.
;
; La commande CLS du BASIC appelle cette routine du firmware ; comme le
; BASIC est en ROM haute, elle passe forcement par le jumpblock, donc
; elle est accrochable — meme raisonnement que pour EDIT (&BD5E).
; On previent le PC par un marqueur ESC 'L', puis on enchaine.
; ==================================================================
cls_hook:	push	af
		ld	a,(active)
		or	a
		jr	z, cls_pass
		ld	a,#0x1B			; ESC
		call	tx_put
		ld	a,#0x4C			; 'L'
		call	tx_put
cls_pass:	pop	af
		jp	cls_tramp

install_cls:	ld	hl,#TXTCLS_JB		; sauver les 3 octets d'origine
		ld	de,#cls_tramp
		ld	bc,#3
		ldir
		ld	a,#0xC9			; ... suivis d'un RET
		ld	(cls_tramp+3),a
		di
		ld	a,#0xC3			; JP cls_hook
		ld	(TXTCLS_JB),a
		ld	hl,#cls_hook
		ld	(TXTCLS_JB+1),hl
		ei
		ret

remove_cls:	ld	a,(cls_tramp)		; rien a restaurer ?
		or	a
		ret	z
		di
		ld	hl,#cls_tramp
		ld	de,#TXTCLS_JB
		ld	bc,#3
		ldir
		ei
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
; Un octet &01 introduit une COMMANDE hors-bande venue du PC : l'octet
; suivant n'est pas du texte pour le BASIC mais une instruction pour
; nous. Seule commande pour l'instant : 'D' = relever l'ecran.
; On se contente d'armer un drapeau — le relevé lit le bitmap ecran, or
; la ROM M4 recouvre cette plage quand elle est paginee. Il doit donc
; s'executer APRES depagination, pas ici.
line_put:	ld	c,a
		ld	a,(cmdmode)
		or	a
		jr	z, lp_normal
		xor	a
		ld	(cmdmode),a		; commande consommee
		ld	a,c
		cp	#0x44			; 'D' : relever l'ecran
		jr	nz, lp_notd
		ld	a,#1
		ld	(dumpreq),a
		ret
lp_notd:	cp	#0x46			; 'F' : envoyer le jeu de caracteres
		jr	nz, lp_notf
		ld	a,#1
		ld	(fontreq),a
		ret
lp_notf:	cp	#0x45			; 'E' : renvoyer l'echo des frappes
		ret	nz
		ld	a,#1
		ld	(mirecho),a
		ret
lp_normal:	ld	a,c
		cp	#0x01			; prefixe de commande
		jr	nz, lp_char
		ld	a,#1
		ld	(cmdmode),a
		ret
lp_char:	cp	#10			; ignorer LF
		ret	z
		cp	#13			; CR = fin de ligne
		jr	z, lp_eol
		cp	#0x7F			; DEL = effacer le dernier caractere
		jr	z, lp_del
		cp	#8			; BS aussi, selon le terminal
		jr	z, lp_del
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
		; On raccourcit simplement la ligne : c'est l'echo, plus bas,
		; qui compare la longueur avant/apres et efface a l'ecran.
lp_del:		ld	a,(rx_len)
		or	a
		ret	z			; rien a effacer
		dec	a
		ld	(rx_len),a
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
		ld	a,#1
		ld	(in_m4),a		; verrou anti-reentrance (out_hook)
		ld	a,(m4num)
		ld	c,a
		call	KL_ROM_SELECT
		ld	(pg_bc),bc
		ret

desel_m4:	ld	bc,(pg_bc)
		call	KL_ROM_DESELECT
		push	af			; PRESERVER A : les appelants lisent une
		xor	a			; valeur (ex. le statut socket dans
		ld	(in_m4),a		; tm_wait) AVANT desel_m4 et s'en servent
		pop	af			; APRES. La liberer sans push/pop ecrasait
		ei				; ce A -> statut lu comme 0 -> faux client.
		ret

; ==================================================================
; net_open — creer la socket serveur : socket / bind / listen / accept.
; M4 supposee SELECTIONNEE. Rend A = 0 si tout va bien.
; ==================================================================
net_open:	ld	hl,#cmd_socket
		call	sendcmd
		call	resp0
		cp	#0xFF
		ret	z			; creation refusee
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
		ret	nz
		ld	hl,#cmd_listen
		call	sendcmd
		call	resp0
		or	a
		ret	nz
		ld	hl,#cmd_accept
		call	sendcmd
		xor	a
		ret

; ==================================================================
; net_restart — le PC s'est deconnecte : fermer proprement et se
; remettre en ecoute, pour qu'on puisse relancer cpcterm.py sans
; toucher au CPC.
;
; C_NETCLOSE n'est appele QUE sur une socket etablie ou fermee par le
; distant : sur une socket en ecoute ou en etat transitoire, le
; firmware M4 plante et resette le CPC (constate).
; M4 supposee SELECTIONNEE.
; ==================================================================
net_restart:	ld	hl,#cmd_close
		call	sendcmd
		ld	hl,#TXBUF		; jeter la sortie devenue caduque
		ld	(tx_head),hl
		ld	(tx_tail),hl
		xor	a
		ld	(rx_len),a		; et l'entree en cours
		ld	(line_rdy),a
		ld	a,#0xFF			; re-signaler MODE et couleurs au
		ld	(lastmode),a		; prochain PC
		ld	(colprev),a
		jp	net_open

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
msg_relist:	.ascii	"PC deconnecte - en ecoute sur 6128."
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
lastmode:	.ds	1		; dernier MODE signale au PC
relisten:	.ds	1		; 1 = annoncer la remise en ecoute
mirecho:	.ds	1		; 1 = renvoyer l'echo au PC (afficheur)
echo_from:	.ds	1		; longueur de ligne avant reception
newconn:	.ds	1		; 1 = un client vient de se connecter
cmdmode:	.ds	1		; 1 = l'octet suivant est une commande
dumpreq:	.ds	1		; 1 = relever l'ecran des que possible
fontreq:	.ds	1		; 1 = envoyer le jeu de caracteres
colbuf:		.ds	18		; encre, papier, 16 couleurs de palette
colprev:	.ds	18		; dernier etat signale au PC
scr_w:		.ds	1		; largeur d'ecran pour le releve
dumpline:	.ds	80		; une ligne d'ecran en cours de releve
laststat:	.ds	1		; etat socket au tour precedent
in_m4:		.ds	1		; 1 = transaction M4 en cours (anti-reentrance)
ed_buf:		.ds	2		; tampon de ligne fourni par le BASIC
ed_tick:	.ds	1		; cadenceur d'interrogation M4
ed_tramp:	.ds	4		; 3 octets d'origine de &BD5E + RET
cls_tramp:	.ds	4		; 3 octets d'origine de &BB6C + RET
rsx_chain:	.ds	4
