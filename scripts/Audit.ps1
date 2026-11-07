<#
.SYNOPSIS
    Audit win-tune : LECTURE SEULE. Mesure le système avant toute optimisation.
.DESCRIPTION
    Phase 0 (contexte) + Phase 1 (sections A à I). N'écrit QUE dans :
      reports\audit_<date>\audit.json + audit.log
      baseline\baseline_<date>.json
    Aucune commande d'écriture registre / service / tâche dans ce fichier : vérifiable avec
      Select-String -Path .\scripts\Audit.ps1 -Pattern 'Set-ItemProperty|New-ItemProperty|Remove-Item|Set-Service|Stop-Service|Disable-|Enable-|reg add|reg delete'
    Ce qui demande l'admin n'est PAS lancé : la commande est mise dans "CommandesAdmin".
.EXAMPLE
    .\scripts\Audit.ps1 -WhatIf          # montre ce qui serait écrit, n'écrit rien
    .\scripts\Audit.ps1                  # audit complet (attend 3 min d'inactivité pour la mesure au repos)
    .\scripts\Audit.ps1 -SkipIdleSample  # sans la mesure au repos (rapide)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$BootCount = 10,          # nombre de démarrages analysés
    [int]$Days = 30,               # fenêtre pour la stabilité et les mises à jour
    [int]$IdleRequiredSec = 180,   # inactivité exigée avant la mesure au repos
    [int]$IdleMaxWaitMinutes = 10, # attente maximale de cette inactivité
    [int]$SampleSeconds = 60,      # durée de l'échantillon au repos
    [switch]$SkipIdleSample,
    [string]$ReportsDir,           # défaut : reports\  (Test-WinTune.ps1 passe un dossier temporaire)
    [string]$BaselineDir           # défaut : baseline\
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$since = (Get-Date).AddDays(-$Days)
$constats = New-Object System.Collections.Generic.List[object]   # { Niveau, Section, Texte }
$adminCmds = New-Object System.Collections.Generic.List[object]  # { Pourquoi, Commande }
function Add-Constat([string]$Niveau, [string]$Section, [string]$Texte) {
    $constats.Add([pscustomobject]@{ Niveau = $Niveau; Section = $Section; Texte = $Texte })
}
function Add-AdminCmd([string]$Pourquoi, [string]$Commande) {
    $adminCmds.Add([pscustomobject]@{ Pourquoi = $Pourquoi; Commande = $Commande })
}
function Step([string]$t) { Write-Host "  - $t" -ForegroundColor Cyan }
$isAdmin = Test-WtAdmin

Write-Host "`nwin-tune : audit en lecture seule ($stamp)" -ForegroundColor Green
if ($isAdmin) { Write-Host "  (session administrateur : lectures complètes, toujours AUCUNE modification)" -ForegroundColor Yellow }

# =====================================================================================
# PHASE 0 - CONTEXTE
# =====================================================================================
Step 'Phase 0 : contexte'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$chassis = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)
# Types de châssis portables (SMBIOS) : 8-14, 30-32 ; + présence d'une batterie
$isLaptop = [bool](Get-CimInstance Win32_Battery) -or [bool]($chassis | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 30, 31, 32 })
$uptime = (Get-Date) - $os.LastBootUpTime
$hiberboot = Get-WtRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'

$life = Get-WtConfig 'windows_lifecycle'
$ver = $life.versions | Where-Object { $_.version -eq $cv.DisplayVersion } | Select-Object -First 1
$support = if ($ver) {
    $fin = [datetime]$ver.fin
    [pscustomobject]@{ Version = $ver.version; FinSupport = $ver.fin; JoursRestants = [int]($fin - (Get-Date)).TotalDays; Source = $life.source; VerifieLe = $life.verifieLe }
} else { [pscustomobject]@{ Version = $cv.DisplayVersion; FinSupport = $null; JoursRestants = $null; Source = $life.source; VerifieLe = $life.verifieLe } }
if ($support.JoursRestants -ne $null -and $support.JoursRestants -lt 0) { Add-Constat 'critique' 'Contexte' "Windows $($cv.DisplayVersion) n'est plus supporté depuis le $($support.FinSupport) : plus de correctifs de sécurité." }
elseif ($support.JoursRestants -ne $null -and $support.JoursRestants -lt 120) { Add-Constat 'attention' 'Contexte' "Fin de support de Windows $($cv.DisplayVersion) dans $($support.JoursRestants) jours ($($support.FinSupport))." }
elseif (-not $ver) { Add-Constat 'attention' 'Contexte' "Version $($cv.DisplayVersion) absente de config\windows_lifecycle.json : statut de support à vérifier." }

# Disques : type réel par lecteur (un espace de stockage est suivi jusqu'à ses disques physiques)
$phys = @(Get-PhysicalDisk)
$volumes = foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })) {
    $media = $null; $bus = $null; $modele = $null
    try {
        $disk = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop
        $bus = [string]$disk.BusType
        $pd = if ($disk.BusType -eq 'Spaces') {
            @(Get-VirtualDisk -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $disk.FriendlyName } | Get-PhysicalDisk -ErrorAction SilentlyContinue)
        } else { @($phys | Where-Object { $_.DeviceId -eq [string]$disk.Number }) }
        if ($pd) { $media = (@($pd | ForEach-Object { [string]$_.MediaType }) | Sort-Object -Unique) -join '+'; $modele = (@($pd | ForEach-Object { $_.FriendlyName }) | Sort-Object -Unique) -join ' + ' }
    } catch { }
    [pscustomobject]@{
        Lecteur = "$($v.DriveLetter):"; Nom = $v.FileSystemLabel; Fs = $v.FileSystem
        TailleGo = ConvertTo-Go $v.Size; LibreGo = ConvertTo-Go $v.SizeRemaining
        Support = $media; Bus = $bus; Modele = $modele; Sante = [string]$v.HealthStatus
    }
}

