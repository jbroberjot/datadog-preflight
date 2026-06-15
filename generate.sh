#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Régénère les manifestes Kubernetes (un par site + le standalone) à partir de
# datadog-preflight-posix.sh. À relancer après TOUTE modification du script.
#
#   ./generate.sh                       # repo/branche par défaut
#   ./generate.sh autreuser/autrerepo   # pour un autre dépôt
#   ./generate.sh jbroberjot/datadog-preflight develop   # autre branche
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

REPO="${1:-jbroberjot/datadog-preflight}"
BRANCH="${2:-main}"
SCRIPT="datadog-preflight-posix.sh"
SITES="us1 eu us3 us5 ap1 ap2 gov"

[ -f "$SCRIPT" ] || { echo "Introuvable : $SCRIPT" >&2; exit 1; }
mkdir -p deploy

# Émet un manifeste autoporté (ConfigMap + Job) pour un site donné.
#   $1 = valeur de --site   $2 = fichier de sortie   $3 = en-tête (commentaire)
emit() {
  site="$1"; out="$2"; header="$3"
  {
    printf '%s\n' "$header"
    cat <<'CM'
apiVersion: v1
kind: ConfigMap
metadata:
  name: datadog-preflight-script
  labels: {app: datadog-preflight}
data:
  datadog-preflight.sh: |
CM
    sed 's/^/    /' "$SCRIPT"
    cat <<JOB
---
apiVersion: batch/v1
kind: Job
metadata:
  name: datadog-preflight
  labels: {app: datadog-preflight}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    metadata: {labels: {app: datadog-preflight}}
    spec:
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
      volumes: [{name: script, configMap: {name: datadog-preflight-script}}]
      containers:
        - name: preflight
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
          command: ["sh", "/scripts/datadog-preflight.sh"]
          args: ["--site", "${site}", "--network-only"]
          volumeMounts: [{name: script, mountPath: /scripts, readOnly: true}]
          resources: {requests: {cpu: "50m", memory: "32Mi"}, limits: {cpu: "200m", memory: "64Mi"}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
JOB
  } > "$out"
}

# Émet un manifeste autoporté (ConfigMap + DaemonSet) : le script complet tourne
# sur CHAQUE nœud du cluster. Le pod reste en veille après le test pour permettre
# la lecture des logs (un DaemonSet relancerait sinon le conteneur en boucle).
#   $1 = valeur de --site   $2 = fichier de sortie   $3 = en-tête (commentaire)
emit_nodes() {
  site="$1"; out="$2"; header="$3"
  {
    printf '%s\n' "$header"
    cat <<'CM'
apiVersion: v1
kind: ConfigMap
metadata:
  name: datadog-preflight-script
  labels: {app: datadog-preflight-nodes}
data:
  datadog-preflight.sh: |
CM
    sed 's/^/    /' "$SCRIPT"
    cat <<DS
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: datadog-preflight-nodes
  labels: {app: datadog-preflight-nodes}
spec:
  selector: {matchLabels: {app: datadog-preflight-nodes}}
  template:
    metadata: {labels: {app: datadog-preflight-nodes}}
    spec:
      tolerations: [{operator: Exists}]
      securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
      volumes: [{name: script, configMap: {name: datadog-preflight-script}}]
      containers:
        - name: preflight
          image: busybox:1.36
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args: ["sh /scripts/datadog-preflight.sh --site ${site} --network-only --no-color; echo '--- preflight terminé, pod en veille pour lecture des logs ---'; sleep 3600"]
          volumeMounts: [{name: script, mountPath: /scripts, readOnly: true}]
          resources: {requests: {cpu: "50m", memory: "32Mi"}, limits: {cpu: "200m", memory: "64Mi"}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}}
DS
  } > "$out"
}

# Manifestes par site
for s in $SITES; do
  url="https://raw.githubusercontent.com/${REPO}/${BRANCH}/deploy/${s}.yaml"
  hdr="# ---------------------------------------------------------------------------
# Datadog Preflight Checker — site ${s} (manifeste autoporté, GÉNÉRÉ)
# Ne pas éditer à la main : modifier ${SCRIPT} puis relancer ./generate.sh
#
#   kubectl apply -f ${url}
#   kubectl logs -f job/datadog-preflight
#   kubectl delete -f ${url}
# ---------------------------------------------------------------------------"
  emit "$s" "deploy/${s}.yaml" "$hdr"

  url_n="https://raw.githubusercontent.com/${REPO}/${BRANCH}/deploy/${s}-nodes.yaml"
  hdr_n="# ---------------------------------------------------------------------------
# Datadog Preflight Checker — site ${s}, PAR NŒUD (manifeste autoporté, GÉNÉRÉ)
# Ne pas éditer à la main : modifier ${SCRIPT} puis relancer ./generate.sh
#
#   kubectl apply -f ${url_n}
#   kubectl logs -l app=datadog-preflight-nodes --prefix --tail=-1
#   kubectl delete -f ${url_n}
# ---------------------------------------------------------------------------"
  emit_nodes "$s" "deploy/${s}-nodes.yaml" "$hdr_n"
done

# Standalone (téléchargement + édition manuelle ; défaut = eu)
hdr_std="# ---------------------------------------------------------------------------
# Datadog Preflight Checker — manifeste autoporté (GÉNÉRÉ)
# Un seul fichier, aucune image custom. Adaptez --site puis :
#   kubectl apply -f datadog-preflight-standalone.yaml
#   kubectl logs -f job/datadog-preflight
# Cluster verrouillé sans busybox en cache : remplacez l'image par votre miroir.
# ---------------------------------------------------------------------------"
emit "eu" "datadog-preflight-standalone.yaml" "$hdr_std"

echo "OK — manifestes régénérés pour ${REPO} (branche ${BRANCH})."
echo "   $(ls deploy/*.yaml | wc -l | tr -d ' ') fichiers dans deploy/ + datadog-preflight-standalone.yaml"
