#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# AWS Route 53 -> Azure App Service subdomain migration
#
# Migrates:
#   ADMIN_SUBDOMAIN -> ADMIN_APP.azurewebsites.net
#   WWW_SUBDOMAIN   -> WEB_APP.azurewebsites.net
#
# Does NOT touch:
#   the apex domain
#   MX
#   SES DKIM
#   DMARC
#   existing azure.* domains
#   existing azure-admin.* domains
# ============================================================

RG="${AZURE_RESOURCE_GROUP:?Set AZURE_RESOURCE_GROUP}"

WEBAPP="${WEB_APP_NAME:?Set WEB_APP_NAME}"
ADMIN_APP="${ADMIN_APP_NAME:?Set ADMIN_APP_NAME}"

ZONE_ID="${ROUTE53_ZONE_ID:?Set ROUTE53_ZONE_ID}"

DOMAIN="${APEX_DOMAIN:?Set APEX_DOMAIN}"
ADMIN_DOMAIN="${ADMIN_SUBDOMAIN:-admin.${DOMAIN}}"
WWW_DOMAIN="${WWW_SUBDOMAIN:-www.${DOMAIN}}"

WEBAPP_HOST="${WEBAPP}.azurewebsites.net"
ADMIN_HOST="${ADMIN_APP}.azurewebsites.net"

EXPECTED_ADMIN_DNS="${EXPECTED_ADMIN_DNS:?Set EXPECTED_ADMIN_DNS}"
EXPECTED_WWW_DNS="${EXPECTED_WWW_DNS:?Set EXPECTED_WWW_DNS}"
ALB_HOSTED_ZONE_ID="${ALB_HOSTED_ZONE_ID:?Set ALB_HOSTED_ZONE_ID}"

BACKUP_FILE="dns-zone-backup-$(date +%Y%m%d-%H%M%S).json"
CHANGE_FILE="dns-cutover.json"

# Set to true if you want the script to attempt
# Azure App Service Managed Certificates automatically.
#
# This Azure CLI command is currently Preview.
CREATE_MANAGED_SSL="${CREATE_MANAGED_SSL:-false}"

# ============================================================
# Helpers
# ============================================================

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

fail() {
    echo
    echo "ERROR: $1"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required but not installed."
}

# ============================================================
# Requirements
# ============================================================

log "Checking required commands"

require_cmd az
require_cmd aws
require_cmd jq
require_cmd dig
require_cmd curl

echo "All required commands are available."

# ============================================================
# Azure login check
# ============================================================

log "Checking Azure login"

az account show >/dev/null 2>&1 || fail "Azure CLI is not logged in. Run: az login"

echo "Azure login: OK"

# ============================================================
# AWS credentials check
# ============================================================

log "Checking AWS credentials"

aws sts get-caller-identity >/dev/null 2>&1 \
    || fail "AWS credentials are not configured."

echo "AWS credentials: OK"

# ============================================================
# Verify Azure apps
# ============================================================

log "Checking Azure App Services"

az webapp show \
    --resource-group "$RG" \
    --name "$WEBAPP" \
    >/dev/null \
    || fail "Azure Web App $WEBAPP was not found."

az webapp show \
    --resource-group "$RG" \
    --name "$ADMIN_APP" \
    >/dev/null \
    || fail "Azure Admin App $ADMIN_APP was not found."

echo "Azure apps: OK"

# ============================================================
# Get Azure verification IDs
# ============================================================

WEBAPP_VERIFICATION_ID="$(
    az webapp show \
        --resource-group "$RG" \
        --name "$WEBAPP" \
        --query customDomainVerificationId \
        -o tsv
)"

ADMIN_VERIFICATION_ID="$(
    az webapp show \
        --resource-group "$RG" \
        --name "$ADMIN_APP" \
        --query customDomainVerificationId \
        -o tsv
)"

[[ -n "$WEBAPP_VERIFICATION_ID" ]] \
    || fail "Could not get Web App custom domain verification ID."

[[ -n "$ADMIN_VERIFICATION_ID" ]] \
    || fail "Could not get Admin App custom domain verification ID."

