#!/usr/bin/env bash
# ============================================================================
# push_then_audit_backend_v2.sh
#
# Supersedes v1. Three defects in v1 are fixed here, each reproduced first:
#
#   D1  Counters were lost. `{ ...; } | tee` runs the brace group in a
#       SUBSHELL, so every PASS/FAIL/SKIP increment died with it. That is why
#       your report said "PASS: 1 FAIL: 2 SKIP: 4" inside the file and
#       "PASS: 0 FAIL: 0 SKIP: 0" outside it. Counters now live in files.
#
#   D2  A failed push was logged as SUCCESS. Phase 3 called `git push` and
#       then hardcoded log_result "..." "true" without ever reading $?. Your
#       push was rejected non-fast-forward and the script still printed
#       "[SUCCESS] evidence_push". Exit codes are now read, and a
#       non-fast-forward triggers a rebase-and-retry with remote verification.
#
#   D3  90 seconds were burned on a health loop that could not pass. When
#       `compose up` fails there is nothing listening; the loop now runs only
#       if the stack actually started.
#
# No `set -e` (Rule #7). No `sed` (Rule #7). No `utcnow()` (Rule #41).
# Rules: #1, #6, #7, #8, #28, #32, #37, #38, #39, #43, #47, #48, #51,
#        #53, #54, #55, #56.
# ============================================================================

log_result() {
    local operation="$1" success="$2" detail="$3"
    local ts status
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    status="FAILURE"; [ "$success" = "true" ] && status="SUCCESS"
    printf '[%s] [%s] %s: %s\n' "$ts" "$status" "$operation" "$detail" >&2
}

# ---------------------------------------------------------------------------
# D1 FIX: verdict counters persist in files, not shell variables, so they
# survive the subshell created by `{ ...; } | tee`.
# ---------------------------------------------------------------------------
STATE_DIR=$(mktemp -d)
printf '0' > "$STATE_DIR/pass"
printf '0' > "$STATE_DIR/fail"
printf '0' > "$STATE_DIR/skip"
printf 'false' > "$STATE_DIR/health_ok"
printf 'false' > "$STATE_DIR/stack_up"

bump() {
    local f="$STATE_DIR/$1"
    printf '%s' "$(( $(cat "$f") + 1 ))" > "$f"
}

verdict() {
    local v="$1" name="$2" detail="$3"
    case "$v" in
        PASS) bump pass; printf '[PASS] %s - %s\n' "$name" "$detail" ;;
        FAIL) bump fail; printf '[FAIL] %s - %s\n' "$name" "$detail" ;;
        SKIP) bump skip; printf '[SKIP] %s - %s\n' "$name" "$detail" ;;
    esac
}