$contexte = [ordered]@{
    Edition      = $os.Caption
    EditionID    = $cv.EditionID
    Version      = $cv.DisplayVersion
    Build        = "$($cv.CurrentBuild).$($cv.UBR)"
    Support      = $support
    Type         = if ($isLaptop) { 'Portable' } else { 'Fixe' }
    Processeur   = $cpu.Name.Trim()
    Coeurs       = $cpu.NumberOfCores
    Threads      = $cpu.NumberOfLogicalProcessors
    RamGo        = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    Gpu          = @(Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name })
    DisquesPhysiques = @($phys | ForEach-Object { [pscustomobject]@{ Modele = $_.FriendlyName; Support = [string]$_.MediaType; Bus = [string]$_.BusType; TailleGo = [math]::Round($_.Size / 1GB); Sante = [string]$_.HealthStatus } })
    Volumes      = @($volumes)
    DernierBoot  = $os.LastBootUpTime.ToString('s')
    UptimeHeures = [math]::Round($uptime.TotalHours, 1)
    Admin        = $isAdmin
}
if ($uptime.TotalDays -gt 7) {
    $t = "Uptime de $([math]::Round($uptime.TotalDays,1)) jours."
    if ($hiberboot -eq 1) { $t += " Avec le Démarrage rapide actif, « Arrêter » n'est PAS un vrai redémarrage (le noyau est mis en veille prolongée) : utilise « Redémarrer »." }
    Add-Constat 'attention' 'Contexte' $t
}

# =====================================================================================
# A. BASELINE MESURÉE
# =====================================================================================
Step 'A. Durées de démarrage / arrêt'
$boot = Get-WtBootEvents
# Seuls les démarrages du build ACTUEL sont comparables : une mise à jour majeure ou une réparation
# change les pilotes et les services. InstallDate est remise à jour par ces installations sur place.
$buildSince = $os.InstallDate
$bootRes = [ordered]@{ Source = $boot.Source; BuildDepuis = $buildSince.ToString('s'); Demarrages = @(); Arrets = @(); Ralentisseurs = @(); Approximation = @(); IgnoresAncienBuild = 0 }
if ($boot.Source -and $boot.Source -like 'export*') {
    $expTime = (Get-Item -LiteralPath (Join-Path (Get-WtPath 'baseline') $script:WtBootExport)).LastWriteTime
    if ($expTime -lt $os.LastBootUpTime) {
        Add-Constat 'attention' 'A' ("Export admin des temps de boot périmé ({0:dd/MM HH:mm}, avant le dernier démarrage) : relance la commande admin pour inclure les boots récents." -f $expTime)
        Add-AdminCmd 'Mettre à jour l''export des temps de démarrage/arrêt (lecture seule)' (Get-WtBootExportCommand)
    }
}
if ($boot.Source) {
    $bootRes.IgnoresAncienBuild = @($boot.Events | Where-Object { $_.Id -eq 100 -and $_.Time -lt $buildSince }).Count
    $b100 = @($boot.Events | Where-Object { $_.Id -eq 100 -and $_.Time -ge $buildSince } | Sort-Object Time -Descending | Select-Object -First $BootCount)
    $bootRes.Demarrages = @($b100 | ForEach-Object {
        [pscustomobject]@{
            Date = $_.Time.ToString('s')
            TotalSec = [math]::Round([double]$_.Data['BootTime'] / 1000, 1)            # du logo Windows au bureau utilisable
            CheminPrincipalSec = [math]::Round([double]$_.Data['MainPathBootTime'] / 1000, 1)  # logo -> écran de connexion
            ApresConnexionSec = [math]::Round([double]$_.Data['BootPostBootTime'] / 1000, 1)   # connexion -> CPU au repos
            # UserLogonWaitDuration = attente de la saisie du mot de passe/PIN. Information seulement :
            # sur cette machine elle DÉPASSE parfois BootTime (ex. 87,7 s pour 60,9 s), elle n'y est donc
            # pas simplement incluse. Soustraire les deux donnait des durées négatives : ne pas le faire.
            AttenteMotDePasseSec = [math]::Round([double]$_.Data['UserLogonWaitDuration'] / 1000, 1)
            PilotesSec = [math]::Round([double]$_.Data['BootDriverInitTime'] / 1000, 1)
            ExplorerSec = [math]::Round([double]$_.Data['BootExplorerInitTime'] / 1000, 1)
            AppsDemarrage = [int]$_.Data['BootNumStartupApps']
            Degrade = ($_.Data['BootIsDegradation'] -eq 'true')
        } })
    $bootRes.Arrets = @($boot.Events | Where-Object { $_.Id -eq 200 -and $_.Time -ge $buildSince } | Sort-Object Time -Descending | Select-Object -First $BootCount | ForEach-Object {
        [pscustomobject]@{ Date = $_.Time.ToString('s'); TotalSec = [math]::Round([double]$_.Data['ShutdownTime'] / 1000, 1) } })
    # 101 appli / 102 pilote / 103 service : seulement sur la période des démarrages retenus
    $oldest = if ($b100) { ($b100 | Select-Object -Last 1).Time.AddMinutes(-1) } else { $buildSince }
    $kind = @{ 101 = 'Application'; 102 = 'Pilote'; 103 = 'Service' }
    $bootRes.Ralentisseurs = @($boot.Events | Where-Object { $_.Id -in 101, 102, 103 -and $_.Time -ge $oldest } |
        Group-Object { "$($_.Id)|$($_.Data['Name'])" } | ForEach-Object {
            $f = $_.Group[0]
            [pscustomobject]@{
                Type = $kind[$f.Id]; Nom = $f.Data['Name']; Description = $f.Data['FriendlyName']; Occurrences = $_.Count
                RetardMaxSec = [math]::Round((($_.Group | ForEach-Object { [double]$_.Data['DegradationTime'] }) | Measure-Object -Maximum).Maximum / 1000, 1)
            } } | Sort-Object RetardMaxSec -Descending)
} else {
    Add-Constat 'info' 'A' "Durées de boot exactes : journal Diagnostics-Performance réservé aux administrateurs. Lance la commande admin affichée, puis relance l'audit."
    Add-AdminCmd 'Exporter les temps de démarrage/arrêt (journal Diagnostics-Performance, lecture seule) vers baseline\' (Get-WtBootExportCommand)
}
$bootRes.Approximation = @(Get-WtBootProxy -Count $BootCount | Where-Object { [datetime]$_.Boot -ge $buildSince })
$nbBootsBuild = @($bootRes.Demarrages).Count
if ($boot.Source -and $nbBootsBuild -lt 5) {
    Add-Constat 'attention' 'A' ("Seulement $nbBootsBuild démarrage(s) mesuré(s) depuis l'installation du build actuel ({0:dd/MM/yyyy HH:mm}). La médiane de boot n'est fiable qu'à partir d'environ 5 démarrages : redémarre normalement quelques fois, réexporte, puis relance l'audit." -f $buildSince)
}
$bootMed = Get-WtMedian ([double[]]($bootRes.Demarrages | ForEach-Object { $_.TotalSec }))
$shutMed = Get-WtMedian ([double[]]($bootRes.Arrets | ForEach-Object { $_.TotalSec }))
$proxyMed = Get-WtMedian ([double[]]($bootRes.Approximation | ForEach-Object { $_.Secondes }))
$bootRes.Synthese = [pscustomobject]@{
    NbDemarrages = @($bootRes.Demarrages).Count
    DemarrageMedianSec = $bootMed
    DemarragePireSec = ($bootRes.Demarrages | Measure-Object TotalSec -Maximum).Maximum
    CheminPrincipalMedianSec = Get-WtMedian ([double[]]($bootRes.Demarrages | ForEach-Object { $_.CheminPrincipalSec }))
    ApresConnexionMedianSec = Get-WtMedian ([double[]]($bootRes.Demarrages | ForEach-Object { $_.ApresConnexionSec }))
    PilotesMedianSec = Get-WtMedian ([double[]]($bootRes.Demarrages | ForEach-Object { $_.PilotesSec }))
    NbArrets = @($bootRes.Arrets).Count
    ArretMedianSec = $shutMed
    ArretPireSec = ($bootRes.Arrets | Measure-Object TotalSec -Maximum).Maximum
    ApproxNoyauSessionMedianSec = $proxyMed
}

