#!/bin/bash
# Watch dmesg on a node for mlx5/eswitch/RDMA related messages.
# Usage: bash watch-dmesg.sh <node-fqdn>
# Run this in a separate terminal BEFORE deploying pair B.
# Ctrl-C to stop.

NODE="${1:?Usage: $0 <node-fqdn>}"
NODE_SHORT="${NODE%%.*}"

echo "=== Watching dmesg on ${NODE_SHORT} for mlx5/eswitch/RDMA events ==="
echo "    (Run this BEFORE deploying pair B, Ctrl-C to stop)"
echo ""

oc debug "node/${NODE}" -- chroot /host \
  bash -c 'dmesg -w 2>/dev/null || dmesg -W' \
  | grep --line-buffered -iE "mlx5|rdma|roce|eswitch|fdb|sriov|vport|vf |switchdev|lag|bond" \
  | grep --line-buffered -v "0000:81:00"
