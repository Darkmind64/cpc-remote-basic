# CPC Remote BASIC — drive an Amstrad CPC from your PC over WiFi

*[Version française](README.fr.md)*

Type BASIC commands in a window on your PC; they run on a real **Amstrad CPC**
and its screen output comes straight back. The CPC's own keyboard keeps working
at the same time, and **your BASIC program space stays completely free** — no
resident BASIC program, no line-number tricks.

```
PS> python pc/cpcterm.py 192.168.1.139
Connected to 192.168.1.139:6128

Terminal active.
Ready
10 print "hello"
20 for n=1 to 3:print n:next
list
10 PRINT "hello"
20 FOR n=1 TO 3:PRINT n:NEXT
Ready
run
hello
 1
 2
 3
Ready
```

Everything runs over WiFi through the **M4 Board**, Duke's WiFi/microSD/ROM
expansion for the CPC.

## Features

- **Real-time screen mirroring** — see what the CPC prints as you type
- **No program space waste** — terminal is a background ROM; your BASIC program stays free
- **Dual keyboard** — CPC keyboard + PC keyboard both work
- **Modern graphical viewer** — authentic CPC 8×8 font, 4:3 aspect ratio, resizable window
- **Multi-screen support** — dialogs position correctly on multi-monitor setups
- **File manager** — browse SD card, upload/download files, run programs graphically
- **ROM management** — manage M4 ROM slots from a GUI
- **Character set translation** — full ISO-646-FR (French accented chars) support both ways
- **Terminal relay** — PuTTY telnet support
- **Multiple clients available** — console, graphical, headless tool versions

## Quick start