$repos = $null
if (-not $SkipIdleSample) {
    Step "A. Mesure au repos : $IdleRequiredSec s d'inactivité puis $SampleSeconds s d'échantillon (ne touche plus au PC)"
    $repos = Get-WtIdleSample -IdleRequiredSec $IdleRequiredSec -MaxWaitMinutes $IdleMaxWaitMinutes -DurationSec $SampleSeconds
    if (-not $repos.Representatif) { Add-Constat 'attention' 'A' "Mesure au repos NON représentative (activité clavier/souris pendant l'attente ou l'échantillon). À refaire." }
}
# Processus les plus gourmands en RAM au moment de l'audit (noms seulement, aucun chemin)
$topRam = @(Get-Process | Group-Object ProcessName | ForEach-Object {
        [pscustomobject]@{ Nom = $_.Name; Instances = $_.Count; RamMo = ConvertTo-Mo (($_.Group | Measure-Object WorkingSet64 -Sum).Sum) } } |
    Sort-Object RamMo -Descending | Select-Object -First 15)

# =====================================================================================
# B. DÉMARRAGE / ARRÊT
# =====================================================================================
Step 'B. Démarrage rapide, hibernation, redémarrage en attente'
$pwr = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$hiberSize = $null
try { $hiberSize = ConvertTo-Go (Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction Stop).Length } catch { }
$pfro = Get-WtRegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'
$pending = [ordered]@{
    WindowsUpdate = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    Composants    = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    RenommagesFichiers = [bool]$pfro   # souvent des installeurs : signal faible seul
}
$demarrage = [ordered]@{
    DemarrageRapide = switch ($hiberboot) { 1 { 'actif' } 0 { 'désactivé' } default { 'inconnu' } }
    Hibernation     = switch (Get-WtRegValue $pwr 'HibernateEnabled') { 1 { 'active' } 0 { 'désactivée' } default { 'inconnue' } }
    HiberfilGo      = $hiberSize
    RedemarrageEnAttente = $pending
}
if ($pending.WindowsUpdate -or $pending.Composants) { Add-Constat 'attention' 'B' "Un redémarrage est en attente (mise à jour / composants) : redémarre AVANT de mesurer." }

