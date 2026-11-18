#!/usr/bin/env bash
# ============================================================
# AWS RESOURCE DELETE SCRIPT
#
# SAFE BY DEFAULT: runs in DRY-RUN mode and only PRINTS what it
# would delete. Nothing is destroyed unless you pass --execute
# AND type the confirmation phrase when prompted.
#
# Requires a completed backup manifest
# (pass its output dir with --backup-dir), unless you explicitly
# override with --skip-backup-check.
#
# Usage:
#   RESOURCE_NAME_PATTERN='example-pattern' AWS_REGIONS='region-a region-b' \
#     ./delete-matched-aws-resources.sh --backup-dir path/to/backup
#       -> dry run, shows exactly what would be deleted
#
#   ... --execute
#       -> actually deletes, after typed confirmation
#
#   ... --execute --include-s3
#       -> also empties+deletes matched S3 buckets (extra dangerous, off by default)
# ============================================================

set -u
export AWS_PAGER=""

PATTERN="${RESOURCE_NAME_PATTERN:?Set RESOURCE_NAME_PATTERN}"
read -r -a REGIONS <<< "${AWS_REGIONS:?Set AWS_REGIONS as a space-separated list}"

# Explicit overrides, independent of PATTERN:
# - names here are ALWAYS included even if they don't match PATTERN
#   (for resources not matched by the pattern)
# - names here are NEVER deleted even if they DO match PATTERN
#   (belt-and-suspenders safety net for known other-project resources)
read -r -a EXPLICIT_INCLUDE <<< "${EXPLICIT_INCLUDE:-}"
read -r -a EXPLICIT_EXCLUDE <<< "${EXPLICIT_EXCLUDE:-}"

EXECUTE=false
INCLUDE_S3=false
SKIP_BACKUP_CHECK=false
BACKUP_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --execute) EXECUTE=true; shift ;;
    --include-s3) INCLUDE_S3=true; shift ;;
    --skip-backup-check) SKIP_BACKUP_CHECK=true; shift ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="delete-resources-${STAMP}.log"
: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }

run_or_echo() {
    # $1 = human description, rest = actual aws command
    local DESC="$1"; shift
    if $EXECUTE; then
        log "[DELETE] $DESC"
        "$@" >> "$LOG" 2>&1 || log "    -> command failed (see $LOG)"
    else
        log "[DRY-RUN] Would run: $DESC"
        log "          Command: $*"
    fi
}

matches() {
    local NAME="$1"
    # explicit exclude always wins, even over a pattern match
    for EX in "${EXPLICIT_EXCLUDE[@]}"; do
        [[ "$NAME" == "$EX" ]] && return 1
    done
    # explicit include always matches, even if pattern doesn't
    for INC in "${EXPLICIT_INCLUDE[@]}"; do
        [[ "$NAME" == "$INC" ]] && return 0
    done
    echo "$NAME" | grep -qEi "$PATTERN"
}

# ------------------------------------------------------------
# Backup verification gate
# ------------------------------------------------------------
if ! $SKIP_BACKUP_CHECK; then
    if [[ -z "$BACKUP_DIR" || ! -f "$BACKUP_DIR/BACKUP_MANIFEST.txt" ]]; then
        echo "ERROR: No valid backup manifest found."
        echo "Create and verify a backup manifest first, then pass its directory with --backup-dir."
        echo "(Or pass --skip-backup-check if you really understand the risk.)"
        exit 1
    fi
    log "Backup manifest verified: $BACKUP_DIR/BACKUP_MANIFEST.txt"
fi

log "============================================================"
log " MATCHED AWS RESOURCE DELETE"
log " Mode: $([ "$EXECUTE" = true ] && echo 'EXECUTE (DESTRUCTIVE)' || echo 'DRY-RUN (safe)')"
log " S3 deletion: $([ "$INCLUDE_S3" = true ] && echo 'INCLUDED' || echo 'excluded')"
log "============================================================"

# ------------------------------------------------------------
# Confirmation gate for real execution
# ------------------------------------------------------------
if $EXECUTE; then
    echo
    echo "!!! DESTRUCTIVE MODE !!!"
    echo "This will permanently delete AWS resources matching: $PATTERN"
    echo "across regions: ${REGIONS[*]}"
    $INCLUDE_S3 && echo "INCLUDING S3 bucket contents (irreversible)."
    echo
    read -r -p 'Type exactly "DELETE-MATCHED-RESOURCES" to proceed: ' CONFIRM
    if [[ "$CONFIRM" != "DELETE-MATCHED-RESOURCES" ]]; then
        echo "Confirmation not matched. Aborting, nothing deleted."
        exit 1
    fi
