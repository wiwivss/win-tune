<#
.SYNOPSIS
    Génère reports\rapport_audit.html à partir du dernier audit.json, de config\actions.json et des baselines.
.DESCRIPTION
    Lecture seule sur le système : ce script ne lit que des fichiers du projet et n'écrit que le rapport HTML.
    Le rapport est autonome (CSS intégré, aucune ressource externe). Il ne contient pas le nom du PC ; le nom
    d'utilisateur n'apparaît que dans le chemin du projet des commandes admin. Il reste dans reports\ (ignoré par Git).
    Ordre des sections :
      1. Contexte + baseline (avec avertissement si elle est provisoire)
      2. Santé et stabilité EN PREMIER s'il y a écran bleu, erreur disque ou WHEA (plus important que tout réglage)
      3. Top 5 des gains (classés par gain mesurable, honnêtement)
      4. Tableau complet du catalogue
      5. Ce que je ne recommande PAS, et pourquoi
      6. Vie privée (à part : ce n'est pas de la performance)
      7. Hors périmètre, commandes admin, constats
.EXAMPLE
    .\scripts\New-AuditReport.ps1
    .\scripts\New-AuditReport.ps1 -AuditPath .\reports\audit_2026-11-07_173820\audit.json
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AuditPath,
    [string]$OutFile
)

. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $AuditPath) {
    $last = Get-ChildItem -Path (Get-WtPath 'reports') -Filter 'audit.json' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -like 'audit_*' } | Sort-Object { $_.Directory.Name } | Select-Object -Last 1
    if (-not $last) { throw "Aucun audit trouvé dans reports\. Lance d'abord .\scripts\Audit.ps1" }
    $AuditPath = $last.FullName
}
if (-not $OutFile) { $OutFile = Join-Path (Get-WtPath 'reports') 'rapport_audit.html' }

$a = Get-Content -LiteralPath $AuditPath -Raw -Encoding UTF8 | ConvertFrom-Json
$cat = Get-WtConfig 'actions'
$baselines = @(Get-ChildItem -Path (Get-WtPath 'baseline') -Filter 'baseline_*.json' -ErrorAction SilentlyContinue | Sort-Object Name |
    ForEach-Object { $b = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; $b | Add-Member -NotePropertyName Fichier -NotePropertyValue $_.Name -PassThru })

# ---------- Fonctions utilitaires ----------------------------------------------------------
function E([object]$s) { if ($null -eq $s) { '' } else { [System.Net.WebUtility]::HtmlEncode([string]$s) } }   # échappement HTML

function Get-ByPath($obj, [string]$path) {
    # Lit 'A.B.C' dans un objet issu de ConvertFrom-Json ($null si absent)
    $cur = $obj
    foreach ($p in $path.Split('.')) { if ($null -eq $cur) { return $null }; $cur = $cur.$p }
    $cur
}

function Get-ActionState($act) {
    # Renvoie @{ Code = fait|afaire|averifier ; Texte = valeur actuelle lisible }
    if (-not $act.etat) { return @{ Code = 'averifier'; Texte = "inconnu sans admin (voir commandes)" } }
    $v = Get-ByPath $a $act.etat.chemin
    if ($act.etat.faitSiVide) {
        $n = @($v | Where-Object { $_ }).Count
        return @{ Code = $(if ($n -eq 0) { 'fait' } else { 'afaire' }); Texte = "$n présente(s)" }
    }
    $txt = if ($null -eq $v) { 'non défini (valeur par défaut de Windows)' } elseif ($v -is [bool]) { if ($v) { 'oui' } else { 'non' } } else { [string]$v }
    $done = ($null -ne $v) -and ([string]$v -eq [string]$act.etat.fait)
    @{ Code = $(if ($done) { 'fait' } else { 'afaire' }); Texte = $txt }
}

