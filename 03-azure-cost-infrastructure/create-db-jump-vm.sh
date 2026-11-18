#!/usr/bin/env bash
set -Eeuo pipefail

RG="${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
VM="${VM_NAME:?Set VM_NAME}"
LOCATION="${AZURE_LOCATION:?Set AZURE_LOCATION}"
VNET="${VNET_NAME:?Set VNET_NAME}"
SUBNET="${SUBNET_NAME:?Set SUBNET_NAME}"
NSG="${NSG_NAME:?Set NSG_NAME}"
PIP="${PUBLIC_IP_NAME:?Set PUBLIC_IP_NAME}"
SIZE="${VM_SIZE:?Set VM_SIZE}"
ADMIN="${ADMIN_USERNAME:?Set ADMIN_USERNAME}"

# Check Azure login
az account show >/dev/null

# Make sure the VM does not already exist
if az vm show -g "$RG" -n "$VM" >/dev/null 2>&1; then
  echo "ERROR: $VM already exists. Not creating a duplicate."
  exit 1
fi

# Check the existing network
az network vnet subnet show \
  -g "$RG" --vnet-name "$VNET" -n "$SUBNET" >/dev/null

# Find or create an SSH public key
if [[ -n "${SSH_PUB_KEY:-}" && -f "${SSH_PUB_KEY}" ]]; then
  KEY="$SSH_PUB_KEY"
elif [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
  KEY="$HOME/.ssh/id_ed25519.pub"
elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
  KEY="$HOME/.ssh/id_rsa.pub"
else
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" \
    -N "" -C "azure-db-jump-vm"
  KEY="$HOME/.ssh/id_ed25519.pub"
fi

# Restrict SSH to the current public IP
MY_IP="$(curl -4fsS https://api.ipify.org)"
echo "Allowing SSH from: ${MY_IP}/32"

# Create/reuse NSG
if ! az network nsg show -g "$RG" -n "$NSG" >/dev/null 2>&1; then
  az network nsg create \
    -g "$RG" -n "$NSG" -l "$LOCATION" >/dev/null
fi

# Create or update the SSH rule
if az network nsg rule show \
  -g "$RG" --nsg-name "$NSG" -n "Allow-SSH-From-MyIP" \
  >/dev/null 2>&1; then
  az network nsg rule update \
    -g "$RG" --nsg-name "$NSG" -n "Allow-SSH-From-MyIP" \
    --priority 4090 \
    --access Allow --protocol Tcp --direction Inbound \
    --source-address-prefixes "${MY_IP}/32" \
    --destination-port-ranges 22 >/dev/null
else
  az network nsg rule create \
    -g "$RG" --nsg-name "$NSG" -n "Allow-SSH-From-MyIP" \
    --priority 4090 \
    --access Allow --protocol Tcp --direction Inbound \
    --source-address-prefixes "${MY_IP}/32" \
    --destination-port-ranges 22 >/dev/null
fi

# Create a new static public IP
az network public-ip create \
  -g "$RG" -n "$PIP" -l "$LOCATION" \
  --sku Standard --allocation-method Static >/dev/null

# Install MySQL client automatically during provisioning
CLOUD_INIT="$(mktemp)"
trap 'rm -f "$CLOUD_INIT"' EXIT

cat > "$CLOUD_INIT" <<'CLOUD'
#cloud-config
package_update: true
packages:
  - mysql-client
CLOUD

echo "Creating VM. This may take several minutes..."

az vm create \
  -g "$RG" -n "$VM" -l "$LOCATION" \
  --image Ubuntu2204 \
  --size "$SIZE" \
  --admin-username "$ADMIN" \
  --ssh-key-values "$KEY" \
  --vnet-name "$VNET" \
  --subnet "$SUBNET" \
  --nsg "$NSG" \
  --public-ip-address "$PIP" \
  --custom-data "$CLOUD_INIT" \
  --output none

PUBLIC_IP="$(az network public-ip show \
  -g "$RG" -n "$PIP" --query ipAddress -o tsv)"

echo
echo "VM created successfully."
echo "Public IP: $PUBLIC_IP"
echo "SSH command: ssh ${ADMIN}@${PUBLIC_IP}"
echo "Wait for cloud-init to finish before using mysql."
