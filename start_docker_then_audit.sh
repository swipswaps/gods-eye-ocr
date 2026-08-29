#!/usr/bin/env bash
# ============================================================================
# start_docker_then_audit.sh
# Bring the Docker daemon up, confirm THIS user can reach the socket, then
# hand off to push_then_audit_backend_v2.sh.
#
# Two distinct failures are handled separately, because they need different
# fixes and v2 could not tell them apart:
#   (a) daemon not running        -> systemctl enable --now docker
#   (b) daemon running, user denied -> usermod -aG docker, then sg docker
#
# No `set -e` (Rule #7). No `sed` (Rule #7). No `utcnow()` (Rule #41).
# Rules: #1, #6, #8, #28, #37, #38, #51.
# ============================================================================

log_result() {
    local operation="$1" success="$2" detail="$3"
    local ts status
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    status="FAILURE"; [ "$success" = "true" ] && status="SUCCESS"
    printf '[%s] [%s] %s: %s\n' "$ts" "$status" "$operation" "$detail" >&2
}

AUDIT="./push_then_audit_backend_v2.sh"
if [ ! -x "$AUDIT" ]; then
    log_result "audit_present" "false" "$AUDIT not found or not executable"
    exit 1
fi
log_result "audit_present" "true" "$AUDIT"

# ---------------------------------------------------------------------------
# Step 1: is the service running? Ask systemd, don't assume.
# ---------------------------------------------------------------------------
ACTIVE=$(systemctl is-active docker 2>/dev/null)
printf 'systemctl is-active docker: %s\n' "$ACTIVE"
if [ "$ACTIVE" != "active" ]; then
    printf 'Starting the Docker daemon (sudo will prompt)...\n'
    sudo systemctl enable --now docker
    if [ $? -ne 0 ]; then
        log_result "daemon_start" "false" "systemctl enable --now docker failed"
        printf '\nDiagnostics:\n'
        systemctl status docker --no-pager -l | head -30
        journalctl -u docker --no-pager -n 30
        exit 1
    fi
    # Rule #51: bounded wait, never a blocking read.
    WAITED=0
    while [ $WAITED -lt 30 ]; do
        [ "$(systemctl is-active docker 2>/dev/null)" = "active" ] && break
        sleep 1
        WAITED=$((WAITED + 1))
    done
    ACTIVE=$(systemctl is-active docker 2>/dev/null)
fi

if [ "$ACTIVE" != "active" ]; then
    log_result "daemon_start" "false" "docker.service still $ACTIVE after 30s"
    systemctl status docker --no-pager -l | head -30
    exit 1
fi
log_result "daemon_start" "true" "docker.service is active"

# ---------------------------------------------------------------------------
# Step 2: can THIS user reach the socket? Running as root proves nothing
# about the unprivileged account that runs the audit.
# ---------------------------------------------------------------------------
if docker info >/dev/null 2>/tmp/dinfo_err; then
    log_result "socket_access" "true" "$(id -un) can reach the socket directly"
    exec "$AUDIT"
fi

ERR=$(cat /tmp/dinfo_err)
printf '\ndocker info as %s failed:\n%s\n\n' "$(id -un)" "$ERR"

if ! printf '%s' "$ERR" | grep -qi 'permission denied'; then
    log_result "socket_access" "false" "daemon active but unreachable for a reason other than permissions"
    sudo docker info 2>&1 | head -20
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 3: permission denied -> group membership. Add if missing, then re-run
# under `sg docker`, which applies the new group WITHOUT a logout.
# ---------------------------------------------------------------------------
if id -nG "$(id -un)" | tr ' ' '\n' | grep -qx docker; then
    log_result "docker_group" "true" "$(id -un) is already in the docker group (login predates it)"
else
    printf 'Adding %s to the docker group (sudo will prompt)...\n' "$(id -un)"
    sudo usermod -aG docker "$(id -un)"
    if [ $? -ne 0 ]; then
        log_result "docker_group" "false" "usermod failed"
        exit 1
    fi
    log_result "docker_group" "true" "added - takes effect at next login, or via sg now"
fi

# Guard against re-exec recursion if sg still cannot reach the socket.
if [ "$SG_RETRY" = "1" ]; then
    log_result "socket_access" "false" "still denied under sg docker - log out and back in, then re-run $AUDIT"
    exit 1
fi

printf '\nRe-running under the docker group via sg...\n'
SG_RETRY=1 exec sg docker -c "SG_RETRY=1 $AUDIT"
