# CPC Remote BASIC — drive an Amstrad CPC from your PC over WiFi

*[Version française](README.fr.md)*

Type BASIC commands in a window on your PC; they run on a real **Amstrad CPC**
and its screen output comes straight back. The CPC's own keyboard keeps working
at the same time, and **your BASIC program space stays completely free** — no
resident BASIC program, no line-number tricks.

```
PS> python pc/cpcterm.py 192.168.1.139
Connecte a 192.168.1.139:6128

Terminal actif.
Ready
10 print "bonjour"
20 for n=1 to 3:print n:next
list
10 PRINT "bonjour"
20 FOR n=1 TO 3:PRINT n:NEXT
Ready
run
bonjour
 1
 2
 3
Ready
```

Everything runs over WiFi through the **M4 Board**, Duke's WiFi/microSD/ROM
expansion for the CPC.

## How it works

Two firmware hooks, a couple of RSXs, and a Python script:

1. A small Z80 resident (`cpc/cterm2.s`) runs at `&8000`. It is carried inside a
   background ROM (`cpc/termrom2.s`) whose init reserves the RAM above `&8000` at
   boot — or loaded manually with `MEMORY &7FFF` + `LOAD` + `CALL`. It opens a TCP
   server socket on port 6128 through the M4's network API.
2. It hooks **`TXT OUT ACTION`** (indirection `&BDDA`) to capture every character
   the CPC prints, into a ring buffer. The hook only buffers — it never talks to
   the board.
3. It hooks the BASIC **line editor**, jumpblock entry `EDIT` at **`&BD5E`**.
   When BASIC asks for a line, the hook either hands over a line received from
   the PC (carry set — BASIC runs it exactly as if typed), or chains to the
   original editor so the local keyboard behaves normally.
4. `pc/cpcterm.py` connects, displays the mirrored screen output, and sends the
   lines you type. It also offers a local telnet relay (`--telnet`) so you can
   drive the CPC from PuTTY.

**Why `EDIT` is the right hook.** BASIC lives in the *upper* ROM and cannot call
the *lower* ROM directly — it must go through the firmware jumpblock. That makes
`&BD5E` interceptable. By contrast `KM WAIT CHAR` / `KM READ CHAR` are called
firmware-internally (`&1BBF` → `&1BC5`) and can never be hooked from RAM. This
single fact is what makes the whole thing possible; finding it took a long hunt
(see [docs/09](docs/09-nouvelle-architecture.md)).

## Quick start

