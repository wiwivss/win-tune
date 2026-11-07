<#
.SYNOPSIS
    Auto-test des garde-fous win-tune dans un bac à sable. Ne touche à AUCUN réglage réel.
.DESCRIPTION
    Bac à sable : clé HKCU:\Software\WinTuneTest + dossier %TEMP%\WinTuneTest_<date>, supprimés à la fin.
    Vérifie :
      1. Export .reg + Undo restaurent exactement une valeur (valeur ET type), suppriment ce qui a été
         créé, et un second Undo ne refait rien.
      2. Un service protégé (ou sa clé de registre) ne peut pas être modifié, même via le catalogue.
      3. -WhatIf ne modifie rien (ni registre, ni fichier de session) ; Undo -WhatIf non plus.
      4. L'audit n'écrit rien en dehors de ses dossiers reports\ et baseline\ (ici redirigés vers le
         bac à sable), et Audit.ps1 ne contient aucune commande d'écriture.
.EXAMPLE
    .\scripts\Test-WinTune.ps1
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'Common.ps1')
$apply = Join-Path $PSScriptRoot 'Apply.ps1'
$undo = Join-Path $PSScriptRoot 'Undo.ps1'
$audit = Join-Path $PSScriptRoot 'Audit.ps1'
$key = 'HKCU:\Software\WinTuneTest'
$tmp = Join-Path $env:TEMP ("WinTuneTest_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
$logs = Join-Path $tmp 'logs'
$script:pass = 0; $script:fail = 0

function Assert([bool]$cond, [string]$what) {
    if ($cond) { $script:pass++; Write-Host "  [OK]    $what" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  [ÉCHEC] $what" -ForegroundColor Red }
}
function Get-Val([string]$name, [string]$path = $key) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $k = Get-Item -LiteralPath $path
    if ($k.GetValueNames() -notcontains $name) { return $null }
    [pscustomobject]@{ Valeur = $k.GetValue($name); Type = [string]$k.GetValueKind($name) }
}
function Reset-Sandbox {
    # Repart d'un état connu : uniquement NOTRE clé de test
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'Existante' -PropertyType DWord -Value 1 | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'Texte' -PropertyType String -Value 'original' | Out-Null
}
function Invoke-Quiet([scriptblock]$sb) {
    # Lance un script en capturant TOUS les flux : renvoie l'objet résultat + le texte affiché
    # Piège : « -is [pscustomobject] » est vrai pour presque tout objet enveloppé : on repère le
    # résultat d'Apply/Undo par ses propriétés.
    $out = & $sb *>&1
    $isRes = { $_ -and ($_.PSObject.Properties['Ignorees'] -or $_.PSObject.Properties['Annulees']) }
    [pscustomobject]@{
        Resultat = @($out | Where-Object $isRes) | Select-Object -Last 1
        Texte = (@($out | Where-Object { -not (& $isRes) } | ForEach-Object { [string]$_ }) -join "`n")
    }
}

Write-Host "`nwin-tune : auto-test des garde-fous (bac à sable $key + $tmp)" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Catalogue de test : n'écrit QUE dans HKCU:\Software\WinTuneTest (et tente des cibles protégées)
$catalog = @{
    actions = @(
        @{ num = 901; id = 'test-registre'; auto = $true; admin = $false; profil = 'prudent'; risque = 'vert'; verifie = $true; classement = 'test'; titre = 'Test registre'
            registre = @(
                @{ chemin = $key; nom = 'Existante'; type = 'DWord'; valeur = 0 },
                @{ chemin = $key; nom = 'Texte'; type = 'String'; valeur = 'modifié' },
                @{ chemin = $key; nom = 'Nouvelle'; type = 'DWord'; valeur = 5 },
                @{ chemin = "$key\Creee"; nom = 'X'; type = 'DWord'; valeur = 1 }) },
        @{ num = 902; id = 'test-service-protege'; auto = $true; admin = $false; profil = 'prudent'; risque = 'vert'; verifie = $true; classement = 'test'; titre = 'Test service protégé'
            services = @(@{ nom = 'WinDefend'; demarrage = 'Disabled' }) },
        @{ num = 903; id = 'test-cle-service-protege'; auto = $true; admin = $false; profil = 'prudent'; risque = 'vert'; verifie = $true; classement = 'test'; titre = 'Test clé de service protégé'
            registre = @(@{ chemin = 'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv'; nom = 'Start'; type = 'DWord'; valeur = 4 }) },
        @{ num = 904; id = 'test-non-verifie'; auto = $true; admin = $false; profil = 'prudent'; risque = 'vert'; verifie = $false; classement = 'test'; titre = 'Test non vérifié'
            registre = @(@{ chemin = $key; nom = 'NonVerifie'; type = 'DWord'; valeur = 1 }) },
        @{ num = 905; id = 'test-orange'; auto = $true; admin = $false; profil = 'equilibre'; risque = 'orange'; verifie = $true; classement = 'test'; titre = 'Test orange en profil Prudent'
            registre = @(@{ chemin = $key; nom = 'Orange'; type = 'DWord'; valeur = 1 }) }
    )
}
$catPath = Join-Path $tmp 'catalogue_test.json'
$catalog | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $catPath -Encoding UTF8

try {
    # ---------------------------------------------------------------------------------------
    Write-Host "`n1. Export .reg + Undo restaurent les valeurs" -ForegroundColor White
    Reset-Sandbox
    $r = Invoke-Quiet { & $apply -Actions 901 -CatalogPath $catPath -LogRoot $logs -NoVerifyState -Force }
    $sess = Get-ChildItem -LiteralPath $logs -Directory -ErrorAction SilentlyContinue | Select-Object -Last 1
    Assert ((Get-Val 'Existante').Valeur -eq 0) "Apply a modifié Existante (1 -> 0)"
    Assert ((Get-Val 'Texte').Valeur -eq 'modifié') "Apply a modifié Texte"
    Assert ((Get-Val 'Nouvelle').Valeur -eq 5) "Apply a créé Nouvelle"
    Assert ((Get-Val 'X' "$key\Creee").Valeur -eq 1) "Apply a créé la sous-clé Creee"
    $regFiles = @(if ($sess) { Get-ChildItem -LiteralPath $sess.FullName -Filter '*.reg' })
    Assert ($regFiles.Count -ge 1) "Export .reg créé AVANT modification ($($regFiles.Count) fichier(s))"
    $regText = if ($regFiles) { Get-Content -LiteralPath $regFiles[0].FullName -Raw } else { '' }
    Assert ($regText -match '"Existante"=dword:00000001') "L'export .reg contient la valeur d'origine (dword:00000001)"
    $j = @(if ($sess) { Read-WtJsonArray -Path (Join-Path $sess.FullName 'journal.json') })
    Assert ($j.Count -eq 4) "Journal : 4 modifications enregistrées"
    Assert (@($j | Where-Object { $_.Nom -eq 'Existante' -and $_.ValeurOrigine -eq 1 -and $_.TypeOrigine -eq 'DWord' }).Count -eq 1) "Journal : valeur ET type d'origine sauvegardés"

    $u = Invoke-Quiet { & $undo -Session last -LogRoot $logs }
    $v = Get-Val 'Existante'
    Assert ($v.Valeur -eq 1 -and $v.Type -eq 'DWord') "Undo : Existante = 1 (DWord) restaurée"
    $v = Get-Val 'Texte'
    Assert ($v.Valeur -eq 'original' -and $v.Type -eq 'String') "Undo : Texte = 'original' (String) restaurée"
    Assert ($null -eq (Get-Val 'Nouvelle')) "Undo : Nouvelle supprimée (n'existait pas avant)"
    Assert (-not (Test-Path -LiteralPath "$key\Creee")) "Undo : sous-clé créée par win-tune supprimée"
    Assert (Test-Path -LiteralPath $key) "Undo : la clé d'origine existe toujours"
    $u2 = Invoke-Quiet { & $undo -Session last -LogRoot $logs }
    Assert ($u2.Resultat.Annulees -eq 0) "Second Undo : rien à refaire (entrées marquées annulées)"

    # ---------------------------------------------------------------------------------------
    Write-Host "`n2. Services protégés" -ForegroundColor White
    foreach ($s in 'WinDefend', 'mpssvc', 'wuauserv', 'WSearch', 'DPS') { Assert (Test-WtProtectedService -Name $s) "$s est protégé" }
    Assert (-not (Test-WtProtectedService -Name 'Spooler')) "Spooler n'est pas dans la liste (contrôle du test lui-même)"
    Assert (Test-WtProtectedRegistryPath -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend\Parameters') "La clé de registre de WinDefend est protégée"
    $before = (Get-Service WinDefend -ErrorAction SilentlyContinue).StartType
    $r = Invoke-Quiet { & $apply -Actions 902, 903 -CatalogPath $catPath -LogRoot $logs -NoVerifyState -Force }
    Assert ($r.Resultat.Ignorees -eq 2 -and $r.Resultat.Appliquees -eq 0) "Apply refuse les 2 actions visant des services protégés"
    Assert (($r.Texte -split "`n" | Where-Object { $_ -match 'REFUSÉ' }).Count -ge 2) "Motif « REFUSÉ … protégé » affiché pour chacune"
    Assert ((Get-Service WinDefend -ErrorAction SilentlyContinue).StartType -eq $before) "WinDefend inchangé ($before)"
    Assert ($r.Resultat.Journal.Count -eq 0) "Aucune entrée de journal pour une action refusée"

    Write-Host "`n   Autres garde-fous du catalogue" -ForegroundColor White
    Reset-Sandbox
    $r = Invoke-Quiet { & $apply -Actions 904 -CatalogPath $catPath -LogRoot $logs -NoVerifyState -Force }
    Assert ($null -eq (Get-Val 'NonVerifie')) "Réglage « non vérifié » refusé sans -IncludeUnverified"
    $r = Invoke-Quiet { & $apply -Actions 905 -Profil Prudent -CatalogPath $catPath -LogRoot $logs -NoVerifyState -Force }
    Assert ($null -eq (Get-Val 'Orange')) "Action orange refusée en profil Prudent"

    # ---------------------------------------------------------------------------------------
    Write-Host "`n3. -WhatIf ne modifie rien" -ForegroundColor White
    Reset-Sandbox
    $nbSess = @(Get-ChildItem -LiteralPath $logs -Directory -ErrorAction SilentlyContinue).Count
    $r = Invoke-Quiet { & $apply -Actions 901 -CatalogPath $catPath -LogRoot $logs -NoVerifyState -Force -WhatIf }
    Assert ((Get-Val 'Existante').Valeur -eq 1 -and (Get-Val 'Texte').Valeur -eq 'original') "Apply -WhatIf : valeurs inchangées"
    Assert ($null -eq (Get-Val 'Nouvelle') -and -not (Test-Path -LiteralPath "$key\Creee")) "Apply -WhatIf : rien de créé"
    Assert (@(Get-ChildItem -LiteralPath $logs -Directory -ErrorAction SilentlyContinue).Count -eq $nbSess) "Apply -WhatIf : aucun dossier de session ni .reg écrit"
    # (les lignes « WhatIf : … » vont directement à la console en PS 5.1 : non capturables par *>&1)
    Assert ($r.Texte -match 'SIMULATION') "Apply -WhatIf : annoncé comme SIMULATION"
    $r = Invoke-Quiet { & $apply -Actions 901 -CatalogPath $catPath -LogRoot $logs -NoVerifyState -Force }
    $u = Invoke-Quiet { & $undo -Session last -LogRoot $logs -WhatIf }
    Assert ((Get-Val 'Existante').Valeur -eq 0 -and (Get-Val 'Nouvelle').Valeur -eq 5) "Undo -WhatIf : valeurs modifiées laissées telles quelles"
    $u = Invoke-Quiet { & $undo -Session last -LogRoot $logs }
    Assert ((Get-Val 'Existante').Valeur -eq 1) "Undo réel après Undo -WhatIf : restauration complète"

    # ---------------------------------------------------------------------------------------
    Write-Host "`n4. L'audit n'écrit rien hors de reports\ et baseline\" -ForegroundColor White
    $forbidden = 'Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|Remove-Item\b|Set-Service|Stop-Service|Start-Service|Disable-|Enable-|Set-CimInstance|Invoke-CimMethod|reg(\.exe)?\s+(add|delete|import)|Remove-AppxPackage|Checkpoint-Computer'
    $hits = @(Select-String -LiteralPath $audit -Pattern $forbidden | Where-Object { $_.Line -notmatch '^\s*(#|Select-String|\.EXAMPLE|\s{4}Select-String)' })
    Assert ($hits.Count -eq 0) ("Audit.ps1 ne contient aucune commande d'écriture système" + $(if ($hits) { ' : ' + (($hits | ForEach-Object { "L$($_.LineNumber)" }) -join ',') }))

    # Instantané du projet (hors reports\ et baseline\) et de la clé témoin
    $root = Get-WtPath '.'
    $snap = { Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(reports|baseline|\.git)\\' } |
            ForEach-Object { "{0}|{1}|{2}" -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks } | Sort-Object }
    Reset-Sandbox
    $projBefore = & $snap
    $regBefore = (Get-Item -LiteralPath $key).GetValueNames() -join ','
    $rep = Join-Path $tmp 'reports'; $base = Join-Path $tmp 'baseline'

    $null = Invoke-Quiet { & $audit -SkipIdleSample -BootCount 3 -ReportsDir $rep -BaselineDir $base -WhatIf }
    Assert (-not (Test-Path -LiteralPath $rep) -and -not (Test-Path -LiteralPath $base)) "Audit -WhatIf : n'écrit même pas ses propres rapports"

    $null = Invoke-Quiet { & $audit -SkipIdleSample -BootCount 3 -ReportsDir $rep -BaselineDir $base }
    $projAfter = & $snap
    $diff = @(Compare-Object -ReferenceObject @($projBefore) -DifferenceObject @($projAfter))
    Assert ($diff.Count -eq 0) ("Audit : aucun fichier du projet créé/modifié hors reports\ et baseline\" + $(if ($diff) { ' : ' + (($diff | Select-Object -First 3 | ForEach-Object { $_.InputObject.Split('|')[0] }) -join ', ') }))
    Assert (((Get-Item -LiteralPath $key).GetValueNames() -join ',') -eq $regBefore) "Audit : clé de registre témoin inchangée"
    $written = @(Get-ChildItem -LiteralPath $rep, $base -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
    Assert (($written -join ',') -match '^audit\.json,audit\.log,baseline_[\d_-]+\.json$') "Audit : écrit exactement audit.json, audit.log et baseline_<date>.json ($($written -join ', '))"
} catch {
    $script:fail++
    Write-Host "  [ÉCHEC] erreur inattendue : $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor Red
} finally {
    # Nettoyage : uniquement le bac à sable créé par ce test (aucune jonction dans ces dossiers)
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

Write-Host ("`nRésultat : {0} réussi(s), {1} échec(s)" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
Write-Host "Bac à sable supprimé : $(-not (Test-Path -LiteralPath $key) -and -not (Test-Path -LiteralPath $tmp))"
if ($script:fail) { exit 1 }
