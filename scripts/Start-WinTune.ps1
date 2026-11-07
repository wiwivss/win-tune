<#
.SYNOPSIS
    Menu interactif de win-tune (lancé par wintune.cmd).
.DESCRIPTION
    Règles appliquées par le menu :
      - l'audit est en lecture seule ;
      - toute application passe d'abord par une SIMULATION (-WhatIf) affichée à l'écran ;
      - l'exécution réelle demande de taper OUI en majuscules ;
      - profil Prudent par défaut ; Équilibré = actions orange validées une par une ;
        Avancé = actions rouges, avertissement explicite, seulement si tu le demandes ;
      - un réglage « non vérifié » (sans source officielle) demande une confirmation séparée ;
      - les commandes administrateur sont affichées (copiables), jamais lancées.
.PARAMETER Inputs
    Réponses pré-remplies séparées par « | » (tests automatisés, ex : "7|0").
    Quand elles sont épuisées, le menu répond « 0 » (retour / quitter).
.PARAMETER NoOpen
    N'ouvre pas le rapport HTML dans le navigateur.
#>
param(
    [string]$Inputs,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'Common.ps1')
$reportPath = Join-Path (Get-WtPath 'reports') 'rapport_audit.html'

# ---------------------------------------------------------------- Saisie (interactive ou scriptée)
$queue = New-Object System.Collections.Queue
$scripted = [bool]$Inputs
if ($Inputs) { foreach ($i in ($Inputs -split '\|')) { $queue.Enqueue($i) } }