You need an Amstrad CPC with an [M4 Board](https://github.com/M4Duke/m4hardware)
on your WiFi, plus [SDCC](https://sdcc.sourceforge.net/) and Python 3 on the PC.

### Recommended: install it as a ROM

The terminal then lives in an M4 ROM slot: nothing to load, nothing to type at
boot. Build it and upload from `pc/m4term.py`:

```bash
cd cpc && ./build_termrom2.cmd        # builds TERM2.ROM
```
```
put ../cpc/TERM2.ROM
rom ../cpc/TERM2.ROM 3 TERM
resetm4
```

From then on, whenever you want the terminal, just type on the CPC:

```basic
|TERM
```

The ROM's init claims memory above `&8000` at boot (`HIMEM` drops to `&7F7B`), so
no `MEMORY` command is ever needed. `|TERMOFF` stops the terminal and gives the
firmware its hooks back. To remove the ROM: `delrom 3` then `resetm4` — this works
over WiFi even if the CPC is hung, which is exactly why a separate slot is used
rather than patching the M4 ROM.

### Alternative: load it as a binary

If you would rather not use a ROM slot:

```bash
cd cpc && ./build_cterm2.cmd          # builds CTERM2.BIN
```
```
put ../cpc/CTERM2.BIN
```
```basic
MEMORY &7FFF:LOAD"cterm2.bin":CALL &8000:|TERM
```

### Then, on the PC

```bash
python pc/cpcterm.py <cpc-ip-address>
```

Local commands inside `cpcterm.py`: `:aide` for help, `:get prog.bas` … `:fin`
to capture a `list` into a clean `.bas` file on the PC.

### A faithful graphical viewer

For a window that looks like the real machine — the CPC's own 8×8 glyphs,
colours and 4:3 proportions instead of your terminal's font:

```bash
python pc/cpcview.py <cpc-ip-address>
```

It fetches the CPC character set once and caches it in `pc/cpcfont.bin`, so later
launches are instant (`--refont` to fetch it again). This is the only client that
renders the block graphics and symbols correctly, since it draws the actual CPC
matrices rather than mapping them to Unicode.

The window is resizable (the characters scale with it, keeping 4:3), carries a
status bar (IP, connection state, screen MODE, cursor position), and a full **M4
menu** that reproduces the card's web interface over its HTTP API: a graphical
**file browser** of the SD card (upload / download / delete / run / mkdir), ROM
slot management, and CPC/M4 resets. `--dump` grabs the CPC's current screen on
connect for a pixel-exact start.

### Character set

The CPC is not Latin-1, and the French model follows ISO-646-FR: the accented
letters take the place of `@ \ { | }`. Verified on the machine — `ASC("é")` = 123,
and the screen does show `à ç é ù è` at those codes. The other ISO-646-FR
positions (`# [ ] ` ~`) are **not** substituted.

`cpcterm.py` translates both ways: your accented input becomes the right CPC
codes, and the CPC's output comes back faithfully — including the Greek letters
(176-191) and the block graphics (128-143). An unmapped CPC symbol shows as
`<NN>` rather than being displayed wrongly, and a character the CPC does not have
(`€`, `œ`) is reported instead of being silently dropped.

Worth knowing: `|` and `ù` are **the same character** on the CPC (code 124), as
are `@` and `à` (code 64). So a `LIST` containing an RSX call comes back as
`ùTERM` — exactly what the CPC screen shows.

To stop and restore the firmware hooks: `|TERMOFF` on the CPC.

## Repository layout

| Path | Contents |
|---|---|
| [`cpc/termrom2.s`](cpc/termrom2.s) | **The ROM** — background ROM that carries the core and exposes `\|TERM` / `\|TERMOFF` from boot; its init reserves RAM above `&8000` |
| [`cpc/cterm2.s`](cpc/cterm2.s) | **The resident** — output hook, `EDIT` hook, M4 network I/O, RSX `\|TERM` `\|TERMOFF` `\|TERMIO` |
| [`pc/cpcterm.py`](pc/cpcterm.py) | **The PC terminal** — console or telnet relay, screen capture to file |
| [`pc/cpcview.py`](pc/cpcview.py) | **The graphical viewer** — renders the CPC's real 8×8 font in a 4:3 window, font cached in `cpcfont.bin` |
| [`pc/m4term.py`](pc/m4term.py) | File transfer / control over the M4's HTTP API (`ls`, `put`, `get`, `run`, `rom`, `reset`) |
| [`cpc/keyscan.s`](cpc/keyscan.s) | Firmware-probing tool built during the hunt (`\|KFIND` `\|KRAW` `\|KDUMP` `\|KPUSH` `\|KFULL`) — memory snapshot/diff, useful for any CPC firmware spelunking |
| [`cpc/probe.s`](cpc/probe.s) | M4 ROM paging probe (`\|M4VER` `\|PGTEST` `\|PGASYNC`) |
| [`cpc/tcpecho.s`](cpc/tcpecho.s), [`cpc/tcpmirror.s`](cpc/tcpmirror.s), [`cpc/tcpterm.s`](cpc/tcpterm.s) | Earlier steps, still working: TCP echo server, screen mirror, foreground bidirectional terminal. PC clients: `pc/echotest.py`, `pc/mirror_view.py`, `pc/chat.py` |
| [`cpc/cterm.s`](cpc/cterm.s) | First resident (output mirror + keyboard-injection attempts) — superseded, kept as history |
| [`cpc/attic/`](cpc/attic/), [`pc/attic/`](pc/attic/) | BASIC shell, diagnostic programs and superseded PC clients from the intermediate approach, each documented |
| [`docs/`](docs/) | Detailed technical journal (French) — build notes, firmware findings, dead ends |

## What we learned the hard way

These cost days to find and are documented nowhere else. Full detail in
[docs/09-nouvelle-architecture.md](docs/09-nouvelle-architecture.md).

- **`RUN"prog.bin"` can never return to BASIC.** The binary is not entered via a
  `CALL`, so its `ret` pops a bogus address and the machine reboots. Use
  `LOAD` + `CALL`. This one bug had produced a whole chain of false conclusions.
- **`KL ROM SELECT` (`&B90F`) is undone by `KL ROM DESELECT` (`&B918`)**, not by
  `KL ROM RESTORE` (`&B90C`, which reads the state from `A`). Get this wrong and
  the upper-ROM state is restored at random.
- **Keep the M4 ROM selected for a whole transaction.** Toggling ROM selection
  between sending a command and reading its answer corrupts the answer — the
  board returns spaces. Duke's own `tcp.s` never toggles.
- **Receive before sending.** The board handles one command at a time; sending
  output then immediately reading input corrupts the read.
- **Never poll the M4 at 50 Hz.** A few seconds of tight polling destabilises the
  firmware. ~10 Hz is stable and plenty responsive.
- **Injecting keystrokes is impossible on this setup.** The firmware key buffer
  (`&B65E`, with counters at `&B686`/`&B687`/`&B688`/`&B68A`) stores *key codes*,
  not ASCII; and reproducing a real keypress byte for byte still never wakes the
  editor. Hooking `EDIT` sidesteps the problem entirely.

## Credits

- **Duke** ([spinpoint.org](https://www.spinpoint.org/)) — designer of the M4
  Board. Production ended on 30 September 2025 and all manufacturing files were
  released: [M4Duke/m4hardware](https://github.com/M4Duke/m4hardware),
  [m4rom](https://github.com/M4Duke/m4rom),
  [M4examples](https://github.com/M4Duke/M4examples),
  [cpcxfer](https://github.com/M4Duke/cpcxfer). His `tcp.s` was the reference
  that fixed our M4 protocol handling.
- **Bread80** — [CPCForRC2014](https://github.com/Bread80/CPCForRC2014), a
  disassembly and adaptation of the CPC 6128 firmware. It gave us the key-buffer
  layout and, crucially, proof that `KM WAIT CHAR` is called firmware-internally.
- **Csaba Tóth** — the M4 Extended User Manual (not redistributed here).

Third-party repositories and copyrighted documentation are intentionally **not**
included in this repository; the links above point to the originals.

## Status and licence

Working and in daily use on a CPC 6128 with M4 firmware v2.0.8. The firmware
addresses (`&BD5E`, `&B65E`…) are those of the 6128 / BASIC 1.1; a 464 or 664
would need them re-checked — `cpc/keyscan.s` is exactly the tool for that.

Released under the MIT licence — see [LICENSE](LICENSE).
