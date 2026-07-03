#!/usr/bin/env bash
# Creates 4 Debian 12 KVM VMs for the Kubernetes The Hard Way tutorial:
#   jumpbox (192.168.100.10) — 1 vCPU, 512MB RAM, 10GB disk
#   server  (192.168.100.11) — 1 vCPU,   2GB RAM, 20GB disk
#   node-0  (192.168.100.12) — 1 vCPU,   2GB RAM, 20GB disk
#   node-1  (192.168.100.13) — 1 vCPU,   2GB RAM, 20GB disk
#
# Usage:
#   bash setup-vms.sh           — create all VMs (idempotent)
#   bash setup-vms.sh cleanup   — destroy VMs, delete disks/ISOs/cloud-init
#                                 dirs, and remove the libvirt network
#                                 (the base image is kept; pass --all to also
#                                 remove it)
#
# Setup steps:
#   1. Download the Debian 12 genericcloud AMD64 image (one-time, ~300MB)
#   2. Create a libvirt NAT network (k8s-hardway, 192.168.100.0/24)
#   3. For each VM: create a thin-provisioned overlay disk, configure it
#      directly with virt-customize (password, SSH key, static IP, hostname),
#      then launch with virt-install
#   4. Test SSH connectivity after boot
#
# Requires: virsh, virt-install, qemu-img, cloud-localds (cloud-image-utils)
set -euo pipefail

IMAGES_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_PASSWORD="${VM_PASSWORD:-k8s-hardway}"
SSH_PUB_KEY_PATH="${SSH_PUB_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
if [[ ! -f "$SSH_PUB_KEY_PATH" ]]; then
  echo "ERROR: SSH public key not found at '$SSH_PUB_KEY_PATH'" >&2
  echo "       Set SSH_PUB_KEY_PATH to override the default path." >&2
  exit 1
fi
SSH_PUB_KEY="$(cat "$SSH_PUB_KEY_PATH")"

DEBIAN_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
BASE_IMAGE="$IMAGES_DIR/debian-12-base.qcow2"

NETWORK_NAME="k8s-hardway"
NETWORK_SUBNET="192.168.100"
GATEWAY="${NETWORK_SUBNET}.1"

declare -A VM_IP=( [jumpbox]="${NETWORK_SUBNET}.10" [server]="${NETWORK_SUBNET}.11" [node-0]="${NETWORK_SUBNET}.12" [node-1]="${NETWORK_SUBNET}.13" )
declare -A VM_RAM=( [jumpbox]=512  [server]=2048 [node-0]=2048 [node-1]=2048 )
declare -A VM_DISK=( [jumpbox]=10  [server]=20   [node-0]=20   [node-1]=20   )
VMS=(jumpbox server node-0 node-1)

# ── Subcommand: cleanup ───────────────────────────────────────────────────────
cmd_cleanup() {
  local remove_base=false
  [[ "${1:-}" == "--all" ]] && remove_base=true

  echo "==> Destroying VMs..."
  for VM in "${VMS[@]}"; do
    if virsh dominfo "$VM" &>/dev/null; then
      virsh destroy "$VM" 2>/dev/null || true  # force-off; ignore if already stopped
      # Try managed-storage removal first; fall back to plain undefine if disks
      # are outside libvirt's pool or already gone, then suppress any remaining error.
      virsh undefine "$VM" --remove-all-storage 2>/dev/null || \
        virsh undefine "$VM" 2>/dev/null || true
      echo "    Removed VM: $VM"
    else
      echo "    VM '$VM' not found, skipping."
    fi
  done

  echo ""
  echo "==> Removing disk images..."
  for VM in "${VMS[@]}"; do
    local disk="$IMAGES_DIR/${VM}.qcow2"
    [[ -f "$disk" ]] && rm -f "$disk" && echo "    Deleted ${VM}.qcow2" || true
  done

  echo ""
  echo "==> Removing libvirt network '$NETWORK_NAME'..."
  if virsh net-info "$NETWORK_NAME" &>/dev/null; then
    virsh net-destroy   "$NETWORK_NAME" 2>/dev/null || true  # ignore if already inactive
    virsh net-undefine  "$NETWORK_NAME"
    echo "    Network '$NETWORK_NAME' removed."
  else
    echo "    Network '$NETWORK_NAME' not found, skipping."
  fi

  if $remove_base; then
    echo ""
    echo "==> Removing base image..."
    [[ -f "$BASE_IMAGE" ]] && rm -f "$BASE_IMAGE" && echo "    Deleted debian-12-base.qcow2" \
      || echo "    Base image not found, skipping."
  else
    echo ""
    echo "==> Base image kept at: $BASE_IMAGE"
    echo "    Run with 'cleanup --all' to also remove it."
  fi

  echo ""
  echo "==> Cleanup complete."
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "${1:-}" in
  cleanup) cmd_cleanup "${2:-}" ; exit 0 ;;
  "")      ;;  # fall through to setup
  *)       echo "Usage: $0 [cleanup [--all]]" >&2 ; exit 1 ;;
