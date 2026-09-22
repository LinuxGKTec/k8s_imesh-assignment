#!/usr/bin/env bash
# 00 — Bring up a KIND cluster sized for the demo and install ingress-nginx.
set -euo pipefail

CLUSTER_NAME="${1:-imesh-tech}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  echo "==> KIND cluster '${CLUSTER_NAME}' already exists — skipping create"
else
  echo "==> Creating KIND cluster '${CLUSTER_NAME}'"
  kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT}/Kind_Infra/kind-cluster.yaml" --wait 120s
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

echo "==> Installing ingress-nginx (kind preset)"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/kind/deploy.yaml

echo "==> Waiting for ingress controller to be ready"
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "==> KIND cluster is up."