function Get-MeasureText($act) {
    if (-not $act.mesure) { return '' }
    $v = Get-ByPath $a $act.mesure.chemin
    if ($null -eq $v) { return '' }
    if ($v -is [array] -or $v -is [System.Management.Automation.PSCustomObject]) {
        return (@($v) | ForEach-Object { ($_.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ' }) -join ' ; '
    }
    "$v $($act.mesure.texte)"
}

$rankClass = @{ 'gain réel mesuré' = 0; 'stabilité' = 1; 'gain marginal' = 2; 'placebo' = 3 }
function Badge([string]$kind, [string]$text) { "<span class=""badge $kind"">$(E $text)</span>" }
function RiskBadge([string]$r) { Badge "r-$r" $r }
function StateBadge($st) {
    switch ($st.Code) { 'fait' { Badge 'ok' 'déjà en place' } 'afaire' { Badge 'todo' 'à faire' } default { Badge 'unk' 'à vérifier' } }
}
function Link([string]$u) { if ($u) { "<a href=""$(E $u)"">$(E (([uri]$u).Host + ([uri]$u).AbsolutePath.Substring(0, [math]::Min(40, ([uri]$u).AbsolutePath.Length))))…</a>" } else { '—' } }

# ---------- Préparation des données ---------------------------------------------------------
$ctx = $a.Contexte
$syn = $a.A_Baseline.Demarrage.Synthese
$rep = $a.A_Baseline.Repos
$stab = $a.G_Stabilite
$hasCritical = (@($stab.EcransBleus1001).Count -gt 0) -or ([int]$stab.ErreursDisqueTotal -gt 0) -or (@($stab.ErreursWHEA).Count -gt 0)
$provisoire = ([int]$syn.NbDemarrages -lt 5) -or ($rep -and -not $rep.Representatif) -or (-not $rep)

$actions = @($cat.actions | ForEach-Object { $st = Get-ActionState $_; $_ | Add-Member -NotePropertyName Etat_ -NotePropertyValue $st -Force -PassThru })
$top = @($actions | Where-Object { $_.Etat_.Code -ne 'fait' -and $_.verifie -and $_.recommande -ne 'déjà fait' -and $_.classement -ne 'placebo' } |
    Sort-Object { $rankClass[$_.classement] }, num | Select-Object -First 5)

# ---------- HTML -----------------------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
function W([string]$s) { [void]$sb.AppendLine($s) }

W @'
<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>win-tune – rapport d'audit</title>
<style>
:root{--bg:#f7f7f5;--card:#fff;--fg:#1d1d1f;--mut:#6b6b70;--line:#e3e3e0;--ok:#1f7a3f;--okbg:#e6f4ea;--warn:#9a5b00;--warnbg:#fff3dc;--bad:#b42318;--badbg:#fdecea;--unk:#475467;--unkbg:#eef1f5;--acc:#2f5bd3}
@media (prefers-color-scheme:dark){:root{--bg:#141416;--card:#1d1d20;--fg:#ececef;--mut:#9b9ba3;--line:#2e2e33;--ok:#6fcf8f;--okbg:#17321f;--warn:#f2b44c;--warnbg:#3a2a10;--bad:#ff8a80;--badbg:#3b1715;--unk:#b8c0cc;--unkbg:#262a31;--acc:#8fb0ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px 64px}h1{font-size:26px;margin:0 0 4px}h2{font-size:19px;margin:32px 0 10px}
.sub{color:var(--mut);margin:0 0 20px}.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px;margin:12px 0}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px}.kpi{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.kpi b{display:block;font-size:22px}.kpi span{color:var(--mut);font-size:13px}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden;font-size:14px}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{background:var(--unkbg);font-weight:600}
.tw{overflow-x:auto}.badge{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}
.ok,.r-vert{background:var(--okbg);color:var(--ok)}.todo,.r-orange{background:var(--warnbg);color:var(--warn)}.r-rouge,.crit{background:var(--badbg);color:var(--bad)}.unk{background:var(--unkbg);color:var(--unk)}
.alert{border-left:4px solid var(--warn);background:var(--warnbg)}.alert.crit{border-left-color:var(--bad);background:var(--badbg);color:var(--fg)}
.mut{color:var(--mut)}code,pre{font-family:Consolas,monospace;font-size:13px}pre{background:var(--unkbg);padding:10px;border-radius:8px;overflow-x:auto;white-space:pre-wrap;word-break:break-all}
a{color:var(--acc)}ul{margin:6px 0;padding-left:20px}
</style></head><body><main>
'@

W "<h1>win-tune – rapport d'audit</h1>"
W "<p class=""sub"">Audit du $(E ([datetime]$a.Date).ToString('dd/MM/yyyy HH:mm')) · $(E $ctx.Edition) $(E $ctx.Version) (build $(E $ctx.Build)) · $(E $ctx.Type) · lecture seule</p>"

# --- Contexte ---
$sup = $ctx.Support
$supTxt = if ($sup.FinSupport) { "supporté jusqu'au $(([datetime]$sup.FinSupport).ToString('dd/MM/yyyy')) ($($sup.JoursRestants) jours)" } else { 'statut inconnu' }
W "<div class=""card""><b>Machine</b> : $(E $ctx.Processeur) ($($ctx.Coeurs) cœurs / $($ctx.Threads) threads) · $($ctx.RamGo) Go RAM · $(E (@($ctx.Gpu) -join ', ')) · Windows $(E $ctx.Version) $(E $supTxt) (<a href=""$(E $sup.Source)"">source</a>, vérifié le $(E $sup.VerifieLe))<br>"
# Attention : « W "a" + "b" » passerait "+" comme argument (mode commande) : on parenthèse.
W ("<b>Disques</b> : " + ((@($ctx.Volumes) | ForEach-Object { "$($_.Lecteur) $(E $_.Support) $(E $_.Bus) – $($_.LibreGo)/$($_.TailleGo) Go libres" }) -join ' · ') + "<br>")
W "<b>Uptime</b> : $($ctx.UptimeHeures) h · session administrateur : $(if ($ctx.Admin) { 'oui' } else { 'non' })</div>"

# --- Baseline ---
W "<h2>Baseline mesurée</h2>"
if ($provisoire) {
    W "<div class=""card alert""><b>Baseline provisoire.</b> $(if ([int]$syn.NbDemarrages -lt 5) { "Seulement $([int]$syn.NbDemarrages) démarrage(s) mesuré(s) sur ce build (installé le $(E ([datetime]$a.A_Baseline.Demarrage.BuildDepuis).ToString('dd/MM/yyyy HH:mm'))) : il en faut ~5 pour une médiane fiable. " })$(if ($rep -and -not $rep.Representatif) { 'Mesure au repos interrompue par une activité clavier/souris. ' })Ne compare pas encore AVANT/APRÈS sur ces chiffres.</div>"
}
function Sec($v) { if ($null -eq $v -or "$v" -eq '') { '—' } else { "$v s" } }   # durée ou tiret si absente
$kp = @(
    @('Démarrage (médiane)', (Sec $syn.DemarrageMedianSec), "pire $(Sec $syn.DemarragePireSec) · $([int]$syn.NbDemarrages) boot(s)"),
    @('Arrêt (médiane)', (Sec $syn.ArretMedianSec), "pire $(Sec $syn.ArretPireSec)"),
    @('CPU au repos', $(if ($rep) { "$($rep.CpuPct.Mediane) %" } else { '—' }), $(if ($rep) { "max $($rep.CpuPct.Max) %" })),
    @('RAM utilisée au repos', $(if ($rep) { "$([math]::Round($rep.RamUtiliseeMo.Mediane / 1024, 1)) Go" } else { '—' }), "sur $($ctx.RamGo) Go"),
    @('Disque actif', $(if ($rep) { "$($rep.DisqueActifPct.Mediane) %" } else { '—' }), ''),
    @('Processus / services', $(if ($rep) { "$($rep.Processus.Mediane) / $($rep.ServicesEnCours.Mediane)" } else { '—' }), $(if ($rep) { "$($rep.Handles.Mediane) handles" }))
)
W '<div class="grid">'
foreach ($k in $kp) { W "<div class=""kpi""><span>$(E $k[0])</span><b>$(E $k[1])</b><span>$(E $k[2])</span></div>" }
W '</div>'
if ($baselines.Count -gt 1) {
    W '<p class="mut">Historique des baselines (une seule est la référence : la dernière fiable avant les réglages).</p><div class="tw"><table><tr><th>Fichier</th><th>Build</th><th>Boots</th><th>Démarrage médian</th><th>CPU repos</th><th>RAM repos</th><th>Repos représentatif</th></tr>'
    foreach ($b in $baselines) {
        W "<tr><td>$(E $b.Fichier)</td><td>$(E $b.Build)</td><td>$([int]$b.Demarrage.NbDemarrages)</td><td>$(E (Sec $b.Demarrage.DemarrageMedianSec))</td><td>$(if ($b.Repos) { "$($b.Repos.CpuPct.Mediane) %" })</td><td>$(if ($b.Repos) { "$([math]::Round($b.Repos.RamUtiliseeMo.Mediane / 1024, 1)) Go" })</td><td>$(if ($b.Repos) { if ($b.Repos.Representatif) { Badge 'ok' 'oui' } else { Badge 'todo' 'non' } })</td></tr>"
    }
    W '</table></div>'
}

# --- Avant / Après (dernière vérification de Verify.ps1, s'il y en a une) ---
$verif = Get-ChildItem -Path (Get-WtPath 'reports') -Filter 'verification_*.json' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
if ($verif) {
    $v = Get-Content -LiteralPath $verif.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    W "<h2>Avant / après les réglages</h2>"
    W "<p class='mut'>Réglages du $(E ([datetime]$v.ReglagesLe).ToString('dd/MM/yyyy HH:mm')) (actions : $(E (@($v.Actions) -join ', '))) · référence $(E $v.Reference) · mesure $(E $v.Audit).</p>"
    W '<div class="tw"><table><tr><th>Mesure</th><th>Avant</th><th>Après</th><th>Écart</th><th>Conclusion</th></tr>'
    foreach ($c in $v.Comparaison) {
        $k = switch ($c.Conclusion) { 'gain mesuré' { 'ok' } 'dégradation' { 'crit' } default { 'unk' } }
        W "<tr><td>$(E $c.Mesure)</td><td>$(E $c.Avant) $(E $c.Unite)</td><td>$(E $c.Apres) $(E $c.Unite)</td><td>$(E $c.Ecart)</td><td>$(Badge $k $c.Conclusion)$(if ($c.Note) { "<br><span class='mut'>$(E $c.Note)</span>" })</td></tr>"
    }
    W '</table></div>'
    foreach ($w in @($v.Avertissements)) { if ($w) { W "<div class=""card alert"">$(E $w)</div>" } }
    W "<div class=""card""><b>Conclusion :</b> $(E $v.Conclusion)</div>"
}

# --- Santé et stabilité (section construite ici, placée avant ou après le Top 5) ---
$health = New-Object System.Text.StringBuilder
[void]$health.AppendLine('<h2>Santé et stabilité</h2>')
$gConst = @($a.Constats | Where-Object { $_.Section -in 'G', 'F' })
if ($stab.JournalSystemDepuis) {   # absent des audits antérieurs à cette version
    [void]$health.AppendLine("<p class='mut'>Journal Système disponible depuis le $(E ([datetime]$stab.JournalSystemDepuis).ToString('dd/MM/yyyy HH:mm')) (fenêtre demandée : $($stab.PeriodeJours) jours).</p>")
}
[void]$health.AppendLine('<div class="tw"><table><tr><th>Indicateur</th><th>Valeur</th></tr>')
$rows = @(
    @('Écrans bleus (BugCheck 1001)', @($stab.EcransBleus1001).Count),
    @('Arrêts inattendus (Kernel-Power 41)', @($stab.ArretsInattendusKernelPower41).Count),
    @('Erreurs matérielles WHEA', @($stab.ErreursWHEA).Count),
    @('Erreurs disque (7, 11, 51, 153)', "$([int]$stab.ErreursDisqueTotal) (dont $([int]$stab.ErreursDisqueDepuisBoot) depuis le démarrage)"),
    @('Plantages d''applis', [int]$stab.PlantagesApplis),
    @('Périphériques en erreur', $(if (@($stab.PeripheriquesEnErreur).Count) { (@($stab.PeripheriquesEnErreur) | ForEach-Object { $_.Nom }) -join ', ' } else { 0 })),
    @('Dernière mise à jour de sécurité', $(if ($a.F_MisesAJour.DerniereMajSecurite) { "$($a.F_MisesAJour.DerniereMajSecurite.KB) le $($a.F_MisesAJour.DerniereMajSecurite.Date) (il y a $($a.F_MisesAJour.DerniereMajSecurite.Jours) j)" } else { '—' }))
)
foreach ($r in $rows) { [void]$health.AppendLine("<tr><td>$(E $r[0])</td><td>$(E $r[1])</td></tr>") }
[void]$health.AppendLine('</table></div>')
if (@($stab.Top10Plantages).Count) {
    [void]$health.AppendLine('<p><b>Applis qui plantent le plus</b></p><div class="tw"><table><tr><th>Appli</th><th>Plantages</th><th>Dernier</th></tr>')
    foreach ($t in $stab.Top10Plantages) { [void]$health.AppendLine("<tr><td>$(E $t.Appli)</td><td>$(E $t.Plantages)</td><td>$(E $t.Dernier)</td></tr>") }
    [void]$health.AppendLine('</table></div>')
}
foreach ($c in $gConst) { [void]$health.AppendLine("<div class=""card alert $(if ($c.Niveau -eq 'critique') { 'crit' })"">$(E $c.Texte)</div>") }

if ($hasCritical) {
    W '<div class="card alert crit"><b>Problème de santé détecté</b> : il passe avant tout réglage de performance.</div>'
    W $health.ToString()
}

# --- Top 5 ---
W '<h2>Top 5 des gains</h2>'
W '<p class="mut">Classés par gain mesurable : gain réel mesuré &gt; stabilité &gt; gain marginal. Les réglages « placebo », « non vérifiés » ou déjà en place sont exclus.</p>'
if (-not @($actions | Where-Object { $_.classement -eq 'gain réel mesuré' -and $_.Etat_.Code -ne 'fait' }).Count) {
    W '<div class="card"><b>Constat honnête :</b> aucun réglage restant n''a de gain de vitesse mesurable sur cette machine. Les gros leviers (Démarrage rapide, hibernation, applis en arrière-plan, effets visuels) sont déjà en place. Ce qui reste relève de la stabilité ou du confort.</div>'
}
if ($top.Count) {
    W '<div class="tw"><table><tr><th>N°</th><th>Réglage</th><th>Classement</th><th>Pourquoi ici</th><th>Risque</th></tr>'
    foreach ($t in $top) { W "<tr><td>$($t.num)</td><td><b>$(E $t.titre)</b><br><span class='mut'>$(E (Get-MeasureText $t))</span></td><td>$(E $t.classement)</td><td>$(E $t.classementDetail)</td><td>$(RiskBadge $t.risque)$(if ($t.admin) { ' ' + (Badge 'unk' 'admin') })</td></tr>" }
    W '</table></div>'
}

if (-not $hasCritical) { W $health.ToString() }

# --- Catalogue complet ---
W '<h2>Catalogue complet</h2>'
W '<div class="tw"><table><tr><th>N°</th><th>Réglage</th><th>État actuel</th><th>Classement</th><th>Gain mesuré / explication</th><th>Risque</th><th>Source</th></tr>'
foreach ($x in $actions) {
    $ver = if ($x.verifie) { '' } else { '<br>' + (Badge 'crit' 'non vérifié – désactivé') + "<br><span class='mut'>$(E $x.nonVerifieDetail)</span>" }
    W "<tr><td>$($x.num)</td><td><b>$(E $x.titre)</b><br><span class='mut'>$(E $x.quoi)</span></td><td>$(StateBadge $x.Etat_)<br><span class='mut'>$(E $x.Etat_.Texte)</span></td><td>$(E $x.classement)</td><td>$(E $x.classementDetail)$(if (Get-MeasureText $x) { "<br><span class='mut'>Mesure : $(E (Get-MeasureText $x))</span>" })</td><td>$(RiskBadge $x.risque)$(if ($x.admin) { '<br>' + (Badge 'unk' 'admin') })$(if ($x.risqueDetail) { "<br><span class='mut'>$(E $x.risqueDetail)</span>" })</td><td>$(Link $x.source)$ver</td></tr>"
}
W '</table></div>'
W '<p class="mut">Annulation : chaque action a sa procédure dans config\actions.json (champ « annulation ») ; les modifications faites par Apply.ps1 sont annulables par Undo.ps1 grâce au journal de session.</p>'

# --- Non recommandé ---
W '<h2>Ce que je ne te recommande PAS, et pourquoi</h2><div class="tw"><table><tr><th>Idée répandue</th><th>Pourquoi non</th></tr>'
foreach ($n in $cat.nonRecommande) { W "<tr><td>$(E $n.titre)</td><td>$(E $n.pourquoi)</td></tr>" }
foreach ($x in @($actions | Where-Object { $_.classement -eq 'placebo' -and $_.Etat_.Code -ne 'fait' })) { W "<tr><td>$(E $x.titre) (n° $($x.num))</td><td>$(E $x.classementDetail)</td></tr>" }
W '</table></div>'

# --- Vie privée ---
$h = $a.H_ViePrivee
W '<h2>Vie privée (présenté à part : ce n''est pas un gain de performance)</h2><div class="tw"><table><tr><th>Réglage</th><th>État</th></tr>'
W "<tr><td>Télémétrie (stratégie AllowTelemetry)</td><td>$(E $h.TelemetrieStrategie) – sur l'édition Pro, 0 est traité comme le niveau minimal « Requis »</td></tr>"
W "<tr><td>Service DiagTrack</td><td>$(E $h.ServiceDiagTrack)</td></tr>"
W "<tr><td>Identifiant publicitaire</td><td>$(E $h.IdentifiantPublicitaire)</td></tr>"
W "<tr><td>Historique d'activité (stratégie)</td><td>$(if ($null -eq $h.HistoriqueActiviteStrategie) { 'non défini (réglage utilisateur)' } else { E $h.HistoriqueActiviteStrategie })</td></tr>"
W '</table></div>'

# --- Hors périmètre ---
W '<h2>Hors périmètre (signalé seulement)</h2><ul>'
foreach ($o in $cat.horsPerimetre) { W "<li><b>$(E $o.projet)</b> : $(E $o.sujet)</li>" }
W '</ul>'

# --- Commandes admin ---
if (@($a.CommandesAdmin).Count) {
    W '<h2>Commandes administrateur (à copier, rien n''est lancé)</h2>'
    foreach ($c in $a.CommandesAdmin) { W "<p class='mut'>$(E $c.Pourquoi)</p><pre>$(E $c.Commande)</pre>" }
}

# --- Tous les constats ---
W '<h2>Tous les constats de l''audit</h2><ul>'
foreach ($c in @($a.Constats | Sort-Object { @{ critique = 0; attention = 1; info = 2 }[$_.Niveau] })) {
    $k = switch ($c.Niveau) { 'critique' { 'crit' } 'attention' { 'todo' } default { 'unk' } }
    W "<li>$(Badge $k $c.Niveau) <b>$(E $c.Section)</b> : $(E $c.Texte)</li>"
}
W '</ul>'
W "<p class='mut'>Généré le $(Get-Date -Format 'dd/MM/yyyy HH:mm') par New-AuditReport.ps1 à partir de $(E (Split-Path (Split-Path $AuditPath -Parent) -Leaf))\audit.json.</p>"
W '</main></body></html>'

if ($PSCmdlet.ShouldProcess($OutFile, 'Écrire le rapport HTML')) {
    New-Item -ItemType Directory -Force -Path (Split-Path $OutFile -Parent) | Out-Null
    [IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Rapport : $OutFile" -ForegroundColor Green
}
