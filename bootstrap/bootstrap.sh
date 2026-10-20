#!/usr/bin/env bash
# Amorçage du cluster homelab. Tout le reste est géré par Argo CD.
#
#   ./bootstrap.sh server      # sur le premier node (control plane)
#   ./bootstrap.sh agent       # sur chaque node agent
#   ./bootstrap.sh platform    # là où kubectl et helm pointent vers le cluster
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"

server() {
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="$K3S_CHANNEL" sh -s - server \
    --secrets-encryption \
    --write-kubeconfig-mode 600
  echo
  echo "Jeton pour les agents : sudo cat /var/lib/rancher/k3s/server/node-token"
}

agent() {
  read -rp "URL du server (ex. https://shokunin1.home.muskegg.com:6443) : " K3S_URL
  read -rsp "Jeton du server : " K3S_TOKEN
  echo
  # Passé par l'environnement pour ne pas apparaître dans la liste des processus
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
    K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" sh -s - agent
}

platform() {
  for bin in kubectl helm; do
    command -v "$bin" >/dev/null || { echo "$bin introuvable" >&2; exit 1; }
  done

  # Le seul secret créé à la main : le jeton du compte de service 1Password
  kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
  if ! kubectl -n external-secrets get secret onepassword-token >/dev/null 2>&1; then
    read -rsp "Jeton du compte de service 1Password : " OP_TOKEN
    echo
    kubectl -n external-secrets create secret generic onepassword-token \
      --from-file=token=/dev/stdin <<<"$OP_TOKEN"
    unset OP_TOKEN
  fi

  # Même version que l'Application argocd, pour qu'Argo CD se reprenne sans changement
  local argocd_version
  argocd_version="$(awk '/chart: argo-cd/{f=1} f && /targetRevision:/{print $2; exit}' \
    "$REPO_ROOT/clusters/homelab/apps/argocd.yaml")"

  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --version "$argocd_version" \
    --namespace argocd --create-namespace \
    --values "$REPO_ROOT/platform/argocd/values.yaml" \
    --wait

  kubectl apply -f "$REPO_ROOT/clusters/homelab/root.yaml"
  echo "Argo CD installé ($argocd_version). L'application root déploie maintenant le reste."
}

case "${1:-}" in
  server|agent|platform) "$1" ;;
  *) echo "Usage : $0 {server|agent|platform}" >&2; exit 1 ;;
esac
