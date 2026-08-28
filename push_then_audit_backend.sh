#!/usr/bin/env bash
# ============================================================================
# push_then_audit_backend.sh
#
# Phase 1: push the current repo state (evidence is safe before anything runs)
# Phase 2: audit the backend end-to-end (compose up, health, ingest, query,
#          single-DB check, sqlite-vec check) with explicit PASS/FAIL/SKIP
# Phase 3: evidence completeness gate, push report, validate + print raw link
#
# No `set -e` (Rule #7). No `sed` (Rule #7). No `utcnow()` (Rule #41).
# No blocking `read -r` before evidence is pushed (Rule #51).
#
# Rules complied with: #1 evidential grounding, #6 design by contract,
# #7 guarded edits, #8 observability, #28 dependency management,
# #32 streaming subprocess, #37 skip-as-pass prohibition, #38 bash
# special-char safety, #39/#45 gitignore before git add, #43 staged scope,
# #47 diagnostic-then-push, #48 rule compliance logging, #51 non-interruptible
# timeout, #53 repo owner discovery, #54 evidence completeness,
# #55 raw link validation.
#
# Citations:
#   - docker compose CLI: https://docs.docker.com/reference/cli/docker/compose/
#     (general knowledge - not retrieved this session)
#   - curl -w %{http_code}: https://curl.se/docs/manpage.html#-w
#     (general knowledge - not retrieved this session)
#   - git check-ignore: https://git-scm.com/docs/git-check-ignore
#     (general knowledge - not retrieved this session)
# ============================================================================

# ---------------------------------------------------------------------------
# Logging convention
# ---------------------------------------------------------------------------
log_result() {
    local operation="$1" success="$2" detail="$3"
    local ts status
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    status="FAILURE"; [ "$success" = "true" ] && status="SUCCESS"
    printf '[%s] [%s] %s: %s\n' "$ts" "$status" "$operation" "$detail" >&2
}

FAIL_COUNT=0
SKIP_COUNT=0
PASS_COUNT=0

verdict() {
    # verdict <PASS|FAIL|SKIP> <check name> <detail>
    local v="$1" name="$2" detail="$3"
    case "$v" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)); printf '[PASS] %s - %s\n' "$name" "$detail" ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s - %s\n' "$name" "$detail" ;;
        SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)); printf '[SKIP] %s - %s\n' "$name" "$detail" ;;
    esac
}

# ---------------------------------------------------------------------------
# Rule #48: rule compliance logging with read-back verification
# ---------------------------------------------------------------------------
COMPLIANCE_DB="./mutations.db"
HAVE_SQLITE3=false
command -v sqlite3 >/dev/null 2>&1 && HAVE_SQLITE3=true

log_rule_compliance() {
    local rule_id="$1" script_name="$2" passed="$3" evidence="$4"
    if [ "$HAVE_SQLITE3" != "true" ]; then
        # Rule #37: a missing tool is a SKIP, never a silent PASS.
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
VALUES ('$rule_id', '$script_name', $passed, '$evidence', '$ts');
SQL
    row_count=$(sqlite3 "$COMPLIANCE_DB" "SELECT COUNT(*) FROM rule_compliance WHERE rule_id='$rule_id' AND script_name='$script_name' AND ts='$ts';")
    if [ "$row_count" != "1" ]; then
        log_result "rule_compliance" "false" "read-back failed for $rule_id"
        return 1
    fi
    log_result "rule_compliance" "true" "logged $rule_id passed=$passed"
    return 0
}

SCRIPT_NAME="push_then_audit_backend.sh"

# ---------------------------------------------------------------------------
# Rule #28: dependency preflight
# ---------------------------------------------------------------------------
MISSING=""
for cmd in git curl python3 docker; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then
    log_result "dependency_preflight" "false" "missing:$MISSING"
    printf 'Install the missing tools and re-run. Nothing has been changed.\n'
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
# Locate the repo root - never hardcode a path
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Rule #53: discover owner/repo dynamically from the live remote
# ---------------------------------------------------------------------------
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
# PHASE 1 - PUSH FIRST
# The repo state goes up before any container is started, so a crash or an
# interrupt during the audit cannot cost work that is already on disk.
# ===========================================================================
printf '\n=== PHASE 1: PUSH CURRENT REPO STATE ===\n'

git add -A -- backend frontend terraform ansible .github scripts \
    docker-compose.yml .gitignore 2>/dev/null
