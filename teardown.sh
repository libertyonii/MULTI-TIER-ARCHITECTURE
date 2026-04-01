#!/bin/bash
# teardown.sh — Delete all resources for this deployment
# WARNING: This is permanent. Everything in the resource group will be deleted.

RESOURCE_GROUP="${RESOURCE_GROUP:-Multi-tier-archi}"

echo "WARNING: This will permanently delete '$RESOURCE_GROUP' and everything in it."
read -rp "Type 'yes' to confirm: " confirm
[[ "$confirm" != "yes" ]] && { echo "Aborted."; exit 0; }

echo "Deleting $RESOURCE_GROUP..."
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
echo "Deletion started. Check the Azure portal for progress."
