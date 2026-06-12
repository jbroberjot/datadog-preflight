#!/usr/bin/env bash
#
# datadog-preflight.sh
# ---------------------------------------------------------------------------
# Vérifie qu'un hôte est prêt à accueillir l'agent Datadog AVANT de
# lancer l'installation : résolution DNS, ouverture du firewall (port 443),
# détection de proxy, prérequis système et validation optionnelle de la clé API.
#
# Usage :
#   ./datadog-preflight.sh --site eu
#   ./datadog-preflight.sh --site us5 --api-key <CLE_API>
#   ./datadog-preflight.sh --site us1 --json
#
# Codes de sortie :
#   0  Tout est bon (aucune erreur bloquante)
#   1  Au moins une erreur bloquante détectée
#   2  Erreur d'utilisation (mauvais argument)
# ---------------------------------------------------------------------------

set -u

VERSION="0.1.0"

# --------------------------------------------------------------------------
# Paramètres par défaut
# --------------------------------------------------------------------------
SITE_INPUT="us1"
API_KEY=""
OUTPUT_JSON=false
USE_COLOR=true
TIMEOUT=5          # secondes par test réseau
MIN_DISK_GB=2      # espace disque minimum recommandé pour l'agent
CHECK_LEGACY_TCP=false  # teste le canal logs TCP héritage (port 10516, US1)
NETWORK_ONLY=false      # saute les prérequis d'installation hôte (sudo/disque/init)

# --------------------------------------------------------------------------
# Compteurs et collecte des résultats (pour le rapport et le JSON)
# --------------------------------------------------------------------------
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
JSON_ITEMS=()

# --------------------------------------------------------------------------
# Aide
# --------------------------------------------------------------------------
usage() {
  cat <<EOF
Datadog Preflight Checker v${VERSION}

Vérifie qu'un serveur est prêt à recevoir l'agent Datadog.

OPTIONS :
  --site <site>      Site Datadog. Valeurs acceptées :
                       us1 (us, défaut), eu, us3, us5, ap1, ap2, gov
  --api-key <cle>    Clé API Datadog (optionnel) : teste sa validité.
                     Peut aussi être fournie via la variable DD_API_KEY.
  --json             Sortie au format JSON (pour pipelines / automatisation).
  --no-color         Désactive les couleurs.
  --timeout <sec>    Délai par test réseau (défaut : ${TIMEOUT}s).
  --check-legacy-tcp Teste aussi le canal logs TCP héritage (port 10516, US1).
                     Désactivé par défaut : ce canal est déprécié au profit
                     des logs en HTTPS sur 443.
  --network-only     Ne teste que le réseau (saute sudo/disque/init).
                     Utilisé par l'image Kubernetes.
  -h, --help         Affiche cette aide.

EXEMPLES :
  ./datadog-preflight.sh --site eu
  ./datadog-preflight.sh --site us5 --api-key abc123...
  ./datadog-preflight.sh --site us1 --json
EOF
}

# --------------------------------------------------------------------------
# Lecture des arguments
# --------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --site)      SITE_INPUT="${2:-}"; shift 2 ;;
    --api-key)   API_KEY="${2:-}"; shift 2 ;;
    --json)      OUTPUT_JSON=true; shift ;;
    --no-color)  USE_COLOR=false; shift ;;
    --timeout)   TIMEOUT="${2:-5}"; shift 2 ;;
    --check-legacy-tcp) CHECK_LEGACY_TCP=true; shift ;;
    --network-only) NETWORK_ONLY=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "Argument inconnu : $1" >&2; usage >&2; exit 2 ;;
  esac
done

# JSON force l'absence de couleur
if [ "$OUTPUT_JSON" = true ]; then
  USE_COLOR=false
fi

# La clé API peut venir de l'environnement (pratique avec un Secret Kubernetes)
if [ -z "$API_KEY" ] && [ -n "${DD_API_KEY:-}" ]; then
  API_KEY="$DD_API_KEY"
fi

# --------------------------------------------------------------------------
# Couleurs
# --------------------------------------------------------------------------
if [ "$USE_COLOR" = true ] && [ -t 1 ]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_BLUE=$'\033[0;34m';  C_BOLD=$'\033[1m';      C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

