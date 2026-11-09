#!/bin/bash

echo "Disabling unattended-upgrades"
systemctl disable --now unattended-upgrades
apt remove -y unattended-upgrades

echo "Adding hostname to /etc/hosts"
echo "127.0.1.1 $(hostname)" >> /etc/hosts

echo "Disabling systemd-resolved to free port 53"
systemctl disable --now systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" > /etc/resolv.conf

echo "Increasing inotify limits"
echo 'fs.inotify.max_user_instances=512' >> /etc/sysctl.d/99-inotify.conf
echo 'fs.inotify.max_user_watches=524288' >> /etc/sysctl.d/99-inotify.conf
sysctl --system

echo "Installing k3s"
# Pinned: Flux 2.10 needs Kubernetes >= 1.35.2, so a rebuild must not land on
# an older k3s, nor on a newer minor nobody has checked. Bump together with the
# live node (docs: https://docs.k3s.io/upgrades/manual), one minor at a time.
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.35.10+k3s1 sh -s - --disable servicelb --disable traefik --write-kubeconfig-mode=644
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
./get_helm.sh

helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --version 0.62.1 \
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
    # Pinned to a minor: "2.x" would follow Flux past the k3s version above.
    version: "2.10.x"
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
