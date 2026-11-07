<#
.SYNOPSIS
    Applique des actions du catalogue (config\actions.json). TOUJOURS simuler d'abord avec -WhatIf.
.DESCRIPTION
    Garde-fous, dans l'ordre :
      1. Profil : Prudent (vert) < Équilibré (+ orange, validées une par une) < Avancé (+ rouge, avertissement).
      2. Réglage « non vérifié » (sans source officielle) : refusé sans -IncludeUnverified.
      3. Action non automatique (admin, outil système) : commandes AFFICHÉES, jamais lancées.
      4. Service protégé (config\protected_services.json) ou clé de service protégé : refusé, même en admin.
      5. Avant chaque écriture : export .reg de la clé + valeur d'origine (type compris) dans le journal JSON.
      6. Point de restauration : proposé (commande affichée) ; le dernier point existant est indiqué.
    Sous -WhatIf : AUCUNE écriture (ni registre, ni fichier, ni dossier de session).
    Journal : logs\session_<date>\journal.json + apply.log + *.reg ; annulation : .\scripts\Undo.ps1
.EXAMPLE
    .\scripts\Apply.ps1 -Actions 4 -IncludeUnverified -Profil Equilibre -WhatIf
    .\scripts\Apply.ps1 -Actions 4 -IncludeUnverified -Profil Equilibre
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][int[]]$Actions,
    [ValidateSet('Prudent', 'Equilibre', 'Avance')][string]$Profil = 'Prudent',
    [switch]$IncludeUnverified,   # autorise les réglages marqués verifie=false
    [switch]$Force,               # pas de question par action orange/rouge (le menu a déjà demandé « OUI »)
    [string]$CatalogPath,         # catalogue alternatif (utilisé par Test-WinTune.ps1)
    [string]$LogRoot,             # dossier des sessions (défaut : logs\)
    [switch]$NoVerifyState        # n'écrit pas baseline\a_verifier.json (tests)
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$ErrorActionPreference = 'Stop'

$cat = if ($CatalogPath) { Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { Get-WtConfig 'actions' }
if (-not $LogRoot) { $LogRoot = Get-WtPath 'logs' }
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$session = "session_$stamp"
$sessDir = Join-Path $LogRoot $session
$simulation = [bool]$WhatIfPreference
$isAdmin = Test-WtAdmin
$level = Get-WtRiskLevel $Profil
$riskLevel = @{ vert = 1; orange = 2; rouge = 3 }

$journal = New-Object System.Collections.Generic.List[object]   # une entrée par valeur modifiée
$logLines = New-Object System.Collections.Generic.List[string]
function Log([string]$msg, [string]$color = 'Gray') {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    $logLines.Add($line)
    Write-Host "  $msg" -ForegroundColor $color
}
function Ensure-SessionDir { if (-not (Test-Path -LiteralPath $sessDir)) { New-Item -ItemType Directory -Force -Path $sessDir -WhatIf:$false | Out-Null } }

function Export-WtKey([string]$KeyPath) {
    # Export .reg de la clé AVANT modification (reg.exe, lecture seule sur le registre)
    if (-not (Test-Path -LiteralPath $KeyPath)) { return $null }
    Ensure-SessionDir
    $file = Join-Path $sessDir (((ConvertTo-WtRegExePath $KeyPath) -replace '[\\:\s]', '_') + '.reg')
    if (-not (Test-Path -LiteralPath $file)) {
        # Piège PS 5.1 : avec $ErrorActionPreference='Stop', le moindre texte sur stderr d'un .exe
        # redirigé par 2>&1 devient une erreur bloquante. On repasse en 'Continue' le temps de l'appel.
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $out = & reg.exe export (ConvertTo-WtRegExePath $KeyPath) $file /y 2>&1
        $code = $LASTEXITCODE; $ErrorActionPreference = $eap
        if ($code -ne 0) { throw "Export .reg impossible pour $KeyPath : $out" }
    }
    $file
}

function Set-WtServiceStartType {
    <#
        Seule fonction autorisée à changer un type de démarrage de service.
        Refuse les services protégés AVANT toute tentative (même en administrateur).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$StartType, [string]$ActionId)
    if (Test-WtProtectedService -Name $Name) { throw "REFUSÉ : le service '$Name' est protégé (config\protected_services.json)." }
    $svc = Get-Service -Name $Name -ErrorAction Stop
    $orig = [string]$svc.StartType
    if ($orig -eq $StartType) { Log "[$ActionId] service $Name déjà en $StartType"; return }
    if (-not $isAdmin) { throw "Le service '$Name' demande les droits administrateur : commande à lancer toi-même : Set-Service -Name $Name -StartupType $StartType" }
    if ($PSCmdlet.ShouldProcess("service $Name", "type de démarrage $orig -> $StartType")) {
        $journal.Add([pscustomobject]@{ Action = $ActionId; Type = 'service'; Nom = $Name; Origine = $orig; Nouveau = $StartType; Date = (Get-Date).ToString('s'); Annule = $false })
        Set-Service -Name $Name -StartupType $StartType
        Log "[$ActionId] service $Name : $orig -> $StartType" 'Green'
    }
}

