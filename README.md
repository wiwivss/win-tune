# win-tune

Boîte à outils PowerShell pour **mesurer puis optimiser Windows 10/11 lui-même** (démarrage, arrêt, activité en arrière-plan, mémoire, stockage côté système, interface, stabilité), sans placebo :

1. on **mesure avant** (baseline : temps de boot, CPU / RAM / disque au repos) ;
2. on ne règle **que ce qui a un effet prouvé**, avec une **source officielle** ;
3. on **vérifie après un vrai redémarrage** et on conclut honnêtement : « gain mesuré » ou « aucun gain mesurable sur cette machine ».

> 3ᵉ projet d'une suite : [pc-cleanup](https://github.com/wiwivss/pc-cleanup) (nettoyage disque) et netguard-gaming (réseau, sécurité, jeu). Projet personnel d'étudiant ingénieur Réseaux & Sécurité : le but est autant de comprendre Windows que de le régler.

## Démarrage rapide

1. Télécharge le dépôt (**Code > Download ZIP**) et extrais-le où tu veux.
2. Double-clique sur **`wintune.cmd`**. Aucune installation, aucun droit administrateur.
3. Suis le menu :

```
  1  Audit (lecture seule) + rapport HTML
  2  Ouvrir le dernier rapport
  3  Appliquer des réglages (simulation, puis réel si tu tapes OUI)
  4  Actions manuelles / admin : commandes à copier
  5  Annuler une session de réglages
  6  Vérifier après redémarrage (avant / après)
  7  Auto-test des garde-fous
  0  Quitter
```

Le cycle conseillé : **1** (audit avec mesure au repos) → lire le rapport → **3** (profil, numéros, simulation, `OUI`) → **Redémarrer** → **6** (avant/après). Le temps de démarrage ne se mesure qu'après plusieurs vrais redémarrages : compte ~5 boots.

> `wintune.cmd` lance PowerShell avec `-ExecutionPolicy Bypass` **pour ce seul processus** : la stratégie d'exécution de Windows n'est pas modifiée. Lis les scripts avant : tout est en clair et commenté.

## Principes de sécurité

| Règle | Mise en œuvre |
|---|---|
| L'audit ne modifie rien | `Audit.ps1` n'écrit que dans `reports\` et `baseline\`. `Test-WinTune.ps1` le prouve (instantané du projet avant/après, recherche de toute commande d'écriture). |
| Simulation d'abord | Tous les scripts gèrent `-WhatIf` ; le menu simule toujours avant de demander `OUI`. |
| Sauvegarde avant modification | Export `.reg` de la clé + valeur et **type** d'origine dans `logs\session_<date>\journal.json`, écrit **avant** chaque changement. |
| Annulation | `Undo.ps1` rejoue le journal à l'envers ; ne supprime une clé que si win-tune l'a créée et qu'elle est vide. |
| Sources | Chaque réglage du catalogue cite learn.microsoft.com. Sans source officielle : **« non vérifié »**, désactivé par défaut. |
| Zones interdites | Defender, pare-feu, Windows Update, liste de blocage des pilotes : jamais. Windows Search : seulement sur demande explicite. Services de `config\protected_services.json` : refusés même en administrateur. Fichier d'échange : jamais supprimé (laissé en automatique). VM, projets, coffres de mots de passe, pilotes : non touchés. |
| Pas d'admin implicite | Ce qui demande l'administrateur est **affiché**, jamais lancé. |
| Pas d'outil tiers | Aucun script de « debloat » téléchargé, aucun nettoyeur de registre, aucun « optimiseur de RAM ». |

### Niveaux de risque et profils

| Niveau | Signification | Profil minimal |
|---|---|---|
| 🟢 Vert | Réversible, sans effet visible gênant | Prudent |
| 🟠 Orange | Conséquence visible ou redémarrage | Équilibré (validées **une par une**) |
| 🔴 Rouge | Réglage système sensible | Avancé (avertissement explicite, seulement sur demande) |

### Classement honnête de chaque réglage

| Classement | Signification |
|---|---|
| gain réel mesuré | Effet mesuré par la baseline (temps, RAM, espace) |
| stabilité | Pas plus rapide, mais plus fiable ou récupérable |
| gain marginal | Effet réel mais trop petit pour être ressenti |
| placebo | Aucun effet mesurable sur une machine comme celle-ci |

## Contenu

```
wintune.cmd                double-clic : lance le menu
scripts\
  Start-WinTune.ps1        menu interactif
  Audit.ps1                Phase 0 (contexte) + Phase 1 (audit A à I, lecture seule) -> reports\audit_<date>\, baseline\baseline_<date>.json
  New-AuditReport.ps1      rapport HTML autonome -> reports\rapport_audit.html
  Apply.ps1                applique les actions choisies (profil, simulation, export .reg, journal)
  Undo.ps1                 annule une session à partir de son journal
  Verify.ps1               après redémarrage : nouvelle mesure et comparaison avant/après
  Test-WinTune.ps1         auto-test dans un bac à sable (HKCU:\Software\WinTuneTest + %TEMP%)
  Common.ps1               fonctions partagées (lecture seule)
