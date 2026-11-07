<#
.SYNOPSIS
    Fonctions partagées par les scripts win-tune.
.DESCRIPTION
    À charger avec : . (Join-Path $PSScriptRoot 'Common.ps1')
    AUCUNE fonction de ce fichier ne modifie le système : lecture de registre, de journaux
    d'événements, de compteurs de performance et de configuration uniquement.
    Les fonctions qui écrivent (export .reg, journal de session) sont dans Apply.ps1.
#>

# Sous -WhatIf, le chargement automatique du module CimCmdlets affiche 12 lignes « Définir l'alias »
# (il crée ses alias avec Set-Alias, qui hérite de -WhatIf). On le charge une fois, sans -WhatIf.
& { $WhatIfPreference = $false; Import-Module CimCmdlets -ErrorAction SilentlyContinue }

# Racine du projet (dossier parent de scripts\)
$script:WtRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Get-WtPath {
    # Chemin absolu d'un sous-dossier du projet : Get-WtPath 'reports'
    param([Parameter(Mandatory)][string]$Child)
    Join-Path $script:WtRoot $Child
}

function ConvertTo-Go { param([double]$Bytes) [math]::Round($Bytes / 1GB, 2) }
function ConvertTo-Mo { param([double]$Bytes) [math]::Round($Bytes / 1MB, 1) }

function Get-WtMedian {
    # Médiane d'une liste de nombres ($null si vide)
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = $Values | Sort-Object
    $n = $s.Count
    if ($n % 2) { return [double]$s[($n - 1) / 2] }
    return ([double]$s[$n / 2 - 1] + [double]$s[$n / 2]) / 2
}

function Test-WtAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WtConfig {
    <#
        Lit config\<Name>.json. Si config\<Name>.local.json existe (ignoré par Git),
        ses listes sont AJOUTÉES à celles de la config publique.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path (Get-WtPath 'config') "$Name.json"
    $cfg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $local = Join-Path (Get-WtPath 'config') "$Name.local.json"
    if (Test-Path -LiteralPath $local) {
        $l = Get-Content -LiteralPath $local -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $l.PSObject.Properties) {
            if ($cfg.PSObject.Properties[$p.Name] -and $cfg.($p.Name) -is [array]) {
                $cfg.($p.Name) = @($cfg.($p.Name)) + @($p.Value)
            } else {
                $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
        }
    }
    $cfg
}

function Get-WtRegValue {
    <#
        Lit une valeur de registre. Renvoie $null si la clé ou la valeur n'existe pas.
        Note : ne PAS nommer une fonction 'R' : c'est un alias intégré d'Invoke-History,
        prioritaire sur les fonctions (piège rencontré pendant le développement).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Test-WtProtectedService {
    <#
        Vrai si le service est protégé (config\protected_services.json) : nom exact ou motif (*).
        Utilisé par Apply.ps1 AVANT toute modification de service, et par Test-WinTune.ps1.
    #>
    param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-WtConfig 'protected_services'
    foreach ($s in @($cfg.services)) { if ($Name -ieq $s.name) { return $true } }
    foreach ($p in @($cfg.patterns)) { if ($Name -ilike $p) { return $true } }
    return $false
}

function Test-WtProtectedRegistryPath {
    <#
        Vrai si un chemin de registre vise la configuration d'un service protégé
        (HKLM:\SYSTEM\CurrentControlSet\Services\<nom>...) : on refuse de l'écrire, comme Set-Service.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '(?i)^HKLM:?\\SYSTEM\\(CurrentControlSet|ControlSet\d{3})\\Services\\([^\\]+)') {
        return (Test-WtProtectedService -Name $Matches[2])
    }
    return $false
}

function ConvertTo-WtRegExePath {
    # 'HKCU:\Software\X' -> 'HKCU\Software\X' (syntaxe de reg.exe)
    param([Parameter(Mandatory)][string]$Path)
    $Path -replace '^(HKCU|HKLM|HKCR|HKU):\\', '$1\'
}

