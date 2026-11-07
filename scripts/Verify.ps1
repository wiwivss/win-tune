<#
.SYNOPSIS
    Phase 4 : vérification APRÈS redémarrage. Compare la baseline d'avant les réglages à une nouvelle mesure.
.DESCRIPTION
    1. Lit baseline\a_verifier.json (écrit par Apply.ps1) : date des réglages + baseline de référence.
    2. Refuse de conclure si aucun redémarrage n'a eu lieu depuis (le temps de boot ne change qu'après un vrai redémarrage).
    3. Relance l'audit (mesure au repos incluse) sauf -SkipAudit.
    4. Compare : démarrage (uniquement les boots APRÈS les réglages), RAM, CPU, processus, services au repos.
    5. Conclusion par mesure : « gain mesuré », « dégradation » ou « aucun gain mesurable sur cette machine ».
       Seuils (au-delà du bruit de mesure observé) : boot 3 s ET 5 % ; RAM 200 Mo ; CPU 1 point ;
       processus 3 ; services 2. Démarrage : au moins 3 boots après les réglages, sinon « trop tôt ».
    Écrit reports\verification_<date>.json (lu par New-AuditReport.ps1). Lecture seule sur le système.
.EXAMPLE
    .\scripts\Verify.ps1
    .\scripts\Verify.ps1 -SkipAudit     # compare avec le dernier audit existant
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipAudit,
    [string]$Reference   # nom d'un fichier baseline_*.json (sinon : celui de a_verifier.json)
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$baseDir = Get-WtPath 'baseline'
$stateFile = Join-Path $baseDir 'a_verifier.json'
$state = if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
if (-not $state -and -not $Reference) {
    Write-Host "Rien à vérifier : aucune application en attente (baseline\a_verifier.json absent)." -ForegroundColor Yellow
    Write-Host "Pour comparer deux baselines à la main : .\scripts\Verify.ps1 -Reference baseline_<date>.json -SkipAudit"
    return
}
$refName = if ($Reference) { $Reference } else { $state.BaselineAvant }
$refPath = Join-Path $baseDir $refName
if (-not $refName -or -not (Test-Path -LiteralPath $refPath)) { throw "Baseline de référence introuvable : $refName" }
$ref = Get-Content -LiteralPath $refPath -Raw -Encoding UTF8 | ConvertFrom-Json
$applied = if ($state) { [datetime]$state.Date } else { [datetime]$ref.Date }

# Un vrai redémarrage depuis les réglages ? (Démarrage rapide désactivé : un arrêt complet compte aussi)
$lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
if ($lastBoot -lt $applied) {
    Write-Host ("Pas encore de redémarrage depuis les réglages du {0:dd/MM HH:mm} (dernier démarrage : {1:dd/MM HH:mm})." -f $applied, $lastBoot) -ForegroundColor Yellow
    Write-Host "Redémarre (Redémarrer), puis relance la vérification." -ForegroundColor Yellow
    return
}

# Nouvelle mesure
if (-not $SkipAudit) {
    Write-Host "Nouvelle mesure (audit complet, ~5 min, ne touche pas au PC)..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Audit.ps1') | Out-Null
}
$lastAudit = Get-ChildItem -Path (Get-WtPath 'reports') -Filter 'audit.json' -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -like 'audit_*' } | Sort-Object { $_.Directory.Name } | Select-Object -Last 1
if (-not $lastAudit) { throw "Aucun audit disponible." }
$now = Get-Content -LiteralPath $lastAudit.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
if ([datetime]$now.Date -lt $applied) { throw "Le dernier audit ($($now.Date)) est antérieur aux réglages : relance sans -SkipAudit." }

# Démarrage : seulement les boots postérieurs aux réglages
$bootsAfter = @($now.A_Baseline.Demarrage.Demarrages | Where-Object { [datetime]$_.Date -gt $applied })
$bootAfter = Get-WtMedian ([double[]]($bootsAfter | ForEach-Object { $_.TotalSec }))
$bootBefore = $ref.Demarrage.DemarrageMedianSec
$rb = $ref.Repos; $ra = $now.A_Baseline.Repos