function Ask([string]$Question, [string]$Default = '') {
    $label = if ($Default) { "$Question [$Default]" } else { $Question }
    if ($queue.Count) { $a = [string]$queue.Dequeue(); Write-Host "$label : $a" -ForegroundColor DarkGray }
    elseif ($scripted) { $a = '0'; Write-Host "$label : 0 (fin des réponses de test)" -ForegroundColor DarkGray }
    else { $a = Read-Host $label }
    if (-not $a) { $a = $Default }
    "$a".Trim()
}
function Confirm-Yes([string]$Question) { (Ask "$Question (oui/non)" 'non') -match '^(o|oui)$' }
function Confirm-Strong([string]$Question) { (Ask "$Question Tape OUI en majuscules pour confirmer") -ceq 'OUI' }
function Wait-Menu { if (-not $scripted) { [void](Read-Host "`nEntrée pour revenir au menu") } }
function Show-Title([string]$t) { Write-Host ''; Write-Host ('=' * 72) -ForegroundColor DarkCyan; Write-Host " $t" -ForegroundColor Cyan; Write-Host ('=' * 72) -ForegroundColor DarkCyan }
function Get-Numbers([string]$text) { @($text -split '[,; ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Sort-Object -Unique) }
function Get-LastAudit {
    $f = Get-ChildItem -Path (Get-WtPath 'reports') -Filter 'audit.json' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -like 'audit_*' } | Sort-Object { $_.Directory.Name } | Select-Object -Last 1
    if ($f) { Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
}
function Write-Risk([string]$r) {
    $c = @{ vert = 'Green'; orange = 'Yellow'; rouge = 'Red' }[$r]; if (-not $c) { $c = 'Gray' }
    Write-Host ('{0,-7}' -f $r) -ForegroundColor $c -NoNewline
}

# ---------------------------------------------------------------- En-tête
function Show-Header {
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $up = (Get-Date) - $os.LastBootUpTime
    Show-Title "win-tune - mesurer, régler ce qui compte, vérifier"
    Write-Host ("  Windows {0} build {1}.{2} · démarré depuis {3:N1} h · installé/mis à jour le {4:dd/MM/yyyy}" -f $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR, $up.TotalHours, $os.InstallDate)
    if ($up.TotalDays -gt 7) { Write-Host "  ! Uptime > 7 jours : redémarre (Redémarrer) avant de mesurer." -ForegroundColor Yellow }
    $a = Get-LastAudit
    if ($a) { Write-Host ("  Dernier audit : {0:dd/MM/yyyy HH:mm} · {1} constat(s) critique(s)" -f [datetime]$a.Date, @($a.Constats | Where-Object { $_.Niveau -eq 'critique' }).Count) }
    else { Write-Host "  Aucun audit : commence par 1." -ForegroundColor Yellow }
    $st = Join-Path (Get-WtPath 'baseline') 'a_verifier.json'
    if (Test-Path -LiteralPath $st) {
        $s = Get-Content -LiteralPath $st -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ("  Réglages du {0:dd/MM HH:mm} à vérifier après redémarrage : option 6" -f [datetime]$s.Date) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  1  Audit (lecture seule) + rapport HTML'
    Write-Host '  2  Ouvrir le dernier rapport'
    Write-Host '  3  Appliquer des réglages (simulation, puis réel si tu tapes OUI)'
    Write-Host '  4  Actions manuelles / admin : commandes à copier'
    Write-Host '  5  Annuler une session de réglages'
    Write-Host '  6  Vérifier après redémarrage (avant / après)'
    Write-Host '  7  Auto-test des garde-fous'
    Write-Host '  0  Quitter'
}

# ---------------------------------------------------------------- Actions du menu
function Invoke-AuditMenu {
    Show-Title 'Audit (lecture seule)'
    $skip = -not (Confirm-Yes "Inclure la mesure au repos (attend 3 min sans clavier/souris + 60 s) ?")
    & (Join-Path $here 'Audit.ps1') -SkipIdleSample:$skip
    & (Join-Path $here 'New-AuditReport.ps1')
    if (-not $NoOpen -and -not $scripted -and (Test-Path -LiteralPath $reportPath)) { Invoke-Item -LiteralPath $reportPath }
}

function Show-Catalog($cat, $audit) {
    Write-Host ("  {0,-3} {1,-7} {2,-17} {3,-6} {4}" -f 'N°', 'Risque', 'Classement', 'Mode', 'Réglage')
    foreach ($x in $cat.actions) {
        $done = $false
        if ($audit -and $x.etat) {
            $v = $audit; foreach ($p in $x.etat.chemin.Split('.')) { if ($null -ne $v) { $v = $v.$p } }
            $done = if ($x.etat.faitSiVide) { @($v | Where-Object { $_ }).Count -eq 0 } else { ($null -ne $v) -and ([string]$v -eq [string]$x.etat.fait) }
        }
        Write-Host ("  {0,-3} " -f $x.num) -NoNewline; Write-Risk $x.risque
        $mode = if ($x.auto) { 'auto' } else { 'admin' }
        $flags = @(); if ($done) { $flags += 'déjà en place' }; if (-not $x.verifie) { $flags += 'NON VÉRIFIÉ' }
        Write-Host (" {0,-17} {1,-6} {2}{3}" -f $x.classement, $mode, $x.titre, $(if ($flags) { "  [" + ($flags -join ', ') + "]" })) -ForegroundColor $(if ($done) { 'DarkGray' } else { 'Gray' })
    }
}

function Invoke-ApplyMenu {
    Show-Title 'Appliquer des réglages'
    $cat = Get-WtConfig 'actions'
    Show-Catalog $cat (Get-LastAudit)
    Write-Host "`n  Profils : 1 Prudent (vert) · 2 Équilibré (+ orange, une par une) · 3 Avancé (+ rouge)"
    $p = Ask 'Profil' '1'
    $profil = switch ($p) { '2' { 'Equilibre' } '3' { 'Avance' } default { 'Prudent' } }
    if ($profil -eq 'Avance') {
        Write-Host "  AVERTISSEMENT : le profil Avancé autorise des réglages ROUGES (système sensible)." -ForegroundColor Red
        if (-not (Confirm-Strong 'Tu veux vraiment le profil Avancé ?')) { $profil = 'Equilibre'; Write-Host '  -> profil Équilibré.' }
    }
    $nums = Get-Numbers (Ask 'Numéros des actions (ex : 3,6), 0 = retour' '0')
    if (-not $nums -or $nums -contains 0) { return }
    $sel = @($cat.actions | Where-Object { $nums -contains $_.num })

    # Validation une par une des actions orange/rouges (Équilibré / Avancé)
    $keep = @()
    foreach ($x in $sel) {
        if ($x.risque -ne 'vert' -and $x.auto) {
            Write-Host ("  [{0}] {1} : risque {2} - {3}" -f $x.num, $x.titre, $x.risque, $x.risqueDetail) -ForegroundColor Yellow
            if (-not (Confirm-Yes 'La garder ?')) { continue }
        }
        $keep += $x
    }
    $unverified = @($keep | Where-Object { -not $_.verifie -and $_.auto })
    $incl = $false
    if ($unverified) {
        foreach ($x in $unverified) { Write-Host ("  [{0}] NON VÉRIFIÉ : {1}" -f $x.num, $x.nonVerifieDetail) -ForegroundColor Yellow }
        $incl = Confirm-Yes 'Inclure quand même ces réglages sans source officielle ?'
    }
    $nums = @($keep | ForEach-Object { $_.num })
    if (-not $nums) { Write-Host '  Rien à faire.'; return }

    Show-Title 'SIMULATION (rien ne sera modifié)'
    & (Join-Path $here 'Apply.ps1') -Actions $nums -Profil $profil -IncludeUnverified:$incl -Force -WhatIf | Out-Null
    if (-not @($keep | Where-Object { $_.auto }).Count) { Write-Host "`n  Uniquement des actions manuelles/admin : rien à exécuter automatiquement."; return }
    if (Confirm-Strong "`nAppliquer pour de vrai ce qui est simulé ci-dessus ?") {
        & (Join-Path $here 'Apply.ps1') -Actions $nums -Profil $profil -IncludeUnverified:$incl -Force | Out-Null
    } else { Write-Host '  Annulé : rien n''a été modifié.' }
}

function Show-AdminCommands {
    Show-Title 'Actions manuelles / admin (à copier dans un PowerShell administrateur)'
    $cat = Get-WtConfig 'actions'
    foreach ($x in @($cat.actions | Where-Object { -not $_.auto -and $_.recommande -ne 'déjà fait' })) {
        Write-Host ("`n[{0}] {1}  ({2}, risque {3})" -f $x.num, $x.titre, $x.classement, $x.risque) -ForegroundColor White
        foreach ($c in @($x.commandes)) { Write-Host ("    " + ($c -replace '<logs>', (Get-WtPath 'logs'))) }
        Write-Host "    Annulation : $($x.annulation)" -ForegroundColor DarkGray
        Write-Host "    Source : $($x.source)" -ForegroundColor DarkGray
    }
    $a = Get-LastAudit
    if ($a -and @($a.CommandesAdmin).Count) {
        Write-Host "`nMesures complémentaires demandées par l'audit (lecture seule) :" -ForegroundColor White
        foreach ($c in $a.CommandesAdmin) { Write-Host "  # $($c.Pourquoi)" -ForegroundColor DarkGray; Write-Host "  $($c.Commande)" }
    }
}

function Invoke-UndoMenu {
    Show-Title 'Annuler une session'
    & (Join-Path $here 'Undo.ps1') -List
    $s = Ask 'Session à annuler (nom, « last », 0 = retour)' 'last'
    if ($s -eq '0') { return }
    & (Join-Path $here 'Undo.ps1') -Session $s -WhatIf | Out-Null
    if (Confirm-Strong "`nAnnuler pour de vrai ?") { & (Join-Path $here 'Undo.ps1') -Session $s | Out-Null }
}

# ---------------------------------------------------------------- Boucle principale
while ($true) {
    Show-Header
    $c = Ask "`nChoix" '0'
    switch ($c) {
        '1' { Invoke-AuditMenu; Wait-Menu }
        '2' { if (Test-Path -LiteralPath $reportPath) { if (-not $NoOpen -and -not $scripted) { Invoke-Item -LiteralPath $reportPath } else { Write-Host "Rapport : $reportPath" } } else { Write-Host 'Aucun rapport : lance d''abord 1.' -ForegroundColor Yellow }; Wait-Menu }
        '3' { Invoke-ApplyMenu; Wait-Menu }
        '4' { Show-AdminCommands; Wait-Menu }
        '5' { Invoke-UndoMenu; Wait-Menu }
        '6' { & (Join-Path $here 'Verify.ps1') | Out-Null; Wait-Menu }
        '7' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Test-WinTune.ps1'); Wait-Menu }
        '0' { return }
        default { Write-Host "Choix inconnu : $c" -ForegroundColor Yellow }
    }
}
