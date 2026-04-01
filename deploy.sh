#!/bin/bash
# deploy.sh — Full Azure Multi-Tier Deployment
# Edit the CONFIG section below before running

set -euo pipefail

# ── CONFIG ────────────────────────────────────────────────────────────────────
RESOURCE_GROUP="Multi-tier-archi"
LOCATION="southafricanorth"
VNET_NAME="multivnet"
VNET_PREFIX="10.0.0.0/16"

WEB_SUBNET="WEBSB"
APP_SUBNET="APPSB"
DB_SUBNET="DBSB"
WEB_PREFIX="10.0.1.0/24"
APP_PREFIX="10.0.2.0/24"
DB_PREFIX="10.0.3.0/24"

WEB_VM="web-vm"
APP_VM="app-vm"
DB_VM="db-vm"
VM_SIZE="Standard_B2s"       # change if unavailable in your region
VM_IMAGE="Ubuntu2204"
ADMIN_USER="libo"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"

WEB_NSG="WEBNSG"
APP_NSG="APPNSG"
DB_NSG="DBNSG"
# ─────────────────────────────────────────────────────────────────────────────

log() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()  { echo -e "\033[1;32m[ OK ]\033[0m $*"; }
err() { echo -e "\033[1;31m[ERR ]\033[0m $*"; exit 1; }

# Check Azure CLI is installed and logged in
check_deps() {
    command -v az >/dev/null 2>&1 || err "Azure CLI not found. Install from https://aka.ms/installazurecli"
    az account show >/dev/null 2>&1 || az login
    ok "Logged in as: $(az account show --query name -o tsv)"
}

# Step 1 — Resource group
create_resource_group() {
    log "Creating resource group..."
    az group create \
        --name "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --output none
    ok "Resource group: $RESOURCE_GROUP"
}

# Step 2 — VNet and subnets
create_vnet() {
    log "Creating VNet..."
    az network vnet create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VNET_NAME" \
        --address-prefix "$VNET_PREFIX" \
        --location "$LOCATION" \
        --output none
    ok "VNet: $VNET_NAME"

    log "Creating subnets..."
    for entry in "$WEB_SUBNET:$WEB_PREFIX" "$APP_SUBNET:$APP_PREFIX" "$DB_SUBNET:$DB_PREFIX"; do
        name="${entry%%:*}"
        prefix="${entry##*:}"
        az network vnet subnet create \
            --resource-group "$RESOURCE_GROUP" \
            --vnet-name "$VNET_NAME" \
            --name "$name" \
            --address-prefix "$prefix" \
            --output none
        ok "  Subnet: $name ($prefix)"
    done
}

# Step 3 — NSGs and rules
create_nsgs() {
    log "Creating NSG objects..."
    for nsg in "$WEB_NSG" "$APP_NSG" "$DB_NSG"; do
        az network nsg create \
            --resource-group "$RESOURCE_GROUP" \
            --name "$nsg" \
            --location "$LOCATION" \
            --output none
        ok "  NSG: $nsg"
    done

    log "Configuring WEB NSG..."
    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$WEB_NSG" \
        --name "Allow-HTTP-Inbound" --priority 100 \
        --direction Inbound --access Allow --protocol Tcp \
        --source-address-prefixes Internet --source-port-ranges "*" \
        --destination-address-prefixes "$WEB_PREFIX" --destination-port-ranges 80 443 --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$WEB_NSG" \
        --name "Allow-SSH-Inbound" --priority 110 \
        --direction Inbound --access Allow --protocol Tcp \
        --source-address-prefixes Internet --source-port-ranges "*" \
        --destination-address-prefixes "$WEB_PREFIX" --destination-port-ranges 22 --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$WEB_NSG" \
        --name "Allow-ICMP-VNet" --priority 120 \
        --direction Inbound --access Allow --protocol Icmp \
        --source-address-prefixes VirtualNetwork --source-port-ranges "*" \
        --destination-address-prefixes "$WEB_PREFIX" --destination-port-ranges "*" --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$WEB_NSG" \
        --name "Allow-Web-To-App" --priority 100 \
        --direction Outbound --access Allow --protocol Tcp \
        --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
        --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges 8080 443 22 --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$WEB_NSG" \
        --name "Deny-Web-To-DB" --priority 110 \
        --direction Outbound --access Deny --protocol "*" \
        --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
        --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges "*" --output none
    ok "WEB NSG configured"

    log "Configuring APP NSG..."
    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$APP_NSG" \
        --name "Allow-From-Web" --priority 100 \
        --direction Inbound --access Allow --protocol Tcp \
        --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
        --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges 8080 443 22 --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$APP_NSG" \
        --name "Allow-ICMP-From-Web" --priority 110 \
        --direction Inbound --access Allow --protocol Icmp \
        --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
        --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges "*" --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$APP_NSG" \
        --name "Deny-Internet-To-App" --priority 200 \
        --direction Inbound --access Deny --protocol "*" \
        --source-address-prefixes Internet --source-port-ranges "*" \
        --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges "*" --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$APP_NSG" \
        --name "Deny-DB-To-App" --priority 210 \
        --direction Inbound --access Deny --protocol "*" \
        --source-address-prefixes "$DB_PREFIX" --source-port-ranges "*" \
        --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges "*" --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$APP_NSG" \
        --name "Allow-App-To-DB" --priority 100 \
        --direction Outbound --access Allow --protocol Tcp \
        --source-address-prefixes "$APP_PREFIX" --source-port-ranges "*" \
        --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges 3306 5432 1433 22 --output none
    ok "APP NSG configured"

    log "Configuring DB NSG..."
    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$DB_NSG" \
        --name "Allow-From-App" --priority 100 \
        --direction Inbound --access Allow --protocol Tcp \
        --source-address-prefixes "$APP_PREFIX" --source-port-ranges "*" \
        --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges 3306 5432 1433 22 --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$DB_NSG" \
        --name "Allow-ICMP-From-App" --priority 110 \
        --direction Inbound --access Allow --protocol Icmp \
        --source-address-prefixes "$APP_PREFIX" --source-port-ranges "*" \
        --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges "*" --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$DB_NSG" \
        --name "Deny-Web-To-DB" --priority 200 \
        --direction Inbound --access Deny --protocol "*" \
        --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
        --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges "*" --output none

    az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$DB_NSG" \
        --name "Deny-Internet-To-DB" --priority 210 \
        --direction Inbound --access Deny --protocol "*" \
        --source-address-prefixes Internet --source-port-ranges "*" \
        --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges "*" --output none
    ok "DB NSG configured"

    log "Associating NSGs with subnets..."
    az network vnet subnet update --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
        --name "$WEB_SUBNET" --network-security-group "$WEB_NSG" --output none
    az network vnet subnet update --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
        --name "$APP_SUBNET" --network-security-group "$APP_NSG" --output none
    az network vnet subnet update --resource-group "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
        --name "$DB_SUBNET" --network-security-group "$DB_NSG" --output none
    ok "NSGs associated with subnets"
}