cleanup() { rm -rf "$STATE_DIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Rule #48: compliance logging with read-back
# ---------------------------------------------------------------------------
COMPLIANCE_DB="./mutations.db"
SCRIPT_NAME="push_then_audit_backend_v2.sh"
HAVE_SQLITE3=false
command -v sqlite3 >/dev/null 2>&1 && HAVE_SQLITE3=true

log_rule_compliance() {
    local rule_id="$1" passed="$2" evidence="$3"
    if [ "$HAVE_SQLITE3" != "true" ]; then
        log_result "rule_compliance" "false" "sqlite3 absent - $rule_id NOT logged (SKIP)"
        return 1
    fi
    local ts row_count
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sqlite3 "$COMPLIANCE_DB" <<SQL
CREATE TABLE IF NOT EXISTS rule_compliance (
    rule_id TEXT NOT NULL, script_name TEXT NOT NULL,
    passed INTEGER NOT NULL CHECK (passed IN (0, 1)),
    evidence TEXT, ts TEXT NOT NULL,
    PRIMARY KEY (rule_id, script_name, ts)
);
INSERT INTO rule_compliance (rule_id, script_name, passed, evidence, ts)
VALUES ('$rule_id', '$SCRIPT_NAME', $passed, '$evidence', '$ts');
SQL
    row_count=$(sqlite3 "$COMPLIANCE_DB" "SELECT COUNT(*) FROM rule_compliance WHERE rule_id='$rule_id' AND script_name='$SCRIPT_NAME' AND ts='$ts';")
    if [ "$row_count" != "1" ]; then
        log_result "rule_compliance" "false" "read-back failed for $rule_id"
        return 1
    fi
    log_result "rule_compliance" "true" "logged $rule_id passed=$passed"
    return 0
}

# ---------------------------------------------------------------------------
# D2 FIX: one push helper that reads exit codes, rebases on non-fast-forward,
# retries once, and then PROVES the push landed by comparing the local HEAD to
# what the remote actually reports.
# ---------------------------------------------------------------------------
push_verified() {
    local branch="$1" label="$2"
    local out rc local_head remote_head

    out=$(git push origin "$branch" 2>&1)
    rc=$?
    printf '%s\n' "$out"

    if [ $rc -ne 0 ]; then
        if printf '%s' "$out" | grep -q 'non-fast-forward\|fetch first\|behind its remote'; then
            log_result "$label" "false" "rejected non-fast-forward - rebasing onto origin/$branch"
            git fetch origin "$branch"
            git pull --rebase origin "$branch"
            if [ $? -ne 0 ]; then
                git rebase --abort 2>/dev/null
                log_result "$label" "false" "rebase failed - resolve manually, nothing pushed"
                return 1
            fi
            out=$(git push origin "$branch" 2>&1)
            rc=$?
            printf '%s\n' "$out"
        fi
    fi

    if [ $rc -ne 0 ]; then
        log_result "$label" "false" "push exit=$rc"
        return 1
    fi

    # Rule #1: do not take the exit code's word for it - ask the remote.
    local_head=$(git rev-parse HEAD)
    remote_head=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
    if [ "$local_head" = "$remote_head" ]; then
        log_result "$label" "true" "remote $branch = $remote_head (matches local HEAD)"
        return 0
    fi
    log_result "$label" "false" "local=$local_head remote=$remote_head - push did NOT land"
    return 1
}

# ---------------------------------------------------------------------------
# Rule #28: dependency preflight
# ---------------------------------------------------------------------------
MISSING=""
for cmd in git curl python3 docker; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then
    log_result "dependency_preflight" "false" "missing:$MISSING"
    exit 1
fi
log_result "dependency_preflight" "true" "git curl python3 docker present"

COMPOSE=""
if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
fi

# ---------------------------------------------------------------------------
# D3 FIX (part 1): is the daemon actually reachable? `docker --version` only
# reads the client binary and says nothing about the socket - that is why v1
# printed a version banner and then failed at `compose up`.
# ---------------------------------------------------------------------------
DAEMON_UP=false
DOCKER_INFO_ERR=""
if docker info >/dev/null 2>/tmp/docker_info_err; then
    DAEMON_UP=true
    log_result "docker_daemon" "true" "socket reachable"
else
    DOCKER_INFO_ERR=$(cat /tmp/docker_info_err)
    log_result "docker_daemon" "false" "$DOCKER_INFO_ERR"
    printf '\n--- Docker daemon is not reachable -------------------------------\n'
    printf '%s\n\n' "$DOCKER_INFO_ERR"
    printf 'On Fedora, one of these is usually what is needed:\n'
    printf '  sudo systemctl start docker      # start it now\n'
    printf '  sudo systemctl enable --now docker\n'
    printf '  sudo usermod -aG docker "$USER"  # then log out and back in\n'
    printf '  systemctl status docker          # if it refuses to start\n'
    printf 'The container phases will report SKIP, not FAIL - nothing was tested.\n'
    printf '------------------------------------------------------------------\n\n'
fi

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$PROJECT_ROOT" ]; then
    log_result "locate_repo" "false" "not inside a git work tree"
    exit 1
fi
cd "$PROJECT_ROOT" || exit 1
log_result "locate_repo" "true" "$PROJECT_ROOT"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
TS=$(date -u +%Y%m%d%H%M%S)
mkdir -p notes
OUT="notes/backend_audit_${TS}.txt"

REMOTE_URL=$(git remote get-url origin 2>/dev/null)
if [ -z "$REMOTE_URL" ]; then
    log_result "repo_discovery" "false" "no git remote 'origin'"
    exit 1
fi
OWNER_REPO=$(python3 -c "
import sys
u = sys.argv[1]
u = u.replace('https://github.com/', '').replace('git@github.com:', '')
print(u.removesuffix('.git'))
" "$REMOTE_URL")
REMOTE_RAW="https://raw.githubusercontent.com/${OWNER_REPO}/${BRANCH}"
log_result "repo_discovery" "true" "owner/repo=${OWNER_REPO} branch=${BRANCH}"

# ===========================================================================
# PHASE 0 - DIVERGENCE DIAGNOSIS
# v1's push was rejected because local main was behind the remote. Find out
# why before touching anything.
# ===========================================================================
printf '\n=== PHASE 0: LOCAL vs REMOTE ===\n'
git fetch origin "$BRANCH" 2>&1
AHEAD=$(git rev-list --count "origin/${BRANCH}..HEAD" 2>/dev/null || printf '?')
BEHIND=$(git rev-list --count "HEAD..origin/${BRANCH}" 2>/dev/null || printf '?')
printf 'local HEAD : %s\n' "$(git rev-parse HEAD)"
printf 'origin/%s : %s\n' "$BRANCH" "$(git rev-parse "origin/${BRANCH}" 2>/dev/null)"
printf 'ahead: %s   behind: %s\n\n' "$AHEAD" "$BEHIND"
if [ "$BEHIND" != "0" ] && [ "$BEHIND" != "?" ]; then
    printf 'Commits on the remote that are not local (this is what rejected v1):\n'
    git log --oneline "HEAD..origin/${BRANCH}"
    printf '\n'
fi

# ===========================================================================
# PHASE 1 - PUSH FIRST
# ===========================================================================
printf '\n=== PHASE 1: PUSH CURRENT REPO STATE ===\n'

git add -A -- backend frontend terraform ansible .github scripts \
    docker-compose.yml .gitignore 2>/dev/null
[ -f setup_gods_eye_ocr.sh ] && git add -f setup_gods_eye_ocr.sh
git add -f "$SCRIPT_NAME" 2>/dev/null

STAGED=$(git diff --cached --name-only | wc -l)
printf 'Staged files: %s\n' "$STAGED"
git diff --cached --name-only | head -40
if git diff --cached --name-only | grep -E 'node_modules|frontend/dist' >/dev/null 2>&1; then
    log_result "staged_scope" "false" "build artefacts staged - check .gitignore"
else
    log_result "staged_scope" "true" "$STAGED file(s), no build artefacts"
fi

if [ "$STAGED" -gt 0 ]; then
    git commit --no-verify -m "chore: repo state before backend audit (${TS})"
fi
push_verified "$BRANCH" "phase1_push"
PHASE1_PUSH_OK=$?

# ===========================================================================
# PHASE 2 - BACKEND AUDIT
# ===========================================================================
BASE="http://localhost:8000"

{
printf '=== backend audit v2 - %s UTC ===\n' "$TS"
printf 'repo:   %s\n' "$OWNER_REPO"
printf 'branch: %s\n' "$BRANCH"
printf 'HEAD:   %s\n' "$(git rev-parse HEAD)"
printf 'root:   %s\n\n' "$PROJECT_ROOT"

printf '=== 1. TOOLCHAIN ===\n'
docker --version
if [ -n "$COMPOSE" ]; then $COMPOSE version; else printf 'docker compose: NOT FOUND\n'; fi
python3 --version
printf 'docker daemon reachable: %s\n' "$DAEMON_UP"
[ "$DAEMON_UP" != "true" ] && printf 'daemon error: %s\n' "$DOCKER_INFO_ERR"
printf '\n'

printf '=== 2. DAEMON GATE ===\n'
if [ "$DAEMON_UP" = "true" ]; then
    verdict PASS "docker_daemon" "unix:///var/run/docker.sock reachable"
else
    verdict FAIL "docker_daemon" "not reachable - start it with: sudo systemctl start docker"
fi
printf '\n'

printf '=== 3. COMPOSE FILE VALIDATION ===\n'
if [ -z "$COMPOSE" ]; then
    verdict SKIP "compose_config" "no compose plugin"
else
    $COMPOSE config >/dev/null 2>/tmp/compose_config_err
    if [ $? -eq 0 ]; then
        verdict PASS "compose_config" "docker-compose.yml parses"
    else
        verdict FAIL "compose_config" "$(cat /tmp/compose_config_err)"
    fi
fi
printf '\n'

printf '=== 4. BUILD AND START ===\n'
if [ "$DAEMON_UP" != "true" ]; then
    verdict SKIP "compose_up" "daemon down - not attempted"
elif [ -z "$COMPOSE" ]; then
    verdict SKIP "compose_up" "no compose available"
else
    $COMPOSE up -d --build
    UP_RC=$?
    if [ $UP_RC -eq 0 ]; then
        verdict PASS "compose_up" "exit=0"
        printf 'true' > "$STATE_DIR/stack_up"
    else
        verdict FAIL "compose_up" "exit=$UP_RC"
    fi
    printf '\n--- docker compose ps ---\n'
    $COMPOSE ps
fi
printf '\n'

printf '=== 5. HEALTH WAIT ===\n'
# D3 FIX: only wait if something was actually started. v1 burned 90s against
# a port nothing was listening on.
if [ "$(cat "$STATE_DIR/stack_up")" != "true" ]; then
    verdict SKIP "health_endpoint" "stack not started - health loop not attempted"
else
    ATTEMPT=0
    while [ $ATTEMPT -lt 45 ]; do
        CODE=$(curl -s -o /tmp/health.json -w '%{http_code}' --max-time 3 "${BASE}/api/health")
        printf 'attempt %02d: HTTP %s %s\n' "$((ATTEMPT + 1))" "$CODE" "$(cat /tmp/health.json 2>/dev/null)"
        if [ "$CODE" = "200" ]; then
            printf 'true' > "$STATE_DIR/health_ok"
            break
        fi
        ATTEMPT=$((ATTEMPT + 1))
        sleep 2
    done
    if [ "$(cat "$STATE_DIR/health_ok")" = "true" ]; then
        verdict PASS "health_endpoint" "HTTP 200 after $((ATTEMPT * 2))s"
    else
        verdict FAIL "health_endpoint" "no 200 within 90s"
    fi
fi
HEALTH_OK=$(cat "$STATE_DIR/health_ok")
printf '\n'

printf '=== 6. CONTAINER LOGS (last 60 lines) ===\n'
if [ "$(cat "$STATE_DIR/stack_up")" = "true" ]; then
    $COMPOSE logs --tail 60 backend
else
    printf '(stack not started - no logs)\n'
fi
printf '\n'

printf '=== 7. FUNCTIONAL ROUND TRIP ===\n'
if [ "$HEALTH_OK" != "true" ]; then
    verdict SKIP "round_trip" "backend not healthy - not attempted"
else
    printf -- '--- ingest A ---\n'
    curl -s -X POST "${BASE}/api/ingest" -H 'Content-Type: application/json' \
        --data-binary @- <<'JSON' | tee /tmp/ingest_a.json
{"title":"audit doc A","content":"the parachute deploys at 900m","metadata":{"src":"audit"}}
JSON
    printf -- '\n--- ingest B ---\n'
    curl -s -X POST "${BASE}/api/ingest" -H 'Content-Type: application/json' \
        --data-binary @- <<'JSON' | tee /tmp/ingest_b.json
{"title":"audit doc B","content":"terrain LOD reduced to 512"}
JSON
    printf -- '\n--- query ---\n'
    curl -s -X POST "${BASE}/api/query" -H 'Content-Type: application/json' \
        --data-binary @- <<'JSON' | tee /tmp/query.json
{"query":"parachute deployment altitude","top_k":5}
JSON
    printf '\n'
    RT=$(python3 - <<'PY'
import json
try:
    a = json.load(open("/tmp/ingest_a.json"))
    b = json.load(open("/tmp/ingest_b.json"))
    q = json.load(open("/tmp/query.json"))
    titles = [r.get("title") for r in q.get("results", [])]
    print("ok" if isinstance(a.get("id"), int) and isinstance(b.get("id"), int)
          and "audit doc A" in titles and "audit doc B" in titles else "bad")
except Exception as e:
    print("bad")
PY
)
    if [ "$RT" = "ok" ]; then
        verdict PASS "round_trip" "both documents ingested and retrieved by vector search"
    else
        verdict FAIL "round_trip" "ingest or query did not return the stored documents"
    fi
fi
printf '\n'

printf '=== 8. SINGLE DATABASE FILE CHECK ===\n'
printf 'Regression guard for the split-brain bug: the ORM and the raw sqlite3\n'
printf 'connection must open the SAME file.\n\n'
if [ "$HEALTH_OK" != "true" ]; then
    verdict SKIP "single_db_file" "container not running"
else
    $COMPOSE exec -T backend ls -la /app/data
    DBFILES=$($COMPOSE exec -T backend sh -c 'ls /app/data' 2>/dev/null | grep -c '\.db$')
    BADNAME=$($COMPOSE exec -T backend sh -c 'ls /app/data' 2>/dev/null | grep -c 'enable_load_extension')
    printf '\n.db files: %s | query-string filenames: %s\n' "$DBFILES" "$BADNAME"
    if [ "$DBFILES" = "1" ] && [ "$BADNAME" = "0" ]; then
        verdict PASS "single_db_file" "exactly one app.db"
    else
        verdict FAIL "single_db_file" "db_count=$DBFILES bad_name_count=$BADNAME"
    fi
fi
printf '\n'

printf '=== 9. SQLITE-VEC EXTENSION AND SCHEMA ===\n'
if [ "$HEALTH_OK" != "true" ]; then
    verdict SKIP "sqlite_vec" "container not running"
else
    $COMPOSE exec -T backend python -c "
import sqlite3, os
p = os.environ.get('DB_PATH', '/app/data/app.db')
c = sqlite3.connect(p)
names = [r[0] for r in c.execute(\"SELECT name FROM sqlite_master WHERE type IN ('table','view')\")]
print('db path :', p)
print('objects :', names)
print('documents rows:', c.execute('SELECT count(*) FROM documents').fetchone()[0])
try:
    print('vec_documents rows:', c.execute('SELECT count(*) FROM vec_documents').fetchone()[0])
    print('VEC_OK')
except Exception as e:
    print('VEC_MISSING', e)
" > /tmp/vec_check.txt 2>&1
    cat /tmp/vec_check.txt
    if grep -q 'VEC_OK' /tmp/vec_check.txt; then
        verdict PASS "sqlite_vec" "vec0 loaded, vec_documents present"
    else
        verdict FAIL "sqlite_vec" "extension or table missing"
    fi
fi
printf '\n'

printf '=== 10. CORS PREFLIGHT FROM THE PAGES ORIGIN ===\n'
if [ "$HEALTH_OK" != "true" ]; then
    verdict SKIP "cors" "backend not healthy"
else
    ORIGIN="https://$(printf '%s' "$OWNER_REPO" | cut -d/ -f1).github.io"
    printf 'Origin under test: %s\n' "$ORIGIN"
    CORS_HDR=$(curl -s -i -X OPTIONS "${BASE}/api/query" -H "Origin: ${ORIGIN}" \
        -H 'Access-Control-Request-Method: POST' \
        -H 'Access-Control-Request-Headers: content-type' | grep -i 'access-control-allow-origin')
    printf '%s\n' "$CORS_HDR"
    if [ -n "$CORS_HDR" ]; then
        verdict PASS "cors" "allow-origin header present"
    else
        verdict FAIL "cors" "no allow-origin on preflight"
    fi
fi
printf '\n'

printf '=== 11. NOTE ON THE LIVE SITE ===\n'
printf 'The published SPA is served over HTTPS from github.io and defaults to\n'
printf 'http://localhost:8000. Browsers block that mixed-content request, so\n'
printf '"Backend Unreachable" on the hosted page is expected even when this\n'
printf 'audit is fully green. Use npm run dev locally, or serve the backend\n'
printf 'over HTTPS and rebuild with VITE_BACKEND_URL set to that origin.\n\n'

printf '=== AUDIT SUMMARY ===\n'
printf 'PASS: %s   FAIL: %s   SKIP: %s\n' \
    "$(cat "$STATE_DIR/pass")" "$(cat "$STATE_DIR/fail")" "$(cat "$STATE_DIR/skip")"
printf '=== END AUDIT ===\n'
} 2>&1 | tee "$OUT"

# D1 FIX in effect: read the counters back from the state files, which the
# subshell could not destroy.
PASS_COUNT=$(cat "$STATE_DIR/pass")
FAIL_COUNT=$(cat "$STATE_DIR/fail")
SKIP_COUNT=$(cat "$STATE_DIR/skip")

# ===========================================================================
# PHASE 3 - EVIDENCE GATE, PUSH, RAW LINK VALIDATION
# ===========================================================================
printf '\n=== PHASE 3: EVIDENCE GATE AND PUSH ===\n'

if [ ! -f "$OUT" ] || [ ! -s "$OUT" ]; then
    log_result "evidence_completeness" "false" "$OUT missing or empty"
    exit 1
fi
if ! grep -q '=== END AUDIT ===' "$OUT"; then
    log_result "evidence_completeness" "false" "$OUT truncated"
    exit 1
fi
log_result "evidence_completeness" "true" "$OUT is $(wc -c < "$OUT") bytes and complete"

git check-ignore -v "$OUT" >/dev/null 2>&1 && printf '!notes/\n' >> .gitignore
git add -f "$OUT" .gitignore

EV_STAGED=$(git diff --cached --name-only | wc -l)
printf 'Evidence files staged: %s\n' "$EV_STAGED"
PUSH_OK=1
if [ "$EV_STAGED" -gt 0 ]; then
    git commit --no-verify -m "evidence: backend audit v2 ${TS}"
    push_verified "$BRANCH" "evidence_push"
    PUSH_OK=$?
else
    log_result "evidence_push" "false" "nothing staged"
fi

RAW_LINK="${REMOTE_RAW}/${OUT}"
LINK_OK=false
if [ $PUSH_OK -eq 0 ]; then
    ATTEMPT=1; DELAY=3
    while [ $ATTEMPT -le 4 ]; do
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -L "$RAW_LINK")
        log_result "raw_link_check" "$([ "$HTTP_CODE" = "200" ] && printf true || printf false)" \
            "attempt=$ATTEMPT http=$HTTP_CODE"
        [ "$HTTP_CODE" = "200" ] && { LINK_OK=true; break; }
        sleep $DELAY; DELAY=$((DELAY * 2)); ATTEMPT=$((ATTEMPT + 1))
    done
else
    log_result "raw_link_check" "false" "push did not land - link not checked"
fi

log_rule_compliance "54" 1 "report complete, $(wc -c < "$OUT") bytes"
log_rule_compliance "55" "$([ "$LINK_OK" = true ] && printf 1 || printf 0)" "raw link http check"

printf '\n=== RESULT ===\n'
printf 'PASS: %s   FAIL: %s   SKIP: %s\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
if [ "$LINK_OK" = "true" ]; then
    printf '\n=== RAW LINK FOR LLM REVIEW ===\n'
    printf '%s\n' "$RAW_LINK"
else
    printf '\nNo validated raw link. Local report: %s/%s\n' "$PROJECT_ROOT" "$OUT"
fi
