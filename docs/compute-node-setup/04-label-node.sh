#!/bin/bash
# Label the compute node for OpenStack workloads
# Run on your local machine with kubectl access

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <node-name>"
  echo "Example: $0 hpg9-compute2"
  exit 1
fi

NODE_NAME="$1"

echo "=== Labeling node ${NODE_NAME} for OpenStack compute ==="

# Wait for node to be ready
echo "Waiting for node to appear..."
kubectl wait --for=condition=Ready node/${NODE_NAME} --timeout=300s

# Label for OpenStack compute workloads
kubectl label node ${NODE_NAME} openstack-compute-node=enabled --overwrite
kubectl label node ${NODE_NAME} openvswitch=enabled --overwrite
kubectl label node ${NODE_NAME} openstack-nova-compute=enabled --overwrite

# Taint to prefer OpenStack workloads (optional - remove if you want other pods too)
# kubectl taint nodes ${NODE_NAME} openstack-compute=true:PreferNoSchedule

echo ""
echo "Node labels:"
kubectl get node ${NODE_NAME} --show-labels | tr ',' '\n' | grep openstack

echo ""
echo "=== Node labeled successfully ==="
echo ""
echo "Next: sync ArgoCD and verify nova/neutron daemons on this node"