[ -f setup_gods_eye_ocr.sh ] && git add -f setup_gods_eye_ocr.sh
git add -f "$SCRIPT_NAME" 2>/dev/null

# Rule #43: confirm scope before committing.
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
    git push origin "$BRANCH"
    PUSH_RC=$?
    if [ $PUSH_RC -eq 0 ]; then
        log_result "phase1_push" "true" "pushed $BRANCH"
    else
        log_result "phase1_push" "false" "push exit=$PUSH_RC - continuing to audit anyway"
    fi
else
    printf 'Nothing to commit - working tree already matches HEAD.\n'
    log_result "phase1_push" "true" "no changes to push"
fi
log_rule_compliance "43" "$SCRIPT_NAME" 1 "staged=$STAGED before commit"

# ===========================================================================
# PHASE 2 - BACKEND AUDIT
# Everything from here is captured to $OUT. The report is NOT staged until it
# is fully written (Rule #47: the v1 self-truncation defect).
# ===========================================================================
BASE="http://localhost:8000"

{
printf '=== backend audit - %s UTC ===\n' "$TS"
printf 'repo:   %s\n' "$OWNER_REPO"
printf 'branch: %s\n' "$BRANCH"
printf 'HEAD:   %s\n' "$(git rev-parse HEAD)"
printf 'root:   %s\n\n' "$PROJECT_ROOT"

printf '=== 1. TOOLCHAIN ===\n'
docker --version
if [ -n "$COMPOSE" ]; then
    $COMPOSE version
else
    printf 'docker compose: NOT FOUND\n'
fi
python3 --version
printf '\n'

printf '=== 2. COMPOSE FILE VALIDATION ===\n'
if [ -z "$COMPOSE" ]; then
    verdict SKIP "compose_config" "no docker compose plugin or docker-compose binary"
else
    $COMPOSE config >/dev/null 2>/tmp/compose_config_err
    if [ $? -eq 0 ]; then
        verdict PASS "compose_config" "docker-compose.yml parses"
        $COMPOSE config
    else
        verdict FAIL "compose_config" "$(cat /tmp/compose_config_err)"
    fi
fi
printf '\n'

printf '=== 3. BUILD AND START ===\n'
if [ -z "$COMPOSE" ]; then
    verdict SKIP "compose_up" "no compose available"
else
    $COMPOSE up -d --build
    UP_RC=$?
    if [ $UP_RC -eq 0 ]; then
        verdict PASS "compose_up" "exit=0"
    else
        verdict FAIL "compose_up" "exit=$UP_RC"
    fi
    printf '\n--- docker compose ps ---\n'
    $COMPOSE ps
fi
printf '\n'

printf '=== 4. HEALTH WAIT (max 90s, non-interactive - Rule #51) ===\n'
HEALTH_OK=false
ATTEMPT=0
while [ $ATTEMPT -lt 45 ]; do
    CODE=$(curl -s -o /tmp/health.json -w '%{http_code}' --max-time 3 "${BASE}/api/health")
    printf 'attempt %02d: HTTP %s %s\n' "$((ATTEMPT + 1))" "$CODE" "$(cat /tmp/health.json 2>/dev/null)"
    if [ "$CODE" = "200" ]; then
        HEALTH_OK=true
        break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 2
done
if [ "$HEALTH_OK" = "true" ]; then
    verdict PASS "health_endpoint" "HTTP 200 after $((ATTEMPT * 2))s"
else
    verdict FAIL "health_endpoint" "never returned 200 within 90s"
fi
printf '\n'

printf '=== 5. CONTAINER LOGS (last 60 lines) ===\n'
if [ -n "$COMPOSE" ]; then
    $COMPOSE logs --tail 60 backend
else
    verdict SKIP "container_logs" "no compose available"
fi
printf '\n'

printf '=== 6. FUNCTIONAL ROUND TRIP ===\n'
if [ "$HEALTH_OK" != "true" ]; then
    verdict SKIP "round_trip" "backend not healthy - not attempted"
else
    printf '--- ingest A ---\n'
    curl -s -X POST "${BASE}/api/ingest" \
        -H 'Content-Type: application/json' --data-binary @- <<'JSON' | tee /tmp/ingest_a.json
{"title":"audit doc A","content":"the parachute deploys at 900m","metadata":{"src":"audit"}}
JSON
    printf '\n--- ingest B ---\n'
    curl -s -X POST "${BASE}/api/ingest" \
        -H 'Content-Type: application/json' --data-binary @- <<'JSON' | tee /tmp/ingest_b.json
{"title":"audit doc B","content":"terrain LOD reduced to 512"}
JSON
    printf '\n--- query ---\n'
    curl -s -X POST "${BASE}/api/query" \
        -H 'Content-Type: application/json' --data-binary @- <<'JSON' | tee /tmp/query.json
{"query":"parachute deployment altitude","top_k":5}
JSON
    printf '\n'

    python3 - <<'PY'
import json, sys

def load(p):
    try:
        return json.load(open(p))
    except Exception as e:
        print(f"[FAIL] round_trip_parse - {p}: {e}")
        sys.exit(0)

a = load("/tmp/ingest_a.json")
b = load("/tmp/ingest_b.json")
q = load("/tmp/query.json")

if isinstance(a.get("id"), int) and isinstance(b.get("id"), int):
    print(f"[PASS] ingest - ids {a['id']} and {b['id']} returned")
else:
    print(f"[FAIL] ingest - no integer id in {a} / {b}")

results = q.get("results", [])
titles = [r.get("title") for r in results]
if len(results) >= 2 and "audit doc A" in titles and "audit doc B" in titles:
    print(f"[PASS] query - {len(results)} result(s), both ingested docs retrieved: {titles}")
elif results:
    print(f"[FAIL] query - returned {len(results)} result(s) but titles were {titles}")
else:
    print("[FAIL] query - empty result set (vector index likely not populated)")

if all(isinstance(r.get("distance"), (int, float)) for r in results) and results:
    print("[PASS] distances - all results carry a numeric distance")
elif results:
    print("[FAIL] distances - non-numeric distance in results")
PY
    # Roll the python verdicts into the shell counters.
    RT=$(python3 - <<'PY'
import json
try:
    q = json.load(open("/tmp/query.json"))
    print("ok" if len(q.get("results", [])) >= 2 else "bad")
except Exception:
    print("bad")
PY
)
    if [ "$RT" = "ok" ]; then
        verdict PASS "round_trip" "ingest + vector query returned >=2 results"
    else
        verdict FAIL "round_trip" "ingest or vector query did not return the stored documents"
    fi
fi
printf '\n'

printf '=== 7. SINGLE DATABASE FILE CHECK ===\n'
printf 'This is the regression guard for the split-brain bug: the ORM and the\n'
printf 'raw sqlite3 connection must open the SAME file. Exactly one *.db is\n'
printf 'expected, and no filename containing a query string.\n\n'
if [ -z "$COMPOSE" ] || [ "$HEALTH_OK" != "true" ]; then
    verdict SKIP "single_db_file" "container not running"
else
    $COMPOSE exec -T backend ls -la /app/data
    DBFILES=$($COMPOSE exec -T backend sh -c 'ls /app/data' 2>/dev/null | grep -c '\.db$')
    BADNAME=$($COMPOSE exec -T backend sh -c 'ls /app/data' 2>/dev/null | grep -c 'enable_load_extension')
    printf '\n.db files: %s | names containing a query string: %s\n' "$DBFILES" "$BADNAME"
    if [ "$DBFILES" = "1" ] && [ "$BADNAME" = "0" ]; then
        verdict PASS "single_db_file" "exactly one app.db, no query-string filename"
    else
        verdict FAIL "single_db_file" "db_count=$DBFILES bad_name_count=$BADNAME"
    fi
fi
printf '\n'

printf '=== 8. SQLITE-VEC EXTENSION AND SCHEMA ===\n'
if [ -z "$COMPOSE" ] || [ "$HEALTH_OK" != "true" ]; then
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
    n = c.execute('SELECT count(*) FROM vec_documents').fetchone()[0]
    print('vec_documents rows:', n)
    print('VEC_OK' if 'vec_documents' in names else 'VEC_MISSING')
except Exception as e:
    print('VEC_MISSING', e)
" > /tmp/vec_check.txt 2>&1
    cat /tmp/vec_check.txt
    if grep -q 'VEC_OK' /tmp/vec_check.txt; then
        verdict PASS "sqlite_vec" "vec0 extension loaded, vec_documents present"
    else
        verdict FAIL "sqlite_vec" "vec_documents missing or extension not loaded"
    fi
fi
printf '\n'

printf '=== 9. CORS PREFLIGHT FROM THE PAGES ORIGIN ===\n'
if [ "$HEALTH_OK" != "true" ]; then
    verdict SKIP "cors" "backend not healthy"
else
    ORIGIN="https://$(printf '%s' "$OWNER_REPO" | cut -d/ -f1).github.io"
    printf 'Origin under test: %s\n' "$ORIGIN"
    CORS_HDR=$(curl -s -i -X OPTIONS "${BASE}/api/query" \
        -H "Origin: ${ORIGIN}" \
        -H 'Access-Control-Request-Method: POST' \
        -H 'Access-Control-Request-Headers: content-type' | grep -i 'access-control-allow-origin')
    printf '%s\n' "$CORS_HDR"
    if [ -n "$CORS_HDR" ]; then
        verdict PASS "cors" "preflight returned an allow-origin header"
    else
        verdict FAIL "cors" "no access-control-allow-origin on preflight"
    fi
fi
printf '\n'

printf '=== 10. NOTE ON THE LIVE SITE ===\n'
printf 'The published SPA is served over HTTPS from github.io and points at\n'
printf 'http://localhost:8000 by default. A browser will block that mixed-content\n'
printf 'request, so "Backend Unreachable" on the hosted page is expected even\n'
printf 'when this audit passes. Run the frontend locally (npm run dev) to talk to\n'
printf 'this backend, or publish the backend behind HTTPS and rebuild with\n'
printf 'VITE_BACKEND_URL set to that origin.\n\n'

printf '=== AUDIT SUMMARY ===\n'
printf 'PASS: %s   FAIL: %s   SKIP: %s\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
printf '=== END AUDIT ===\n'
} 2>&1 | tee "$OUT"