# --------------------------------------------------------------------------
# Résolution du site -> domaine complet
# --------------------------------------------------------------------------
case "$(echo "$SITE_INPUT" | tr '[:upper:]' '[:lower:]')" in
  us1|us|datadoghq.com) SITE="datadoghq.com";     SITE_NAME="US1" ;;
  eu|eu1)               SITE="datadoghq.eu";      SITE_NAME="EU1" ;;
  us3)                  SITE="us3.datadoghq.com"; SITE_NAME="US3" ;;
  us5)                  SITE="us5.datadoghq.com"; SITE_NAME="US5" ;;
  ap1)                  SITE="ap1.datadoghq.com"; SITE_NAME="AP1" ;;
  ap2)                  SITE="ap2.datadoghq.com"; SITE_NAME="AP2" ;;
  gov|fed|us1-fed)      SITE="ddog-gov.com";      SITE_NAME="GOV" ;;
  *)
    echo "Site inconnu : '$SITE_INPUT'. Utilisez us1, eu, us3, us5, ap1, ap2 ou gov." >&2
    exit 2 ;;
esac

# --------------------------------------------------------------------------
# Échappement minimal pour le JSON
# --------------------------------------------------------------------------
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  printf '%s' "$s"
}

# --------------------------------------------------------------------------
# Enregistre un résultat
#   $1 = statut (PASS|WARN|FAIL)
#   $2 = catégorie (ex: "RÉSEAU")
#   $3 = libellé court (ex: "logs.datadoghq.eu:443")
#   $4 = message
#   $5 = (optionnel) suggestion de correction
#   $6 = (optionnel) lien doc
# --------------------------------------------------------------------------
record() {
  local status="$1" cat="$2" label="$3" msg="$4"
  local fix="${5:-}" doc="${6:-}" req="${7:-}"

  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT+1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT+1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT+1)) ;;
  esac

  local required=false
  [ "$req" = req ] && required=true

  if [ "$OUTPUT_JSON" = true ]; then
    JSON_ITEMS+=("{\"status\":\"$status\",\"required\":$required,\"category\":\"$(json_escape "$cat")\",\"target\":\"$(json_escape "$label")\",\"message\":\"$(json_escape "$msg")\",\"suggestion\":\"$(json_escape "$fix")\",\"doc\":\"$(json_escape "$doc")\"}")
    return
  fi

  local mark color
  case "$status" in
    PASS) mark="[✓]"; color="$C_GREEN" ;;
    WARN) mark="[⚠]"; color="$C_YELLOW" ;;
    FAIL) mark="[✗]"; color="$C_RED" ;;
  esac

  printf "%s%s%s  %-9s %-38s %s\n" \
    "$color" "$mark" "$C_RESET" "$cat" "$label" "$msg"

  # Bloc explicatif uniquement en cas d'échec ou d'avertissement
  if [ "$status" != "PASS" ]; then
    [ -n "$fix" ] && printf "    %s► Comment corriger :%s %s\n" "$C_DIM" "$C_RESET" "$fix"
    [ -n "$doc" ] && printf "    %s► Documentation :%s    %s\n" "$C_DIM" "$C_RESET" "$doc"
    echo
  fi
}

# --------------------------------------------------------------------------
# Outils réseau
# --------------------------------------------------------------------------