esac

# ── 1. Download base image ────────────────────────────────────────────────────
if [[ ! -f "$BASE_IMAGE" ]]; then
  echo "==> Downloading Debian 12 cloud image..."
  wget -q --show-progress -O "$BASE_IMAGE" "$DEBIAN_IMAGE_URL"
else
  echo "==> Base image already present, skipping download."
fi

# ── 2. Create libvirt NAT network ─────────────────────────────────────────────
if ! virsh net-info "$NETWORK_NAME" &>/dev/null; then
  echo "==> Creating libvirt network '$NETWORK_NAME'..."
  virsh net-define /dev/stdin <<EOF
<network>
  <name>${NETWORK_NAME}</name>
  <forward mode='nat'/>
  <bridge name='virbr-k8s' stp='on' delay='0'/>
  <ip address='${GATEWAY}' netmask='255.255.255.0'>
  </ip>
</network>
EOF
  virsh net-autostart "$NETWORK_NAME"
  virsh net-start "$NETWORK_NAME"
elif ! virsh net-info "$NETWORK_NAME" | grep -q "^Active:.*yes"; then
  # Defined but not running (e.g. after a host reboot with autostart disabled)
  echo "==> Network '$NETWORK_NAME' is defined but inactive, starting it..."
  virsh net-start "$NETWORK_NAME"
else
  echo "==> Network '$NETWORK_NAME' already active, skipping."
fi

# ── 3. Create each VM ─────────────────────────────────────────────────────────
new_vms=0
for VM in "${VMS[@]}"; do
  IP="${VM_IP[$VM]}"
  RAM="${VM_RAM[$VM]}"
  DISK_GB="${VM_DISK[$VM]}"
  DISK_PATH="$IMAGES_DIR/${VM}.qcow2"

  echo ""
  echo "==> Setting up VM: $VM  (IP: $IP, RAM: ${RAM}MB, Disk: ${DISK_GB}GB)"

  # Skip if VM already defined
  if virsh dominfo "$VM" &>/dev/null; then
    echo "    VM '$VM' already exists, skipping."
    continue
  fi

  # Create overlay disk
  if [[ ! -f "$DISK_PATH" ]]; then
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_PATH" "${DISK_GB}G"
  fi

  # Configure the disk image directly — no cloud-init required
  virt-customize -a "$DISK_PATH" \
    --hostname "$VM" \
    --root-password "password:${VM_PASSWORD}" \
    --ssh-inject "root:string:${SSH_PUB_KEY}" \
    --run-command "printf 'PermitRootLogin yes\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/99-k8s-hardway.conf" \
    --run-command "ssh-keygen -A" \
    --run-command "printf '[Match]\nName=enp1s0\n\n[Network]\nAddress=${IP}/24\nGateway=${GATEWAY}\nDNS=8.8.8.8\nDNS=1.1.1.1\n' > /etc/systemd/network/enp1s0.network" \
    --run-command "echo '127.0.1.1 ${VM}.kubernetes.local ${VM}' >> /etc/hosts"

  # Launch VM
  virt-install \
    --name "$VM" \
    --memory "$RAM" \
    --vcpus 1 \
    --disk "path=$DISK_PATH,format=qcow2" \
    --os-variant debian12 \
    --network "network=$NETWORK_NAME,model=virtio" \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import \
    --boot hd

  echo "    VM '$VM' created."
  new_vms=$((new_vms + 1))
done

if [[ $new_vms -eq 0 ]]; then
  echo ""
  echo "==> All VMs already exist, nothing to do."
else
  echo ""
  echo "==> $new_vms VM(s) launched. Waiting ~30s for cloud-init to complete..."
  sleep 30
fi

echo ""
echo "==> VM status:"
for VM in "${VMS[@]}"; do
  STATE=$(virsh domstate "$VM" 2>/dev/null || echo "unknown")
  echo "    $VM  ${VM_IP[$VM]}  $STATE"
done

if [[ $new_vms -gt 0 ]]; then
  echo ""
  echo "==> Waiting for SSH connectivity (timeout: 60s per VM)..."
  for VM in "${VMS[@]}"; do
    IP="${VM_IP[$VM]}"
    deadline=$((SECONDS + 60))
    while [[ $SECONDS -lt $deadline ]]; do
      if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -o BatchMode=yes \
           -i ~/.ssh/id_ed25519 root@"$IP" hostname &>/dev/null; then
        echo "    $VM ($IP): OK"
        break
      fi
      sleep 3
    done
    if [[ $SECONDS -ge $deadline ]]; then
      echo "    $VM ($IP): timed out — try manually: ssh root@$IP"
    fi
  done
fi

echo ""
echo "Done. Add these to your /etc/hosts if you want hostname access:"
echo "  ${NETWORK_SUBNET}.10  jumpbox"
echo "  ${NETWORK_SUBNET}.11  server"
echo "  ${NETWORK_SUBNET}.12  node-0"
echo "  ${NETWORK_SUBNET}.13  node-1"
