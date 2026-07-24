# Guide de fabrication — M4 Board v2.5C

Procédure officielle (README du dépôt m4hardware) enrichie de détails pratiques.

## 1. Fabrication du PCB

- Envoyer `m4hardware/m4board_v25c.zip` tel quel à un fabricant (JLCPCB, PCBWay, Aisler…). Carte 2 couches, 1,6 mm.
- Option : partir du projet partagé PCBWay « Amstrad M4 Board From Duke » (Gerbers déjà chargés).
- Pour la variante edge : demander un biseau du bord connecteur si possible, finition ENIG conseillée.

## 2. Assemblage

Ordre conseillé :

1. **STM32F407VGT6** (LQFP-100, pas 0,5 mm) — le plus délicat : positionner, souder deux coins, puis drag-soldering avec beaucoup de flux, tresse pour les ponts. Vérifier chaque broche à la loupe/multimètre.
2. Régulateur RT9166A-36 (ou HT7536-1), quartz, R/C 0603, LED.
3. Slot microSD, USB mini-B, boutons.
4. **ESP-12-F** (module à plots demi-lune, se soude en surface).
5. Connecteur d'expansion (edge dessous **ou** header 2×25 90° dessus) + jumper d'alim + en-tête JTAG.

**Vérifications avant mise sous tension :** absence de court 3,6 V ↔ GND et 5 V ↔ GND ; puis alimenter par USB (jumper côté USB) et vérifier ~3,6 V en sortie du régulateur et la LED ON allumée.

## 3. Flash du bootloader (une seule fois)

Matériel : **ST-Link v2** (le clone « clé USB » suffit), branché sur l'en-tête « JTAG » JP1 (1×9) de la carte.

**Brochage de JP1 (relevé sur le schéma v2.5C, page 2)** — pin 1 = côté marqué :

| Pin JP1 | Signal | Utilisation ST-Link (SWD) |
|---|---|---|
| 1 | DEBUG_RX | — (UART debug) |
| 2 | DEBUG_TX | — (UART debug) |
| 3 | GND | → GND du ST-Link |
| 4 | RESET | → RST/NRST (optionnel, utile pour « connect under reset ») |
| 5 | FLASH_SCK_TDO | — |
| 6 | SWCLK | → SWCLK |
| 7 | SWDIO | → SWDIO |
| 8 | FLASH_CS_TDI | — |
| 9 | +3V6 | → VTref (uniquement si ST-Link d'origine avec détection de tension ; **ne pas** y injecter le 3,3 V d'un clone si la carte est déjà alimentée) |

Seuls GND + SWCLK + SWDIO sont indispensables ; la carte est alimentée par son propre USB pendant le flash. Les niveaux 3,3 V du ST-Link sont compatibles avec le STM32 alimenté en 3,6 V.

Avec **STM32CubeProgrammer** (ou `st-flash`/OpenOCD) :

1. Alimenter la carte (USB) et connecter le ST-Link (mode SWD, ne pas alimenter en 3,3 V par le ST-Link si la carte est déjà alimentée — juste Vref).
2. Effacer la flash, puis programmer `m4hardware/m4board_bootloader.bin` à l'adresse **0x08000000**.
   - CLI : `STM32_Programmer_CLI -c port=SWD -d m4board_bootloader.bin 0x08000000 -v`
   - ou : `st-flash write m4board_bootloader.bin 0x8000000`
3. **Protéger en écriture les deux premiers secteurs** (secteurs 0 et 1, qui contiennent le bootloader) — recommandation explicite de Duke. Dans CubeProgrammer : onglet Option Bytes → Write Protection → cocher WRP secteurs 0–1 → Apply.

Le bootloader ne se retouche plus ensuite ; toutes les mises à jour passent par la microSD.

## 4. Installation du firmware

1. Formater une microSD en **FAT32**.
2. Copier `M4FIRM.BIN` (firmware STM32) et `ESPFIRM.BIN` (firmware ESP8266) **à la racine**.
3. Insérer la carte, mettre la M4 sous tension : le bootloader détecte les fichiers et flashe les deux puces (laisser finir, la LED d'activité clignote), puis redémarre.

Ces deux binaires sont dans le clone `m4hardware/` (v2.0.8 = dernière version). `|VERSION` sur le CPC affichera les versions installées ; `|UPGRADE` télécharge la dernière version par WiFi.

## 5. Premier test sur CPC

1. CPC éteint, brancher la M4 sur le port d'expansion (composants vers le haut, vérifier l'orientation !). Mettre le jumper d'alim côté **CPC** (ou garder USB si le CPC ne fournit pas assez de courant — cas de certaines configs 464+écran mono).
2. Allumer : le message de démarrage doit afficher la ROM M4 (« M4 Board » + version).
3. `CAT` doit lister la microSD ; `|M4HELP` liste les commandes.
4. Configurer le WiFi (voir docs/04) puis `|NETSTAT` pour vérifier la connexion, et accéder à l'interface web via l'IP affichée.

## Dépannage fabrication

| Symptôme | Piste |
|---|---|
| Pas de LED ON | Alim/jumper, court-circuit, régulateur mal soudé |
| ST-Link ne voit pas le MCU | Soudures VDD/VSS/NRST du LQFP, câblage SWD |
| Bootloader OK mais pas de flash firmware | microSD pas en FAT32, fichiers pas à la racine, slot SD mal soudé (SDIO 4 bits : vérifier D0–D3) |
| CPC démarre mais pas de ROM M4 | Orientation/contacts du connecteur edge (nettoyer), soudures du bus |
| Resets/plantages/glitches graphiques | Connecteur edge sale ou usé — nettoyer les contacts (conseil officiel) |
| WiFi mort mais SD OK | Soudure ESP-12-F (CH_PD/RESET), ESPFIRM pas flashé |
