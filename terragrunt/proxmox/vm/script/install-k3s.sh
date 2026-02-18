#!/bin/bash

echo "Installing k3s"
curl -sfL https://get.k3s.io | sh -s - --disable servicelb --disable traefik --write-kubeconfig-mode=644
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh

helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace

cat <<EOF | kubectl apply -f -
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
  annotations:
    fluxcd.controlplane.io/reconcile: "enabled"
    fluxcd.controlplane.io/reconcileEvery: "1h"
    fluxcd.controlplane.io/reconcileTimeout: "5m"
spec:
  distribution:
    version: "2.x"
    registry: "ghcr.io/fluxcd"
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
    - image-reflector-controller
    - image-automation-controller
  sync:
    kind: GitRepository
    url: "https://github.com/fordkuppp/homelab"
    ref: "refs/heads/main"
    path: "kubernetes/"
    interval: 1m
EOF