config\
  actions.json             catalogue numéroté : classement, risque, méthode, clé/commande, source, annulation
  protected_services.json  services jamais modifiés
  appx_candidates.json     applis préinstallées « sans risque » / « à éviter »
  windows_lifecycle.json   fins de support Windows 11 (recopiées de learn.microsoft.com)
  *.local.json             surcharges locales (ignorées par Git)
reports\ baseline\ logs\   résultats, mesures et journaux (ignorés par Git : données perso)
```

## Ce que mesure l'audit

| Section | Contenu |
|---|---|
| 0. Contexte | Édition, build, fin de support, SSD/HDD par lecteur (y compris espaces de stockage), portable/fixe, RAM, uptime |
| A. Baseline | Démarrage/arrêt (Diagnostics-Performance 100/200, ralentisseurs 101 appli / 102 pilote / 103 service) ; repos : 3 min sans clavier/souris puis 60 s d'échantillon (CPU, RAM, disque, processus, services, handles) |
| B. Démarrage | Démarrage rapide, hibernation, `hiberfil.sys`, redémarrage en attente |
| C. Arrière-plan | Applis en arrière-plan, Widgets, Copilot, recherche web, suggestions, applis Appx |
| D. Mémoire / stockage | TRIM, optimisation planifiée et son historique, Windows Search, SysMain, compression mémoire, fichier d'échange |
| E. Interface | Effets visuels, transparence, animations (gain estimé selon la machine) |
| F. Mises à jour | Heures d'activité, échecs, redémarrages forcés, **date de la dernière mise à jour de sécurité** |
| G. Stabilité | Plantages (top 10), écrans bleus, Kernel-Power 41, WHEA, erreurs disque 7/11/51/153, périphériques en erreur, **période réellement couverte par le journal** |
| H. Vie privée | Télémétrie, identifiant publicitaire, historique d'activité (présenté à part : ce n'est pas de la performance) |
| I. Portable | Commandes `powercfg /batteryreport`, `/sleepstudy`, `/energy` |

## Catalogue des actions

| N° | Réglage | Classement | Risque | Source | Annulation |
|---|---|---|---|---|---|
| 1 | Fichier d'échange géré par Windows | stabilité | 🟠 admin | [Microsoft](https://learn.microsoft.com/troubleshoot/windows-client/performance/how-to-determine-the-appropriate-page-file-size-for-64-bit-versions-of-windows) | Mémoire virtuelle : remettre les tailles d'origine (gardées dans l'audit) |
| 2 | Vérifier / réactiver WinRE | stabilité | 🟢 admin | [REAgentC](https://learn.microsoft.com/windows-hardware/manufacture/desktop/reagentc-command-line-options) | `reagentc /disable` |
| 3 | Widgets coupés (stratégie « Allow widgets ») | gain marginal | 🟢 admin | [Policy CSP NewsAndInterests](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-newsandinterests) | Supprimer `AllowNewsAndInterests` |
| 4 | Suggestions, pubs, installations silencieuses | placebo | 🟢 | ❌ non vérifié | `Undo.ps1` ou `.reg` exporté |
| 5 | Recherche web du menu Démarrer | placebo | 🟠 | ❌ non vérifié | `Undo.ps1` |
| 6 | Retrait d'applis préinstallées « sans risque » | placebo (rangement) | 🟢 | [Remove-AppxPackage](https://learn.microsoft.com/powershell/module/appx/remove-appxpackage) | Réinstaller depuis le Microsoft Store |
| 7 | Démarrage rapide désactivé (constat) | gain marginal | 🟢 | [powercfg](https://learn.microsoft.com/windows-hardware/design/device-experiences/powercfg-command-line-options) | `powercfg /hibernate on` |
| 8 | Hibernation désactivée (constat) | gain réel (espace) | 🟢 | [powercfg](https://learn.microsoft.com/windows-hardware/design/device-experiences/powercfg-command-line-options) | `powercfg /hibernate on` |
| 9 | Applis en arrière-plan coupées (constat) | gain marginal | 🟢 | ❌ non documenté | Paramètres > Applis |
| 10 | Effets visuels « performances » (constat) | placebo | 🟢 | ❌ pas de registre documenté | `SystemPropertiesPerformance.exe` |

**Non recommandé, et pourquoi** (détail dans le rapport) : désactiver SysMain, l'indexation, le fichier d'échange, la transparence ; couper DiagTrack « pour la vitesse » ; nettoyeurs de registre et « optimiseurs de RAM » ; défragmenter un SSD ; désactiver la liste de blocage des pilotes vulnérables.

## Usage des scripts sans le menu

```powershell
.\scripts\Audit.ps1 -WhatIf                       # ce qui serait écrit, sans rien écrire
.\scripts\Audit.ps1                               # audit complet (attend 3 min d'inactivité)
.\scripts\Audit.ps1 -SkipIdleSample               # rapide, sans mesure au repos
.\scripts\New-AuditReport.ps1

