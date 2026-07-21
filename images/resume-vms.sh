#!/usr/bin/env bash
# Resumes the 4 Debian 12 KVM VMs used by the Kubernetes The Hard Way
# tutorial (created by setup-vms.sh) — powers them back on from whatever
# shut-off state they were left in, without recreating anything, and
# verifies they come back up:
#   jumpbox (192.168.100.10)
#   server  (192.168.100.11)
#   node-0  (192.168.100.12)
#   node-1  (192.168.100.13)
#
# Usage:
#   bash resume-vms.sh
#
# For each VM this:
#   1. Ensures the k8s-hardway libvirt network is active
#   2. Starts the VM if it's not already running (idempotent — a VM that's
#      already running is left alone, not rebooted)
#   3. Waits for SSH connectivity and reports OK/FAILED per VM
#
# Safe to run repeatedly: re-running against VMs that are already up and
# reachable is a no-op other than the SSH check.
#
# Exits non-zero if any VM fails to come back up.
set -euo pipefail

NETWORK_NAME="k8s-hardway"
NETWORK_SUBNET="192.168.100"

declare -A VM_IP=( [jumpbox]="${NETWORK_SUBNET}.10" [server]="${NETWORK_SUBNET}.11" [node-0]="${NETWORK_SUBNET}.12" [node-1]="${NETWORK_SUBNET}.13" )
VMS=(jumpbox server node-0 node-1)

SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
SSH_TIMEOUT_PER_VM="${SSH_TIMEOUT_PER_VM:-60}"

# ── Ensure the network is up ──────────────────────────────────────────────────
if ! virsh net-info "$NETWORK_NAME" &>/dev/null; then
  echo "ERROR: libvirt network '$NETWORK_NAME' not found. Run setup-vms.sh first." >&2
  exit 1
fi
if ! virsh net-info "$NETWORK_NAME" | grep -q "^Active:.*yes"; then
  echo "==> Network '$NETWORK_NAME' is inactive, starting it..."
  virsh net-start "$NETWORK_NAME"
fi

# ── Restart each VM ───────────────────────────────────────────────────────────
for VM in "${VMS[@]}"; do
  if ! virsh dominfo "$VM" &>/dev/null; then
    echo "ERROR: VM '$VM' is not defined. Run setup-vms.sh first." >&2
    exit 1
  fi

  echo ""
  echo "==> Ensuring VM is running: $VM"
  STATE=$(virsh domstate "$VM")
  if [[ "$STATE" == "running" ]]; then
    echo "    '$VM' already running, skipping."
  else
    virsh start "$VM"
    echo "    '$VM' was $STATE, started."
  fi
done

# ── Verify SSH connectivity ────────────────────────────────────────────────────
echo ""
echo "==> Waiting for SSH connectivity (timeout: ${SSH_TIMEOUT_PER_VM}s per VM)..."
declare -A RESULT
for VM in "${VMS[@]}"; do
  IP="${VM_IP[$VM]}"
  deadline=$((SECONDS + SSH_TIMEOUT_PER_VM))
  ok=false
  while [[ $SECONDS -lt $deadline ]]; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
         -i "$SSH_KEY_PATH" root@"$IP" hostname &>/dev/null; then
      ok=true
      break
    fi
    sleep 3
  done
  if $ok; then
    echo "    $VM ($IP): OK"
    RESULT[$VM]="OK"
  else
    echo "    $VM ($IP): FAILED — try manually: ssh root@$IP"
    RESULT[$VM]="FAILED"
  fi
done

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "==> Restart summary:"
failed=0
for VM in "${VMS[@]}"; do
  echo "    $VM: ${RESULT[$VM]}"
  [[ "${RESULT[$VM]}" == "FAILED" ]] && failed=$((failed + 1))
done

if [[ $failed -gt 0 ]]; then
  echo ""
  echo "==> $failed VM(s) failed to come back up."
  exit 1
fi

echo ""
echo "==> All VMs restarted and reachable via SSH."
