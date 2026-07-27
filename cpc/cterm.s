; ------------------------------------------------------------------
; cterm — terminal resident CPC -> PC (etape A : sortie seule)
;
; Nouvelle architecture (voir docs/09-nouvelle-architecture.md) :
;   - resident en RAM a &8000, deploye par LOAD + CALL (JAMAIS par RUN :
;     un binaire lance par RUN ne peut pas revenir, son ret reboote) ;
;   - un seul point qui parle a la M4 : l'evenement frame-fly, arme par
;     |TERM. Le hook d'affichage n'empile que ;
;   - la ROM M4 est paginee/depaginee par KL ROM SELECT / KL ROM
;     DESELECT (&B90F / &B918, appariement correct) : on peut donc LIRE
;     l'etat de la socket en tache de fond et se synchroniser vraiment.
;
; Mode d'emploi sur le CPC :
;     MEMORY &7FFF
;     LOAD"CTERM.BIN"
;     CALL &8000            installe les RSX
;     |TERM                 ouvre le port 6128 et attend le PC
;     ... utiliser le BASIC normalement, tout part sur le PC ...
;     |TERMST               etat      |TERMOFF   arret
;
; Cote PC :  python pc/mirror_view.py <ip-du-cpc>
; ------------------------------------------------------------------
		.module	cterm
		.area	_HEADER (ABS)
		.org	0x8000

; --- M4 ------------------------------------------------------------
DATAPORT	.equ	0xFE00
ACKPORT		.equ	0xFC00
C_NETSOCKET	.equ	0x4331
C_NETCLOSE	.equ	0x4333
C_NETRECV	.equ	0x4335
C_NETSEND	.equ	0x4334
C_NETBIND	.equ	0x4338
C_NETLISTEN	.equ	0x4339
C_NETACCEPT	.equ	0x433A

; --- firmware ------------------------------------------------------
TXT_OUTPUT	.equ	0xBB5A
TXT_OA_ADDR	.equ	0xBDDA		; champ adresse du JP : TXT OUT ACTION
TXT_DC_ADDR	.equ	0xBDCE		; champ adresse du JP : TXT DRAW CURSOR
KM_READ_CHAR	.equ	0xBB09		; entree de jumpblock : RST 1 + adresse
KM_CHAR_RETURN	.equ	0xBB0C		; remet un caractere dans le clavier
MC_WAIT_FLYBACK	.equ	0xBD19
KL_LOG_EXT	.equ	0xBCD1
KL_ROM_SELECT	.equ	0xB90F
KL_ROM_DESELECT	.equ	0xB918
KL_CURR_SELECTION .equ	0xB912
KL_ADD_FRAME_FLY .equ	0xBCD7
KL_DEL_FRAME_FLY .equ	0xBCDA

EV_ASYNC	.equ	0x60		; RAM + asynchrone

; --- reglages ------------------------------------------------------
PORT		.equ	6128
LINEBUF		.equ	0x9000		; tampon hors image : fichier court
LBSIZE		.equ	0x1500		; 5376 o : &9000-&A4FF
CHUNK		.equ	200		; max par trame (taille sur 1 octet)
HIWATER		.equ	0x1000		; au-dela, on vide meme si ca parle
IDLEN		.equ	3		; passages sans affichage avant le vidage
FWAIT		.equ	400		; borne d'attente « socket libre »
NDRAIN		.equ	8		; morceaux max par vidage volontaire
RXBUF		.equ	0xA500		; tampon d'entree : &A500-&A57F
					; (workspace AMSDOS/M4 a partir de &A67C)
RXSIZE		.equ	128		; petit : le PC s'auto-limite par l'echo
RXMAX		.equ	32		; octets max par C_NETRECV
DRAINK		.equ	4		; touches injectees au plus par passage

; ==================================================================
; Point d'entree (CALL &8000) : installer les RSX et rendre la main.
; IX/IY appartiennent a l'appelant.
; ==================================================================
start:		push	ix
		push	iy
		xor	a
		ld	(active),a
		ld	(lock),a
		ld	bc,#rsx_table
		ld	hl,#rsx_chain
		call	KL_LOG_EXT
		ld	hl,#msg_inst
		call	printz
		pop	iy
		pop	ix
		ret

rsx_table:	.dw	name_table
		jp	rsx_term
		jp	rsx_termoff
		jp	rsx_termst
		jp	rsx_termf
		jp	rsx_termkey
		jp	rsx_termin
		jp	rsx_termrx
		jp	rsx_termdump
name_table:	.ascis	"TERM"
		.ascis	"TERMOFF"
		.ascis	"TERMST"
		.ascis	"TERMF"
		.ascis	"TERMKEY"
		.ascis	"TERMIN"
		.ascis	"TERMRX"
		.ascis	"TERMDUMP"
		.db	0

; ==================================================================
; |TERMDUMP,@a$ — DIAGNOSTIC : envoie un C_NETRECV (8 octets) et met
; dans a$ le contenu BRUT du tampon de reponse M4 en hexa :
;   disp = sockavail(2) status(1) size(2) data0..7(8)
; Permet de voir EXACTEMENT ce que la carte renvoie en premier plan.
; ==================================================================
rsx_termdump:	push	ix
		push	iy
		cp	#1
		jp	nz, td_out
		ld	l,0(ix)
		ld	h,1(ix)
		ld	(descr),hl
		inc	hl
		ld	e,(hl)
		inc	hl
		ld	d,(hl)
		ld	(strbuf),de		; de = buffer de sortie

		ld	a,#1
		ld	(lock),a

		call	sock_avail		; de(sockavail) -> mais de est le buf...
		; sock_avail rend l'info dans DE ; on la sauve
		ld	(dbg_av),de

		ld	a,#8			; demander 8 octets
		ld	(cmd_recv+4),a
		xor	a
		ld	(cmd_recv+5),a
		ld	hl,#cmd_recv
		call	sendcmd
		call	page_m4
		ld	hl,(resp_ptr)
		ld	de,#dbg_resp		; copier 12 octets de reponse
		ld	bc,#12
		ldir
		call	unpage_m4
		xor	a
		ld	(lock),a

		; --- formater en hexa dans a$
		ld	de,(strbuf)
		ld	a,(dbg_av+1)		; sockavail (2 octets)
		call	hexbyte
		ld	a,(dbg_av)
		call	hexbyte
		ld	a,#0x2D			; '-'
		ld	(de),a
		inc	de
		ld	hl,#dbg_resp+3		; status, size, data (resp+3..)
		ld	b,#9