# Résolution DNS portable (essaie plusieurs outils)
resolve_dns() {
  local host="$1"
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" >/dev/null 2>&1 && return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    [ -n "$(dig +short "$host" 2>/dev/null)" ] && return 0
  fi
  if command -v host >/dev/null 2>&1; then
    host "$host" >/dev/null 2>&1 && return 0
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$host" >/dev/null 2>&1 && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import socket,sys; socket.gethostbyname(sys.argv[1])" "$host" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# Test de connexion TCP via /dev/tcp (natif bash, sans dépendance)
check_tcp() {
  local host="$1" port="$2"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
  else
    ( bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1 ) &
    local pid=$!
    ( sleep "$TIMEOUT"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    wait "$pid" 2>/dev/null
  fi
}

# Vérifie un endpoint : DNS puis TCP. Distingue les deux causes pour
# proposer la bonne suggestion.
#   $1 = host  $2 = port  $3 = catégorie produit (ex: "Logs")  $4 = critique(true/false)
check_endpoint() {
  local host="$1" port="$2" product="$3" critical="${4:-true}"
  local label="${host}:${port}"
  local fail_status="FAIL" req="req"
  if [ "$critical" = "false" ]; then fail_status="WARN"; req="opt"; fi

  if ! resolve_dns "$host"; then
    record "$fail_status" "DNS" "$host" \
      "résolution impossible ($product)" \
      "Vérifiez que votre DNS interne/proxy autorise ce domaine. Ajoutez *.${SITE} à votre liste d'autorisation." \
      "https://docs.datadoghq.com/agent/configuration/network/" "$req"
    return
  fi

  if check_tcp "$host" "$port"; then
    record "PASS" "RÉSEAU" "$label" "accessible ($product)" "" "" "$req"
  else
    record "$fail_status" "RÉSEAU" "$label" \
      "connexion refusée ou bloquée ($product)" \
      "Ouvrez le port TCP $port sortant vers $host dans votre firewall ou proxy." \
      "https://docs.datadoghq.com/agent/configuration/network/" "$req"
  fi
}

# --------------------------------------------------------------------------
# En-tête
# --------------------------------------------------------------------------
print_header() {
  [ "$OUTPUT_JSON" = true ] && return
  echo
  printf "%s========================================%s\n" "$C_BOLD" "$C_RESET"
  printf "%s  Datadog Preflight Checker%s   [site %s]\n" "$C_BOLD" "$C_RESET" "$SITE_NAME"
  printf "%s========================================%s\n" "$C_BOLD" "$C_RESET"
  printf "%s[✓] ok   [⚠] avertissement (non bloquant)   [✗] bloquant%s\n" "$C_DIM" "$C_RESET"
  printf "%sLes sections INDISPENSABLE doivent être au vert. Les sections%s\n" "$C_DIM" "$C_RESET"
  printf "%sOPTIONNEL dépendent des produits Datadog que vous activez.%s\n" "$C_DIM" "$C_RESET"
  echo
}

print_section() {
  [ "$OUTPUT_JSON" = true ] && return
  printf "%s%s%s\n" "$C_BLUE" "── $1" "$C_RESET"
}

# ==========================================================================
# DÉBUT DES VÉRIFICATIONS
# ==========================================================================
print_header

# --------------------------------------------------------------------------
# 1. Prérequis système
# --------------------------------------------------------------------------
print_section "Système"

# OS et distribution
OS="$(uname -s 2>/dev/null || echo inconnu)"
case "$OS" in
  Linux)
    if [ -r /etc/os-release ]; then
      . /etc/os-release
      record "PASS" "SYSTÈME" "OS" "${NAME:-Linux} ${VERSION_ID:-} ($(uname -m))"
    else
      record "PASS" "SYSTÈME" "OS" "Linux ($(uname -m))"
    fi
    ;;
  Darwin)
    record "PASS" "SYSTÈME" "OS" "macOS ($(uname -m))"
    ;;
  *)
    record "WARN" "SYSTÈME" "OS" "système non reconnu : $OS" \
      "Ce script cible Linux et macOS. Sous Windows, utilisez la version PowerShell."
    ;;
esac

# Droits, disque et init ne concernent que l'installation directe sur un hôte.
# En mode --network-only (ex: image Kubernetes), on les saute.
if [ "$NETWORK_ONLY" = false ]; then

# Droits d'installation (root ou sudo)
if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
  record "PASS" "SYSTÈME" "Droits" "exécution en root"
elif command -v sudo >/dev/null 2>&1; then
  record "PASS" "SYSTÈME" "Droits" "sudo disponible"
else
  record "WARN" "SYSTÈME" "Droits" "ni root ni sudo détectés" \
    "L'installation de l'agent requiert des droits administrateur (root ou sudo)."
fi

