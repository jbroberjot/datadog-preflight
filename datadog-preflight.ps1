#requires -Version 5.1
<#
.SYNOPSIS
  Datadog Preflight Checker (Windows / PowerShell).
  Vérifie qu'un hôte Windows est prêt à recevoir l'agent Datadog AVANT
  l'installation : DNS, pare-feu (443), proxy, prérequis système et
  validation optionnelle de la clé API.

.EXAMPLE
  .\datadog-preflight.ps1 -Site eu
  .\datadog-preflight.ps1 -Site us5 -ApiKey <CLE>
  .\datadog-preflight.ps1 -Site eu -Json
#>
[CmdletBinding()]
param(
  [string]$Site = "us1",
  [string]$ApiKey = $env:DD_API_KEY,
  [switch]$Json,
  [int]$Timeout = 3,
  [switch]$CheckLegacyTcp,
  [switch]$Help
)

$ErrorActionPreference = "SilentlyContinue"

if ($Help) {
  @"
Datadog Preflight Checker (Windows)

PARAMÈTRES :
  -Site <site>       us1 (défaut), eu, us3, us5, ap1, ap2, gov
  -ApiKey <cle>      Clé API (ou variable d'environnement DD_API_KEY)
  -Json              Sortie JSON
  -Timeout <sec>     Délai par test réseau (défaut : 3)
  -CheckLegacyTcp    Teste aussi le canal logs TCP héritage (port 10516, US1)
"@ | Write-Host
  exit 0
}

# --- Résolution du site -> domaine -----------------------------------------
$sites = @{
  "us1"="datadoghq.com"; "us"="datadoghq.com"; "eu"="datadoghq.eu"; "eu1"="datadoghq.eu";
  "us3"="us3.datadoghq.com"; "us5"="us5.datadoghq.com";
  "ap1"="ap1.datadoghq.com"; "ap2"="ap2.datadoghq.com"; "gov"="ddog-gov.com"
}
$siteNames = @{
  "datadoghq.com"="US1"; "datadoghq.eu"="EU1"; "us3.datadoghq.com"="US3";
  "us5.datadoghq.com"="US5"; "ap1.datadoghq.com"="AP1"; "ap2.datadoghq.com"="AP2";
  "ddog-gov.com"="GOV"
}
$key = $Site.ToLower()
if (-not $sites.ContainsKey($key)) {
  Write-Host "Site inconnu : '$Site'. Utilisez us1, eu, us3, us5, ap1, ap2 ou gov." -ForegroundColor Red
  exit 2
}
$SITE = $sites[$key]
$SITE_NAME = $siteNames[$SITE]

# --- État -------------------------------------------------------------------
$script:Pass = 0; $script:Warn = 0; $script:Fail = 0
$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
  param($Status, $Category, $Target, $Message, $Fix="", $Doc="", [bool]$Required=$false)
  switch ($Status) { "PASS" {$script:Pass++} "WARN" {$script:Warn++} "FAIL" {$script:Fail++} }
  $script:Results.Add([pscustomobject]@{
    status=$Status; required=$Required; category=$Category; target=$Target
    message=$Message; suggestion=$Fix; doc=$Doc
  })
  if ($Json) { return }

  switch ($Status) {
    "PASS" { $mark="[v]"; $color="Green" }
    "WARN" { $mark="[!]"; $color="Yellow" }
    "FAIL" { $mark="[x]"; $color="Red" }
  }
  Write-Host $mark -ForegroundColor $color -NoNewline
  Write-Host ("  {0,-9} {1,-38} {2}" -f $Category, $Target, $Message)
  if ($Status -ne "PASS") {
    if ($Fix) { Write-Host "    > Comment corriger : $Fix" -ForegroundColor DarkGray }
    if ($Doc) { Write-Host "    > Documentation :    $Doc" -ForegroundColor DarkGray }
    Write-Host ""
  }
}

function Write-Section($title) { if (-not $Json) { Write-Host "-- $title" -ForegroundColor Cyan } }

# --- Tests réseau -----------------------------------------------------------
function Test-DnsResolves($hostName) {
  try { [System.Net.Dns]::GetHostAddresses($hostName) | Out-Null; return $true }
  catch { return $false }
}