function Read-WtJsonArray {
    <#
        Lit un fichier JSON contenant un tableau et renvoie VRAIMENT un tableau d'objets.
        Piège PS 5.1 : « Get-Content | ConvertFrom-Json » émet le tableau comme UN SEUL objet ;
        @(...) donne alors un tableau à 1 élément qui contient tout le journal, et $e.Annule
        devient un tableau de $false... considéré comme VRAI (tableau non vide). ForEach-Object déroule.
    #>
    param([Parameter(Mandatory)][string]$Path)
    @(Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
}

function Get-WtRiskLevel { param([string]$Profil) @{ prudent = 1; equilibre = 2; avance = 3 }[$Profil.ToLower()] }

# --- Inactivité clavier/souris (GetLastInputInfo, user32) -------------------------------
if (-not ('WinTune.Idle' -as [type])) {
    Add-Type -Namespace WinTune -Name Idle -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
[DllImport("kernel32.dll")] public static extern uint GetTickCount();
'@
}

function Get-WtIdleSeconds {
    # Secondes écoulées depuis la dernière action clavier/souris de la session.
    $l = New-Object WinTune.Idle+LASTINPUTINFO
    $l.cbSize = 8
    [void][WinTune.Idle]::GetLastInputInfo([ref]$l)
    # Deux compteurs 32 bits non signés (rebouclent tous les ~49,7 jours) : on corrige l'écart négatif
    $d = [int64][WinTune.Idle]::GetTickCount() - [int64]$l.dwTime
    if ($d -lt 0) { $d += 4294967296 }
    [math]::Round($d / 1000, 0)
}

function Get-WtIdleSample {
    <#
        Mesure "au repos" : attend $IdleRequiredSec d'inactivité (au plus $MaxWaitMinutes),
        puis échantillonne pendant $DurationSec toutes les $IntervalSec secondes.
        Pourquoi pas Get-Counter : sous Windows en français, les noms de compteurs sont traduits
        ("\Processeur(_Total)\% temps processeur") et la traduction par index PDH échoue sur cette
        machine. Les classes CIM Win32_PerfFormattedData_* lisent les MÊMES compteurs avec des
        noms indépendants de la langue.
    #>
    param(
        [int]$IdleRequiredSec = 180,
        [int]$MaxWaitMinutes = 10,
        [int]$DurationSec = 60,
        [int]$IntervalSec = 5
    )
    $waitStart = Get-Date
    $idleOk = $true
    while ((Get-WtIdleSeconds) -lt $IdleRequiredSec) {
        if (((Get-Date) - $waitStart).TotalMinutes -ge $MaxWaitMinutes) { $idleOk = $false; break }
        Write-Progress -Activity 'Mesure au repos' -Status ("Attente de {0} s sans clavier ni souris (inactif depuis {1} s)" -f $IdleRequiredSec, (Get-WtIdleSeconds))
        Start-Sleep -Seconds 5
    }
    $totalMB = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB
    # Premier appel "à vide" : les classes formatées calculent un écart entre deux lectures
    [void](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'")
    [void](Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'")
    Start-Sleep -Seconds 1

    $samples = New-Object System.Collections.Generic.List[object]
    $interrupted = $false
    $end = (Get-Date).AddSeconds($DurationSec)
    while ((Get-Date) -lt $end) {
        Write-Progress -Activity 'Mesure au repos' -Status ("Échantillon {0} - ne touche pas au PC" -f ($samples.Count + 1))
        $cpu  = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
        $mem  = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
        $procs = Get-Process
        $samples.Add([pscustomobject]@{
            CpuPct      = [double]$cpu.PercentProcessorTime
            RamUsedMB   = [math]::Round($totalMB - $mem.AvailableMBytes)
            CommitMB    = [math]::Round($mem.CommittedBytes / 1MB)
            DiskBusyPct = [math]::Max(0, 100 - [double]$disk.PercentIdleTime)
            Processes   = $procs.Count
            Handles     = [int](($procs | Measure-Object -Property HandleCount -Sum).Sum)
            Services    = @(Get-Service | Where-Object { $_.Status -eq 'Running' }).Count
        })
        if ((Get-WtIdleSeconds) -lt $IntervalSec) { $interrupted = $true }
        Start-Sleep -Seconds $IntervalSec
    }
    Write-Progress -Activity 'Mesure au repos' -Completed

    $stat = {
        param($prop)
        $v = [double[]]($samples | ForEach-Object { $_.$prop })   # accès direct .Propriété (piège -WhatIf)
        [pscustomobject]@{ Mediane = [math]::Round((Get-WtMedian $v), 1); Max = [math]::Round(($v | Measure-Object -Maximum).Maximum, 1) }
    }
    [pscustomobject]@{
        Date               = (Get-Date).ToString('s')
        InactifAvantMesure = $idleOk
        Interrompu         = $interrupted
        Representatif      = ($idleOk -and -not $interrupted)
        Echantillons       = $samples.Count
        DureeSec           = $DurationSec
        CpuPct             = & $stat 'CpuPct'
        RamUtiliseeMo      = & $stat 'RamUsedMB'
        ChargeValideeMo    = & $stat 'CommitMB'
        DisqueActifPct     = & $stat 'DiskBusyPct'
        Processus          = & $stat 'Processes'
        Handles            = & $stat 'Handles'
        ServicesEnCours    = & $stat 'Services'
    }
}

# --- Temps de démarrage / arrêt -----------------------------------------------------------
$script:WtBootLog = 'Microsoft-Windows-Diagnostics-Performance/Operational'
$script:WtBootExport = 'boot_events_admin.xml'   # dans baseline\ (export fait par l'admin)

function Get-WtBootExportCommand {
    # Commande admin (affichée, jamais lancée) qui exporte les événements de boot dans baseline\
    $dir = Get-WtPath 'baseline'
    $dest = Join-Path $dir $script:WtBootExport
    "New-Item -ItemType Directory -Force -Path '$dir' | Out-Null; Get-WinEvent -FilterHashtable @{LogName='$script:WtBootLog'; Id=100,101,102,103,200} -MaxEvents 500 | ForEach-Object { `$_.ToXml() } | Set-Content -Encoding UTF8 -LiteralPath '$dest'"
}

function ConvertFrom-WtEventXml {
    # Transforme le XML d'un événement en objet { Id, Time, Data = @{Nom = valeur} }
    param([string]$Xml)
    $x = [xml]$Xml
    $data = @{}
    foreach ($d in @($x.Event.EventData.Data)) { if ($d.Name) { $data[$d.Name] = $d.'#text' } }
    [pscustomobject]@{
        Id   = [int]$x.Event.System.EventID
        Time = [datetime]$x.Event.System.TimeCreated.SystemTime
        Data = $data
    }
}

function Get-WtBootEvents {
    <#
        Événements Diagnostics-Performance. Ce journal est RÉSERVÉ AUX ADMINISTRATEURS :
        en utilisateur standard, Get-WinEvent -FilterHashtable répond « aucun événement »
        (et non « accès refusé ») : piège ! On teste donc l'accès explicitement.
        Ordre : lecture directe (si admin) > export admin dans baseline\ > indisponible.
        Sens des ID (Microsoft, Diagnostics-Performance) :
          100 = démarrage terminé (BootTime en ms, IsDegradation)
          101 = une APPLICATION a ralenti le démarrage
          102 = un PILOTE a ralenti le démarrage
          103 = un SERVICE a ralenti le démarrage
          200 = arrêt terminé (ShutdownTime en ms)
    #>
    $source = $null; $events = @()
    try {
        [void](Get-WinEvent -LogName $script:WtBootLog -MaxEvents 1 -ErrorAction Stop)
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $script:WtBootLog; Id = 100, 101, 102, 103, 200 } -MaxEvents 500 -ErrorAction Stop |
            ForEach-Object { ConvertFrom-WtEventXml $_.ToXml() })
        $source = 'journal (lecture directe)'
    } catch {
        $exp = Join-Path (Get-WtPath 'baseline') $script:WtBootExport
        if (Test-Path -LiteralPath $exp) {
            $events = @(Get-Content -LiteralPath $exp -Encoding UTF8 | Where-Object { $_ -match '^<Event' } |
                ForEach-Object { ConvertFrom-WtEventXml $_ })
            $source = "export admin du {0:dd/MM/yyyy HH:mm}" -f (Get-Item -LiteralPath $exp).LastWriteTime
        }
    }
    [pscustomobject]@{ Source = $source; Events = $events }
}

function Get-WtBootProxy {
    <#
        Mesure de secours, lisible sans admin (journal Système) :
        Kernel-General 12 (démarrage du noyau) -> Winlogon 7001 (ouverture de session).
        APPROXIMATIF : n'inclut ni le BIOS/UEFI ni le chargement du bureau, et INCLUT le temps
        de saisie du mot de passe / code PIN.
    #>
    param([int]$Count = 10)
    $starts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 12 } -MaxEvents $Count -ErrorAction SilentlyContinue)
    $logons = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Winlogon'; Id = 7001 } -MaxEvents ($Count * 4) -ErrorAction SilentlyContinue)
    foreach ($s in $starts) {
        $l = $logons | Where-Object { $_.TimeCreated -gt $s.TimeCreated -and $_.TimeCreated -lt $s.TimeCreated.AddMinutes(15) } |
            Sort-Object TimeCreated | Select-Object -First 1
        if ($l) {
            [pscustomobject]@{ Boot = $s.TimeCreated.ToString('s'); Secondes = [math]::Round(($l.TimeCreated - $s.TimeCreated).TotalSeconds) }
        }
    }
}