echo "Web App verification ID : $WEBAPP_VERIFICATION_ID"
echo "Admin verification ID    : $ADMIN_VERIFICATION_ID"

# ============================================================
# Backup Route 53 zone
# ============================================================

log "Backing up Route 53"

aws route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    > "$BACKUP_FILE"

echo "Backup created:"
echo "$(pwd)/$BACKUP_FILE"

# ============================================================
# Show current records before changing anything
# ============================================================

log "Current relevant DNS records"

aws route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${ADMIN_DOMAIN}.' || Name=='${WWW_DOMAIN}.' || Name=='asuid.${ADMIN_DOMAIN}.' || Name=='asuid.${WWW_DOMAIN}.']" \
    --output table

# ============================================================
# Safety check: admin must still point to old AWS ALB
# ============================================================

log "Validating current admin record"

CURRENT_ADMIN_DNS="$(
    aws route53 list-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --query "ResourceRecordSets[?Name=='${ADMIN_DOMAIN}.' && Type=='A'].AliasTarget.DNSName | [0]" \
        --output text
)"

if [[ "$CURRENT_ADMIN_DNS" != "$EXPECTED_ADMIN_DNS" ]]; then
    fail "$ADMIN_DOMAIN is not pointing to the expected old load balancer. Aborting for safety."
fi

echo "Admin record matches the expected old load balancer."

# ============================================================
# Safety check: www must still point to old CloudFront
# ============================================================

log "Validating current www record"

CURRENT_WWW_DNS="$(
    aws route53 list-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --query "ResourceRecordSets[?Name=='${WWW_DOMAIN}.' && Type=='CNAME'].ResourceRecords[0].Value | [0]" \
        --output text
)"

if [[ "$CURRENT_WWW_DNS" != "$EXPECTED_WWW_DNS" ]]; then
    fail "$WWW_DOMAIN is not pointing to the expected old CDN. Aborting for safety."
fi

echo "WWW record matches the expected old CDN."

# ============================================================
# Add Azure verification TXT records
# ============================================================

log "Adding Azure verification TXT records"

aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "{
      \"Comment\": \"Tamra Azure App Service domain verification\",
      \"Changes\": [
        {
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"asuid.${ADMIN_DOMAIN}.\",
            \"Type\": \"TXT\",
            \"TTL\": 300,
            \"ResourceRecords\": [
              {
                \"Value\": \"\\\"${ADMIN_VERIFICATION_ID}\\\"\"
              }
            ]
          }
        },
        {
          \"Action\": \"UPSERT\",
          \"ResourceRecordSet\": {
            \"Name\": \"asuid.${WWW_DOMAIN}.\",
            \"Type\": \"TXT\",
            \"TTL\": 300,
            \"ResourceRecords\": [
              {
                \"Value\": \"\\\"${WEBAPP_VERIFICATION_ID}\\\"\"
              }
            ]
          }
        }
      ]
    }"

echo "Azure verification TXT records added."

# ============================================================
# Add custom domains to Azure
# ============================================================

log "Adding $ADMIN_DOMAIN to the configured admin app"

if az webapp config hostname list \
    --resource-group "$RG" \
    --webapp-name "$ADMIN_APP" \
    --query "[?name=='${ADMIN_DOMAIN}'] | length(@)" \
    -o tsv | grep -q '^1$'; then

    echo "$ADMIN_DOMAIN already exists on Azure Admin App."
else
    az webapp config hostname add \
        --resource-group "$RG" \
        --webapp-name "$ADMIN_APP" \
        --hostname "$ADMIN_DOMAIN"
fi

log "Adding $WWW_DOMAIN to the configured web app"

if az webapp config hostname list \
    --resource-group "$RG" \
    --webapp-name "$WEBAPP" \
    --query "[?name=='${WWW_DOMAIN}'] | length(@)" \
    -o tsv | grep -q '^1$'; then

    echo "$WWW_DOMAIN already exists on Azure Web App."
else
    az webapp config hostname add \
        --resource-group "$RG" \
        --webapp-name "$WEBAPP" \
        --hostname "$WWW_DOMAIN"
fi

echo "Azure custom domains configured."

# ============================================================
# Verify Azure hostname bindings
# ============================================================