function Test-Tcp($hostName, $port) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($hostName, $port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($Timeout))
    if ($ok -and $client.Connected) { $client.EndConnect($iar); return $true }
    return $false
  } catch { return $false }
  finally { $client.Close() }
}

function Test-Endpoint {
  param($HostName, $Port, $Product, [bool]$Critical=$true)
  $label = "$HostName`:$Port"
  $failStatus = if ($Critical) { "FAIL" } else { "WARN" }

  if (-not (Test-DnsResolves $HostName)) {
    Add-Result $failStatus "DNS" $HostName "résolution impossible ($Product)" `
      "Vérifiez que votre DNS/proxy autorise ce domaine. Ajoutez *.$SITE à la liste d'autorisation." `
      "https://docs.datadoghq.com/agent/configuration/network/" $Critical
    return
  }
  if (Test-Tcp $HostName $Port) {
    Add-Result "PASS" "RÉSEAU" $label "accessible ($Product)" "" "" $Critical
  } else {
    Add-Result $failStatus "RÉSEAU" $label "connexion refusée ou bloquée ($Product)" `
      "Ouvrez le port TCP $Port sortant vers $HostName dans votre pare-feu ou proxy." `
      "https://docs.datadoghq.com/agent/configuration/network/" $Critical
  }
}

# --- En-tête ----------------------------------------------------------------
if (-not $Json) {
  Write-Host ""
  Write-Host "========================================"
  Write-Host "  Datadog Preflight Checker   [site $SITE_NAME]"
  Write-Host "========================================"
  Write-Host "[v] ok   [!] avertissement (non bloquant)   [x] bloquant" -ForegroundColor DarkGray
  Write-Host "Les sections INDISPENSABLE doivent etre au vert. Les sections" -ForegroundColor DarkGray
  Write-Host "OPTIONNEL dependent des produits Datadog que vous activez." -ForegroundColor DarkGray
  Write-Host ""
}

# --- 1. Système -------------------------------------------------------------
Write-Section "Système"
$os = (Get-CimInstance Win32_OperatingSystem).Caption
if (-not $os) { $os = [System.Environment]::OSVersion.VersionString }
Add-Result "PASS" "SYSTÈME" "OS" "$os ($($env:PROCESSOR_ARCHITECTURE))"

# Droits administrateur
$isAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
  Add-Result "PASS" "SYSTÈME" "Droits" "exécution en administrateur"
} else {
  Add-Result "WARN" "SYSTÈME" "Droits" "non administrateur" `
    "L'installation de l'agent requiert des droits administrateur (clic droit > Exécuter en tant qu'administrateur)."
}

# Espace disque (lecteur système)
$sysDrive = $env:SystemDrive.TrimEnd(":")
$free = (Get-PSDrive -Name $sysDrive).Free
if ($free) {
  $freeGb = [math]::Round($free / 1GB)
  if ($freeGb -ge 2) {
    Add-Result "PASS" "SYSTÈME" "Espace disque" "$freeGb Go disponibles sur ${sysDrive}:"
  } else {
    Add-Result "WARN" "SYSTÈME" "Espace disque" "$freeGb Go sur ${sysDrive}: (min. recommandé : 2 Go)" `
      "Libérez de l'espace avant d'installer l'agent."
  }
}

# --- 2. Proxy ---------------------------------------------------------------
Write-Section "Proxy"
$proxyFound = @()
foreach ($v in "HTTP_PROXY","HTTPS_PROXY","DD_PROXY_HTTP","DD_PROXY_HTTPS") {
  $val = [System.Environment]::GetEnvironmentVariable($v)
  if ($val) { $proxyFound += "$v=$val" }
}
$sysProxy = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy("https://api.$SITE")
if ($sysProxy -and $sysProxy.Host -ne "api.$SITE") { $proxyFound += "système=$($sysProxy.AbsoluteUri)" }
if ($proxyFound.Count -gt 0) {
  Add-Result "WARN" "PROXY" "Configuration" ("proxy détecté : " + ($proxyFound -join " ")) `
    "L'agent doit être configuré pour ce proxy (section 'proxy' de datadog.yaml)." `
    "https://docs.datadoghq.com/agent/configuration/proxy/"
} else {
  Add-Result "PASS" "PROXY" "Configuration" "aucun proxy détecté"
}

