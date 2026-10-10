#!/bin/bash
# Orkestrator scan SonarQube berdiri sendiri
# Called from release-dashboard to trigger scan without full pipeline.
#
# Semua nama repo, group dan module di file ini sintetis. Konvensinya sama seperti
# pita project ID 1001-1999 di ci-library/gateway.yml: bentuknya nyata, isinya tidak.
# scripts/check-sanitised.sh memblokir kosakata internal yang pernah ada di sini. for up-to-date scanning.
#
# Flow: clone ci-scripts → clone source repo → build (if Java) → scan → output JSON
#
# Usage:
#   SCAN_PROJECT=platform-api SCAN_TYPE=maven SCAN_SERVICES="identity:R1.2" ./run-scan.sh
#   SCAN_PROJECT=portal SCAN_TYPE=java SCAN_SERVICES="portal/identity:R1.0" ./run-scan.sh
#   SCAN_PROJECT=portal SCAN_TYPE=frontend SCAN_SERVICES="portal-ui:R1.0" ./run-scan.sh
#
# Environment variables (required):
#   SCAN_PROJECT     project name: platform-api, portal
#   SCAN_TYPE        scan type: maven, native, java, frontend, android
#   SCAN_SERVICES    comma-separated service:branch (e.g. "identity:R1.2,catalog:R1.2")
#
# Environment variables (optional, auto-resolved):
#   GIT_TOKEN        GitLab token (default from credentials.sh)
#   SONAR_HOST       SonarQube URL (default: http://sonar.example.internal:9000)
#   SONAR_TOKEN      SonarQube token (default from credentials.sh)
#
# Output: JSON to stdout
#   { "status": "success|failed", "results": [...], "errors": [...] }
#
# Semua log ke stderr, hanya hasil JSON ke stdout.

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────
SCAN_PROJECT="${SCAN_PROJECT:?SCAN_PROJECT required (platform-api|portal)}"
SCAN_TYPE="${SCAN_TYPE:?SCAN_TYPE required (maven|native|java|frontend|android)}"
SCAN_SERVICES="${SCAN_SERVICES:?SCAN_SERVICES required (service:branch,...)}"

CI_SCRIPTS_REPO="${CI_SCRIPTS_REPO:-git.example.internal:platform/pipeline-gateway.git}"
CI_SCRIPTS_PATH="/tmp/ci-scripts"
SCAN_WORKSPACE="/tmp/scan-workspace-$$"

SONAR_HOST="${SONAR_HOST:-http://sonar.example.internal:9000}"
SONAR_TOKEN='${VAULT_SONAR_TOKEN}'
GIT_TOKEN='${VAULT_GIT_TOKEN}'

# Export for child scripts
export SONAR_HOST SONAR_TOKEN GIT_TOKEN

# ─────────────────────────────────────────────────────────────
# Git URLs per project dan scan type
# ─────────────────────────────────────────────────────────────
# Portal backend: monolith repos (portal, identity, catalog, reports-batch)
DASHBOARD_BE_URL="git.example.internal/wholesale/portal/be"
# Portal frontend
DASHBOARD_FE_URL="git.example.internal/wholesale/portal/fe"

log() { echo "[run-scan] $*" >&2; }

# ─────────────────────────────────────────────────────────────
# STEP 1: Clone ci-scripts (always fresh)
# ─────────────────────────────────────────────────────────────
log "Cloning ci-scripts..."
rm -rf "${CI_SCRIPTS_PATH}"
git clone --depth 1 "https://oauth2:${GIT_TOKEN}@${CI_SCRIPTS_REPO}" "${CI_SCRIPTS_PATH}" >&2 2>&1

# Source shared scripts
source "${CI_SCRIPTS_PATH}/ci-library/scripts/clone-repo.sh"
source "${CI_SCRIPTS_PATH}/ci-library/scripts/sonar-scan.sh"

# ─────────────────────────────────────────────────────────────
# STEP 2: Parse services
# ─────────────────────────────────────────────────────────────
log "Parsing services: ${SCAN_SERVICES}"
mkdir -p "${SCAN_WORKSPACE}"