.\scripts\Apply.ps1 -Actions 6 -Profil Prudent -WhatIf
.\scripts\Apply.ps1 -Actions 6 -Profil Prudent
.\scripts\Apply.ps1 -Actions 4 -Profil Equilibre -IncludeUnverified -WhatIf   # réglage sans source : opt-in explicite

.\scripts\Undo.ps1 -List
.\scripts\Undo.ps1 -Session last -WhatIf
.\scripts\Undo.ps1 -Session last

.\scripts\Verify.ps1                              # après redémarrage
.\scripts\Test-WinTune.ps1
```

Les temps de démarrage exacts sont dans un journal **réservé aux administrateurs**. L'audit affiche une commande d'export (lecture seule) à lancer dans un PowerShell admin ; il lit ensuite l'export dans `baseline\`.

## Pièges rencontrés (Windows PowerShell 5.1)

- Le journal `Diagnostics-Performance/Operational` répond « aucun événement » (et non « accès refusé ») à un utilisateur standard : l'audit teste l'accès explicitement.
- `Get-Counter` échoue sur un Windows en français (noms de compteurs traduits) : l'audit lit les mêmes compteurs via `Win32_PerfFormattedData_*`.
- `R` est un alias intégré d'`Invoke-History`, prioritaire sur une fonction du même nom.
- `Get-Content | ConvertFrom-Json` d'un tableau renvoie **un seul objet** : `@()` donne un tableau à un élément, et `$x.Annule` devient un tableau de `$false`… considéré comme vrai. D'où `Read-WtJsonArray`. Bug trouvé par l'auto-test : Undo n'annulait rien.
- `continue` dans un `switch` ne passe pas à l'itération suivante d'un `for`.
- Avec `$ErrorActionPreference = 'Stop'`, le stderr d'un `.exe` redirigé par `2>&1` devient une erreur bloquante.
- Les lignes « WhatIf : … » vont directement à la console : `*>&1` ne les capture pas.
- Sous `-WhatIf`, `ForEach-Object NomDePropriété` ne renvoie rien : le code utilise `.Propriété`.
- Une réinstallation sur place de Windows **efface les journaux d'événements** : l'audit indique la période réellement couverte au lieu d'annoncer « 0 erreur ».
- `UserLogonWaitDuration` (attente du mot de passe) dépasse parfois `BootTime` : la soustraire donne des durées négatives, l'audit ne le fait pas.

## Risques et limites

- **Mesures bruitées** : CPU/RAM au repos varient selon les applis ouvertes ; compare dans les mêmes conditions. Verify.ps1 applique des seuils (boot 3 s et 5 %, RAM 200 Mo, CPU 1 point…) en deçà desquels il conclut « aucun gain mesurable ».
- **Boot** : il faut plusieurs redémarrages après un changement (et après chaque mise à jour de Windows) pour une médiane fiable.
- **Applis Appx retirées** : réinstallation manuelle depuis le Store (pas d'annulation automatique).
- **Réglages « non vérifiés »** : valeurs non documentées par Microsoft, qu'une mise à jour peut ignorer ou réinitialiser.
- **PC géré (MDM, Intune…)** : des stratégies d'entreprise ou d'école peuvent primer sur les réglages locaux.
- Le rapport, l'audit et les journaux contiennent des données de la machine : ils sont exclus du dépôt par `.gitignore`.

## Résultat sur ma machine

Ryzen 7 3700X, 32 Go, RTX 4070 SUPER, SSD SATA 120 Go pour Windows, Windows 11 Pro 25H2.

| | Démarrage (médiane) | Arrêt | CPU au repos | RAM au repos | Processus / services |
|---|---|---|---|---|---|
| Baseline, build 26200.6584 (10 boots) | 64,4 s | 9,2 s | 2,5 % | 8,9 Go | 195 / 107 |
| Build 26200.9711, juste après la mise à jour (provisoire) | — (0 boot) | — | 14 % ¹ | 9,4 Go | 193 / 113 |
| Après réglages win-tune | *à mesurer* | | | | |

¹ tâches de fond de Windows après la mise à jour ; ~2 % quelques minutes plus tard.

Ce que l'audit a trouvé **avant tout réglage** (plus important que n'importe quel tweak) :
- **Windows bloqué au niveau de correctifs de septembre 2025** : la mise à jour échouait au téléchargement depuis des mois (C: plein, cache de Windows Update resté sur un autre disque). Réparé : réinitialisation du cache puis installation, build 26200.9711.
- **Fichier d'échange en taille fixe sur un SSD qui venait de produire des milliers d'erreurs de pagination** : action n° 1.
- **Un vieux pilote révoqué** réenregistré par la réparation (fenêtre « pilote vulnérable » au démarrage) : service orphelin retiré, sans toucher à la liste de blocage.

Conclusion à ce stade : les leviers de vitesse classiques (Démarrage rapide, hibernation, applis en arrière-plan, effets visuels) étaient déjà en place ; ce qui reste relève de la **stabilité** ou du confort. La section sera complétée par `Verify.ps1` après les réglages.

## Licence

MIT