td_hx:		ld	a,(hl)
		call	hexbyte
		inc	hl
		djnz	td_hx

		ld	hl,(descr)		; longueur = 2+2+1+9*2 = 23
		ld	(hl),#23
td_out:		pop	iy
		pop	ix
		scf
		ret

; A -> 2 chiffres hexa en (DE), DE avance. Preserve HL/BC.
hexbyte:	push	af
		rrca
		rrca
		rrca
		rrca
		call	hexnib
		pop	af
hexnib:		and	#0x0F
		add	a,#0x90
		daa
		adc	a,#0x40
		daa
		ld	(de),a
		inc	de
		ret

; ==================================================================
; |TERMRX,@a$ — DIAGNOSTIC : vide TOUT ce qui est arrive du PC dans
; a$, sans attendre de fin de ligne. Sert a savoir si do_recv recoit
; quoi que ce soit, independamment de la detection de CR.
; ==================================================================
rsx_termrx:	push	ix
		push	iy
		cp	#1
		jp	nz, tx_out
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

		ld	a,#1
		ld	(lock),a
		call	do_recv
		xor	a
		ld	(lock),a

		ld	b,#0			; b = longueur copiee
		ld	de,(strbuf)
tx_copy:	ld	hl,(rx_head)		; rx vide ?
		ld	a,(rx_tail)
		cp	l
		jr	nz, tx_take
		ld	a,(rx_tail+1)
		cp	h
		jr	z, tx_done
tx_take:	ld	a,(hl)
		call	rx_advance
		ld	c,a
		ld	a,(maxlen)
		cp	b
		jr	z, tx_done		; plein
		ld	a,c
		ld	(de),a
		inc	de
		inc	b
		jr	tx_copy
tx_done:	ld	hl,(descr)
		ld	(hl),b
