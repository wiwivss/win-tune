<#
.SYNOPSIS
    Annule une session d'Apply.ps1 à partir de son journal (logs\session_<date>\journal.json).
.DESCRIPTION
    Pour chaque modification, dans l'ordre INVERSE :
      - registre : remet la valeur d'origine avec son type d'origine, ou supprime la valeur si elle
        n'existait pas ; supprime la clé seulement si Apply l'a créée ET qu'elle est vide.
      - service  : remet le type de démarrage d'origine (admin).
      - appx     : impossible à réinstaller par script (fichiers supprimés) : la liste à réinstaller
        depuis le Microsoft Store est affichée.
    Chaque entrée annulée est marquée « Annule » dans le journal : relancer Undo ne refait rien deux fois.
    Secours manuel : double-clic sur les .reg exportés dans le dossier de session.
.EXAMPLE
    .\scripts\Undo.ps1 -List
    .\scripts\Undo.ps1 -Session last -WhatIf
    .\scripts\Undo.ps1 -Session session_2026-11-08_101500
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Session = 'last',
    [switch]$List,
    [string]$LogRoot
)

. (Join-Path $PSScriptRoot 'Common.ps1')
$ErrorActionPreference = 'Stop'
if (-not $LogRoot) { $LogRoot = Get-WtPath 'logs' }

$sessions = @(Get-ChildItem -LiteralPath $LogRoot -Directory -Filter 'session_*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'journal.json') } | Sort-Object Name)
if ($List -or -not $sessions) {
    if (-not $sessions) { Write-Host "Aucune session à annuler dans $LogRoot" -ForegroundColor Yellow; return }
    foreach ($s in $sessions) {
        $j = Read-WtJsonArray -Path (Join-Path $s.FullName 'journal.json')
        "{0}  {1} modification(s), dont {2} déjà annulée(s) - actions : {3}" -f $s.Name, $j.Count, @($j | Where-Object { $_.Annule }).Count, ((@($j | ForEach-Object { $_.Action }) | Sort-Object -Unique) -join ', ')
    }
    return
}

$dir = if ($Session -eq 'last') { $sessions[-1] } else { $sessions | Where-Object { $_.Name -eq $Session } | Select-Object -First 1 }
if (-not $dir) { throw "Session introuvable : $Session (voir .\scripts\Undo.ps1 -List)" }
$jPath = Join-Path $dir.FullName 'journal.json'
$journal = Read-WtJsonArray -Path $jPath
$simulation = [bool]$WhatIfPreference
$isAdmin = Test-WtAdmin
$log = New-Object System.Collections.Generic.List[string]
function Log([string]$m, [string]$c = 'Gray') { $log.Add(("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m)); Write-Host "  $m" -ForegroundColor $c }

Write-Host ("`nwin-tune : annulation de {0} ({1})" -f $dir.Name, $(if ($simulation) { 'SIMULATION' } else { 'RÉEL' })) -ForegroundColor $(if ($simulation) { 'Cyan' } else { 'Yellow' })
$ok = 0; $fail = 0; $appx = @()

for ($i = $journal.Count - 1; $i -ge 0; $i--) {
    $e = $journal[$i]
    if ($e.Annule) { continue }
    # Traité AVANT le switch : dans un switch, « continue » ne passe pas à l'itération suivante du for
    if ($e.Type -eq 'appx') { $appx += $e; continue }
    try {
        switch ($e.Type) {
            'registre' {
                if ($e.Chemin -match '^HKLM:' -and -not $isAdmin) { throw "$($e.Chemin) demande un PowerShell administrateur." }
                $target = "$($e.Chemin)\$($e.Nom)"
                if ($e.ValeurExistait) {
                    if ($PSCmdlet.ShouldProcess($target, "restaurer $($e.ValeurOrigine) ($($e.TypeOrigine))")) {
                        if (-not (Test-Path -LiteralPath $e.Chemin)) { New-Item -Path $e.Chemin -Force | Out-Null }
                        $val = $e.ValeurOrigine
                        if ($e.TypeOrigine -eq 'MultiString') { $val = [string[]]@($val) }
                        if ($e.TypeOrigine -eq 'Binary') { $val = [byte[]]@($val) }
                        New-ItemProperty -LiteralPath $e.Chemin -Name $e.Nom -PropertyType $e.TypeOrigine -Value $val -Force | Out-Null
                        Log "restauré : $target = $($e.ValeurOrigine)" 'Green'
                    }
                } else {
                    if ($PSCmdlet.ShouldProcess($target, 'supprimer (valeur absente avant win-tune)')) {
                        if (Test-Path -LiteralPath $e.Chemin) { Remove-ItemProperty -LiteralPath $e.Chemin -Name $e.Nom -ErrorAction SilentlyContinue }
                        Log "supprimé : $target (n'existait pas avant)" 'Green'
                    }
                }
                # Clé créée par Apply : supprimée seulement si elle est VIDE (ni valeur, ni sous-clé).
                # Jamais de Remove-Item -Recurse : on ne détruit rien qu'on n'a pas créé.
                if (-not $e.CleExistait -and (Test-Path -LiteralPath $e.Chemin)) {
                    $k = Get-Item -LiteralPath $e.Chemin
                    if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0 -and $PSCmdlet.ShouldProcess($e.Chemin, 'supprimer la clé vide créée par win-tune')) {
                        Remove-Item -LiteralPath $e.Chemin
                        Log "clé supprimée (créée par win-tune, vide) : $($e.Chemin)" 'Green'
                    }
                }
            }
            'service' {
                if (Test-WtProtectedService -Name $e.Nom) { throw "service protégé $($e.Nom) : ne devrait pas figurer dans un journal, à vérifier à la main." }
                if (-not $isAdmin) { throw "service $($e.Nom) : lance dans un PowerShell admin : Set-Service -Name $($e.Nom) -StartupType $($e.Origine)" }
                if ($PSCmdlet.ShouldProcess("service $($e.Nom)", "remettre $($e.Origine)")) {
                    Set-Service -Name $e.Nom -StartupType $e.Origine
                    Log "service $($e.Nom) remis en $($e.Origine)" 'Green'
                }
            }
            default { throw "type d'entrée inconnu : $($e.Type)" }
        }
        if (-not $simulation) { $e.Annule = $true }
        $ok++
    } catch {
        Log "ÉCHEC : $($e.Type) $($e.Chemin)$($e.Nom) : $($_.Exception.Message)" 'Red'
        $fail++
    }
}

if ($appx) {
    Write-Host "`n  Applis retirées : à réinstaller depuis le Microsoft Store si tu en as besoin :" -ForegroundColor Cyan
    foreach ($p in $appx) { Write-Host "    - $($p.Titre) ($($p.Nom))" }
}
if (-not $simulation) {
    ConvertTo-Json -InputObject @($journal) -Depth 5 | Set-Content -LiteralPath $jPath -Encoding UTF8
    $log | Set-Content -LiteralPath (Join-Path $dir.FullName ("undo_{0:yyyy-MM-dd_HHmmss}.log" -f (Get-Date))) -Encoding UTF8
}
Write-Host ("Bilan : {0} annulée(s), {1} échec(s){2}" -f $ok, $fail, $(if ($simulation) { ' (simulation : rien modifié)' })) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { Write-Host "  Secours : double-clic sur les .reg du dossier $($dir.FullName)" -ForegroundColor Yellow }
[pscustomobject]@{ Session = $dir.Name; Annulees = $ok; Echecs = $fail }