fi

# ============================================================
# REGIONAL DELETION
# ============================================================
for REGION in "${REGIONS[@]}"; do
  log ""
  log "############################################################"
  log " REGION: $REGION"
  log "############################################################"

  # --------------------------------------------------------
  # EB ENVIRONMENTS (terminate) — do this BEFORE deleting RDS/EC2,
  # since terminating the env also cleans up its EC2/ASG/ALB.
  # --------------------------------------------------------
  ENVS_JSON=$(aws elasticbeanstalk describe-environments --region "$REGION" --output json 2>/dev/null || echo '{}')
  echo "$ENVS_JSON" | jq -r '.Environments[]? | select(.Status!="Terminated") | .EnvironmentName' 2>/dev/null |
  while read -r ENV; do
      [[ -z "$ENV" ]] && continue
      matches "$ENV" || continue
      run_or_echo "Terminate EB environment $ENV ($REGION)" \
          aws elasticbeanstalk terminate-environment --region "$REGION" --environment-name "$ENV"
  done

  # --------------------------------------------------------
  # EB APPLICATIONS (delete, after environments are gone)
  # --------------------------------------------------------
  APPS_JSON=$(aws elasticbeanstalk describe-applications --region "$REGION" --output json 2>/dev/null || echo '{}')
  echo "$APPS_JSON" | jq -r '.Applications[]?.ApplicationName' 2>/dev/null |
  while read -r APP; do
      [[ -z "$APP" ]] && continue
      matches "$APP" || continue
      run_or_echo "Delete EB application $APP ($REGION)" \
          aws elasticbeanstalk delete-application --region "$REGION" \
          --application-name "$APP" --terminate-env-by-force
  done

  # --------------------------------------------------------
  # RDS INSTANCES — final snapshot on delete for extra safety margin
  # --------------------------------------------------------
  RDS_JSON=$(aws rds describe-db-instances --region "$REGION" --output json 2>/dev/null || echo '{}')
  echo "$RDS_JSON" | jq -r '.DBInstances[]?.DBInstanceIdentifier' 2>/dev/null |
  while read -r DBID; do
      [[ -z "$DBID" ]] && continue
      matches "$DBID" || continue
      FINAL_SNAP="final-before-delete-${DBID:0:40}-${STAMP}"
      FINAL_SNAP="${FINAL_SNAP//[^a-zA-Z0-9-]/-}"
      run_or_echo "Delete RDS instance $DBID ($REGION) with final snapshot $FINAL_SNAP" \
          aws rds delete-db-instance --region "$REGION" \
          --db-instance-identifier "$DBID" \
          --final-db-snapshot-identifier "$FINAL_SNAP"
  done

  # --------------------------------------------------------
  # ELASTICACHE — delete matching replication groups / clusters
  # --------------------------------------------------------
  RG_JSON=$(aws elasticache describe-replication-groups --region "$REGION" --output json 2>/dev/null || echo '{}')
  echo "$RG_JSON" | jq -r '.ReplicationGroups[]?.ReplicationGroupId' 2>/dev/null |
  while read -r RGID; do
      [[ -z "$RGID" ]] && continue
      matches "$RGID" || continue
      run_or_echo "Delete ElastiCache replication group $RGID ($REGION)" \
          aws elasticache delete-replication-group --region "$REGION" \
          --replication-group-id "$RGID" \
          --final-snapshot-identifier "final-${RGID}-${STAMP}"
  done

  CC_JSON=$(aws elasticache describe-cache-clusters --region "$REGION" --output json 2>/dev/null || echo '{}')
  echo "$CC_JSON" | jq -r '.CacheClusters[]? | select(.ReplicationGroupId==null) | .CacheClusterId' 2>/dev/null |
  while read -r CID; do
      [[ -z "$CID" ]] && continue
      matches "$CID" || continue
      run_or_echo "Delete ElastiCache cluster $CID ($REGION)" \
          aws elasticache delete-cache-cluster --region "$REGION" --cache-cluster-id "$CID"
  done

  # --------------------------------------------------------
  # ECR REPOSITORIES
  # --------------------------------------------------------
  ECR_JSON=$(aws ecr describe-repositories --region "$REGION" --output json 2>/dev/null || echo '{}')
  echo "$ECR_JSON" | jq -r '.repositories[]?.repositoryName' 2>/dev/null |
  while read -r REPO; do
      [[ -z "$REPO" ]] && continue
      matches "$REPO" || continue
      run_or_echo "Delete ECR repository $REPO ($REGION), force (all images)" \
          aws ecr delete-repository --region "$REGION" --repository-name "$REPO" --force
  done

  # --------------------------------------------------------
  # LAMBDA FUNCTIONS
  # --------------------------------------------------------
  FN_JSON=$(aws lambda list-functions --region "$REGION" --output json 2>/dev/null || echo '{}')
  echo "$FN_JSON" | jq -r '.Functions[]?.FunctionName' 2>/dev/null |
  while read -r FN; do
      [[ -z "$FN" ]] && continue
      matches "$FN" || continue
      run_or_echo "Delete Lambda function $FN ($REGION)" \
          aws lambda delete-function --region "$REGION" --function-name "$FN"
  done

  # --------------------------------------------------------
  # CLOUDFORMATION STACKS
  # --------------------------------------------------------
  STK_JSON=$(aws cloudformation list-stacks --region "$REGION" \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
      --output json 2>/dev/null || echo '{}')
  echo "$STK_JSON" | jq -r '.StackSummaries[]?.StackName' 2>/dev/null |
  while read -r STK; do
      [[ -z "$STK" ]] && continue
      matches "$STK" || continue
      run_or_echo "Delete CloudFormation stack $STK ($REGION)" \
          aws cloudformation delete-stack --region "$REGION" --stack-name "$STK"
  done

  # --------------------------------------------------------
  # CLOUDWATCH LOG GROUPS
  # --------------------------------------------------------
  LG_JSON=$(aws logs describe-log-groups --region "$REGION" --output json 2>/dev/null || echo '{}')
  echo "$LG_JSON" | jq -r '.logGroups[]?.logGroupName' 2>/dev/null |
  while read -r LG; do
      [[ -z "$LG" ]] && continue
      matches "$LG" || continue
      run_or_echo "Delete CloudWatch log group $LG ($REGION)" \
          aws logs delete-log-group --region "$REGION" --log-group-name "$LG"
  done