# --- 3. Téléchargement de l'agent ------------------------------------------
Write-Section "Téléchargement de l'agent — INDISPENSABLE"
Test-Endpoint "install.datadoghq.com"     443 "Installation" $true
Test-Endpoint "windows-agent.datadoghq.com" 443 "Binaire Windows" $true
Test-Endpoint "keys.datadoghq.com"        443 "Clés GPG" $true

# --- 4. Communication Datadog ----------------------------------------------
Write-Section "Communication avec Datadog ($SITE_NAME) — INDISPENSABLE"
Test-Endpoint "7-50-0-app.agent.$SITE"        443 "Métriques" $true
Test-Endpoint "api.$SITE"                     443 "API & validation clé" $true
Test-Endpoint "trace.agent.$SITE"             443 "APM / traces" $true
Test-Endpoint "agent-http-intake.logs.$SITE"  443 "Logs (HTTPS)" $true
Test-Endpoint "process.$SITE"                 443 "Processus / conteneurs" $true

Write-Section "Communication avec Datadog ($SITE_NAME) — OPTIONNEL (selon produits activés)"
Test-Endpoint "orchestrator.$SITE"   443 "Orchestrator" $false
Test-Endpoint "config.$SITE"         443 "Remote Configuration" $false
Test-Endpoint "intake.profile.$SITE" 443 "Profiling" $false

if ($CheckLegacyTcp -and $SITE_NAME -eq "US1") {
  Test-Endpoint "agent-intake.logs.$SITE" 10516 "Logs TCP (héritage)" $false
}

# --- 5. Validation de la clé API -------------------------------------------
if ($ApiKey) {
  Write-Section "Validation de la clé API"
  $code = 0
  try {
    $resp = Invoke-WebRequest -Uri "https://api.$SITE/api/v1/validate" `
      -Headers @{ "DD-API-KEY" = $ApiKey } -UseBasicParsing -TimeoutSec $Timeout
    $code = [int]$resp.StatusCode
  } catch {
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode.value__ }
  }
  switch ($code) {
    200 { Add-Result "PASS" "CLÉ API" "api.$SITE" "clé API valide" "" "" $true }
    403 { Add-Result "FAIL" "CLÉ API" "api.$SITE" "clé API refusée (403)" `
            "Vérifiez la clé dans Organization Settings > API Keys." "" $true }
    0   { Add-Result "WARN" "CLÉ API" "api.$SITE" "aucune réponse (réseau ?)" `
            "La connexion à api.$SITE a échoué : voir les tests réseau ci-dessus." }
    default { Add-Result "WARN" "CLÉ API" "api.$SITE" "réponse inattendue (HTTP $code)" }
  }
}

# --- Rapport final ----------------------------------------------------------
if ($Json) {
  $total = $script:Pass + $script:Warn + $script:Fail
  [pscustomobject]@{
    site = $SITE_NAME; site_domain = $SITE
    summary = [pscustomobject]@{ pass=$script:Pass; warn=$script:Warn; fail=$script:Fail; total=$total }
    ready = ($script:Fail -eq 0)
    checks = $script:Results
  } | ConvertTo-Json -Depth 5
} else {
  Write-Host ""
  Write-Host "----------------------------------------"
  Write-Host "RÉSULTAT : " -NoNewline
  Write-Host "$($script:Pass) réussis" -ForegroundColor Green -NoNewline
  Write-Host " · " -NoNewline
  Write-Host "$($script:Warn) avertissements" -ForegroundColor Yellow -NoNewline
  Write-Host " · " -NoNewline
  Write-Host "$($script:Fail) bloquants" -ForegroundColor Red
  if ($script:Fail -eq 0) {
    Write-Host "[v] Tous les contrôles INDISPENSABLES sont au vert : prêt pour l'agent Datadog." -ForegroundColor Green
    if ($script:Warn -gt 0) {
      Write-Host "    Les avertissements concernent des fonctions optionnelles, à vérifier" -ForegroundColor DarkGray
      Write-Host "    seulement selon les produits Datadog que vous comptez activer." -ForegroundColor DarkGray
    }
  } else {
    Write-Host "[x] Un contrôle INDISPENSABLE a échoué : l'agent ne fonctionnera pas" -ForegroundColor Red
    Write-Host "    correctement tant qu'il n'est pas corrigé (voir les lignes [x] ci-dessus)." -ForegroundColor Red
  }
  Write-Host "----------------------------------------"
}

if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