tx_out:		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; |TERMIN,@a$ — rendre au BASIC la ligne recue du PC (vide si aucune
; ligne complete n'est arrivee).
;
; C'est la piece qui manquait. On n'essaie plus de reveiller l'editeur
; BASIC (impossible : reproduire a l'identique l'etat memoire d'une
; vraie frappe ne suffit pas, le signal attendu est un evenement
; firmware). A la place, c'est un PROGRAMME BASIC qui tient la boucle
; et vient chercher la ligne ici — le meme modele que tcpterm, mais
; avec le BASIC vivant.
;
; Emploi :   10 a$=SPACE$(100)
;            20 |TERMIN,@a$
;            30 IF a$="" THEN 20
;
; a$ doit etre pre-dimensionne (SPACE$) : on ecrit dans son tampon.
; ==================================================================
rsx_termin:	push	ix
		push	iy
		cp	#1			; un seul argument attendu
		jp	nz, ti_out

		ld	l,0(ix)			; -> descripteur de chaine
		ld	h,1(ix)
		ld	(descr),hl
		ld	a,(hl)			; octet 0 = longueur reservee
		ld	(maxlen),a
		inc	hl
		ld	e,(hl)			; octets 1-2 = adresse du tampon
		inc	hl
		ld	d,(hl)
		ld	(strbuf),de

		ld	a,#1			; ecarter le tick et le curseur
		ld	(lock),a
		call	do_recv			; premier plan : lecture permise
		xor	a
		ld	(lock),a

		call	find_eol		; une ligne complete est-elle la ?
		jr	nc, ti_empty

		; --- copier la ligne dans le tampon de la chaine
		ld	b,#0			; b = longueur copiee
		ld	de,(strbuf)
		; find_eol garantit qu'un CR est present : la boucle s'arrete
ti_copy:	ld	hl,(rx_head)
		ld	a,(hl)
		call	rx_advance
		cp	#13			; fin de ligne -> termine
		jr	z, ti_done
		cp	#10			; ignorer les sauts de ligne
		jr	z, ti_copy
		ld	c,a
		ld	a,(maxlen)
		cp	b
		jr	z, ti_copy		; plein : on jette le surplus
		ld	a,c
		ld	(de),a
		inc	de
		inc	b
		jr	ti_copy

ti_done:	ld	hl,(descr)		; longueur reelle de la chaine
		ld	(hl),b
		jr	ti_out
ti_empty:	ld	hl,(descr)
		ld	(hl),#0			; chaine vide
ti_out:		pop	iy
		pop	ix
		scf
		ret

; --- y a-t-il un CR dans le tampon d'entree ? (carry = oui) --------
find_eol:	ld	hl,(rx_head)
		ld	de,(rx_tail)
fe_loop:	ld	a,l
		cp	e
		jr	nz, fe_test
		ld	a,h
		cp	d
		jr	z, fe_none		; parcouru sans trouver
fe_test:	ld	a,(hl)
		cp	#13
		jr	z, fe_yes
		inc	hl
		ld	bc,#RXBUF+RXSIZE
		ld	a,h
		cp	b
		jr	nz, fe_loop
		ld	a,l
		cp	c
		jr	nz, fe_loop
		ld	hl,#RXBUF
		jr	fe_loop
fe_none:	or	a
		ret
fe_yes:		scf
		ret

; --- avancer rx_head d'une case (avec bouclage) -------------------
rx_advance:	push	af
		ld	hl,(rx_head)
		inc	hl
		ld	de,#RXBUF+RXSIZE
		or	a
		sbc	hl,de
		jr	c, ra_nowrap
		ld	hl,#RXBUF
		jr	ra_set
ra_nowrap:	add	hl,de
ra_set:		ld	(rx_head),hl
		pop	af
		ret

; --- |TERMKEY : armer/desarmer l'injection clavier (experimental) ---
rsx_termkey:	ld	a,(injon)
		cpl
		ld	(injon),a
		or	a
		ld	hl,#msg_kon
		jr	nz, tk_show
		ld	hl,#msg_koff
tk_show:	call	printz
		scf
		ret

; ==================================================================
; |TERMF — vidage FORCE : envoyer tout ce qui reste, sans attendre le
; silence. Sert de discriminateur : si la fin d'un CAT bloquee arrive
; des qu'on tape |TERMF, le coupable est le compteur de silence ; si
; elle n'arrive qu'a la commande suivante, c'est la carte qui retient
; le dernier segment TCP.
; ==================================================================
rsx_termf:	push	ix
		push	iy
		ld	a,(active)
		or	a
		jr	z, tf_off
tf_loop:	call	tx_used
		ld	a,h
		or	l
		jr	z, tf_done
		ld	a,#1			; verrou : ecarter tick et curseur
		ld	(lock),a
		call	do_drain
		xor	a
		ld	(lock),a
		jr	tf_loop
tf_done:	ld	hl,#msg_flush
		jr	tf_end
tf_off:		ld	hl,#msg_notact
tf_end:		call	printz
		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; |TERM — ouvrir la socket serveur, attendre le PC, armer le resident
; ==================================================================
rsx_term:	push	ix
		push	iy
		ld	a,(active)
		or	a
		jp	nz, tm_already

		ld	hl,#LINEBUF		; tampons vides
		ld	(tx_head),hl
		ld	(tx_tail),hl
		ld	hl,#RXBUF
		ld	(rx_head),hl
		ld	(rx_tail),hl
		ld	hl,#0
		ld	(ticks),hl
		ld	(sends),hl
		ld	(hooks),hl
		ld	(curs),hl
		ld	(rej_q),hl
		ld	(rej_b),hl
		ld	(injs),hl
		ld	(rxs),hl
		xor	a
		ld	(lock),a
		ld	(pend),a
		ld	(ack),a
		ld	h,a			; p_buf=0 : do_inject inactif tant
		ld	l,a			; que find_kb_slot n'a pas localise
		ld	(p_buf),hl		; le tampon
		ld	(injon),a		; injection clavier DESARMEE : dans
					; l'environnement M4, l'editeur ne lit
					; le tampon que sur une vraie frappe.
					; Le sens PC->CPC passe par |TERMIN +
					; shell BASIC. |TERMKEY reste pour essais.

		call	find_m4_rom
		cp	#0xFF
		jp	z, tm_norom
		ld	(m4num),a
		call	page_m4
		ld	hl,(#0xFF02)		; tampon de reponse
		ld	(resp_ptr),hl
		ld	hl,(#0xFF06)		; structure sockinfo
		ld	(sock_ptr),hl
		call	unpage_m4

		; --- creation de la socket : 0,0,6 (surtout pas BSD)
		ld	hl,#cmd_socket
		call	sendcmd
		call	resp_byte
		cp	#0xFF
		jp	z, tm_err
		ld	(socknum),a
		ld	(cmd_bind+3),a
		ld	(cmd_listen+3),a
		ld	(cmd_accept+3),a
		ld	(cmd_close+3),a
		ld	(cmd_recv+3),a

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
		call	resp_byte
		or	a
		jp	nz, tm_err
		ld	hl,#cmd_listen
		call	sendcmd
		call	resp_byte
		or	a
		jp	nz, tm_err
		ld	hl,#cmd_accept
		call	sendcmd

		ld	hl,#msg_wait
		call	printz

		; --- attente du PC (50 Hz, ESC = abandon)
tm_wait:	call	MC_WAIT_FLYBACK
		call	KM_READ_CHAR
		jr	nc, tm_stat
		cp	#0xFC			; ESC
		jp	z, tm_abort
tm_stat:	call	sockstat
		cp	#4			; 4 = attente d'une connexion
		jr	z, tm_wait
		cp	#240
		jp	nc, tm_err

		; --- poser les hooks (indirections = vrais JP)
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
		call	find_kb_slot		; localiser le tampon clavier

		; --- armer l'unique point de dialogue avec la carte
		ld	hl,#ev_block
		ld	b,#EV_ASYNC
		ld	c,#0
		ld	de,#tick
		call	KL_ADD_FRAME_FLY
		ld	a,#1
		ld	(active),a

		ld	hl,#msg_on
		jr	tm_end

tm_already:	ld	hl,#msg_already
		jr	tm_end
tm_norom:	ld	hl,#msg_norom
		jr	tm_end
tm_abort:	ld	hl,#msg_abort
		jr	tm_end
tm_err:		ld	hl,#msg_err
tm_end:		call	printz
		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; |TERMOFF — desarmer, retirer le hook, fermer la socket
; ==================================================================
rsx_termoff:	push	ix
		push	iy
		ld	a,(active)
		or	a
		jr	z, off_none

		xor	a			; 1. plus aucun tick n'agit
		ld	(active),a
		ld	hl,#ev_block		; 2. retirer l'evenement
		call	KL_DEL_FRAME_FLY
		ld	hl,(my_chain+1)		; 3. rendre les indirections
		ld	de,(cur_chain+1)
		di
		ld	(TXT_OA_ADDR),hl
		ld	(TXT_DC_ADDR),de
		ei
		ld	hl,#cmd_close		; 4. liberer la socket
		call	sendcmd
		ld	hl,#msg_off
		jr	off_end
off_none:	ld	hl,#msg_notact
off_end:	call	printz
		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; |TERMST — etat : actif, octets en attente, etat de la socket
; ==================================================================
rsx_termst:	push	ix
		push	iy
		ld	a,(active)
		or	a
		jp	z, st_off
		ld	hl,#msg_st
		call	printz
		ld	hl,(ticks)		; T = appels de l'evenement
		call	disphl
		ld	hl,#msg_st2
		call	printz
		ld	hl,(sends)		; S = trames emises
		call	disphl
		ld	hl,#msg_sth		; H = appels du hook d'affichage
		call	printz
		ld	hl,(hooks)
		call	disphl
		ld	hl,#msg_stm		; C = battements du hook curseur
		call	printz
		ld	hl,(curs)
		call	disphl
		ld	hl,#msg_st3
		call	printz
		call	tx_used			; U = octets en attente
		call	disphl
		ld	hl,#msg_stq		; Xm = refus « M4 occupee »
		call	printz
		ld	hl,(rej_q)
		call	disphl
		ld	hl,#msg_stb		; Xb = refus « carte occupee »
		call	printz
		ld	hl,(rej_b)
		call	disphl
		ld	hl,#msg_str		; R = octets recus du PC
		call	printz
		ld	hl,(rxs)
		call	disphl
		ld	hl,#msg_sti		; I = touches injectees
		call	printz
		ld	hl,(injs)
		call	disphl
		ld	hl,#msg_stk		; W = base du tampon clavier
		call	printz
		ld	hl,(p_buf)
		call	disphl
		ld	hl,#msg_stn		; N = table clavier active
		call	printz
		ld	hl,(p_ntab)
		call	disphl
		ld	hl,#msg_st5
		call	printz
		call	sockstat		; K = etat de la socket
		call	disphex
		call	crlf
		jr	st_end
st_off:		ld	hl,#msg_notact
		call	printz
st_end:		pop	iy
		pop	ix
		scf
		ret

; ==================================================================
; HOOK D'AFFICHAGE — A = caractere, JAMAIS modifie (TXT OUT ACTION
; voit aussi les codes de controle et leurs parametres).
; Empilage seul : aucune I/O, donc aucune concurrence avec le tick.
; Le hook n'ecrit que tx_tail, le tick n'ecrit que tx_head : les deux
; pointeurs sont ecrits par un seul `ld (nn),hl`, indivisible.
; ==================================================================
my_hook:	push	af
		push	bc
		push	de
		push	hl
		ld	c,a
		xor	a			; un caractere vient de sortir
		ld	(idle),a
		ld	a,(pend)		; une touche etait en attente ?
		or	a
		jr	z, mh_noack
		xor	a			; cet affichage EST son echo :
		ld	(pend),a		; la touche a ete consommee
		inc	a
		ld	(ack),a
mh_noack:	ld	a,c
		ld	hl,(hooks)		; diagnostic : frequence reelle du hook
		inc	hl
		ld	(hooks),hl
		ld	hl,(tx_tail)
		ld	de,#LINEBUF+LBSIZE	; avancer d'une case, avec bouclage
		inc	hl
		or	a
		sbc	hl,de
		jr	c, mh_nowrap
		ld	hl,#LINEBUF
		jr	mh_test
mh_nowrap:	add	hl,de
mh_test:	ld	de,(tx_head)		; tampon plein ?
		or	a
		sbc	hl,de
		jr	z, mh_out		; oui -> caractere perdu
		add	hl,de			; hl = nouveau tail
		ex	de,hl
		ld	hl,(tx_tail)
		ld	(hl),c			; ecrire le caractere
		ex	de,hl
		ld	(tx_tail),hl
mh_out:		pop	hl
		pop	de
		pop	bc
		pop	af
my_chain:	jp	0x0000			; -> TXT OUT ACTION d'origine

; ==================================================================
; TICK — evenement frame-fly, 50 Hz. SEUL endroit qui parle a la M4
; une fois le terminal arme. Une transaction par tick au maximum.
; ==================================================================
tick:		push	af
		push	bc
		push	de
		push	hl
		push	ix
		push	iy
		ld	hl,(ticks)
		inc	hl
		ld	(ticks),hl
		call	pump
		pop	iy
		pop	ix
		pop	hl
		pop	de
		pop	bc
		pop	af
		ret

; ==================================================================
; HOOK CURSEUR (TXT DRAW CURSOR) — le battement du REPOS.
; Mesure faite le 22/07/2026 : l'evenement frame-fly ne tourne que
; ~6,6 fois par seconde et uniquement pendant qu'une commande
; s'execute ; il ne bat pas quand le BASIC attend une saisie. Or le
; curseur, lui, clignote precisement a ce moment-la. Les deux points
; d'appel sont donc complementaires, et le verrou de pump() les
; serialise. Le hook ne touche a rien d'autre et rechaine intact.
; ==================================================================
cur_hook:	push	af
		push	bc
		push	de
		push	hl
		push	ix
		push	iy
		ld	hl,(curs)
		inc	hl
		ld	(curs),hl
		call	pump
		pop	iy
		pop	ix
		pop	hl
		pop	de
		pop	bc
		pop	af
cur_chain:	jp	0x0000			; -> TXT DRAW CURSOR d'origine

; ==================================================================
; pump — decompte du silence puis vidage. Appele depuis le tick ET
; depuis le hook curseur : le verrou garantit une seule execution.
; ==================================================================
pump:		ld	a,(active)
		or	a
		ret	z
		ld	a,(lock)
		or	a
		ret	nz
		ld	a,#1
		ld	(lock),a

		ld	a,(idle)		; temps ecoule depuis le dernier
		inc	a			; caractere affiche (sature a 255)
		jr	z, pm_sat
		ld	(idle),a
pm_sat:		cp	#IDLEN
		jr	c, pm_soft

		; l'affichage s'est tu : vidage VOLONTAIRE, comme |TERMF.
		; C'est toute la difference avec l'ancien code — il renoncait
		; au premier refus, donc le dernier morceau restait en attente
		; jusqu'a la commande suivante.
		call	do_drain
		call	do_recv		; ... puis relever ce que le PC envoie
		jr	pm_end

pm_soft:	call	do_send		; en pleine sortie : envoi opportuniste
pm_end:		call	do_inject	; servir une touche au BASIC
		xor	a
		ld	(lock),a
		ret

; ==================================================================
; do_recv — relever les octets envoyes par le PC.
; N'est appelee QUE dans la fenetre d'inactivite, apres le vidage :
; on ne parle a la carte que lorsqu'elle est au repos, et un seul
; interlocuteur a la fois (c'est ce qui avait fait echouer l'etape 3c
; de l'ancienne architecture : deux flux de commandes concurrents).
; ==================================================================
; MODELE DUKE (M4examples/tcp.s) : la ROM M4 doit rester selectionnee
; du DEBUT de sendcmd jusqu'a la lecture de la reponse. Toggler la
; selection ROM entre l'envoi et la lecture corrompt la reponse (la
; carte s'en sert pour banker son tampon). On pagine donc UNE fois,
; on envoie ET on lit paginé, puis on depagine.
do_recv:	call	rx_free			; place dans le tampon d'entree
		or	a
		ret	z
		ld	c,a			; c = place libre
		call	page_m4			; <-- paginer AVANT tout

		ld	hl,(sockstat_ptr)	; octets annonces (sockinfo+2)
		inc	hl
		inc	hl
		ld	e,(hl)
		inc	hl
		ld	d,(hl)
		ld	a,d
		or	a
		jr	nz, dr_cap		; > 255 -> plafonner
		ld	a,e
		or	a
		jr	z, dr_none		; rien a lire
		cp	#RXMAX+1
		jr	c, dr_min
dr_cap:		ld	a,#RXMAX
dr_min:		cp	c			; n = min(dispo, place, RXMAX)
		jr	c, dr_go
		ld	a,c
dr_go:		ld	(cmd_recv+4),a		; taille demandee
		xor	a
		ld	(cmd_recv+5),a
		ld	hl,#cmd_recv
		call	sendcmd			; envoi PENDANT que la M4 est paginee

		ld	hl,(resp_ptr)
		ld	de,#3
		add	hl,de
		ld	a,(hl)			; data[0] = etat
		or	a
		jr	nz, dr_none
		inc	hl
		ld	c,(hl)			; data[1..2] = taille reelle
		inc	hl
		ld	b,(hl)
		inc	hl			; data[3...] = les octets
		ld	a,b
		or	c
		jr	z, dr_none
dr_copy:	ld	a,(hl)
		push	hl
		push	bc
		call	rx_put
		pop	bc
		pop	hl
		inc	hl
		dec	bc
		ld	a,b
		or	c
		jr	nz, dr_copy
dr_none:	jp	unpage_m4

; --- octets annonces par la carte : sockinfo + 2 (2 octets) --------
sock_avail:	call	page_m4
		ld	hl,(sockstat_ptr)
		inc	hl
		inc	hl
		ld	e,(hl)
		inc	hl
		ld	d,(hl)
		push	de
		call	unpage_m4
		pop	de
		ret

; ==================================================================
; do_inject — servir UNE touche au BASIC.
; KM CHAR RETURN est l'appel firmware prevu pour cela : pas de
; jumpblock a detourner (piege 3.3), et il n'a d'effet que si le
; systeme lit le clavier — donc exactement quand le BASIC attend.
; Une seule touche par passage : la case de rappel n'en contient
; qu'une, en pousser deux ecraserait la premiere.
; ==================================================================
; do_inject — servir une touche au BASIC.
;
; On n'APPELLE PAS KM CHAR RETURN : mesure faite le 23/07/2026, cet
; appel fonctionne parfaitement depuis le premier plan (|KPUSH : le Z
; est bien consomme par l'editeur) mais jamais depuis notre hook, qui
; s'execute sur interruption — la routine firmware n'est pas
; reentrante et on la preempte.
;
; On ecrit donc directement dans sa « case de rappel », dont l'adresse
; a ete localisee a l'execution (find_kb_slot). Une ecriture d'un octet
; est atomique : rien a serialiser.
;
; Le marqueur &FF = « case vide » donne en prime un controle de flux
; exact : tant que la case ne vaut pas &FF, la touche precedente n'a
; pas ete lue — plus besoin de deviner par l'echo.
; do_inject — LA methode correcte, etablie le 23/07/2026.
;
; Il n'existe AUCUN point de hook : le firmware appelle ses propres
; routines (KM WAIT CHAR -> KM READ CHAR) directement en ROM basse,
; jamais par le jumpblock (&BB06/&BB09). Detourner le jumpblock ne
; capture donc rien de ce que fait l'editeur de ligne.
;
; La seule voie est de REMPLIR le vrai tampon clavier, celui que
; KM SCAN KEYS alimente a l'interruption et que KM READ CHAR lit. Il
; stocke des CODES DE TOUCHE (matrice 0-79), pas de l'ASCII — ce que
; nos mesures montraient (M=03, Q=08). On traduit donc ASCII->touche
; avec les tables embarquees (la matrice est materielle, identique sur
; tous les CPC), puis on replique push_into_key_buffer a l'octet pres.
;
; Source de reference : desassemblage du firmware 6128 par Bread80
; (CPCForRC2014). Nos propres mesures confirment les adresses de
; workspace sur cette machine (B65E buffer, B686 libre, B687 index,
; B688/B68A compteurs) — toutes derivees de Returned_char (&B62A),
; localisee a l'execution, donc rien n'est code en dur.
do_inject:	ld	a,(injon)
		or	a
		ret	z
		ld	hl,(p_buf)		; workspace localise ?
		ld	a,h
		or	l
		ret	z
		ld	b,#DRAINK		; au plus DRAINK touches par passage
di_loop:	push	bc
		ld	hl,(p_free)		; place libre dans le tampon clavier ?
		ld	a,(hl)
		cp	#2			; free_plus_1 <= 1 -> plein
		jr	c, di_stop
		ld	de,(rx_head)		; un caractere du PC en attente ?
		ld	hl,(rx_tail)
		or	a
		sbc	hl,de
		jr	z, di_stop
		ld	hl,(rx_head)
		ld	a,(hl)
		call	rx_advance		; consommer dans notre tampon
		cp	#10			; ignorer les LF (le CR suffit)
		jr	z, di_cont
		call	ascii_to_cpc		; A -> (C,B), carry si touche connue
		jr	nc, di_cont		; pas de touche : caractere ignore
		call	push_key
		ld	hl,(injs)
		inc	hl
		ld	(injs),hl
di_cont:	pop	bc
		djnz	di_loop
		ret
di_stop:	pop	bc
		ret

; --- ascii_to_cpc : A=ascii -> C=code+modif, B=bit colonne ---------
; Cherche dans la table normale puis la table shift (bit5). Carry=OK.
; On utilise les tables du FIRMWARE (pointeurs p_ntab/p_stab) si elles
; sont en RAM : sinon notre round-trip serait incoherent avec la
; disposition reelle du clavier (AZERTY vs QWERTY). Repli sur nos
; tables embarquees (anglaises) si le firmware garde les siennes en ROM.
ascii_to_cpc:	ld	hl,(p_ntab)
		call	scan_tbl
		ret	c
		ld	hl,(p_stab)
		call	scan_tbl
		ret	nc
		set	5,c
		scf
		ret

; cherche A dans 80 octets a (HL). Carry + (C=ligne, B=bit colonne).
scan_tbl:	ld	b,#80
		ld	c,#0			; index courant
st_loop:	cp	(hl)
		jr	z, st_found
		inc	hl
		inc	c
		djnz	st_loop
		or	a			; pas trouve
		ret
st_found:	ld	a,c			; index -> (ligne, bit colonne)
		and	#7			; colonne
		ld	b,a
		ld	a,#1
st_bit:		dec	b
		jp	m, st_col
		add	a,a
		jr	st_bit
st_col:		ld	b,a			; B = 1<<colonne
		ld	a,c
		rrca
		rrca
		rrca
		and	#0x0F			; ligne
		ld	c,a			; C = ligne
		scf
		ret

; --- push_key : replique push_into_key_buffer (C,B) ---------------
; Interruptions coupees : KM SCAN KEYS pousse aussi dans ce tampon a
; chaque interruption ; on ne doit pas s'entrelacer avec lui.
push_key:	ld	a,i			; sauver l'etat des interruptions
		push	af			; (P/V = IFF2) — on peut etre en
		di				; contexte interruption OU premier
						; plan (|TERMIN) : ne pas forcer EI
		ld	hl,(p_free)		; --free_plus_1 ; 0 => plein
		dec	(hl)
		jr	z, pk_full
		ld	hl,(p_widx)		; ++index, bouclage a 20
		inc	(hl)
		ld	a,(hl)
		cp	#20
		jr	nz, pk_addr
		xor	a
		ld	(hl),a
pk_addr:	add	a,a			; buffer + 2*index
		ld	e,a
		ld	d,#0
		ld	hl,(p_buf)
		add	hl,de
		ld	(hl),c			; octet 0 = code+modif
		inc	hl
		ld	(hl),b			; octet 1 = bit colonne
		ld	hl,(p_cnt)		; ++number_of_keys
		inc	(hl)
		ld	hl,(p_cnt1)		; ++number_of_keys_plus_1
		inc	(hl)
		jr	pk_done
pk_full:	inc	(hl)			; plein : restaurer free_plus_1
pk_done:	pop	af			; restaurer l'etat des interruptions
		ret	po			; IFF etait a 0 -> laisser di
		ei
		ret

; --- localiser le workspace clavier -------------------------------
; On repere Returned_char par la methode de |KPUSH (ecrire un temoin
; via KM CHAR RETURN et voir quel octet change), puis on en derive
; toutes les adresses du tampon : elles bougent en bloc d'une version
; de firmware a l'autre, donc rien n'est code en dur.
find_kb_slot:	ld	hl,#0
		ld	(p_buf),hl
		ld	hl,#0xB600
		ld	de,#kbsnap
		ld	bc,#256
		ldir
		ld	a,#0xA5			; valeur temoin
		call	KM_CHAR_RETURN
		ld	hl,#0xB600
		ld	de,#kbsnap
		ld	b,#0
fk_loop:	ld	a,(de)
		cp	(hl)
		jr	z, fk_next
		ld	a,(hl)
		cp	#0xA5
		jr	z, fk_found
fk_next:	inc	hl
		inc	de
		djnz	fk_loop
		ret				; pas trouve : injection inactive
fk_found:	ld	(hl),#0xFF		; hl = Returned_char (&B62A)
		; deriver les adresses du workspace (offsets 6128, verifies)
		ld	de,#0x34		; Key_buffer
		call	kb_addr
		ld	(p_buf),bc
		ld	de,#0x5C		; free_entries_plus_1
		call	kb_addr
		ld	(p_free),bc
		ld	de,#0x5D		; index
		call	kb_addr
		ld	(p_widx),bc
		ld	de,#0x5E		; number_of_keys_plus_1
		call	kb_addr
		ld	(p_cnt1),bc
		ld	de,#0x60		; number_of_keys
		call	kb_addr
		ld	(p_cnt),bc
		; --- pointeurs des tables de traduction du firmware
		ld	de,#0x61		; address_of_the_normal_key_table
		call	kb_addr
		ld	a,(bc)			; lire le pointeur (-> RAM ou ROM ?)
		ld	l,a
		inc	bc
		ld	a,(bc)
		ld	h,a
		ld	(p_ntab),hl		; par defaut : table du firmware
		ld	de,#0x63		; address_of_the_shifted_key_table
		push	hl
		call	kb_addr
		ld	a,(bc)
		ld	l,a
		inc	bc
		ld	a,(bc)
		ld	h,a
		ld	(p_stab),hl
		pop	hl			; hl = pointeur normal
		ld	a,h			; en ROM basse (<&4000) ? illisible
		cp	#0x40			; d'ici -> repli sur nos tables
		ret	nc
		ld	hl,#tbl_normal
		ld	(p_ntab),hl
		ld	hl,#tbl_shift
		ld	(p_stab),hl
		ret
kb_addr:	push	hl			; bc = hl + de, hl preserve
		add	hl,de
		ld	b,h
		ld	c,l
		pop	hl
		ret

; ==================================================================
; Tables de traduction clavier (matrice materielle, identiques sur
; 464/664/6128). Indexees par code de touche 0-79. Extraites du
; firmware ; scan_tbl y cherche l'ASCII a injecter.
; ==================================================================
tbl_normal:	.db	0xf0,0xf3,0xf1,0x89,0x86,0x83,0x8b,0x8a
		.db	0xf2,0xe0,0x87,0x88,0x85,0x81,0x82,0x80
		.db	0x10,0x5b,0x0d,0x5d,0x84,0xff,0x5c,0xff
		.db	0x5e,0x2d,0x40,0x70,0x3b,0x3a,0x2f,0x2e
		.db	0x30,0x39,0x6f,0x69,0x6c,0x6b,0x6d,0x2c
		.db	0x38,0x37,0x75,0x79,0x68,0x6a,0x6e,0x20
		.db	0x36,0x35,0x72,0x74,0x67,0x66,0x62,0x76
		.db	0x34,0x33,0x65,0x77,0x73,0x64,0x63,0x78
		.db	0x31,0x32,0xfc,0x71,0x09,0x61,0xfd,0x7a
		.db	0x0b,0x0a,0x08,0x09,0x58,0x5a,0xff,0x7f
tbl_shift:	.db	0xf4,0xf7,0xf5,0x89,0x86,0x83,0x8b,0x8a
		.db	0xf6,0xe0,0x87,0x88,0x85,0x81,0x82,0x80
		.db	0x10,0x7b,0x0d,0x7d,0x84,0xff,0x60,0xff
		.db	0xa3,0x3d,0x7c,0x50,0x2b,0x2a,0x3f,0x3e
		.db	0x5f,0x29,0x4f,0x49,0x4c,0x4b,0x4d,0x3c
		.db	0x28,0x27,0x55,0x59,0x48,0x4a,0x4e,0x20
		.db	0x26,0x25,0x52,0x54,0x47,0x46,0x42,0x56
		.db	0x24,0x23,0x45,0x57,0x53,0x44,0x43,0x58
		.db	0x21,0x22,0xfc,0x51,0x09,0x41,0xfd,0x5a
		.db	0x0b,0x0a,0x08,0x09,0x58,0x5a,0xff,0x7f

; --- empiler un octet recu (A) ------------------------------------
rx_put:		ld	hl,(rxs)		; diagnostic : octets recus au total
		inc	hl
		ld	(rxs),hl
		ld	hl,(rx_tail)
		ld	(hl),a
		inc	hl
		ld	de,#RXBUF+RXSIZE
		or	a
		sbc	hl,de
		jr	c, rp_nowrap
		ld	hl,#RXBUF
		ld	(rx_tail),hl
		ret
rp_nowrap:	add	hl,de
		ld	(rx_tail),hl
		ret

; --- place libre dans le tampon d'entree (A), 0 si plein ----------
rx_free:	ld	hl,(rx_tail)
		ld	de,(rx_head)
		or	a
		sbc	hl,de			; occupe
		jr	nc, rf_ok
		ld	de,#RXSIZE
		add	hl,de
rf_ok:		ld	a,#RXSIZE-1
		sub	l
		ret

; ==================================================================
; do_send — envoyer un morceau si c'est opportun
; ==================================================================
; Deux garde-fous seulement, tous deux MESURES (plus de compteur de
; silence : il ne retombait jamais a zero et retenait le dernier
; morceau jusqu'a la commande suivante) :
;   1. la ROM M4 est-elle en cours d'utilisation ? Si le firmware l'a
;      selectionnee, elle execute une commande et son tampon de
;      reponse est unique : lui parler le corromprait (§3.7).
;   2. la socket est-elle libre ?
do_send:	call	tx_used
		ld	a,h
		or	l
		ret	z			; rien a envoyer

		call	KL_CURR_SELECTION	; 1. la carte travaille-t-elle ?
		ld	hl,#m4num
		cp	(hl)
		jr	nz, ds_go
		ld	hl,(rej_q)		; diagnostic : refus « M4 occupee »
		inc	hl
		ld	(rej_q),hl
		ret

ds_go:		call	sockstat		; 2. la carte est-elle prete ?
		cp	#2			; 2 = envoi en cours
		jr	nz, ds_ready
		ld	hl,(rej_b)		; diagnostic : refus « carte occupee »
		inc	hl
		ld	(rej_b),hl
		ret
ds_ready:	jr	ds_size

; --- vidage force : on ATTEND que la carte se libere, puis on envoie
;     un morceau. L'attente est bornee pour ne pas figer la machine.
do_force:	ld	de,#FWAIT
df_wait:	call	sockstat
		cp	#2			; 2 = envoi en cours
		jr	nz, ds_size
		dec	de
		ld	a,d
		or	e
		jr	nz, df_wait
		ret

; --- vider jusqu'a NDRAIN morceaux d'affilee (borne le temps passe
;     en interruption ; le reste part au passage suivant)
do_drain:	ld	b,#NDRAIN
dd_next:	push	bc
		call	tx_used
		ld	a,h
		or	l
		jr	z, dd_done
		call	do_force
		pop	bc
		djnz	dd_next
		ret
dd_done:	pop	bc
		ret
		cp	#240			; erreur -> se desarmer
		jr	c, ds_size
		xor	a
		ld	(active),a
		ret

		; --- taille du morceau contigu, plafonnee a CHUNK
ds_size:	ld	hl,(tx_tail)
		ld	de,(tx_head)
		or	a
		sbc	hl,de
		jr	nc, ds_cap		; tail > head : contigu
		ld	hl,#LINEBUF+LBSIZE	; sinon jusqu'au bout du tampon
		ld	de,(tx_head)
		or	a
		sbc	hl,de
ds_cap:		ld	a,h
		or	a
		jr	nz, ds_max
		ld	a,l
		cp	#CHUNK+1
		jr	c, ds_hdr
ds_max:		ld	a,#CHUNK

		; --- entete C_NETSEND : [taille][34 43][socket][len][0]
ds_hdr:		ld	c,a			; c = taille des donnees
		add	a,#5
		ld	(hdr+0),a
		ld	a,#0x34
		ld	(hdr+1),a
		ld	a,#0x43
		ld	(hdr+2),a
		ld	a,(socknum)
		ld	(hdr+3),a
		ld	a,c
		ld	(hdr+4),a
		xor	a
		ld	(hdr+5),a

		ld	bc,#DATAPORT
		ld	hl,#hdr
		ld	d,#6
ds_ph:		inc	b
		outi
		dec	d
		jr	nz, ds_ph
		ld	hl,(tx_head)		; donnees, directement du tampon
		ld	a,(hdr+4)
		ld	d,a
ds_pd:		inc	b
		outi
		dec	d
		jr	nz, ds_pd
		ld	bc,#ACKPORT
		out	(c),c
		ld	de,(sends)		; diagnostic : trames emises
		inc	de
		ld	(sends),de

		; --- avancer head (hl pointe deja apres le morceau)
		ld	de,#LINEBUF+LBSIZE
		or	a
		sbc	hl,de
		jr	c, ds_nowrap
		ld	hl,#LINEBUF
		ld	(tx_head),hl
		ret
ds_nowrap:	add	hl,de
		ld	(tx_head),hl
		ret

; ==================================================================
; tx_used — HL = nombre d'octets en attente
; ==================================================================
tx_used:	ld	hl,(tx_tail)
		ld	de,(tx_head)
		or	a
		sbc	hl,de
		ret	nc
		ld	de,#LBSIZE
		add	hl,de
		ret

; ==================================================================
; Pagination de la ROM M4 — l'appariement qui manquait au projet :
; KL ROM SELECT rend B = etat precedent, C = ROM precedente, et c'est
; KL ROM DESELECT (&B918) qui les reprend. PAS KL ROM RESTORE (&B90C),
; qui lit l'etat dans A : c'est ce qui corrompait l'ecran.
; ==================================================================
; Interruptions coupees pendant toute la fenetre : sinon le hook
; curseur (contexte interruption) peut paginer a son tour au milieu
; d'une pagination du premier plan et ecraser pg_bc — l'etat de la ROM
; serait alors restaure de travers, exactement le defaut d'origine.
page_m4:	ld	a,i
		jp	po, pg_di
		ld	a,#1
		jr	pg_set
pg_di:		xor	a
pg_set:		ld	(pg_iff),a
		di
		ld	a,(m4num)
		ld	c,a
		call	KL_ROM_SELECT
		ld	(pg_bc),bc
		ret

unpage_m4:	ld	bc,(pg_bc)
		call	KL_ROM_DESELECT
		ld	a,(pg_iff)
		or	a
		ret	z
		ei
		ret

; --- etat de la socket (KL ROM DESELECT detruit A : le preserver) --
sockstat:	call	page_m4
		ld	hl,(sockstat_ptr)
		ld	a,(hl)
		push	af
		call	unpage_m4
		pop	af
		ret

; --- octet de reponse d'une commande (data[0]) ---------------------
resp_byte:	call	page_m4
		ld	hl,(resp_ptr)
		ld	de,#3
		add	hl,de
		ld	a,(hl)
		push	af
		call	unpage_m4
		pop	af
		ret

; --- envoi d'un bloc de commande : [taille][cmd][args...] ----------
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

; --- recherche de la ROM M4, etat ROM rendu intact -----------------
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
disphl:		ld	a,h
		call	disphex
		ld	a,l
		jr	disphex

crlf:		ld	hl,#msg_crlf
printz:		ld	a,(hl)
		or	a
		ret	z
		push	hl
		call	TXT_OUTPUT
		pop	hl
		inc	hl
		jr	printz

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

; ==================================================================
; Commandes M4 (le socket est patche a l'offset 3)
; ==================================================================
cmd_socket:	.db	5
		.dw	C_NETSOCKET
		.db	0, 0, 6			; domaine 0, type 0, TCP 6
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
		.dw	0			; taille demandee (patchee)

m4_rom_name:	.ascis	"M4 BOARD"

; ==================================================================
; Messages
; ==================================================================
msg_inst:	.ascii	"CTERM en &8000. RSX : TERM TERMOFF TERMST"
		.db	13,10,0
msg_wait:	.ascii	"Attente du PC sur le port 6128..."
		.db	13,10,0
msg_on:		.ascii	"Terminal actif : sortie BASIC -> PC."
		.db	13,10,0
msg_off:	.ascii	"Terminal arrete."
		.db	13,10,0
msg_flush:	.ascii	"Vidage force effectue."
		.db	13,10,0
msg_kon:	.ascii	"Injection clavier ARMEE (experimental)."
		.db	13,10,0
msg_koff:	.ascii	"Injection clavier desarmee."
		.db	13,10,0
msg_already:	.ascii	"Deja actif."
		.db	13,10,0
msg_notact:	.ascii	"Terminal inactif."
		.db	13,10,0
msg_norom:	.ascii	"ROM M4 introuvable !"
		.db	13,10,0
msg_abort:	.ascii	"Abandon (power-cycle la M4 avant de relancer)."
		.db	13,10,0
msg_err:	.ascii	"Erreur reseau M4."
		.db	13,10,0
msg_st:		.ascii	"Actif  T=&"
		.db	0
msg_st2:	.ascii	" S=&"
		.db	0
msg_sth:	.ascii	" H=&"
		.db	0
msg_stm:	.ascii	" C=&"
		.db	13,10,0
msg_st3:	.ascii	"U=&"
		.db	0
msg_stq:	.ascii	" Xm=&"
		.db	0
msg_stb:	.ascii	" Xb=&"
		.db	0
msg_str:	.ascii	" R=&"
		.db	0
msg_sti:	.ascii	" I=&"
		.db	0
msg_stk:	.ascii	" W=&"
		.db	0
msg_stn:	.ascii	" N=&"
		.db	0
msg_st5:	.ascii	" K=&"
		.db	0
msg_crlf:	.db	13,10,0

; ==================================================================
; Variables
; ==================================================================
active:		.ds	1
lock:		.ds	1
m4num:		.ds	1
socknum:	.ds	1
resp_ptr:	.ds	2
sock_ptr:	.ds	2
sockstat_ptr:	.ds	2
saved_rs:	.ds	2
pg_bc:		.ds	2
tx_head:	.ds	2
tx_tail:	.ds	2
ticks:		.ds	2
sends:		.ds	2
hooks:		.ds	2
curs:		.ds	2
rej_q:		.ds	2
rej_b:		.ds	2
idle:		.ds	1
rx_head:	.ds	2
rx_tail:	.ds	2
injs:		.ds	2
rxs:		.ds	2
pend:		.ds	1
ack:		.ds	1
injon:		.ds	1
p_buf:		.ds	2		; adresses du workspace clavier,
p_free:		.ds	2		; derivees de Returned_char au demarrage
p_widx:		.ds	2
p_cnt1:		.ds	2
p_cnt:		.ds	2
p_ntab:		.ds	2
p_stab:		.ds	2
dbg_av:		.ds	2
dbg_resp:	.ds	12
descr:		.ds	2
strbuf:		.ds	2
maxlen:		.ds	1
kbsnap:		.ds	256
pg_iff:		.ds	1
hdr:		.ds	6
ev_block:	.ds	16
rsx_chain:	.ds	4