# =====================================================================================
# C. ARRIÈRE-PLAN ET BRUIT WINDOWS
# =====================================================================================
Step 'C. Arrière-plan, Widgets, Copilot, recherche web, suggestions, Appx'
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$bgRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
$bgApps = @(Get-ChildItem -LiteralPath $bgRoot -ErrorAction SilentlyContinue)
$bgDisabled = @($bgApps | Where-Object { (Get-WtRegValue $_.PSPath 'Disabled') -eq 1 }).Count
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$cdmVals = [ordered]@{}
$cdmProps = Get-ItemProperty -LiteralPath $cdm -ErrorAction SilentlyContinue
if ($cdmProps) {
    foreach ($p in $cdmProps.PSObject.Properties) {
        if ($p.Name -match '^(SubscribedContent-\d+Enabled|SystemPaneSuggestionsEnabled|SilentInstalledAppsEnabled|SoftLandingEnabled|PreInstalledAppsEnabled|OemPreInstalledAppsEnabled|RotatingLockScreenOverlayEnabled|ContentDeliveryAllowed)$') { $cdmVals[$p.Name] = $p.Value }
    }
}
# RAM des processus liés (mesure réelle, pas une estimation)
function Get-ProcRamMo([string[]]$Names) { ConvertTo-Mo ((Get-Process -Name $Names -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum) }
$appx = @(Get-AppxPackage -ErrorAction SilentlyContinue)
$appxCfg = Get-WtConfig 'appx_candidates'
$appxSafe = @(foreach ($c in $appxCfg.sansRisque) { $appx | Where-Object { $_.Name -like $c.name } | ForEach-Object { [pscustomobject]@{ Nom = $_.Name; Titre = $c.titre; Version = [string]$_.Version } } })
$appxAvoid = @(foreach ($c in $appxCfg.aEviter) { $appx | Where-Object { $_.Name -like $c.name } | ForEach-Object { [pscustomobject]@{ Nom = $_.Name; Raison = $c.raison } } })
$bingSearch = Get-WtRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled'
$searchPol = Get-WtRegValue 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions'
$arrierePlan = [ordered]@{
    ApplisArrierePlan = [ordered]@{
        GlobalementCoupe = ((Get-WtRegValue $bgRoot 'GlobalUserDisabled') -eq 1)
        StrategieLetAppsRunInBackground = Get-WtRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground'
        NbApplisConnues = $bgApps.Count; NbApplisCoupees = $bgDisabled
    }
    Widgets = [ordered]@{
        BoutonBarreDesTaches = switch (Get-WtRegValue $adv 'TaskbarDa') { 0 { 'masqué' } 1 { 'affiché' } default { 'affiché (valeur par défaut)' } }
        Installe = [bool]($appx | Where-Object { $_.Name -eq 'MicrosoftWindows.Client.WebExperience' })
        StrategieAllowNewsAndInterests = Get-WtRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests'
        RamMo = Get-ProcRamMo 'Widgets', 'WidgetService'
    }
    Copilot = [ordered]@{
        AppliInstallee = [bool]($appx | Where-Object { $_.Name -like 'Microsoft.Copilot*' })
        StrategieTurnOffWindowsCopilot = Get-WtRegValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'
        RamMo = Get-ProcRamMo 'Copilot', 'ms-copilot'
    }
    RechercheWebMenuDemarrer = [ordered]@{
        BingSearchEnabled = $bingSearch
        StrategieDisableSearchBoxSuggestions = $searchPol
        Etat = if ($searchPol -eq 1 -or $bingSearch -eq 0) { 'désactivée' } else { 'active (par défaut)' }
        RamMoSearchHost = Get-ProcRamMo 'SearchHost'
    }
    Suggestions = [ordered]@{ ContentDeliveryManager = $cdmVals; NbActives = @($cdmVals.Values | Where-Object { $_ -eq 1 }).Count; NbValeurs = $cdmVals.Count }
    Appx = [ordered]@{ NbInstallees = $appx.Count; CandidatesSansRisque = $appxSafe; PresentesAEviter = $appxAvoid }
}
Add-AdminCmd 'Lister les applis provisionnées (réinstallées pour chaque nouveau compte)' 'Get-AppxProvisionedPackage -Online | Select-Object DisplayName, Version | Sort-Object DisplayName'

# =====================================================================================
# D. MÉMOIRE ET STOCKAGE (côté système)
# =====================================================================================
Step 'D. TRIM, optimisation de disque, Windows Search, SysMain, compression mémoire, fichier d''échange'
$trim = @(fsutil behavior query DisableDeleteNotify 2>$null)
$trimOk = [bool]($trim | Where-Object { $_ -match 'NTFS\s+DisableDeleteNotify\s*=\s*0' })
$defragTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
$defragInfo = if ($defragTask) { Get-ScheduledTaskInfo -InputObject $defragTask -ErrorAction SilentlyContinue }
# Historique de l'Optimiseur de stockage (Application, ID 258 = opération réussie)
$defragHist = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Defrag'; StartTime = (Get-Date).AddDays(-60) } -ErrorAction SilentlyContinue |
    Select-Object -First 40 | ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated.ToString('s'); Id = $_.Id; Message = ($_.Message -replace '\s+', ' ') } })
