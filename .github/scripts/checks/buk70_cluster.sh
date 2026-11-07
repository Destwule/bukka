#!/usr/bin/env bash
# A throwaway Kubernetes cluster on the CI runner, for the BUK-70 and BUK-77
# checks. Run from the repo root.
#
#   buk70_cluster.sh up       kind cluster "bukka" with ports 80/443 mapped
#                             and the ingress-nginx controller (the kind docs
#                             setup), so http://bukka.localhost works
#   buk70_cluster.sh deploy   build web/ and api/ with your Dockerfiles, tag
#                             them as the images your k8s/ manifests name,
#                             load them into kind, create the Secret from
#                             k8s/examples/secret.example.yaml, apply k8s/
#                             and wait for everything to be ready
#   buk70_cluster.sh down     delete the cluster
#
# Env: KIND_CLUSTER (default bukka), BUK70_NAMESPACE (default bukka).

set -euo pipefail

CLUSTER="${KIND_CLUSTER:-bukka}"
NS="${BUK70_NAMESPACE:-bukka}"
KIND_VERSION="v0.27.0"
INGRESS_NGINX="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml"
LOG="${BUK70_LOG:-/tmp/buk70-cluster.log}"

say() { echo "  · $*"; }

ensure_kind() {
  if ! command -v kind >/dev/null 2>&1; then
    say "installing kind $KIND_VERSION"
    curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-amd64"
    chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind
  fi
}

up() {
  ensure_kind
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    say "kind cluster $CLUSTER already exists"
  else
    say "creating kind cluster $CLUSTER"
    kind create cluster --name "$CLUSTER" --wait 120s --config - >>"$LOG" 2>&1 <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
  fi
  say "installing the ingress-nginx controller"
  kubectl apply -f "$INGRESS_NGINX" >>"$LOG" 2>&1
  kubectl -n ingress-nginx wait --for=condition=complete job --all --timeout=180s >>"$LOG" 2>&1 || true
  kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=240s >>"$LOG" 2>&1
  # Make it the default class, so an Ingress without ingressClassName works.
  kubectl annotate ingressclass nginx ingressclass.kubernetes.io/is-default-class=true --overwrite >>"$LOG" 2>&1
}

images_in() {  # every ghcr.io/.../bukka-web|bukka-api image the manifests name
  grep -rhoE 'ghcr\.io/[A-Za-z0-9._/-]+/bukka-(web|api)(:[A-Za-z0-9._-]+)?' "$1" | sort -u
}

deploy() {
  local tmp; tmp=$(mktemp -d)
  cp -R k8s "$tmp/k8s"
  # Use the images built here, not whatever is on GHCR.
  find "$tmp/k8s" -type f \( -name '*.yaml' -o -name '*.yml' \) -exec sed -i 's/imagePullPolicy: *Always/imagePullPolicy: IfNotPresent/' {} +

  say "building web/ and api/ with your Dockerfiles"
  docker build -q -t bukka-web:ci web >>"$LOG" 2>&1
  docker build -q -t bukka-api:ci api >>"$LOG" 2>&1
  local src="$tmp/k8s"
  if ls "$tmp"/k8s/kustomization.y*ml "$tmp"/k8s/Kustomization >/dev/null 2>&1; then
    kubectl kustomize "$tmp/k8s" > "$tmp/rendered.yaml"; src="$tmp/rendered.yaml"
  fi
  local refs; refs=$(images_in "$src" || true)
  [ -n "$refs" ] || { echo "No ghcr.io/<you>/bukka-web or bukka-api images found in k8s/." >&2; return 1; }
  for ref in $refs; do
    case "$ref" in
      */bukka-web*) docker tag bukka-web:ci "$ref" ;;
      */bukka-api*) docker tag bukka-api:ci "$ref" ;;
    esac
    say "loading $ref into kind"
    kind load docker-image --name "$CLUSTER" "$ref" >>"$LOG" 2>&1
  done

  say "creating the namespace and the Secret (from k8s/examples/secret.example.yaml)"
  kubectl create namespace "$NS" >>"$LOG" 2>&1 || true
  if [ -f k8s/examples/secret.example.yaml ]; then
    kubectl apply -n "$NS" -f k8s/examples/secret.example.yaml >>"$LOG" 2>&1
  fi

  say "applying k8s/"
  local how=(-f "$tmp/k8s/")
  if ls "$tmp"/k8s/kustomization.y*ml "$tmp"/k8s/Kustomization >/dev/null 2>&1; then how=(-k "$tmp/k8s/"); fi
  local i
  for i in 1 2 3 4; do  # a second pass picks up anything that needed the namespace or the webhook first
    if kubectl apply "${how[@]}" >>"$LOG" 2>&1; then break; fi
    [ "$i" = 4 ] && { tail -n 20 "$LOG" >&2; return 1; }
    sleep 10
  done
  # Same Ingress controller for everyone on the runner.
  for ing in $(kubectl -n "$NS" get ingress -o name 2>/dev/null); do
    cls=$(kubectl -n "$NS" get "$ing" -o jsonpath='{.spec.ingressClassName}')
    if [ -n "$cls" ] && [ "$cls" != "nginx" ]; then
      kubectl -n "$NS" patch "$ing" --type=merge -p '{"spec":{"ingressClassName":"nginx"}}' >>"$LOG" 2>&1
    fi
  done

  say "waiting for the migration Job and the Deployments"
  kubectl -n "$NS" wait --for=condition=complete job --all --timeout=300s >>"$LOG" 2>&1 || true
  kubectl -n "$NS" wait --for=condition=available deployment --all --timeout=300s >>"$LOG" 2>&1 || true
  kubectl -n "$NS" rollout status deployment --timeout=120s >>"$LOG" 2>&1 || true
  kubectl -n "$NS" get pods -o wide
  # Give the Ingress a moment to pick up the endpoints.
  for i in $(seq 1 30); do
    curl -fsS -o /dev/null -H 'Host: bukka.localhost' http://127.0.0.1/api/restaurants && break
    sleep 2
  done
  rm -rf "$tmp"
}

down() { kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || true; }

case "${1:-}" in
  up) up ;;
  deploy) deploy ;;
  down) down ;;
  *) echo "usage: $0 up|deploy|down" >&2; exit 2 ;;
esac
