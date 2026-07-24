# M4 Board — Présentation

## Qu'est-ce que c'est ?

La M4 Board est une carte d'extension pour **Amstrad CPC 464 / 664 / 6128 et CPC Plus (464+/6128+)**, créée en **2016** par « Duke » (spinpoint.org). Elle se branche sur le port d'expansion du CPC (connecteur bord de carte 50 broches ou IDC selon le modèle) et apporte :

- **Stockage de masse sur microSD** : LOAD/SAVE/RUN/CAT natifs sur la carte SD, navigation dans les images DSK comme des répertoires virtuels, chargement de snapshots SNA, cartouches CPR (CPC+), compatibilité ROMDOS/PARADOS.
- **WiFi** (module ESP8266) : téléchargement de fichiers depuis Internet (`|HTTPGET`), interface web d'administration (upload de fichiers, gestion des ROMs), synchronisation de l'heure par NTP, API sockets TCP pour les développeurs.
- **Émulation de ROM board** : jusqu'à **32 slots de ROM** (applications, autres BASIC, PARADOS…), remplacement possible de la ROM basse, activation/désactivation par slot, mise à jour à chaud.
- **Hack Menu** : déclenchement NMI (bouton physique ou logiciel) avec remap ROM/RAM — fonctions type « Multiface 2 » (inspection mémoire, pokes, sauvegarde d'état).

## Historique et statut du projet

| Date | Événement |
|---|---|
| mai 2016 | Annonce publique (« Retrofun, 8-Bit Amstrad CPC WiFi ») |
| 2016–2025 | Production artisanale par Duke, ~1500 exemplaires, firmware maintenu (v1.0.0 → v2.0.8) |
| 30 sept. 2025 | **Fin de production** (manque de temps + nouvelles contraintes réglementaires UE au 1er oct. 2025). Publication de tous les fichiers sur [github.com/M4Duke/m4hardware](https://github.com/M4Duke/m4hardware) |
| depuis fin 2025 | Le projet continue en open hardware : revendeurs communautaires (UK, Espagne, Pologne) et fabrication DIY |

La version matérielle publiée est la **v2.5C** (« m4board_simp »), la dernière révision produite par Duke. Le firmware courant est **v2.0.8**.

## Architecture en bref

- **MCU : STM32F407VGT6** (ARM Cortex-M4, LQFP-100, 168 MHz, 1 Mo flash, 192 Ko RAM). C'est lui qui fait tout : il écoute le bus du CPC (données, adresses, signaux de contrôle) via ses GPIO tolérants 5 V, sert les ROMs, gère la microSD (SDIO) et le protocole M4.
- **WiFi : ESP-12-F (ESP8266)** relié au STM32 en SPI, avec son propre firmware (`ESPFIRM.BIN`).
- **Alimentation 3,6 V** (régulateur LDO RT9166A-36) depuis le 5 V du CPC ou un port USB mini-B (sélection par jumper). Le choix de 3,6 V (et non 3,3 V) maximise les marges sur le bus 5 V du CPC.
- **Pas de logique de niveau externe** sur la v2.5C : le bus CPC attaque directement les broches 5V-tolerant du STM32 (les premières révisions utilisaient un translateur GTL2000 — obsolète sur la version « simp »).

## Interfaces sur la carte

- Connecteur d'expansion CPC : bord de carte (edge) monté dessous **ou** en-tête coudé 90° monté dessus (2×25) — au choix selon le CPC cible (464/6128 = edge ; 6128 Plus = câble/adaptateur).
- Slot microSD (FAT32).
- USB mini-B : alimentation uniquement.
- Jumper 3 broches : source d'alimentation (5 V CPC ↔ 5 V USB).
- En-tête « JTAG » 1×9 : programmation du STM32 par ST-Link (SWD).
- 3 boutons : **RESET** (reset M4), **CPC_BRST** (reset du CPC), **IOS** (bouton Hack/NMI).
- 2 LED : **ON** (alimentation, bleue) et **DD** (activité SD).