# Step 4 — VMs
create_vms() {
    log "Creating Web VM (public IP)..."
    az vm create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$WEB_VM" \
        --image "$VM_IMAGE" \
        --size "$VM_SIZE" \
        --admin-username "$ADMIN_USER" \
        --generate-ssh-keys \
        --vnet-name "$VNET_NAME" \
        --subnet "$WEB_SUBNET" \
        --public-ip-sku Standard \
        --nsg "" \
        --output none
    ok "Web VM created"

    log "Creating App VM (no public IP)..."
    az vm create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$APP_VM" \
        --image "$VM_IMAGE" \
        --size "$VM_SIZE" \
        --admin-username "$ADMIN_USER" \
        --generate-ssh-keys \
        --vnet-name "$VNET_NAME" \
        --subnet "$APP_SUBNET" \
        --public-ip-address "" \
        --nsg "" \
        --output none
    ok "App VM created"

    log "Creating DB VM (no public IP)..."
    az vm create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DB_VM" \
        --image "$VM_IMAGE" \
        --size "$VM_SIZE" \
        --admin-username "$ADMIN_USER" \
        --generate-ssh-keys \
        --vnet-name "$VNET_NAME" \
        --subnet "$DB_SUBNET" \
        --public-ip-address "" \
        --nsg "" \
        --output none
    ok "DB VM created"
}

# Step 5 — Print IPs
print_ips() {
    log "Fetching IP addresses..."

    WEB_PUB=$(az vm show -d -g "$RESOURCE_GROUP" -n "$WEB_VM" --query publicIps -o tsv)
    WEB_PRV=$(az vm show -d -g "$RESOURCE_GROUP" -n "$WEB_VM" --query privateIps -o tsv)
    APP_PRV=$(az vm show -d -g "$RESOURCE_GROUP" -n "$APP_VM" --query privateIps -o tsv)
    DB_PRV=$(az vm show  -d -g "$RESOURCE_GROUP" -n "$DB_VM"  --query privateIps -o tsv)

    echo ""
    echo "══════════════════════════════════════════"
    echo "  Web VM  — public:  $WEB_PUB"
    echo "  Web VM  — private: $WEB_PRV"
    echo "  App VM  — private: $APP_PRV"
    echo "  DB  VM  — private: $DB_PRV"
    echo "══════════════════════════════════════════"
    echo ""
    echo "  SSH into Web:  ssh $ADMIN_USER@$WEB_PUB"
    echo "  Jump to App:   ssh -J $ADMIN_USER@$WEB_PUB $ADMIN_USER@$APP_PRV"
    echo "  Jump to DB:    ssh -J $ADMIN_USER@$WEB_PUB,$ADMIN_USER@$APP_PRV $ADMIN_USER@$DB_PRV"
    echo ""

    # Save IPs for verify-connectivity.sh
    cat > /tmp/multitier-ips.env <<EOF
WEB_PUB=$WEB_PUB
WEB_PRV=$WEB_PRV
APP_PRV=$APP_PRV
DB_PRV=$DB_PRV
ADMIN_USER=$ADMIN_USER
EOF
    ok "IPs saved to /tmp/multitier-ips.env"
}

main() {
    check_deps
    create_resource_group
    create_vnet
    create_nsgs
    create_vms
    print_ips
    ok "Deployment complete. Run ./verify-connectivity.sh to test NSG rules."
}

main "$@"