done

# ============================================================
# AMPLIFY APPS
# ============================================================
for REGION in "${REGIONS[@]}"; do
    AMP_JSON=$(aws amplify list-apps --region "$REGION" --output json 2>/dev/null || echo '{}')
    echo "$AMP_JSON" | jq -r '.apps[]? | [.appId, .name] | @tsv' 2>/dev/null |
    while IFS=$'\t' read -r APPID NAME; do
        [[ -z "$APPID" ]] && continue
        matches "$NAME" || continue
        run_or_echo "Delete Amplify app $NAME ($APPID, $REGION)" \
            aws amplify delete-app --region "$REGION" --app-id "$APPID"
    done
done

# ============================================================
# S3 — OFF BY DEFAULT, extra dangerous
# ============================================================
if $INCLUDE_S3; then
    ALL_BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text | tr '\t' '\n')
    while read -r BUCKET; do
        [[ -z "$BUCKET" ]] && continue
        matches "$BUCKET" || continue
        run_or_echo "Empty + delete S3 bucket $BUCKET (ALL OBJECTS + VERSIONS)" \
            bash -c "aws s3 rm s3://${BUCKET} --recursive && aws s3api delete-bucket --bucket ${BUCKET}"
    done <<< "$ALL_BUCKETS"
else
    log ""
    log "[S3] Skipped (pass --include-s3 to also empty+delete matched buckets)."
fi

# ============================================================
# SECRETS MANAGER + SSM — NEVER auto-deleted
# ============================================================
log ""
log "[Secrets/SSM] NOT deleted automatically. Review these manually and delete"
log "              yourself once you've confirmed nothing else depends on them:"
for REGION in "${REGIONS[@]}"; do
    aws secretsmanager list-secrets --region "$REGION" \
        --query 'SecretList[].Name' --output text 2>/dev/null | tr '\t' '\n' | \
        grep -Ei "$PATTERN" | sed "s/^/    [$REGION] secret: /" | tee -a "$LOG" || true
    aws ssm describe-parameters --region "$REGION" \
        --query 'Parameters[].Name' --output text 2>/dev/null | tr '\t' '\n' | \
        grep -Ei "$PATTERN" | sed "s/^/    [$REGION] ssm-param: /" | tee -a "$LOG" || true
done

log ""
log "============================================================"
log " DONE. Mode was: $([ "$EXECUTE" = true ] && echo 'EXECUTE' || echo 'DRY-RUN')"
log " Full log: $LOG"
log "============================================================"
if ! $EXECUTE; then
    log ""
    log "This was a DRY RUN — nothing was deleted."
    log "Review the log above/in $LOG, then re-run with --execute to actually delete."
fi