function Compare-Metric([string]$Nom, $Avant, $Apres, [double]$Seuil, [string]$Unite, [string]$Note = '', [double]$SeuilPct = 0) {
    if ($null -eq $Avant -or $null -eq $Apres) {
        return [pscustomobject]@{ Mesure = $Nom; Avant = $Avant; Apres = $Apres; Ecart = $null; Unite = $Unite; Conclusion = 'non mesurable'; Note = $Note }
    }
    $d = [math]::Round([double]$Apres - [double]$Avant, 1)
    $pct = if ([double]$Avant) { [math]::Abs($d) / [double]$Avant * 100 } else { 0 }
    $significant = ([math]::Abs($d) -ge $Seuil) -and ($pct -ge $SeuilPct)
    $concl = if (-not $significant) { 'aucun gain mesurable' } elseif ($d -lt 0) { 'gain mesuré' } else { 'dégradation' }
    [pscustomobject]@{ Mesure = $Nom; Avant = $Avant; Apres = $Apres; Ecart = $d; Unite = $Unite; Conclusion = $concl; Note = $Note }
}

$bootNote = "$($bootsAfter.Count) boot(s) après réglages"
$rows = @(
    $(if ($bootsAfter.Count -lt 3) {
        [pscustomobject]@{ Mesure = 'Démarrage (médiane)'; Avant = $bootBefore; Apres = $bootAfter; Ecart = $null; Unite = 's'; Conclusion = 'trop tôt'; Note = "$bootNote : il en faut au moins 3" }
    } else { Compare-Metric 'Démarrage (médiane)' $bootBefore $bootAfter 3 's' $bootNote 5 }),
    (Compare-Metric 'RAM utilisée au repos' $rb.RamUtiliseeMo.Mediane $ra.RamUtiliseeMo.Mediane 200 'Mo'),
    (Compare-Metric 'CPU au repos' $rb.CpuPct.Mediane $ra.CpuPct.Mediane 1 '%'),
    (Compare-Metric 'Processus au repos' $rb.Processus.Mediane $ra.Processus.Mediane 3 ''),
    (Compare-Metric 'Services en cours' $rb.ServicesEnCours.Mediane $ra.ServicesEnCours.Mediane 2 '')
)
$warn = @()
if ($ref.Build -ne $now.Contexte.Build) { $warn += "Build différent ($($ref.Build) -> $($now.Contexte.Build)) : une mise à jour Windows fausse la comparaison." }
if ($rb -and -not $rb.Representatif) { $warn += 'La mesure au repos de référence n''était pas représentative.' }
if ($ra -and -not $ra.Representatif) { $warn += 'La nouvelle mesure au repos n''est pas représentative (activité pendant la mesure).' }

$gains = @($rows | Where-Object { $_.Conclusion -eq 'gain mesuré' })
$global = if ($gains.Count) { "gain mesuré sur : " + (($gains | ForEach-Object { $_.Mesure }) -join ', ') } else { 'aucun gain mesurable sur cette machine' }

$result = [pscustomobject]@{
    Date = (Get-Date).ToString('s'); Session = $(if ($state) { $state.Session }); Actions = $(if ($state) { $state.Actions })
    ReglagesLe = $applied.ToString('s'); Reference = $refName; Audit = $lastAudit.Directory.Name
    Comparaison = $rows; Avertissements = $warn; Conclusion = $global
}

Write-Host "`n=== AVANT / APRÈS ===" -ForegroundColor Green
$rows | Format-Table Mesure, Avant, Apres, Ecart, Unite, Conclusion, Note -AutoSize | Out-String -Width 200 | Write-Host
foreach ($w in $warn) { Write-Host "  ! $w" -ForegroundColor Yellow }
Write-Host "Conclusion : $global" -ForegroundColor $(if ($gains.Count) { 'Green' } else { 'Yellow' })

$out = Join-Path (Get-WtPath 'reports') ("verification_{0:yyyy-MM-dd_HHmmss}.json" -f (Get-Date))
if ($PSCmdlet.ShouldProcess($out, 'Écrire la vérification')) {
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $out -Encoding UTF8
    # La vérification n'est « close » que si le démarrage a pu être mesuré
    if ($state -and $bootsAfter.Count -ge 3) { Move-Item -LiteralPath $stateFile -Destination (Join-Path $baseDir ("verifie_{0:yyyy-MM-dd_HHmmss}.json" -f (Get-Date))) }
    & (Join-Path $PSScriptRoot 'New-AuditReport.ps1') | Out-Null
    Write-Host "Résultat : $out (et section Avant/Après du rapport HTML)" -ForegroundColor Green
}
$result