RESULTS="[]"
ERRORS="[]"
HAS_ERROR=false

IFS=',' read -ra SVC_LIST <<< "${SCAN_SERVICES}"

for svc_entry in "${SVC_LIST[@]}"; do
    svc_entry=$(echo "$svc_entry" | xargs)  # trim
    if [[ "$svc_entry" != *":"* ]]; then
        log "WARNING: Invalid format '${svc_entry}', expected service:branch, skipping"
        ERRORS=$(echo "$ERRORS" | jq --arg e "Invalid format: ${svc_entry}" '. + [$e]')
        continue
    fi

    # Parse service:branch (support category/module:branch format)
    BRANCH="${svc_entry##*:}"
    SVC_PATH="${svc_entry%%:*}"

    if [[ "$SVC_PATH" == *"/"* ]]; then
        CATEGORY="${SVC_PATH%%/*}"
        MODULE="${SVC_PATH##*/}"
    else
        CATEGORY="$SVC_PATH"
        MODULE="$SVC_PATH"
    fi

    log "Processing: ${CATEGORY}/${MODULE} branch=${BRANCH} type=${SCAN_TYPE}"

    # ─────────────────────────────────────────────────────────
    # STEP 3: Resolve Git URL
    # ─────────────────────────────────────────────────────────
    GIT_URL=""
    PROJECT_KEY_PREFIX=""

    case "${SCAN_TYPE}" in
        maven|native)
            # platform-api backend: resolve dari service-map.yml
            GIT_URL=$(yq -r ".services.\"${MODULE}\".url" "${CI_SCRIPTS_PATH}/ci-library/config/service-map.yml" 2>/dev/null)
            if [ -z "$GIT_URL" ] || [ "$GIT_URL" = "null" ]; then
                GIT_URL=$(yq -r ".libraries.\"${MODULE}\".url" "${CI_SCRIPTS_PATH}/ci-library/config/service-map.yml" 2>/dev/null)
            fi
            PROJECT_KEY_PREFIX="platform-api"
            ;;
        java)
            # Portal backend: monolith repos
            if [ "$MODULE" = "reports-batch" ]; then
                GIT_URL="${DASHBOARD_BE_URL}/reports-batch.git"
            else
                GIT_URL="${DASHBOARD_BE_URL}/${CATEGORY}.git"
            fi
            PROJECT_KEY_PREFIX="dashboard"
            ;;
        frontend)
            # Portal frontend
            GIT_URL="${DASHBOARD_FE_URL}/${MODULE}.git"
            PROJECT_KEY_PREFIX="dashboard"
            ;;
        android)
            GIT_URL="git.example.internal/wholesale/mobile/android.git"
            PROJECT_KEY_PREFIX="platform-api"
            ;;
        *)
            log "ERROR: Unknown SCAN_TYPE: ${SCAN_TYPE}"
            ERRORS=$(echo "$ERRORS" | jq --arg e "Unknown scan type: ${SCAN_TYPE}" '. + [$e]')
            continue
            ;;
    esac

    if [ -z "$GIT_URL" ] || [ "$GIT_URL" = "null" ]; then
        log "ERROR: Cannot resolve Git URL for ${MODULE}"
        ERRORS=$(echo "$ERRORS" | jq --arg e "Git URL not found for ${MODULE}" '. + [$e]')
        HAS_ERROR=true
        continue
    fi

    PROJECT_KEY="${PROJECT_KEY_PREFIX}-${MODULE}-${BRANCH}"
    CLONE_DIR="${SCAN_WORKSPACE}/${MODULE}"

    # ─────────────────────────────────────────────────────────
    # STEP 4: Clone source (always fresh)
    # ─────────────────────────────────────────────────────────
    log "Cloning ${MODULE} (${BRANCH})..."
    rm -rf "${CLONE_DIR}"
    mkdir -p "${SCAN_WORKSPACE}"

    if ! (cd "${SCAN_WORKSPACE}" && clone_repo "${BRANCH}" "${GIT_URL}") >&2 2>&1; then
        log "ERROR: Clone failed for ${MODULE}"
        ERRORS=$(echo "$ERRORS" | jq --arg e "Clone failed: ${MODULE}:${BRANCH}" '. + [$e]')
        HAS_ERROR=true
        continue
    fi

    # Resolve actual clone dir name (basename of git URL without .git)
    REPO_NAME=$(basename "$GIT_URL" .git)
    CLONE_DIR="${SCAN_WORKSPACE}/${REPO_NAME}"

    # ─────────────────────────────────────────────────────────
    # STEP 5: Build (if needed for Java)
    # ─────────────────────────────────────────────────────────
    BUILD_OK=true
    case "${SCAN_TYPE}" in
        maven)
            log "Building Maven project: ${MODULE}..."
            source "${CI_SCRIPTS_PATH}/ci-library/scripts/build-maven.sh"
            if ! build_standard "${CLONE_DIR}" >&2 2>&1; then
                log "WARNING: Build failed for ${MODULE}, scanning without binaries"
                BUILD_OK=false
            fi
            ;;
        native)
            log "Building Native project: ${MODULE}..."
            source "${CI_SCRIPTS_PATH}/ci-library/scripts/build-maven.sh"
            if ! build_native "${CLONE_DIR}" >&2 2>&1; then
                log "WARNING: Native build failed for ${MODULE}"
                BUILD_OK=false
            fi
            ;;
        java)
            # Portal backend (Gradle): butuh product build lebih dulu untuk portal/identity
            log "Building Gradle project: ${MODULE}..."
            source "${CI_SCRIPTS_PATH}/ci-library/scripts/build-gradle.sh"
            if [ "$CATEGORY" = "portal" ] || [ "$CATEGORY" = "identity" ]; then
                # Clone and build product (shared dependency) if not already done
                PRODUCT_DIR="${SCAN_WORKSPACE}/product"
                if [ ! -d "$PRODUCT_DIR" ]; then
                    log "Cloning product (shared dependency)..."
                    (cd "${SCAN_WORKSPACE}" && clone_repo "${BRANCH}" "${DASHBOARD_BE_URL}/product.git") >&2 2>&1 || true
                    if [ -d "$PRODUCT_DIR" ]; then
                        build_product "$PRODUCT_DIR" >&2 2>&1 || log "WARNING: Product build failed"
                    fi
                fi
                build_category "${CLONE_DIR}" "${CATEGORY}" >&2 2>&1 || BUILD_OK=false
            elif [ "$MODULE" = "reports-batch" ]; then
                build_dhe "${CLONE_DIR}" >&2 2>&1 || BUILD_OK=false
            fi
            ;;
        frontend|android)
            # No build needed for scan
            log "No build required for ${SCAN_TYPE} scan"
            ;;
    esac

    # ─────────────────────────────────────────────────────────
    # STEP 6: Run SonarQube scan
    # ─────────────────────────────────────────────────────────
    log "Scanning ${MODULE} (${BRANCH}) with type=${SCAN_TYPE}..."
    SCAN_OK=true
    SONAR_URL=""

    case "${SCAN_TYPE}" in
        java)
            SONAR_URL=$(run_sonar_scan_java "${CLONE_DIR}" "${PROJECT_KEY}" "${MODULE}" "${BRANCH}") || SCAN_OK=false
            ;;
        maven)
            SONAR_URL=$(run_sonar_scan_maven "${CLONE_DIR}" "${PROJECT_KEY}" "${MODULE}" "${BRANCH}") || SCAN_OK=false
            ;;
        native)
            SONAR_URL=$(run_sonar_scan_native "${CLONE_DIR}" "${PROJECT_KEY}" "${MODULE}" "${BRANCH}") || SCAN_OK=false
            ;;
        frontend)
            # Special case: portal-ui + fe-reports-batch → DHE isolation scan
            if [ "$MODULE" = "portal-ui" ] && [ "$BRANCH" = "fe-reports-batch" ]; then
                DHE_PROJECT_KEY="frontend-reports-orphan"
                DHE_EXCLUDE="src/lib/pages/upload"
                log "REPORTS-BATCH isolation scan for ${MODULE} (${BRANCH})"
                SONAR_URL=$(run_sonar_dhe_isolation "${GIT_URL}" "feat/reports-batch" "${BRANCH}" "${DHE_PROJECT_KEY}" "${DHE_EXCLUDE}") || SCAN_OK=false
                PROJECT_KEY="${DHE_PROJECT_KEY}"
            else
                SONAR_URL=$(run_sonar_scan_frontend "${CLONE_DIR}" "${PROJECT_KEY}" "${MODULE}" "${BRANCH}") || SCAN_OK=false
            fi
            ;;
        android)
            SONAR_URL=$(run_sonar_scan_android "${CLONE_DIR}" "${PROJECT_KEY}" "${MODULE}" "${BRANCH}") || SCAN_OK=false
            ;;
    esac

    if [ -z "$SONAR_URL" ]; then
        SONAR_URL="${SONAR_HOST}/dashboard?id=${PROJECT_KEY}"
    fi

    # ─────────────────────────────────────────────────────────
    # STEP 7: Fetch measures from SonarQube API
    # ─────────────────────────────────────────────────────────
    MEASURES="{}"
    SCAN_STATUS="Passed"
    if [ "$SCAN_OK" = "true" ]; then
        # Wait a few seconds for SonarQube to process
        sleep 5
        MEASURES=$(fetch_sonar_measures "${PROJECT_KEY}")
        QG=$(echo "$MEASURES" | jq -r '.quality_gate // "N/A"')
        if [ "$QG" = "ERROR" ]; then SCAN_STATUS="Failed"; fi
        if [ "$QG" = "N/A" ]; then SCAN_STATUS="Warning"; fi
    else
        SCAN_STATUS="Error"
        HAS_ERROR=true
    fi

    # Build result entry
    RESULT_ENTRY=$(jq -n \
        --arg svc "$MODULE" \
        --arg branch "$BRANCH" \
        --arg category "$CATEGORY" \
        --arg pk "$PROJECT_KEY" \
        --arg url "$SONAR_URL" \
        --arg status "$SCAN_STATUS" \
        --arg buildOk "$BUILD_OK" \
        --argjson measures "$MEASURES" \
        '{service: $svc, branch: $branch, category: $category, projectKey: $pk, url: $url, scanStatus: $status, buildSuccess: ($buildOk == "true"), measures: $measures}')

    RESULTS=$(echo "$RESULTS" | jq --argjson entry "$RESULT_ENTRY" '. + [$entry]')
    log "Scan complete: ${MODULE} → ${SCAN_STATUS}"
done


# ─────────────────────────────────────────────────────────────
# STEP 8: Cleanup and output JSON result
# ─────────────────────────────────────────────────────────────
log "Cleaning up workspace..."
rm -rf "${SCAN_WORKSPACE}"

OVERALL_STATUS="success"
if [ "$HAS_ERROR" = "true" ]; then OVERALL_STATUS="partial"; fi
ERROR_COUNT=$(echo "$ERRORS" | jq 'length')
RESULT_COUNT=$(echo "$RESULTS" | jq 'length')
if [ "$RESULT_COUNT" -eq 0 ]; then OVERALL_STATUS="failed"; fi

# Output JSON to stdout (only line that goes to stdout)
jq -n \
    --arg status "$OVERALL_STATUS" \
    --arg project "$SCAN_PROJECT" \
    --arg scanType "$SCAN_TYPE" \
    --arg timestamp "$(TZ=Asia/Jakarta date +%Y-%m-%dT%H:%M:%S+07:00)" \
    --argjson results "$RESULTS" \
    --argjson errors "$ERRORS" \
    '{status: $status, project: $project, scanType: $scanType, timestamp: $timestamp, totalScanned: ($results | length), results: $results, errors: $errors}'