log "Verifying Azure hostname bindings"

az webapp config hostname list \
    --resource-group "$RG" \
    --webapp-name "$ADMIN_APP" \
    -o table

az webapp config hostname list \
    --resource-group "$RG" \
    --webapp-name "$WEBAPP" \
    -o table

# ============================================================
# Optional Managed SSL
# ============================================================

if [[ "$CREATE_MANAGED_SSL" == "true" ]]; then

    log "Creating Azure Managed SSL for admin"

    az webapp config ssl create \
        --resource-group "$RG" \
        --name "$ADMIN_APP" \
        --hostname "$ADMIN_DOMAIN"

    log "Creating Azure Managed SSL for www"

    az webapp config ssl create \
        --resource-group "$RG" \
        --name "$WEBAPP" \
        --hostname "$WWW_DOMAIN"

    echo "Managed SSL creation requested."
    echo "Note: Azure CLI currently marks this command as Preview."
else
    echo
    echo "Managed SSL creation skipped."
    echo "Set CREATE_MANAGED_SSL=true to attempt it."
fi

# ============================================================
# Confirmation before DNS cutover
# ============================================================

log "FINAL DNS CUTOVER"

echo "The following changes WILL be made:"
echo
echo "$ADMIN_DOMAIN"
echo "  Existing load balancer"
echo "      ↓"
echo "  $ADMIN_HOST"
echo
echo "$WWW_DOMAIN"
echo "  Existing CDN"
echo "      ↓"
echo "  $WEBAPP_HOST"
echo

read -r -p "Type CUTOVER to continue: " CONFIRM

if [[ "$CONFIRM" != "CUTOVER" ]]; then
    echo "Cutover cancelled. No production DNS routing was changed."
    exit 0
fi

# ============================================================
# Create Route 53 cutover batch
# ============================================================

log "Creating Route 53 cutover batch"

cat > "$CHANGE_FILE" <<EOF
{
  "Comment": "AWS to Azure App Service subdomain cutover",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${ADMIN_DOMAIN}.",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ALB_HOSTED_ZONE_ID}",
          "DNSName": "${EXPECTED_ADMIN_DNS}",
          "EvaluateTargetHealth": false
        }
      }
    },
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "${ADMIN_DOMAIN}.",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "${ADMIN_HOST}"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${WWW_DOMAIN}.",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [
          {
            "Value": "${WEBAPP_HOST}"
          }
        ]
      }
    }
  ]
}
EOF

cat "$CHANGE_FILE"

# ============================================================
# Apply Route 53 cutover
# ============================================================

log "Applying Route 53 cutover"

CHANGE_ID="$(
    aws route53 change-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --change-batch "file://$CHANGE_FILE" \
        --query 'ChangeInfo.Id' \
        --output text
)"

echo "Route 53 change ID: $CHANGE_ID"

# ============================================================
# Wait for Route 53 INSYNC
# ============================================================

log "Waiting for Route 53"

aws route53 wait resource-record-sets-changed \
    --id "$CHANGE_ID"

echo "Route 53 change: INSYNC"

# ============================================================
# DNS verification
# ============================================================

log "Checking DNS"

echo
echo "$ADMIN_DOMAIN:"
dig +short "$ADMIN_DOMAIN"

echo
echo "$WWW_DOMAIN:"
dig +short "$WWW_DOMAIN"

# ============================================================
# Final HTTPS verification
# ============================================================

log "HTTPS verification"

echo
echo "Admin:"
curl -Iv --max-time 20 "https://${ADMIN_DOMAIN}" || true

echo
echo "WWW:"
curl -Iv --max-time 20 "https://${WWW_DOMAIN}" || true

# ============================================================
# Finish
# ============================================================

log "Migration completed"

echo "Configured subdomains now target Azure:"
echo
echo "https://${ADMIN_DOMAIN}"
echo "    -> ${ADMIN_HOST}"
echo
echo "https://${WWW_DOMAIN}"
echo "    -> ${WEBAPP_HOST}"
echo
echo "Route53 backup:"
echo "    ${BACKUP_FILE}"
echo
echo "Cutover file:"
echo "    ${CHANGE_FILE}"
