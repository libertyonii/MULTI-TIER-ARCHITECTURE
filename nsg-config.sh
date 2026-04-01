#!/bin/bash
# nsg-config.sh — Apply NSG rules only (safe to re-run)
# Use this if you need to update rules without redeploying everything

set -euo pipefail

# ── CONFIG — must match your deployment ──────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-Multi-tier-archi}"
WEB_PREFIX="${WEB_PREFIX:-10.0.1.0/24}"
APP_PREFIX="${APP_PREFIX:-10.0.2.0/24}"
DB_PREFIX="${DB_PREFIX:-10.0.3.0/24}"
WEB_NSG="${WEB_NSG:-WEBNSG}"
APP_NSG="${APP_NSG:-APPNSG}"
DB_NSG="${DB_NSG:-DBNSG}"
# ─────────────────────────────────────────────────────────────────────────────

ok()  { echo -e "\033[1;32m[ OK ]\033[0m $*"; }
log() { echo -e "\033[1;34m[NSG ]\033[0m $*"; }

# Delete a rule if it exists, then create it fresh
upsert() {
    local nsg=$1 name=$2; shift 2
    az network nsg rule delete \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$nsg" --name "$name" \
        --output none 2>/dev/null || true
    az network nsg rule create \
        --resource-group "$RESOURCE_GROUP" \
        --nsg-name "$nsg" --name "$name" \
        "$@" --output none
}

# ── WEB NSG ───────────────────────────────────────────────────────────────────
log "Configuring WEBNSG..."

upsert "$WEB_NSG" "Allow-HTTP-Inbound" \
    --priority 100 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes Internet --source-port-ranges "*" \
    --destination-address-prefixes "$WEB_PREFIX" --destination-port-ranges 80 443
ok "[100] Allow HTTP/HTTPS from Internet"

upsert "$WEB_NSG" "Allow-SSH-Inbound" \
    --priority 110 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes Internet --source-port-ranges "*" \
    --destination-address-prefixes "$WEB_PREFIX" --destination-port-ranges 22
ok "[110] Allow SSH from Internet (restrict to your IP in production)"

upsert "$WEB_NSG" "Allow-ICMP-VNet" \
    --priority 120 --direction Inbound --access Allow --protocol Icmp \
    --source-address-prefixes VirtualNetwork --source-port-ranges "*" \
    --destination-address-prefixes "$WEB_PREFIX" --destination-port-ranges "*"
ok "[120] Allow ICMP from VNet"

upsert "$WEB_NSG" "Allow-Web-To-App" \
    --priority 100 --direction Outbound --access Allow --protocol Tcp \
    --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
    --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges 8080 443 22
ok "[100] Allow Web → App outbound"

upsert "$WEB_NSG" "Deny-Web-To-DB" \
    --priority 110 --direction Outbound --access Deny --protocol "*" \
    --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
    --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges "*"
ok "[110] Deny Web → DB outbound"

# ── APP NSG ───────────────────────────────────────────────────────────────────
log "Configuring APPNSG..."

upsert "$APP_NSG" "Allow-From-Web" \
    --priority 100 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
    --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges 8080 443 22
ok "[100] Allow Web → App"

upsert "$APP_NSG" "Allow-ICMP-From-Web" \
    --priority 110 --direction Inbound --access Allow --protocol Icmp \
    --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
    --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges "*"
ok "[110] Allow ICMP from Web"

upsert "$APP_NSG" "Deny-Internet-To-App" \
    --priority 200 --direction Inbound --access Deny --protocol "*" \
    --source-address-prefixes Internet --source-port-ranges "*" \
    --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges "*"
ok "[200] Deny Internet → App"

upsert "$APP_NSG" "Deny-DB-To-App" \
    --priority 210 --direction Inbound --access Deny --protocol "*" \
    --source-address-prefixes "$DB_PREFIX" --source-port-ranges "*" \
    --destination-address-prefixes "$APP_PREFIX" --destination-port-ranges "*"
ok "[210] Deny DB → App (no reverse channel)"

upsert "$APP_NSG" "Allow-App-To-DB" \
    --priority 100 --direction Outbound --access Allow --protocol Tcp \
    --source-address-prefixes "$APP_PREFIX" --source-port-ranges "*" \
    --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges 3306 5432 1433 22
ok "[100] Allow App → DB outbound"

# ── DB NSG ────────────────────────────────────────────────────────────────────
log "Configuring DBNSG..."

upsert "$DB_NSG" "Allow-From-App" \
    --priority 100 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "$APP_PREFIX" --source-port-ranges "*" \
    --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges 3306 5432 1433 22
ok "[100] Allow App → DB"

upsert "$DB_NSG" "Allow-ICMP-From-App" \
    --priority 110 --direction Inbound --access Allow --protocol Icmp \
    --source-address-prefixes "$APP_PREFIX" --source-port-ranges "*" \
    --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges "*"
ok "[110] Allow ICMP from App"

upsert "$DB_NSG" "Deny-Web-To-DB" \
    --priority 200 --direction Inbound --access Deny --protocol "*" \
    --source-address-prefixes "$WEB_PREFIX" --source-port-ranges "*" \
    --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges "*"
ok "[200] Deny Web → DB (second defence layer)"

upsert "$DB_NSG" "Deny-Internet-To-DB" \
    --priority 210 --direction Inbound --access Deny --protocol "*" \
    --source-address-prefixes Internet --source-port-ranges "*" \
    --destination-address-prefixes "$DB_PREFIX" --destination-port-ranges "*"
ok "[210] Deny Internet → DB"

echo ""
echo "All NSG rules applied."
echo ""
echo "Rule summary:"
echo "  Internet → Web     80/443/22     ALLOW"
echo "  Web      → App     8080/443/22   ALLOW"
echo "  Web      → DB      *             DENY"
echo "  App      → DB      3306/5432/22  ALLOW"
echo "  Internet → App     *             DENY"
echo "  Internet → DB      *             DENY"
echo "  DB       → App     *             DENY"