$searchSvc = Get-Service WSearch -ErrorAction SilentlyContinue
$sysmain = Get-Service SysMain -ErrorAction SilentlyContinue
$indexRules = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex\WorkingSetRules' -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath } | Where-Object { $_.Include -eq 1 -and $_.URL -like 'file:*' } |
    ForEach-Object { ($_.URL -replace '^file:///', '' -replace '\[[0-9a-f\-]+\]\\', '') } | Sort-Object -Unique)
$indexSize = $null
foreach ($f in 'Windows.db', 'Windows.edb') {
    $p = Join-Path $env:ProgramData "Microsoft\Search\Data\Applications\Windows\$f"
    try { $indexSize = ConvertTo-Go (Get-Item -LiteralPath $p -Force -ErrorAction Stop).Length; break } catch { }
}
$mm = $null
try { $mm = Get-MMAgent -ErrorAction Stop | Select-Object MemoryCompression, PageCombining, ApplicationPreLaunch, ApplicationLaunchPrefetching } catch {
    Add-AdminCmd 'État exact de la compression mémoire / prélancement (lecture seule)' 'Get-MMAgent'
}
$memComp = Get-Process -Name 'Memory Compression' -ErrorAction SilentlyContinue
$pfSet = @(Get-CimInstance Win32_PageFileSetting | ForEach-Object { [pscustomobject]@{ Fichier = $_.Name; InitialMo = $_.InitialSize; MaxMo = $_.MaximumSize; Gestion = if ($_.InitialSize -eq 0 -and $_.MaximumSize -eq 0) { 'gérée par le système' } else { 'taille fixe' } } })
$pfUse = @(Get-CimInstance Win32_PageFileUsage | ForEach-Object { [pscustomobject]@{ Fichier = $_.Name; AlloueMo = $_.AllocatedBaseSize; UtiliseMo = $_.CurrentUsage; PicMo = $_.PeakUsage } })
$memoire = [ordered]@{
    Trim = [ordered]@{ Actif = $trimOk; Sortie = $trim }
    OptimisationPlanifiee = [ordered]@{
        Tache = if ($defragTask) { [string]$defragTask.State } else { 'absente' }
        DerniereExecution = if ($defragInfo) { $defragInfo.LastRunTime.ToString('s') } else { $null }
        Historique60j = $defragHist
    }
    WindowsSearch = [ordered]@{ Etat = [string]$searchSvc.Status; Demarrage = [string]$searchSvc.StartType; EmplacementsIndexes = $indexRules; TailleIndexGo = $indexSize; RamMoIndexeur = Get-ProcRamMo 'SearchIndexer' }
    SysMain = [ordered]@{ Etat = [string]$sysmain.Status; Demarrage = [string]$sysmain.StartType }
    CompressionMemoire = [ordered]@{ MMAgent = $mm; ProcessusPresent = [bool]$memComp; RamMo = if ($memComp) { ConvertTo-Mo $memComp.WorkingSet64 } else { $null } }
    FichierEchange = [ordered]@{ GestionAutomatiqueGlobale = [bool]$cs.AutomaticManagedPagefile; Reglages = $pfSet; Utilisation = $pfUse }
}
if (-not $trimOk) { Add-Constat 'attention' 'D' "TRIM désactivé (DisableDeleteNotify=1) alors que la machine a des SSD." }
if ($defragTask -and [string]$defragTask.State -eq 'Disabled') { Add-Constat 'attention' 'D' "Tâche ScheduledDefrag désactivée : les SSD ne reçoivent plus de retrim régulier." }
if (-not $cs.AutomaticManagedPagefile) {
    $fixed = @($pfSet | Where-Object { $_.Gestion -eq 'taille fixe' } | ForEach-Object { "$($_.Fichier) ($($_.InitialMo)-$($_.MaxMo) Mo)" })
    if ($fixed) { Add-Constat 'attention' 'D' ("Fichier d'échange en taille fixe : " + ($fixed -join ', ') + ". La règle du projet est de le laisser géré par Windows.") }
}