function Set-WtRegistryValue {
    # Écrit une valeur après export .reg et sauvegarde de l'état d'origine dans le journal.
    param($Entry, [string]$ActionId)
    $path = $Entry.chemin
    if (Test-WtProtectedRegistryPath -Path $path) { throw "REFUSÉ : $path est la configuration d'un service protégé." }
    if ($path -match '^HKLM:' -and -not $isAdmin) { throw "$path demande les droits administrateur (action à lancer depuis un PowerShell admin)." }

    $keyExists = Test-Path -LiteralPath $path
    $exists = $false; $origVal = $null; $origKind = $null
    if ($keyExists) {
        $key = Get-Item -LiteralPath $path
        if ($key.GetValueNames() -contains $Entry.nom) {
            $exists = $true
            $origVal = $key.GetValue($Entry.nom, $null, 'DoNotExpandEnvironmentNames')
            $origKind = [string]$key.GetValueKind($Entry.nom)
        }
    }
    if ($exists -and [string]$origVal -eq [string]$Entry.valeur -and $origKind -eq $Entry.type) {
        Log "[$ActionId] $path\$($Entry.nom) déjà à $($Entry.valeur) : rien à faire"
        return
    }
    $avant = if ($exists) { "$origVal ($origKind)" } else { 'absente' }
    if ($PSCmdlet.ShouldProcess("$path\$($Entry.nom)", "valeur $avant -> $($Entry.valeur) ($($Entry.type))")) {
        $regFile = Export-WtKey $path
        # Le journal est écrit AVANT la modification : une coupure ne rend rien irrécupérable
        $journal.Add([pscustomobject]@{
            Action = $ActionId; Type = 'registre'; Chemin = $path; Nom = $Entry.nom
            CleExistait = $keyExists; ValeurExistait = $exists; ValeurOrigine = $origVal; TypeOrigine = $origKind
            Nouveau = $Entry.valeur; TypeNouveau = $Entry.type; ExportReg = $regFile; Date = (Get-Date).ToString('s'); Annule = $false
        })
        Save-Journal
        if (-not $keyExists) { New-Item -Path $path -Force | Out-Null }
        New-ItemProperty -LiteralPath $path -Name $Entry.nom -PropertyType $Entry.type -Value $Entry.valeur -Force | Out-Null
        Log "[$ActionId] $path\$($Entry.nom) : $avant -> $($Entry.valeur)" 'Green'
    }
}

function Save-Journal {
    if ($simulation -or $journal.Count -eq 0) { return }
    Ensure-SessionDir
    # -InputObject @(...) : un journal d'UNE seule entrée reste un tableau JSON [ ... ]
    ConvertTo-Json -InputObject @($journal.ToArray()) -Depth 5 | Set-Content -LiteralPath (Join-Path $sessDir 'journal.json') -Encoding UTF8 -WhatIf:$false
}

# ---------------------------------------------------------------------------------------------
Write-Host ("`nwin-tune : application ({0}) - profil {1}{2}" -f $(if ($simulation) { 'SIMULATION, rien ne sera modifié' } else { 'RÉEL' }), $Profil, $(if ($isAdmin) { ', administrateur' } else { '' })) -ForegroundColor $(if ($simulation) { 'Cyan' } else { 'Yellow' })

# Point de restauration : proposé, jamais imposé. Le dernier est lisible sans admin (Application, ID 8194).
if (-not $CatalogPath) {
    $rp = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 8194 } -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($rp) { Write-Host ("  Dernier point de restauration : {0:dd/MM/yyyy HH:mm}" -f $rp.TimeCreated) -ForegroundColor Gray }
    else { Write-Host "  Aucun point de restauration trouvé dans le journal Application (journal vidé par une mise à jour ?). Liste exacte (admin) : Get-ComputerRestorePoint" -ForegroundColor Yellow }
    Write-Host "  Point de restauration (PowerShell admin, max 1 par 24 h) : Checkpoint-Computer -Description 'Avant win-tune' -RestorePointType MODIFY_SETTINGS" -ForegroundColor Gray
}
if ($Profil -eq 'Avance') { Write-Host "  AVERTISSEMENT : profil Avancé = réglages ROUGES possibles (système sensible). À n'utiliser qu'en connaissance de cause." -ForegroundColor Red }

