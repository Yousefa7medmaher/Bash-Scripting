
#!/usr/bin/env bash
set -Eeuo pipefail

# Azure configuration
SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID}"
RG="${RESOURCE_GROUP:?Set RESOURCE_GROUP}"
LOCATION="${AZURE_LOCATION:?Set AZURE_LOCATION}"
VNET="${VNET_NAME:?Set VNET_NAME}"
SUBNET="${SUBNET_NAME:?Set SUBNET_NAME}"

VM="${VM_NAME:?Set VM_NAME}"
VM_SIZE="${VM_SIZE:?Set VM_SIZE}"
NSG="${NSG_NAME:?Set NSG_NAME}"
PIP="${PUBLIC_IP_NAME:?Set PUBLIC_IP_NAME}"
ADMIN="${ADMIN_USERNAME:?Set ADMIN_USERNAME}"

echo "==> Checking existing Azure session..."
az account show >/dev/null 2>&1 || {
  echo "ERROR: No active Azure session. Run az login first."
  exit 1
}

echo "==> Selecting subscription..."
az account set --subscription "$SUBSCRIPTION"

echo "==> Validating resource group and VNet..."
az group show --name "$RG" >/dev/null
az network vnet show \
  --resource-group "$RG" \
  --name "$VNET" >/dev/null

echo "==> Validating dedicated VM subnet..."
SUBNET_ID=$(az network vnet subnet show \
  --resource-group "$RG" \
  --vnet-name "$VNET" \
  --name "$SUBNET" \
  --query id -o tsv)

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
  echo "ERROR: Subnet '$SUBNET' was not found."
  exit 1
fi

# Get current public IPv4 for SSH restriction
MYIP=$(curl -4fsS https://api.ipify.org)
if [[ ! "$MYIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: Could not determine your public IPv4 address."
  exit 1
fi

echo "==> SSH will be allowed only from $MYIP/32"

# Avoid overwriting an existing VM or networking resources
for RESOURCE in \
  "az vm show -g $RG -n $VM" \
  "az network nsg show -g $RG -n $NSG" \
  "az network public-ip show -g $RG -n $PIP"; do
  if eval "$RESOURCE" >/dev/null 2>&1; then
    echo "ERROR: A resource already exists: $RESOURCE"
    echo "Inspect it before rerunning the script."
    exit 1
  fi
done

echo "==> Creating Network Security Group..."
az network nsg create \
  --resource-group "$RG" \
  --name "$NSG" \
  --location "$LOCATION" \
  --output none

echo "==> Adding restricted SSH rule..."
az network nsg rule create \
  --resource-group "$RG" \
  --nsg-name "$NSG" \
  --name "Allow-SSH-My-IP" \
  --priority 100 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --source-address-prefixes "$MYIP/32" \
  --source-port-ranges '*' \
  --destination-address-prefixes '*' \
  --destination-port-ranges 22 \
  --output none

echo "==> Creating Public IP..."
az network public-ip create \
  --resource-group "$RG" \
  --name "$PIP" \
  --location "$LOCATION" \
  --sku Standard \
  --allocation-method Static \
  --output none

echo "==> Creating Ubuntu VM..."
az vm create \
  --resource-group "$RG" \
  --name "$VM" \
  --location "$LOCATION" \
  --image Ubuntu2204 \
  --size "$VM_SIZE" \
  --vnet-name "$VNET" \
  --subnet "$SUBNET" \
  --nsg "$NSG" \
  --nsg-rule NONE \
  --public-ip-address "$PIP" \
  --public-ip-sku Standard \
  --admin-username "$ADMIN" \
  --authentication-type ssh \
  --generate-ssh-keys

PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RG" \
  --name "$PIP" \
  --query ipAddress -o tsv)

echo
echo "=========================================="
echo "VM creation completed"
echo "VM:        $VM"
echo "Resource:  $RG"
echo "Location:  $LOCATION"
echo "VNet:      $VNET"
echo "Subnet:    $SUBNET"
echo "Public IP: $PUBLIC_IP"
echo "SSH rule:  $MYIP/32 only"
echo
echo "Connect using:"
echo "ssh $ADMIN@$PUBLIC_IP"
echo "=========================================="
echo
echo "Next: verify private DNS and MySQL connectivity."