# =====================================================================================
# E. INTERFACE
# =====================================================================================
Step 'E. Effets visuels, transparence, animations'
$vfx = Get-WtRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting'
$interface = [ordered]@{
    EffetsVisuels = switch ($vfx) { 0 { 'laisser Windows choisir' } 1 { 'meilleure apparence' } 2 { 'meilleures performances' } 3 { 'personnalisé' } default { 'laisser Windows choisir (par défaut)' } }
    VisualFXSetting = $vfx
    Transparence = switch (Get-WtRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency') { 0 { 'désactivée' } default { 'active' } }
    AnimationsFenetres = switch (Get-WtRegValue 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate') { '0' { 'désactivées' } default { 'actives' } }
    EstimationGain = if ($contexte.RamGo -ge 16 -and $contexte.Threads -ge 8) { 'placebo : CPU/GPU/RAM largement suffisants, les effets sont rendus par le GPU (DWM)' } elseif ($contexte.RamGo -le 4) { 'gain marginal possible : machine modeste' } else { 'gain marginal' }
}

# =====================================================================================
# F. MISES À JOUR
# =====================================================================================
Step 'F. Heures d''activité, redémarrages forcés, échecs de mise à jour'
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$wuFails = @(); $wuOk = 0
try {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $n = $searcher.GetTotalHistoryCount()
    $hist = @($searcher.QueryHistory(0, [math]::Min($n, 150)) | Where-Object { $_.Date -ge $since.ToUniversalTime() })
    $wuOk = @($hist | Where-Object { $_.ResultCode -eq 2 }).Count
    $wuFails = @($hist | Where-Object { $_.ResultCode -in 4, 5 } | ForEach-Object { [pscustomobject]@{ Date = $_.Date.ToLocalTime().ToString('s'); Titre = $_.Title; Code = ('0x{0:X8}' -f $_.HResult) } })
} catch { }
# Événement 1074 (User32) : qui a déclenché un arrêt/redémarrage
$reboots = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'User32'; Id = 1074; StartTime = $since } -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ Date = $_.TimeCreated.ToString('s'); Processus = (Split-Path ([string]$_.Properties[0].Value) -Leaf) -replace '\s*\(.*$', ''; Type = [string]$_.Properties[4].Value } })
$forced = @($reboots | Where-Object { $_.Processus -match 'MoUsoCoreWorker|TiWorker|TrustedInstaller|usoclient|wuauclt' })
$majs = [ordered]@{
    HeuresActivite = "{0}h - {1}h" -f (Get-WtRegValue $ux 'ActiveHoursStart'), (Get-WtRegValue $ux 'ActiveHoursEnd')
    HeuresActiviteAuto = Get-WtRegValue $ux 'SmartActiveHoursState'
    InstalleesOk = $wuOk
    Echecs = $wuFails
    RedemarragesParWindowsUpdate = $forced.Count
    ArretsRedemarrages = $reboots
}
if ($wuFails.Count) { Add-Constat 'attention' 'F' "$($wuFails.Count) mise(s) à jour en échec sur $Days jours." }
# Niveau de correctifs réel : dernière mise à jour de sécurité installée (Get-HotFix, lecture seule)
$lastSec = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.Description -match 'Security' -and $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
$majs.DerniereMajSecurite = if ($lastSec) { [pscustomobject]@{ KB = $lastSec.HotFixID; Date = $lastSec.InstalledOn.ToString('yyyy-MM-dd'); Jours = [int]((Get-Date) - $lastSec.InstalledOn).TotalDays } }
if ($lastSec -and ((Get-Date) - $lastSec.InstalledOn).TotalDays -gt 45) {
    Add-Constat 'critique' 'F' ("Dernière mise à jour de sécurité installée : {0} le {1:dd/MM/yyyy} (il y a {2} jours ; build {3}). Windows n'est plus à jour : Paramètres > Windows Update > Rechercher des mises à jour." -f $lastSec.HotFixID, $lastSec.InstalledOn, [int]((Get-Date) - $lastSec.InstalledOn).TotalDays, $contexte.Build)
}
if ($forced.Count) { Add-Constat 'info' 'F' "$($forced.Count) redémarrage(s) déclenché(s) par Windows Update sur $Days jours." }

# =====================================================================================
# G. STABILITÉ (30 derniers jours)
# =====================================================================================
Step 'G. Plantages, écrans bleus, WHEA, erreurs disque, périphériques'
$crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -ErrorAction SilentlyContinue)
$hangs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002; StartTime = $since } -ErrorAction SilentlyContinue)
$topCrash = @($crashes | Group-Object { [string]$_.Properties[0].Value } | Sort-Object Count -Descending | Select-Object -First 10 |
    ForEach-Object { [pscustomobject]@{ Appli = $_.Name; Plantages = $_.Count; Dernier = ($_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('s') } })
$kp41 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue |
    ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated.ToString('s'); BugcheckCode = [string]$_.Properties[0].Value } })
$bsod = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; StartTime = $since } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'WER-SystemErrorReporting|BugCheck' } |
    ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated.ToString('s'); Message = (($_.Message -split "`n")[0]).Trim() } })
$whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since } -ErrorAction SilentlyContinue |
    ForEach-Object { [pscustomobject]@{ Date = $_.TimeCreated.ToString('s'); Id = $_.Id; Niveau = $_.LevelDisplayName } })
# 7 = secteur défectueux, 11 = erreur contrôleur, 51 = erreur de pagination, 153 = E/S relancée
$diskErr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7, 11, 51, 153; StartTime = $since } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match '^(disk|stornvme|storahci|storport|iaStor\w*|nvme\w*|amdsata|secnvme|partmgr|volmgr|Ntfs)$' } |
    ForEach-Object {
        $msg = (($_.Message -split "`n")[0]).Trim()
        $dev = if ($msg -match '\\Device\\(Harddisk\d+|RaidPort\d+)') { $Matches[1] } else { '?' }
        [pscustomobject]@{ Date = $_.TimeCreated.ToString('s'); Source = $_.ProviderName; Id = $_.Id; Peripherique = $dev; Message = $msg } })
# Erreurs en rafale : on stocke un résumé par source/ID/périphérique, plus les 50 dernières en détail
$diskErrSummary = @($diskErr | Group-Object Source, Id, Peripherique | ForEach-Object {
        $g = $_.Group | Sort-Object Date
        [pscustomobject]@{ Source = $g[0].Source; Id = $g[0].Id; Peripherique = $g[0].Peripherique; Nombre = $_.Count; Premiere = $g[0].Date; Derniere = $g[-1].Date; Message = $g[0].Message } })
$diskErrSinceBoot = @($diskErr | Where-Object { [datetime]$_.Date -ge $os.LastBootUpTime }).Count
$pnp = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -in 'Error', 'Degraded' } |
    ForEach-Object { [pscustomobject]@{ Nom = $_.FriendlyName; Classe = $_.Class; Etat = [string]$_.Status; CodeErreur = $_.ConfigManagerErrorCode } })