# Espace disque (agent installé sous /opt/datadog-agent)
disk_target="/opt"; [ -d "$disk_target" ] || disk_target="/"
avail_kb="$(df -Pk "$disk_target" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${avail_kb:-}" ] && [ "$avail_kb" -gt 0 ] 2>/dev/null; then
  avail_gb=$(( avail_kb / 1024 / 1024 ))
  if [ "$avail_gb" -ge "$MIN_DISK_GB" ]; then
    record "PASS" "SYSTÈME" "Espace disque" "${avail_gb} Go disponibles sur ${disk_target}"
  else
    record "WARN" "SYSTÈME" "Espace disque" "${avail_gb} Go sur ${disk_target} (min. recommandé : ${MIN_DISK_GB} Go)" \
      "Libérez de l'espace ou installez l'agent sur un volume plus grand."
  fi
else
  record "WARN" "SYSTÈME" "Espace disque" "impossible de mesurer l'espace disque"
fi

# Système d'init (utile pour le démarrage du service agent sous Linux)
if [ "$OS" = "Linux" ]; then
  if command -v systemctl >/dev/null 2>&1; then
    record "PASS" "SYSTÈME" "Init" "systemd détecté"
  elif [ -d /etc/init ]; then
    record "PASS" "SYSTÈME" "Init" "upstart détecté"
  else
    record "WARN" "SYSTÈME" "Init" "gestionnaire de services non identifié" \
      "L'agent utilise systemd ou upstart pour démarrer automatiquement."
  fi
fi

fi  # fin du bloc --network-only

# --------------------------------------------------------------------------
# 2. Proxy
# --------------------------------------------------------------------------
print_section "Proxy"

proxy_found=""
for v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy DD_PROXY_HTTP DD_PROXY_HTTPS; do
  val="$(eval "echo \${$v:-}")"
  [ -n "$val" ] && proxy_found="$proxy_found $v=$val"
done

if [ -n "$proxy_found" ]; then
  record "WARN" "PROXY" "Variables d'env" "proxy détecté :${proxy_found}" \
    "L'agent doit être configuré pour utiliser ce proxy (section 'proxy' de datadog.yaml)." \
    "https://docs.datadoghq.com/agent/configuration/proxy/"
else
  record "PASS" "PROXY" "Variables d'env" "aucun proxy système détecté"
fi

# --------------------------------------------------------------------------
# 3. Endpoints d'installation (téléchargement de l'agent — non liés au site)
# --------------------------------------------------------------------------
print_section "Téléchargement de l'agent — INDISPENSABLE"

check_endpoint "install.datadoghq.com"       443 "Installation"        true
check_endpoint "keys.datadoghq.com"          443 "Clés GPG"            true

print_section "Téléchargement de l'agent — selon votre distribution"
check_endpoint "apt.datadoghq.com"           443 "Dépôt APT (Debian/Ubuntu)" false
check_endpoint "yum.datadoghq.com"           443 "Dépôt YUM (RHEL/CentOS)"   false

# --------------------------------------------------------------------------
# 4. Endpoints applicatifs (dépendent du site)
# --------------------------------------------------------------------------
print_section "Communication avec Datadog (${SITE_NAME}) — INDISPENSABLE"

# Métriques / cœur agent : domaine versionné sous le wildcard *.agent.<site>
check_endpoint "7-50-0-app.agent.${SITE}"    443 "Métriques"           true
check_endpoint "api.${SITE}"                 443 "API & validation clé" true
check_endpoint "trace.agent.${SITE}"         443 "APM / traces"        true
check_endpoint "agent-http-intake.logs.${SITE}" 443 "Logs (HTTPS)"     true
check_endpoint "process.${SITE}"             443 "Processus / conteneurs" true

print_section "Communication avec Datadog (${SITE_NAME}) — OPTIONNEL (selon produits activés)"
check_endpoint "orchestrator.${SITE}"        443 "Orchestrator (K8s)"  false
check_endpoint "config.${SITE}"              443 "Remote Configuration" false
check_endpoint "intake.profile.${SITE}"      443 "Profiling"           false