$done = 0; $skipped = 0; $manual = 0
foreach ($n in $Actions) {
    $act = @($cat.actions | Where-Object { $_.num -eq $n }) | Select-Object -First 1
    if (-not $act) { Log "[$n] action inconnue" 'Red'; $skipped++; continue }
    $id = $act.id
    Write-Host "`n[$n] $($act.titre)  ($($act.classement), risque $($act.risque))" -ForegroundColor White

    # 1. Profil et risque
    if ((Get-WtRiskLevel $act.profil) -gt $level -or $riskLevel[$act.risque] -gt $level) {
        Log "[$id] ignorée : demande le profil '$($act.profil)' / risque $($act.risque) (profil choisi : $Profil)" 'Yellow'; $skipped++; continue
    }
    # 2. Source officielle
    if (-not $act.verifie -and -not $IncludeUnverified) {
        Log "[$id] ignorée : NON VÉRIFIÉE (pas de source officielle). Ajoute -IncludeUnverified si tu l'acceptes en connaissance de cause." 'Yellow'; $skipped++; continue
    }
    # 3. Action manuelle / admin : on affiche, on ne lance pas
    if (-not $act.auto) {
        Log "[$id] action manuelle ou admin : commandes à lancer toi-même :" 'Cyan'
        # <logs> est remplacé par le vrai dossier pour que la commande soit copiable telle quelle
        foreach ($c in @($act.commandes)) { Write-Host ("      " + ($c -replace '<logs>', $LogRoot)) }
        Write-Host "      Annulation : $($act.annulation)" -ForegroundColor Gray
        $manual++; continue
    }
    # Validation une par une des actions orange/rouges (sauf -Force : le menu a déjà demandé)
    if ($act.risque -ne 'vert' -and -not $Force -and -not $simulation) {
        if (-not $PSCmdlet.ShouldContinue("$($act.titre) - $($act.risqueDetail)", "Action $($act.risque) : confirmer ?")) { Log "[$id] refusée par l'utilisateur" 'Yellow'; $skipped++; continue }
    }
    try {
        foreach ($r in @($act.registre)) { if ($r) { Set-WtRegistryValue -Entry $r -ActionId $id } }
        foreach ($s in @($act.services)) { if ($s) { Set-WtServiceStartType -Name $s.nom -StartType $s.demarrage -ActionId $id } }
        if ($id -eq 'appx-safe') {
            # Retrait d'applis pour l'utilisateur courant uniquement (jamais -AllUsers)
            $cfg = Get-WtConfig 'appx_candidates'
            foreach ($c in $cfg.sansRisque) {
                foreach ($p in @(Get-AppxPackage -Name $c.name -ErrorAction SilentlyContinue)) {
                    if ($PSCmdlet.ShouldProcess($p.Name, 'Remove-AppxPackage (utilisateur courant)')) {
                        $journal.Add([pscustomobject]@{ Action = $id; Type = 'appx'; Nom = $p.Name; Paquet = $p.PackageFullName; Titre = $c.titre; Date = (Get-Date).ToString('s'); Annule = $false })
                        Save-Journal
                        Remove-AppxPackage -Package $p.PackageFullName
                        Log "[$id] retirée : $($c.titre) ($($p.Name))" 'Green'
                    }
                }
            }
        }
        $done++
    } catch {
        Log "[$id] ÉCHEC / REFUS : $($_.Exception.Message)" 'Red'
        $skipped++
    }
}

# Fin : journal, log, état « à vérifier après redémarrage »
if (-not $simulation -and $journal.Count) {
    Save-Journal
    $logLines | Set-Content -LiteralPath (Join-Path $sessDir 'apply.log') -Encoding UTF8
    if (-not $NoVerifyState) {
        $base = Get-ChildItem -Path (Get-WtPath 'baseline') -Filter 'baseline_*.json' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
        New-Item -ItemType Directory -Force -Path (Get-WtPath 'baseline') | Out-Null
        [pscustomobject]@{ Session = $session; Date = (Get-Date).ToString('s'); Actions = @($journal | ForEach-Object { $_.Action } | Sort-Object -Unique); BaselineAvant = $(if ($base) { $base.Name }); Etat = 'à vérifier après redémarrage' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Get-WtPath 'baseline') 'a_verifier.json') -Encoding UTF8
    }
    Write-Host "`nSession : $sessDir" -ForegroundColor Green
    Write-Host "Annuler : .\scripts\Undo.ps1 -Session $session" -ForegroundColor Green
    Write-Host "Ensuite : REDÉMARRE (Redémarrer), puis menu 6 / .\scripts\Verify.ps1" -ForegroundColor Green
} elseif ($simulation) {
    Write-Host "`nSimulation terminée : rien n'a été modifié. Relance sans -WhatIf pour appliquer." -ForegroundColor Cyan
}
Write-Host ("Bilan : {0} {3}, {1} manuelle(s) affichée(s), {2} ignorée(s)/refusée(s)" -f $done, $manual, $skipped, $(if ($simulation) { 'simulée(s)' } else { 'appliquée(s)' }))
# Valeur de sortie utile aux tests
[pscustomobject]@{ Session = $(if ($journal.Count -and -not $simulation) { $session }); SessionDir = $sessDir; Appliquees = $done; Manuelles = $manual; Ignorees = $skipped; Journal = $journal.ToArray() }
