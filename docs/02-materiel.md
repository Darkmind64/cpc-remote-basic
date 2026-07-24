# M4 Board v2.5C — Matériel

Sources : `m4hardware/m4board_v2_5c_schematic.pdf` (schéma officiel), `m4hardware/m4board_v25c_bom.txt` (BOM officielle), commentaires de Duke sur le billet de fin de production.

## Le schéma en 6 blocs

1. **Power supply & USB** — Régulateur LDO **RT9166A-36** (3,6 V, SOT-89-3) alimenté soit par `CPC_VCC` (5 V du port d'expansion), soit par le VBUS du connecteur USB mini-B, sélection par le jumper 3 broches. Condensateurs 4,7 µF (entrée) et 1 µF (sortie). LED « ON » sur le rail 3,6 V via 1 kΩ. Les lignes USB D+/D− passent par des résistances série de 22 Ω (R7/R8) vers l'OTG du STM32 (non utilisé en fonctionnement normal, alimentation seulement).
2. **Clocks & JTAG** — Quartz **8 MHz** (SMD 5×3) avec 2×20 pF et 10 MΩ en parallèle. En-tête 1×9 « JTAG » exposant SWD (SWDIO/SWCLK), reset, boot, alimentation — pour le ST-Link. LED « DD » (activité) pilotée par PA3 via 1 kΩ.
3. **ESP8266 WiFi** — Module **ESP-12-F** relié au STM32 : liaison SPI (CS0/MISO/MOSI/SCLK sur GPIO2/4/5/9 du module... voir schéma), lignes RESET et CH_PD contrôlées par le STM32, UART TX/RX également câblée (debug/flash de l'ESP). Découplage 100 µF + 0,1 µF + 100 nF près du module.
4. **MCU** — **STM32F407VGT6** LQFP-100. Reçoit directement : bus d'adresses A0–A15, bus de données CPC_D0–D7, et les signaux de contrôle CPC (IORQ, WR, RD, M1, ROMEN, RAMRD, ROMDIS, RAMDIS, WAIT, INT, NMI, BUSRQ/BUSAK, HALT, MREQ, RFSH, CPC_RSET, CPC_CLK…). BOOT0 tiré à la masse via 10 kΩ. Découplages 0,1 µF sur chaque paire VDD/VSS + 2,2 µF sur les VCAP.
5. **Expansion port** — Empreinte double : connecteur **edge** (bord de carte, monté côté soudure) *ou* en-tête 2×25 coudé 90° (monté côté composants), plus une empreinte JP3 2×25 au pas 2,54 mm (IDC). Un seul est monté selon la variante voulue.
6. **microSD** — Slot push-pull, câblé en **SDIO 4 bits** (SDIO_D0–D3, SDIO_CLK, SDIO_CMD sur PC8–PC12/PD2) avec détection de carte (SD_DETECT).

Le PCB est en **2 couches** (les Gerbers ne contiennent que GTL/GBL en cuivre).

## BOM annotée (v2.5C)

| Qté | Valeur | Boîtier | Repères | Notes d'appro |
|---|---|---|---|---|
| 1 | STM32F407VGT6 | LQFP-100 | MCU | Le composant critique. Mouser/Farnell/LCSC ; attention aux contrefaçons sur AliExpress. Un STM32F407VET6 (512K) n'est **pas** documenté comme substitut — rester sur VGT6 (1 Mo). |
| 1 | ESP-12-F (ESP8266) | module | WIFI | Courant et bon marché (AliExpress, LCSC). |
| 1 | RT9166A-36 (LDO 3,6 V) | SOT-89-3 | — | **Difficile à trouver.** Duke recommande comme alternative le **HT7536-1** (Holtek, SOT-89-3, 3,6 V). |
| 1 | Quartz 8 MHz | SMD 5×3,2 | Q1 | Standard. |
| 1 | Slot microSD « pull type » | — | MICROSD | AliExpress (« push-pull microSD socket », vérifier l'empreinte). |
| 1 | USB mini-B | — | — | AliExpress. |
| 3 | Bouton tact 2 broches 3×6 mm | SW_TACT_3X6 | SW1 (RESET), SW2 (CPC_BRST), SW3 (IOS) | AliExpress. |
| 1 | En-tête 2×25 90° **ou** connecteur edge | 3X25 | EXP_PORT | Selon variante (edge = 464/6128, IDC = Plus). |
| 1 | En-tête 1×3 | M1X3 | Power jumper | + 1 cavalier. |
| 1 | En-tête 1×9 | 1X09 | JTAG | Peut rester non monté après programmation, mais utile. |
| 7 | 0,1 µF | C0603 | C2,C7,C9–C12,C17 | |
| 2 | 20 pF | C0603 | C1,C4 | Charge du quartz. |
| 2 | 2,2 µF | C0603 | C5,C6 | VCAP du STM32. |
| 1 | 1 µF X7R | C0603 | C8 | |
| 1 | 1 µF | C0603 | C16 | Sortie LDO. |
| 1 | 4,7 µF X7R | C0603 | C13 | Entrée LDO. |
| 1 | 10 µF | C0603 | C14 | *Optionnel* (dixit BOM). |
| 1 | 47–100 µF | C1210 | C3 | *Optionnel* (dixit BOM). |
| 2 | 10 kΩ | R0603 | R1,R5 | |
| 1 | 10 MΩ | R0603 | R10 | Parallèle quartz. |
| 2 | 22 Ω | R0603 | R7,R8 | Série USB. |
| 1 | 330 Ω | R0603 | R9 | |
| 2 | 1 kΩ | R0603 | R6,R14 | Séries LED. |
| 2 | LED 3 V 0603 | LED-0603 | DD, ON | Bleue pour ON sur l'originale. |
| 1 | 10 kΩ | R0603 | R1 | (près de SW3/IOS, cf. schéma) |

## Fichiers de fabrication

`m4hardware/m4board_v25c.zip` contient les Gerbers (nommage Protel) :

| Fichier | Couche |
|---|---|
| `.GTL` / `.GBL` | Cuivre top / bottom |
| `.GTO` / `.GBO` | Sérigraphie top / bottom |
| `.GTS` / `.GBS` | Vernis épargne top / bottom |
| `.GTP` / `.GBP` | Pâte à braser top / bottom |
| `.GML` | Contour (mill) |
| `.TXT` | Perçage (Excellon) |
| `.dri` / `.gpi` | Rapports perçage/photoplot (info) |

Les fichiers `m4board_simp_v2_5C.mnb/.mnt` sont des rendus/fichiers de visualisation de la carte. Le projet a été dessiné sous **EAGLE** (nommage des composants type EAGLE dans la BOM) mais les sources CAO ne sont pas publiées — seuls schéma PDF + Gerbers le sont.

**Épaisseur/finition conseillées** : pour la variante edge (la carte s'insère directement dans le connecteur du CPC), commander le PCB en **1,6 mm** avec de préférence une **finition ENIG** et un **biseau (bevel) sur le bord connecteur** si le fabricant le propose — c'est le connecteur qui s'use le plus. Un projet partagé existe chez PCBWay (« Amstrad M4 Board From Duke ») pour commander directement.

## Points d'attention identifiés

- Le régulateur 3,6 V est le seul composant réellement dur à sourcer (RT9166A-36 → alternative HT7536-1 validée par Duke).
- Le LQFP-100 au pas 0,5 mm demande flux + tresse ou air chaud ; c'est la principale difficulté de soudure.
- Bien choisir la variante du connecteur d'expansion **avant** l'assemblage (edge dessous ou header dessus).
- Sur CPC 464, la carte se branche telle quelle ; sur 6128 Plus, prévoir l'adaptation MX4/câble selon la config (voir manuel étendu).