# Logs over TCP : héritage, uniquement pertinent pour US1 (port 10516).
# Désactivé par défaut car déprécié au profit des logs HTTPS sur 443.
if [ "$CHECK_LEGACY_TCP" = true ] && [ "$SITE_NAME" = "US1" ]; then
  check_endpoint "agent-intake.logs.${SITE}" 10516 "Logs TCP (héritage)" false
fi

# --------------------------------------------------------------------------
# 5. Validation de la clé API (optionnel)
# --------------------------------------------------------------------------
if [ -n "$API_KEY" ]; then
  print_section "Validation de la clé API"
  if command -v curl >/dev/null 2>&1; then
    http_code="$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
      -H "DD-API-KEY: ${API_KEY}" \
      "https://api.${SITE}/api/v1/validate" 2>/dev/null)"
    case "$http_code" in
      200) record "PASS" "CLÉ API" "api.${SITE}" "clé API valide" "" "" "req" ;;
      403) record "FAIL" "CLÉ API" "api.${SITE}" "clé API refusée (403)" \
             "Vérifiez la clé dans Organization Settings > API Keys." \
             "https://app.${SITE}/organization-settings/api-keys" "req" ;;
      000) record "WARN" "CLÉ API" "api.${SITE}" "aucune réponse (réseau ?)" \
             "La connexion à api.${SITE} a échoué : voir les tests réseau ci-dessus." ;;
      *)   record "WARN" "CLÉ API" "api.${SITE}" "réponse inattendue (HTTP $http_code)" ;;
    esac
  else
    record "WARN" "CLÉ API" "-" "curl absent, validation impossible" \
      "Installez curl pour activer la validation de la clé API."
  fi
fi

# ==========================================================================
# RAPPORT FINAL
# ==========================================================================
if [ "$OUTPUT_JSON" = true ]; then
  total=$((PASS_COUNT + WARN_COUNT + FAIL_COUNT))
  printf '{\n'
  printf '  "site": "%s",\n' "$SITE_NAME"
  printf '  "site_domain": "%s",\n' "$SITE"
  printf '  "summary": {"pass": %d, "warn": %d, "fail": %d, "total": %d},\n' \
    "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$total"
  printf '  "ready": %s,\n' "$([ "$FAIL_COUNT" -eq 0 ] && echo true || echo false)"
  printf '  "checks": [\n'
  for i in "${!JSON_ITEMS[@]}"; do
    sep=","; [ "$i" -eq $((${#JSON_ITEMS[@]} - 1)) ] && sep=""
    printf '    %s%s\n' "${JSON_ITEMS[$i]}" "$sep"
  done
  printf '  ]\n'
  printf '}\n'
else
  echo
  printf "%s----------------------------------------%s\n" "$C_BOLD" "$C_RESET"
  printf "RÉSULTAT : %s%d réussis%s · %s%d avertissements%s · %s%d bloquants%s\n" \
    "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
    "$C_YELLOW" "$WARN_COUNT" "$C_RESET" \
    "$C_RED" "$FAIL_COUNT" "$C_RESET"
  if [ "$FAIL_COUNT" -eq 0 ]; then
    printf "%s✓ Tous les contrôles INDISPENSABLES sont au vert : prêt pour l'agent Datadog.%s\n" "$C_GREEN" "$C_RESET"
    if [ "$WARN_COUNT" -gt 0 ]; then
      printf "%s  Les avertissements concernent des fonctions optionnelles, à vérifier seulement%s\n" "$C_DIM" "$C_RESET"
      printf "%s  selon les produits Datadog que vous comptez activer.%s\n" "$C_DIM" "$C_RESET"
    fi
  else
    printf "%s✗ Un contrôle INDISPENSABLE a échoué : l'agent ne fonctionnera pas correctement%s\n" "$C_RED" "$C_RESET"
    printf "%s  tant qu'il n'est pas corrigé (voir les lignes [✗] ci-dessus).%s\n" "$C_RED" "$C_RESET"
  fi
  printf "%s----------------------------------------%s\n" "$C_BOLD" "$C_RESET"
fi

# Code de sortie : 1 si au moins une erreur bloquante
[ "$FAIL_COUNT" -eq 0 ]