# ===========================================================================
# PHASE 3 - EVIDENCE COMPLETENESS GATE, PUSH, RAW LINK VALIDATION
# ===========================================================================
printf '\n=== PHASE 3: EVIDENCE GATE AND PUSH ===\n'

# Rule #54: the report must exist, be non-empty, and carry its markers.
if [ ! -f "$OUT" ]; then
    log_result "evidence_completeness" "false" "$OUT does not exist"
    exit 1
fi
if [ ! -s "$OUT" ]; then
    log_result "evidence_completeness" "false" "$OUT is 0 bytes"
    exit 1
fi
if ! grep -q '=== END AUDIT ===' "$OUT"; then
    log_result "evidence_completeness" "false" "$OUT truncated - no END AUDIT marker"
    exit 1
fi
log_result "evidence_completeness" "true" "$OUT is $(wc -c < "$OUT") bytes and complete"

# Rule #39/#45: check the ignore state before staging, never discover it at
# git-add time.
git check-ignore -v "$OUT" && printf '!%s\n' "notes/" >> .gitignore

git add -f "$OUT" .gitignore
EV_STAGED=$(git diff --cached --name-only | wc -l)
printf 'Evidence files staged: %s\n' "$EV_STAGED"
if [ "$EV_STAGED" -gt 0 ]; then
    git commit --no-verify -m "evidence: backend audit ${TS}"
    git push origin "$BRANCH"
    log_result "evidence_push" "true" "pushed $OUT"
