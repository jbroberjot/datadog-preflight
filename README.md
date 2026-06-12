# Datadog Preflight Checker

Vérifie qu'un hôte ou un cluster est prêt à accueillir l'agent Datadog **avant**
l'installation : résolution DNS, ouverture du firewall (port 443), détection de
proxy, prérequis système et validation optionnelle de la clé API.

La sortie est volontairement didactique : chaque échec explique ce qui ne va pas,
**comment le corriger**, et pointe vers la documentation.

## 1. Sur un serveur (Linux / macOS)

```bash
chmod +x datadog-preflight.sh
./datadog-preflight.sh --site eu
```

Options principales :

| Option               | Effet                                                        |
| -------------------- | ------------------------------------------------------------ |
| `--site <site>`      | `us1` (défaut), `eu`, `us3`, `us5`, `ap1`, `ap2`, `gov`      |
| `--api-key <cle>`    | Valide la clé API (ou via la variable `DD_API_KEY`)          |
| `--json`             | Sortie JSON pour pipeline / automatisation                  |
| `--no-color`         | Désactive les couleurs                                       |
| `--timeout <sec>`    | Délai par test réseau (défaut : 5 s)                         |
| `--network-only`     | Ne teste que le réseau (saute sudo / disque / init)          |
| `--check-legacy-tcp` | Teste aussi le canal logs TCP héritage (port 10516, US1)     |

Code de sortie : `0` si l'hôte est prêt, `1` si une erreur bloquante est détectée
(pratique en CI).

## 2. Dans un cluster Kubernetes

L'intérêt : tester la connectivité **depuis le réseau du cluster** — c'est-à-dire
exactement ce que verra l'agent une fois déployé, et non depuis le poste de l'ops.

### Modèle de distribution

L'image est **publiée une seule fois** sur GitHub Container Registry (GHCR), un
registre public gratuit. Les clients n'ont rien à construire : ils tirent l'image
publique directement.

Côté mainteneur (vous) :

- Le workflow `.github/workflows/build.yml` construit l'image **multi-arch**
  (amd64 + arm64) et la publie sur GHCR à chaque push. Aucun `docker build`
  manuel.
- Après le premier build, rendez le package **public** une fois :
  dépôt GitHub → onglet *Packages* → le package → *Package settings* →
  *Change visibility* → *Public*.

L'image est alors disponible à `ghcr.io/jbroberjot/datadog-preflight:latest`.

> Build local optionnel, si vous voulez tester avant la CI (non requis) :
> `docker build -t datadog-preflight:latest .` puis
> `docker run --rm datadog-preflight:latest --site eu`

### Côté client : aucune construction

Le client adapte simplement l'image et le `--site` dans `datadog-preflight-job.yaml`,
puis applique le manifeste (voir ci-dessous). Le runtime du cluster
(containerd / CRI-O) tire l'image publique automatiquement.

### (Optionnel) clé API via Secret

```bash
kubectl create secret generic datadog-preflight-key \
  --from-literal=api-key=<VOTRE_CLE_API>
```

Puis décommentez le bloc `env:` dans `datadog-preflight-job.yaml`.

### Lancer le Job et lire le rapport

```bash
# Adaptez l'image et le --site dans le manifeste au préalable
kubectl apply -f datadog-preflight-job.yaml
kubectl logs -f job/datadog-preflight
kubectl delete -f datadog-preflight-job.yaml
```

## 3. Variante universelle : ConfigMap autoporté (sans image custom)

Pour les clusters verrouillés (egress restreint, registres externes interdits),
le fichier `datadog-preflight-standalone.yaml` embarque le script POSIX
(`datadog-preflight-posix.sh`) dans un ConfigMap et l'exécute sur **busybox** —
l'image la plus susceptible d'être déjà présente sur les nœuds. Avec
`imagePullPolicy: IfNotPresent`, si busybox est en cache, il n'y a **aucun pull**.

Aucune image custom à construire, distribuer ou recopier : un seul `kubectl apply`.

```bash
# Adaptez le --site dans le manifeste, puis :
kubectl apply -f datadog-preflight-standalone.yaml
kubectl logs -f job/datadog-preflight
kubectl delete -f datadog-preflight-standalone.yaml
```

Si le cluster n'a pas busybox en cache et ne peut pas le tirer, remplacez l'image
par votre miroir interne (`harbor.interne/busybox:1.36`).

Particularités de ce mode (script POSIX/busybox) :

- Test TCP via `nc`, résolution DNS via `nslookup` — tous deux fournis par busybox.
- Détection automatique du support de `nc -z` : chemin rapide si disponible,
  sinon repli busybox (chaque endpoint accessible prend ~le délai `--timeout`,
  soit un run d'environ 40 s — normal pour un Job ponctuel).
- Validation de clé API en best-effort : `curl` n'étant pas dans busybox, ce
  check est sauté (avertissement) plutôt que de planter.

Pour régénérer le manifeste après modification du script :

```bash
kubectl create configmap datadog-preflight-script \
  --from-file=datadog-preflight.sh=datadog-preflight-posix.sh \
  --dry-run=client -o yaml
```

## Quel modèle choisir ?

| Contexte                                   | Fichier                              |
| ------------------------------------------ | ------------------------------------ |
| Hôte unique (Linux/macOS), POC manuel      | `datadog-preflight.sh`               |
| Cluster ouvert, image publiée sur GHCR     | `datadog-preflight-job.yaml` + image |
| Cluster verrouillé / zéro distribution     | `datadog-preflight-standalone.yaml`  |

## Ce qui est vérifié

- **Système** (hors `--network-only`) : OS, droits root/sudo, espace disque, init
- **Proxy** : variables d'environnement `HTTP(S)_PROXY`, `DD_PROXY_*`
- **Téléchargement** : `install` / `apt` / `yum` / `keys.datadoghq.com`
- **Communication Datadog** (selon le site) : métriques, API, APM, logs HTTPS,
  processus/conteneurs, orchestrator K8s, remote configuration, profiling
- **Clé API** (si fournie) : appel à `/api/v1/validate`

## Limites connues

- Les endpoints `*.agent.<site>` sont des wildcards DNS ; un domaine versionné
  représentatif est testé pour la connectivité. La suggestion d'autorisation
  `*.agent.<site>` reste valable quelle que soit la version de l'agent.
- Sur les réseaux qui réécrivent les domaines inconnus (NXDOMAIN rewriting),
  le test DNS peut passer à tort. Le test TCP, lui, reste fiable.