$stabilite = [ordered]@{
    PeriodeJours = $Days
    PlantagesApplis = $crashes.Count; BlocagesApplis = $hangs.Count; Top10Plantages = $topCrash
    ArretsInattendusKernelPower41 = $kp41
    EcransBleus1001 = $bsod
    ErreursWHEA = $whea
    ErreursDisqueResume = $diskErrSummary
    ErreursDisqueDernieres = @($diskErr | Sort-Object Date -Descending | Select-Object -First 50)
    ErreursDisqueTotal = $diskErr.Count
    ErreursDisqueDepuisBoot = $diskErrSinceBoot
    PeripheriquesEnErreur = $pnp
}
if ($bsod.Count) { Add-Constat 'critique' 'G' "$($bsod.Count) écran(s) bleu(s) (BugCheck 1001) sur $Days jours." }
if ($kp41.Count) {
    $withCode = @($kp41 | Where-Object { $_.BugcheckCode -and $_.BugcheckCode -ne '0' }).Count
    Add-Constat 'attention' 'G' ("$($kp41.Count) arrêt(s) inattendu(s) (Kernel-Power 41) sur $Days jours" + $(if ($withCode) { ", dont $withCode avec code d'écran bleu." } else { " : sans code d'écran bleu (coupure, bouton reset ou plantage matériel)." }))
}
if ($whea.Count) { Add-Constat 'critique' 'G' "$($whea.Count) erreur(s) matérielle(s) WHEA sur $Days jours (CPU, RAM, PCIe...)." }
if ($diskErr.Count) {
    $src = ($diskErrSummary | ForEach-Object { "$($_.Source)/$($_.Id) sur $($_.Peripherique) x$($_.Nombre) du $($_.Premiere) au $($_.Derniere)" }) -join ' ; '
    Add-Constat 'critique' 'G' "$($diskErr.Count) erreur(s) disque sur $Days jours ($src), dont $diskErrSinceBoot depuis le dernier démarrage. À traiter AVANT tout réglage."
    if (@($diskErrSummary | Where-Object { $_.Id -eq 51 }).Count -and @($pfSet | Where-Object { $_.Fichier -notmatch "^$([regex]::Escape($env:SystemDrive))" }).Count) {
        Add-Constat 'critique' 'G' "Erreurs de PAGINATION (ID 51) et fichier d'échange hors du disque système : si ce disque lâche, Windows perd une partie de sa mémoire virtuelle (risque de plantage)."
    }
}
# Une réinstallation sur place ou un journal circulaire plein peut effacer l'historique :
# « 0 erreur » ne veut alors rien dire. On indique la vraie période couverte.
$oldestSys = (Get-WinEvent -LogName System -Oldest -MaxEvents 1 -ErrorAction SilentlyContinue).TimeCreated
$stabilite.JournalSystemDepuis = if ($oldestSys) { $oldestSys.ToString('s') } else { $null }
if ($oldestSys -and $oldestSys -gt $since.AddDays(1)) {
    Add-Constat 'attention' 'G' ("Le journal Système ne remonte qu'au {0:dd/MM/yyyy HH:mm} (au lieu de {1} jours) : réinstallation/mise à jour ou journal plein. L'absence d'erreurs avant cette date n'est PAS prouvée." -f $oldestSys, $Days)
}
foreach ($tc in @($topCrash | Where-Object { $_.Plantages -ge 50 })) {
    Add-Constat 'attention' 'G' "$($tc.Appli) a planté $($tc.Plantages) fois en $Days jours (dernier : $($tc.Dernier)) : programme cassé qui redémarre en boucle (désinstallation : périmètre pc-cleanup)."
}
if ($pnp.Count) { Add-Constat 'attention' 'G' ("$($pnp.Count) périphérique(s) en erreur : " + (($pnp | ForEach-Object { $_.Nom }) -join ', ')) }