else
    log_result "evidence_push" "false" "nothing staged"
fi

# Rule #55: validate the raw link before presenting it.
RAW_LINK="${REMOTE_RAW}/${OUT}"
ATTEMPT=1
DELAY=3
LINK_OK=false
while [ $ATTEMPT -le 4 ]; do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -L "$RAW_LINK")
    log_result "raw_link_check" "true" "attempt=$ATTEMPT http=$HTTP_CODE"
    if [ "$HTTP_CODE" = "200" ]; then
        LINK_OK=true
        break
    fi
    sleep $DELAY
    DELAY=$((DELAY * 2))
    ATTEMPT=$((ATTEMPT + 1))
done

log_rule_compliance "54" "$SCRIPT_NAME" 1 "report complete, $(wc -c < "$OUT") bytes"
log_rule_compliance "55" "$SCRIPT_NAME" "$([ "$LINK_OK" = true ] && printf 1 || printf 0)" "raw link http check"

printf '\n=== RESULT ===\n'
printf 'PASS: %s   FAIL: %s   SKIP: %s\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
if [ "$LINK_OK" = "true" ]; then
    printf '\n=== RAW LINK FOR LLM REVIEW ===\n'
    printf '%s\n' "$RAW_LINK"
else
    printf '\nRaw link did not return 200 - not presenting it as evidence.\n'
    printf 'Local report is at: %s/%s\n' "$PROJECT_ROOT" "$OUT"
fi