You need an Amstrad CPC with an [M4 Board](https://github.com/M4Duke/m4hardware)
on your WiFi, plus [SDCC](https://sdcc.sourceforge.net/) and Python 3 on the PC.

### Step 1: Install the terminal on the CPC

#### Recommended: install as a ROM (one-command boot)

Build it and upload to the M4 Board:

```bash
cd cpc && ./build_termrom2.cmd        # builds TERM2.ROM
```

**Method A: Using `m4term.py` (command-line)**
```bash
python pc/m4term.py 192.168.1.139
put ../cpc/TERM2.ROM
rom ../cpc/TERM2.ROM 3 TERM
resetm4
```

**Method B: Using M4 Board web interface**
1. Open `http://192.168.1.139` in your browser
2. Upload `TERM2.ROM` via the file manager
3. Use the ROM manager to install it in slot 3
4. Click "Reset M4"

From then on, just type on the CPC:
```basic
|TERM
```

The ROM's init claims memory above `&8000` at boot, so no `MEMORY` command is ever needed.

#### Alternative: load as a binary (manual each time)

If you prefer not to use a ROM slot:

```bash
cd cpc && ./build_cterm2.cmd          # builds CTERM2.BIN
```

**Method A: Using `m4term.py` (command-line)**
```bash
python pc/m4term.py 192.168.1.139
put ../cpc/CTERM2.BIN
```

**Method B: Using M4 Board web interface**
1. Open `http://192.168.1.139` in your browser
2. Upload `CTERM2.BIN` via the file manager

Then on the CPC:
```basic
MEMORY &7FFF:LOAD"cterm2.bin":CALL &8000:|TERM
```

### Step 2: Choose your PC client

#### Terminal client (console)

```bash
python pc/cpcterm.py <cpc-ip-address>
```

**Local commands:** `:aide` for help, `:get prog.bas` to download, `:fin` to close and save `list` to file.

**Telnet relay mode:**
```bash
python pc/cpcterm.py --telnet <cpc-ip-address>
```
Then connect from PuTTY to `localhost:4242` — works with any telnet client.

#### Graphical viewer (recommended for daily use)

```bash
python pc/cpcview.py <cpc-ip-address>
```

**Features:**
- Authentic CPC look — real 8×8 font, proper 4:3 proportions
- Character set cached for instant startup
- Resizable window (characters scale while keeping 4:3 ratio)
- Status bar showing IP, connection state, screen MODE, cursor position
- **Full M4 control panel:**
  - Graphical SD card file browser (upload/download/delete/mkdir/run)
  - ROM slot management
  - CPC/M4 system resets
- Modern dark UI with customtkinter
- Multi-monitor support (dialogs appear on correct screen)
- `--dump` to capture the CPC's current screen on connect

#### M4 control tool

Direct control over the M4's HTTP API:

```bash
python pc/m4term.py 192.168.1.139
```

Commands: `ls`, `put`, `get`, `run`, `rom`, `reset`.

---

## PC Clients — detailed comparison

| Feature | cpcterm.py | cpcview.py | m4term.py |
|---------|------------|------------|-----------|
| **Type** | Console terminal | Graphical GUI | Command-line tool |
| **UI Style** | Text-based | Modern (customtkinter) | CLI commands |
| **CPC Screen** | Text output only | Authentic 8×8 font, 4:3 aspect ratio | Not displayed |
| **Resizable** | No | Yes (proportional scaling) | N/A |
| **Telnet relay** | `--telnet` mode | No | No |
| **File manager** | Manual `:get`/`:put` | Full graphical browser | Direct commands |
| **ROM management** | No | Full GUI panel | Direct commands |
| **System resets** | No | CPC & M4 buttons | CLI: `reset` |
| **Multi-monitor** | N/A | ✓ Correct positioning | N/A |
| **Startup speed** | Instant | Instant (cached font) | Instant |
| **Best for** | Scripting, PuTTY | Daily interactive use | Automation, M4 control |

---

## How it works

Two firmware hooks, a couple of RSXs, and Python scripts:

1. **Z80 resident** (`cpc/cterm2.s`) runs at `&8000`. It's carried in a background ROM
   (`cpc/termrom2.s`) whose init reserves RAM above `&8000` at boot. Opens a TCP
   server on port 6128 via the M4's network API.

2. **Output capture hook** on `TXT OUT ACTION` (indirection `&BDDA`) captures every
   character the CPC prints into a ring buffer. The hook only buffers — never talks
   to the board directly.

3. **Line editor hook** on BASIC's `EDIT` jumpblock (`&BD5E`). When BASIC asks for input,
   the hook either provides a line from the PC (carry set — BASIC executes it) or
   chains to the original editor for normal keyboard input.

4. **Python clients** connect to port 6128, display mirrored output, and send typed lines.

**Why `EDIT` is the right hook:** BASIC lives in the *upper* ROM and can only call
the *lower* ROM through the firmware jumpblock — making `&BD5E` interceptable. By
contrast `KM WAIT CHAR` / `KM READ CHAR` are called firmware-internally and cannot
be hooked from RAM. Finding this single fact took extensive firmware spelunking
(see [docs/09-nouvelle-architecture.md](docs/09-nouvelle-architecture.md)).

---

## Character set

The CPC is not Latin-1. The French model follows ISO-646-FR: accented letters take the
place of `@ \ { | }`.

`cpcterm.py` and `cpcview.py` translate both ways:
- Your accented input → correct CPC codes
- CPC output → displayed faithfully (Greek letters, block graphics included)
- Unmapped CPC symbols show as `<NN>` instead of displaying wrongly
- Missing characters reported instead of silently dropped

**Important:** `|` and `ù` are the same character on the CPC (code 124), as are `@` and `à`
(code 64). A `LIST` containing an RSX call appears as `ùTERM` — exactly what the CPC screen shows.

---

## Repository layout

| Path | Contents |
|---|---|
| [`cpc/termrom2.s`](cpc/termrom2.s) | **The ROM** — background ROM carrying the core; init reserves RAM above `&8000`; exposes `\|TERM` / `\|TERMOFF` from boot |
| [`cpc/cterm2.s`](cpc/cterm2.s) | **The resident** — output hook, `EDIT` hook, M4 network I/O, RSX commands (`\|TERM`, `\|TERMOFF`, `\|TERMIO`) |
| [`pc/cpcterm.py`](pc/cpcterm.py) | **Console terminal** — text-based client, telnet relay mode, screen capture to file |
| [`pc/cpcview.py`](pc/cpcview.py) | **Graphical viewer** — renders authentic CPC 8×8 font in 4:3 window, font cached in `cpcfont.bin`, full M4 control panel, multi-monitor support |
| [`pc/m4term.py`](pc/m4term.py) | **M4 control tool** — file/ROM management via M4's HTTP API (`ls`, `put`, `get`, `run`, `rom`, `reset`) |
| [`cpc/keyscan.s`](cpc/keyscan.s) | Firmware probe tool (`\|KFIND`, `\|KRAW`, `\|KDUMP`, `\|KPUSH`, `\|KFULL`) — memory snapshots for firmware exploration |
| [`cpc/probe.s`](cpc/probe.s) | M4 ROM paging probe (`\|M4VER`, `\|PGTEST`, `\|PGASYNC`) |
| [`cpc/tcpecho.s`](cpc/tcpecho.s), [`cpc/tcpmirror.s`](cpc/tcpmirror.s), [`cpc/tcpterm.s`](cpc/tcpterm.s) | Earlier prototypes (all working): TCP echo, screen mirror, bidirectional terminal. PC clients: `pc/echotest.py`, `pc/mirror_view.py`, `pc/chat.py` |
| [`cpc/cterm.s`](cpc/cterm.s) | First resident (output mirror + keyboard injection attempts) — superseded, kept as history |
| [`cpc/attic/`](cpc/attic/), [`pc/attic/`](pc/attic/) | BASIC shell, diagnostic tools, and earlier PC clients — each documented |
| [`docs/`](docs/) | Detailed technical journal — build notes, firmware findings, dead ends |

---

## What we learned the hard way

These took days to discover and are documented nowhere else. Full details in
[docs/09-nouvelle-architecture.md](docs/09-nouvelle-architecture.md).

- **`RUN"prog.bin"` cannot return to BASIC.** The binary isn't entered via `CALL`, so its `ret` pops garbage and the machine reboots. Use `LOAD` + `CALL`.
- **`KL ROM SELECT` (`&B90F`) is undone by `KL ROM DESELECT` (`&B918`)**, not by `KL ROM RESTORE` (`&B90C`). Get this wrong and the upper-ROM state is random.
- **Keep the M4 ROM selected for entire transactions.** Toggling between sending a command and reading its answer corrupts the response.
- **Receive before sending.** The board handles one command at a time; sending output then immediately reading corrupts the read.
- **Never poll the M4 at 50 Hz.** A few seconds of tight polling destabilizes the firmware. ~10 Hz is stable and responsive.
- **Keystroke injection is impossible.** The firmware key buffer stores *key codes*, not ASCII; byte-for-byte reproduction doesn't wake the editor. Hooking `EDIT` sidesteps this entirely.

---

## Version history

- **v1.0.0** — Multi-screen support, customtkinter GUI, improved ROM manager layout, Windows executable
- Earlier — Console terminal, graphical viewer proof-of-concept

---

## Building on Windows

A GitHub Actions workflow automatically builds a Windows executable on each release tag:

```bash
git tag -a v1.0.0 -m "Release message"
git push origin v1.0.0
```

The executable appears in [Releases](https://github.com/Darkmind64/cpc-remote-basic/releases).

---

## Status and licence

Working and in daily use on a CPC 6128 with M4 firmware v2.0.8. The firmware
addresses (`&BD5E`, `&B65E`…) are those of the 6128 / BASIC 1.1; a 464 or 664
would need re-verification — `cpc/keyscan.s` is the right tool.

**License:** MIT with Commons Clause — see [LICENSE](LICENSE).
- ✓ Use, modify, distribute freely
- ✓ Commercial internal use
- ✓ Consulting/support services
- ✗ Cannot resell the software itself as a product

---

## Credits

- **Duke** ([spinpoint.org](https://www.spinpoint.org/)) — designer of the M4 Board.
  Production ended 30 September 2025, all files released:
  [M4Duke/m4hardware](https://github.com/M4Duke/m4hardware),
  [m4rom](https://github.com/M4Duke/m4rom),
  [M4examples](https://github.com/M4Duke/M4examples),
  [cpcxfer](https://github.com/M4Duke/cpcxfer).
  His `tcp.s` was the reference that fixed our M4 protocol handling.
- **Bread80** — [CPCForRC2014](https://github.com/Bread80/CPCForRC2014),
  a disassembly of the CPC 6128 firmware. Gave us the key-buffer layout and proof
  that `KM WAIT CHAR` is called firmware-internally.
- **Csaba Tóth** — M4 Extended User Manual.

Third-party repositories and copyrighted documentation are intentionally **not**
included in this repository; the links above point to the originals.