# =====================================================================================
# H. VIE PRIVÉE (présentée à part : ce n'est PAS un gain de performance)
# =====================================================================================
Step 'H. Vie privée'
$telePol = Get-WtRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'
$teleOs = Get-WtRegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry'
$diag = Get-Service DiagTrack -ErrorAction SilentlyContinue
$viePrivee = [ordered]@{
    TelemetrieStrategie = $telePol
    TelemetrieParametres = $teleOs
    ServiceDiagTrack = "$($diag.Status) / $($diag.StartType)"
    IdentifiantPublicitaire = switch (Get-WtRegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled') { 0 { 'désactivé' } 1 { 'actif' } default { 'actif (par défaut)' } }
    HistoriqueActiviteStrategie = Get-WtRegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities'
    SuiviDocumentsMenuDemarrer = Get-WtRegValue $adv 'Start_TrackDocs'
}

# =====================================================================================
# I. PORTABLE
# =====================================================================================
$portable = $null
if ($isLaptop) {
    Step 'I. Portable : batterie'
    $portable = [ordered]@{ Note = 'Rapports générés par powercfg (commandes ci-dessous).' }
    Add-AdminCmd 'Rapport de batterie (HTML)' ("powercfg /batteryreport /output `"{0}`"" -f (Join-Path (Get-WtPath 'reports') "battery_$stamp.html"))
    Add-AdminCmd 'Étude de la veille moderne' ("powercfg /sleepstudy /output `"{0}`"" -f (Join-Path (Get-WtPath 'reports') "sleepstudy_$stamp.html"))
    Add-AdminCmd 'Diagnostic énergétique (60 s, machine au repos)' ("powercfg /energy /output `"{0}`"" -f (Join-Path (Get-WtPath 'reports') "energy_$stamp.html"))
} else { Step 'I. PC fixe : section batterie ignorée' }

# =====================================================================================
# ÉCRITURE (uniquement reports\ et baseline\)
# =====================================================================================
$audit = [ordered]@{
    Outil = 'win-tune'; Date = (Get-Date).ToString('s'); Horodatage = $stamp
    Contexte = $contexte
    A_Baseline = [ordered]@{ Demarrage = $bootRes; Repos = $repos; TopRam = $topRam }
    B_DemarrageArret = $demarrage
    C_ArrierePlan = $arrierePlan
    D_MemoireStockage = $memoire
    E_Interface = $interface
    F_MisesAJour = $majs
    G_Stabilite = $stabilite
    H_ViePrivee = $viePrivee
    I_Portable = $portable
    Constats = $constats
    CommandesAdmin = $adminCmds
    HorsPerimetre = @(
        'pc-cleanup : nettoyage disque, programmes/tâches au démarrage, services vs Windows 11, SMART, sfc/DISM',
        'netguard-gaming : réseau, pare-feu, Defender, BitLocker, NVIDIA, Mode Jeu, HAGS, Game Bar, plan d''alimentation, VBS/HVCI, Delivery Optimization'
    )
}
# Baseline : uniquement les mesures comparables avant/après (aucun nom de PC ni d'utilisateur)
$baseline = [ordered]@{
    Date = (Get-Date).ToString('s'); Build = $contexte.Build; BuildDepuis = $bootRes.BuildDepuis; RamGo = $contexte.RamGo
    UptimeHeures = $contexte.UptimeHeures
    Demarrage = $bootRes.Synthese; SourceDemarrage = $bootRes.Source
    Repos = $repos
}

$repDir = Join-Path $(if ($ReportsDir) { $ReportsDir } else { Get-WtPath 'reports' }) "audit_$stamp"
$baseDir = if ($BaselineDir) { $BaselineDir } else { Get-WtPath 'baseline' }
$auditFile = Join-Path $repDir 'audit.json'
$baseFile = Join-Path $baseDir "baseline_$stamp.json"
if ($PSCmdlet.ShouldProcess($repDir, 'Écrire audit.json')) {
    New-Item -ItemType Directory -Force -Path $repDir, $baseDir | Out-Null
    $audit | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $auditFile -Encoding UTF8
    $baseline | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $baseFile -Encoding UTF8
    $constats | ForEach-Object { "[{0}] {1} : {2}" -f $_.Niveau, $_.Section, $_.Texte } | Set-Content -LiteralPath (Join-Path $repDir 'audit.log') -Encoding UTF8
}

# --- Résumé console ----------------------------------------------------------------------
Write-Host "`n=== BASELINE ===" -ForegroundColor Green
$s = $bootRes.Synthese
if ($s.NbDemarrages) {
    "  Démarrage (ID 100, {0} boots) : médiane {1} s, pire {2} s" -f $s.NbDemarrages, $s.DemarrageMedianSec, $s.DemarragePireSec
    "  dont logo -> écran de connexion : médiane {0} s ; connexion -> bureau au repos : médiane {1} s ; pilotes : médiane {2} s" -f $s.CheminPrincipalMedianSec, $s.ApresConnexionMedianSec, $s.PilotesMedianSec
}
elseif ($bootRes.Source) { "  Démarrage exact : aucun boot mesuré depuis l'installation du build actuel ({0})" -f $bootRes.BuildDepuis }
else { "  Démarrage exact : indisponible sans admin (voir CommandesAdmin)" }
if ($s.NbArrets) { "  Arrêt (ID 200, {0}) : médiane {1} s, pire {2} s" -f $s.NbArrets, $s.ArretMedianSec, $s.ArretPireSec }
if ($s.ApproxNoyauSessionMedianSec -ne $null) { "  Approx. noyau -> ouverture de session : médiane {0} s (inclut la saisie du mot de passe)" -f $s.ApproxNoyauSessionMedianSec }
if ($repos) {
    "  Au repos ({0} éch., représentatif={1}) : CPU {2} %, RAM {3} Mo, disque actif {4} %, {5} processus, {6} services, {7} handles" -f `
        $repos.Echantillons, $repos.Representatif, $repos.CpuPct.Mediane, $repos.RamUtiliseeMo.Mediane, $repos.DisqueActifPct.Mediane, $repos.Processus.Mediane, $repos.ServicesEnCours.Mediane, $repos.Handles.Mediane
}
Write-Host "`n=== CONSTATS ===" -ForegroundColor Green
foreach ($c in ($constats | Sort-Object { @{ critique = 0; attention = 1; info = 2 }[$_.Niveau] })) {
    $col = @{ critique = 'Red'; attention = 'Yellow'; info = 'Gray' }[$c.Niveau]
    Write-Host ("  [{0}] {1} : {2}" -f $c.Niveau, $c.Section, $c.Texte) -ForegroundColor $col
}
if ($adminCmds.Count) {
    Write-Host "`n=== COMMANDES ADMIN (à copier dans un PowerShell administrateur, rien n'est lancé) ===" -ForegroundColor Green
    foreach ($a in $adminCmds) { Write-Host "  # $($a.Pourquoi)" -ForegroundColor Gray; Write-Host "  $($a.Commande)" }
}
if (-not $WhatIfPreference) { Write-Host "`nRésultats : $auditFile`nBaseline  : $baseFile" -ForegroundColor Green }
