#!/usr/bin/env bash
# Amorçage du cluster Talos sur Proxmox. Tout le reste est géré par Argo CD.
#
#   ./bootstrap.sh config                    # génère les configs dans _out/ (secrets compris)
#   ./bootstrap.sh apply shokunin1 <ip-dhcp> # pousse la config à une VM en mode maintenance
#   ./bootstrap.sh bootstrap                 # démarre etcd (une seule fois) et récupère le kubeconfig
#   ./bootstrap.sh platform                  # installe Argo CD et l'application root
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/_out"
# shellcheck source=../talos/talos.env
# tr retire les CRLF si le fichier a été édité sous Windows
source <(tr -d '\r' < "$REPO_ROOT/talos/talos.env")
export TALOSCONFIG="$OUT/talosconfig"

NODES=(192.168.1.41 192.168.1.42 192.168.1.43)

require() {
  for bin in "$@"; do
    command -v "$bin" >/dev/null || { echo "$bin introuvable" >&2; exit 1; }
  done
}

config() {
  require talosctl curl
  mkdir -p "$OUT"

  local client
  client="$(talosctl version --client --short | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [[ "$client" != "$TALOS_VERSION" ]]; then
    echo "Attention : talosctl $client, mais le cluster vise $TALOS_VERSION" >&2
  fi

  # La PKI du cluster : à sauvegarder dans 1Password, jamais dans Git
  if [[ ! -f "$OUT/secrets.yaml" ]]; then
    talosctl gen secrets -o "$OUT/secrets.yaml"
    echo ">>> Sauvegarde $OUT/secrets.yaml dans 1Password maintenant."
  fi

  local schematic_id
  schematic_id="$(curl -sf -X POST --data-binary @"$REPO_ROOT/talos/schematic.yaml" \
    https://factory.talos.dev/schematics | sed -E 's/.*"id":"([a-f0-9]+)".*/\1/')"

  talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
    --with-secrets "$OUT/secrets.yaml" \
    --install-image "factory.talos.dev/metal-installer/${schematic_id}:${TALOS_VERSION}" \
    --config-patch @"$REPO_ROOT/talos/patches/all.yaml" \
    --config-patch-control-plane @"$REPO_ROOT/talos/patches/controlplane.yaml" \
    --output-types controlplane,talosconfig \
    --output "$OUT" --force

  talosctl config endpoint "${NODES[@]}"
  talosctl config node "${NODES[0]}"
  echo "Configs prêtes dans $OUT (image ${schematic_id:0:12}…:${TALOS_VERSION})."
}

apply() {
  local node="${1:?nom du node requis}" ip="${2:?IP DHCP temporaire requise}"
  require talosctl
  talosctl apply-config --insecure --nodes "$ip" \
    --file "$OUT/controlplane.yaml" \
    --config-patch @"$REPO_ROOT/talos/nodes/$node.yaml"
  echo "$node installe Talos et redémarrera avec son IP fixe."
}

bootstrap() {
  require talosctl kubectl
  talosctl bootstrap --nodes "${NODES[0]}"
  talosctl health --nodes "${NODES[0]}" --wait-timeout 15m
  talosctl kubeconfig --nodes "${NODES[0]}" --force
  kubectl get nodes -o wide
}

platform() {
  require kubectl helm

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
  config|bootstrap|platform) "$1" ;;
  apply) shift; apply "$@" ;;
  *) echo "Usage : $0 {config|apply <node> <ip>|bootstrap|platform}" >&2; exit 1 ;;
esac
