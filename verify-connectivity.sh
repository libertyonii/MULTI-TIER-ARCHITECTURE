#!/bin/bash
# verify-connectivity.sh — Test NSG rules via SSH + ping
# Run this after deploy.sh completes

set -euo pipefail

# ── Load IPs saved by deploy.sh, or set them manually below ──────────────────
if [[ -f /tmp/multitier-ips.env ]]; then
    source /tmp/multitier-ips.env
else
    WEB_PUB="${WEB_PUB:-}"
    APP_PRV="${APP_PRV:-}"
    DB_PRV="${DB_PRV:-}"
    ADMIN_USER="${ADMIN_USER:-libo}"
fi
# ─────────────────────────────────────────────────────────────────────────────

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

pass() { echo -e "\033[1;32m[PASS]\033[0m $*"; }
fail() { echo -e "\033[1;31m[FAIL]\033[0m $*"; }
log()  { echo -e "\033[1;34m[TEST]\033[0m $*"; }

PASSED=0
FAILED=0

# Validate IPs are set
[[ -z "$WEB_PUB" ]] && { echo "ERROR: WEB_PUB not set. Run deploy.sh first or set the variable manually."; exit 1; }
[[ -z "$APP_PRV" ]] && { echo "ERROR: APP_PRV not set."; exit 1; }
[[ -z "$DB_PRV"  ]] && { echo "ERROR: DB_PRV not set.";  exit 1; }

# Run a command on a remote host
remote() {
    local host=$1; shift
    ssh $SSH_OPTS "$ADMIN_USER@$host" "$@"
}

# Ping test
# Usage: ping_test <from_host> <target_ip> <expected: pass|fail> <label>
ping_test() {
    local host=$1 target=$2 expected=$3 label=$4
    log "$label — ping $target from $host (expect: $expected)"
    if remote "$host" "ping -c 3 -W 5 $target > /dev/null 2>&1"; then
        result="pass"
    else
        result="fail"
    fi
    if [[ "$result" == "$expected" ]]; then
        pass "$label — $result (correct)"
        PASSED=$((PASSED + 1))
    else
        fail "$label — got $result, expected $expected"
        FAILED=$((FAILED + 1))
    fi
}

echo ""
echo "══════════════════════════════════════════════════"
echo "  NSG Connectivity Test Suite"
echo "══════════════════════════════════════════════════"
echo ""

# Check SSH into Web VM works first
log "Checking SSH access to Web VM..."
if ssh $SSH_OPTS "$ADMIN_USER@$WEB_PUB" "echo ok" | grep -q "ok"; then
    pass "SSH to Web VM"
else
    fail "SSH to Web VM — check public IP and WEBNSG Allow-SSH-Inbound rule"
    exit 1
fi

echo ""

# Web → App (should succeed)
ping_test "$WEB_PUB" "$APP_PRV" "pass" "Web → App"

# Web → DB (should be blocked)
ping_test "$WEB_PUB" "$DB_PRV" "fail" "Web → DB (blocked)"

# App → DB via jump through Web (should succeed)
log "App → DB — ping via SSH jump (expect: pass)"
if ssh $SSH_OPTS -J "$ADMIN_USER@$WEB_PUB" "$ADMIN_USER@$APP_PRV" \
    "ping -c 3 -W 5 $DB_PRV > /dev/null 2>&1"; then
    pass "App → DB — pass (correct)"
    PASSED=$((PASSED + 1))
else
    fail "App → DB — fail (expected pass)"
    FAILED=$((FAILED + 1))
fi

# DB → App via double jump (should be blocked)
log "DB → App — ping via double jump (expect: blocked)"
if ssh $SSH_OPTS -J "$ADMIN_USER@$WEB_PUB,$ADMIN_USER@$APP_PRV" "$ADMIN_USER@$DB_PRV" \
    "ping -c 3 -W 5 $APP_PRV > /dev/null 2>&1"; then
    fail "DB → App — pass (NSG not blocking — check Deny-DB-To-App rule)"
    FAILED=$((FAILED + 1))
else
    pass "DB → App — blocked (correct)"
    PASSED=$((PASSED + 1))
fi

echo ""
echo "══════════════════════════════════════════════════"
echo "  Results: $PASSED passed, $FAILED failed"
echo "══════════════════════════════════════════════════"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "\033[1;32mAll tests passed. NSG rules are enforced correctly.\033[0m"
else
    echo -e "\033[1;31m$FAILED test(s) failed. Review NSG rules above.\033[0m"
    exit 1
fi
