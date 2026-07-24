# Ressources et liens

## Officiel (Duke / spinpoint.org)

- Site : https://www.spinpoint.org/
- Dépôt hardware (Gerbers, schéma, BOM, bootloader, firmwares) : https://github.com/M4Duke/m4hardware — *cloné dans `m4hardware/`*
- Doc de référence firmware/RSX/API : http://www.spinpoint.org/cpc/m4info.txt — *copie dans `downloads/m4info.txt`*
- Annonce fin de production (30/09/2025, infos d'appro en commentaires) : https://www.spinpoint.org/2025/09/30/m4-board-the-end-maybe/
- Page « Guides/Setup/Help » : https://www.spinpoint.org/2019/11/19/m4-board-guides/
- GitHub général : https://github.com/M4Duke — YouTube : https://www.youtube.com/channel/UCL4reNs9BnhQ2XnRxXRYLNw

## Manuels et guides

- **Manuel utilisateur étendu** (Csaba Tóth, EN, firmware v2.0.8) : https://www.spinpoint.org/cpc/Amstrad_CPC_M4_Board__Extended_User_Manual.pdf — *copie dans `downloads/M4_Extended_User_Manual.pdf`*
- CPCWiki (page M4 Board, ROMs, problèmes connus) : https://www.cpcwiki.eu/index.php/M4_Board *(protégé par Cloudflare — à consulter dans un navigateur normal)*
- AUAmstrad (ES) : configuration https://auamstrad.es/hardware/m4-board-configuracion/ · gestionnaires de fichiers https://auamstrad.es/hardware/m4-board-gestores/ · Hack Menu https://auamstrad.es/hardware/m4-board-hack-menu/
- Amstrad Noob (EN) : premier contact https://www.amstrad-noob.com/2021/04/23/first-looks-at-the-m4-board-for-amstrad-cpc/ · ajout de ROMs https://www.amstrad-noob.com/2021/04/23/adding-roms-to-the-m4-board/
- Vidéos : StephBB (FR sous-titré EN), Chinnyvision (EN), Professor Retroman (ES), Jungsis Corner (DE), RetroGralnia (PL)…

## Fabrication / achat

- Projet partagé PCBWay : https://www.pcbway.com/project/shareproject/Amstrad_M4_Board_From_Duke_491c279c.html
- Cartes assemblées : UK (annonce forum CPCWiki), Espagne https://hobbyretro.com/, Pologne https://www.sellmyretro.com/offer/details/amstrad-cpc-m4-card-edge-slot-version-64982
- Boîtiers imprimés 3D (versions EDGE/IDC) : Thingiverse et GitHub communautaires (chercher « M4 board case CPC »)

## Outils et logiciels compatibles

- **cpcxfer** — transfert de fichiers PC→CPC par WiFi (ligne de commande)
- **M4FE** — lanceur graphique sur CPC
- **RulezCharge** (hERMOL) — front-end
- **YANCC** — clone Norton Commander pour CPC
- **SymbOS** — support natif de la M4
- Base de compatibilité jeux (Mr. DVG) : 1300+ jeux testés

## Communauté

- Forum CPCWiki (section M4 très active, Duke y répond) : http://www.cpcwiki.eu/forum
- CPC-Power (base logicielle) : http://www.cpc-power.com — ACME : https://acpc.me

## Dépannage courant (rappel)

- Resets/freezes/glitches → nettoyer le connecteur bord de carte.
- Réinitialiser le réseau → supprimer `/m4/config.txt` sur la SD.
- SD non reconnue → FAT32 obligatoire.
- Boards livrées après oct. 2016 → firmware ≥ v1.0.9 requis.
