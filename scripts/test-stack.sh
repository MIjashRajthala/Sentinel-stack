#!/usr/bin/env bash
# =============================================================================
# SHOG repeatable test runner
# Produces a transcript, exact command history, summary, and diagnostics.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ORIGINAL_ARGS=("$@")

MODE="full"
LEVEL="static"
KEEP_RUNNING=false
OUTPUT_ROOT="$PROJECT_DIR/logs/test-runs"

usage() {
    cat <<'EOF'
Usage: ./scripts/test-stack.sh [options]

Options:
  --mode <lite|full>                 Services and resource tier (default: full)
  --level <static|smoke|integration> Test depth (default: static)
  --keep-running                     Do not stop services after integration tests
  --output-dir <path>                Parent directory for run artifacts
  --help                             Show this help

Levels:
  static       Bash syntax, required files, mode wiring, Compose config if available
  smoke        Static checks plus Docker readiness and image pulls
  integration  Deploy, wait for health, probe DNS/UIs, and collect runtime evidence
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            [[ $# -ge 2 ]] || { echo "--mode requires lite or full" >&2; exit 2; }
            MODE="$2"; shift 2 ;;
        --level)
            [[ $# -ge 2 ]] || { echo "--level requires static, smoke, or integration" >&2; exit 2; }
            LEVEL="$2"; shift 2 ;;
        --keep-running) KEEP_RUNNING=true; shift ;;
        --output-dir)
            [[ $# -ge 2 ]] || { echo "--output-dir requires a path" >&2; exit 2; }
            OUTPUT_ROOT="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$MODE" != "lite" && "$MODE" != "full" ]]; then
    echo "Invalid mode: $MODE (expected lite or full)" >&2
    exit 2
fi

case "$LEVEL" in
    static|smoke|integration) ;;
    *) echo "Invalid level: $LEVEL (expected static, smoke, or integration)" >&2; exit 2 ;;
esac

TEST_REPRODUCE="./scripts/test-stack.sh"
for arg in "${ORIGINAL_ARGS[@]}"; do
    printf -v quoted_arg '%q' "$arg"
    TEST_REPRODUCE+=" $quoted_arg"
done

RUN_ID="${SHOG_TEST_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${MODE}-${LEVEL}-${BASHPID}}"
RUN_DIR="${SHOG_TEST_RUN_DIR:-$OUTPUT_ROOT/$RUN_ID}"
LOG_FILE="$RUN_DIR/test.log"
COMMAND_LOG="$RUN_DIR/commands.log"
SUMMARY_FILE="$RUN_DIR/summary.md"
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR" 2>/dev/null || true
touch "$LOG_FILE" "$COMMAND_LOG"

# Re-execute once through tee so every command is captured without relying on
# /dev/fd process substitution (unavailable on some hardened systems).
if [[ "${SHOG_TEST_LOG_ACTIVE:-0}" != "1" ]]; then
    set +e
    SHOG_TEST_LOG_ACTIVE=1 \
    SHOG_TEST_RUN_ID="$RUN_ID" \
    SHOG_TEST_RUN_DIR="$RUN_DIR" \
        bash "$SCRIPT_DIR/test-stack.sh" "${ORIGINAL_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
    TEST_STATUS=${PIPESTATUS[0]}
    exit "$TEST_STATUS"
fi

PASS=0
FAIL=0
WARN=0
LAST_FAILED_COMMAND=""

log() { printf '[%s] %s\n' "$(date -Iseconds 2>/dev/null || date)" "$*"; }

record_command() {
    printf '$' >> "$COMMAND_LOG"
    printf ' %q' "$@" >> "$COMMAND_LOG"
    printf '\n' >> "$COMMAND_LOG"
}

pass() { PASS=$((PASS + 1)); log "PASS: $*"; }
warn() { WARN=$((WARN + 1)); log "WARN: $*"; }
fail() {
    FAIL=$((FAIL + 1))
    LAST_FAILED_COMMAND="$2"
    log "FAIL: $1"
}

run_check() {
    local name="$1"
    shift
    local status
    record_command "$@"
    "$@"
    status=$?
    if [[ "$status" -eq 0 ]]; then
        pass "$name"
        return 0
    fi

    fail "$name (exit $status)" "$(printf '%q ' "$@")"
    return 0
}

compose_args=()
if [[ "$MODE" == "full" ]]; then
    compose_args+=(--profile siem)
fi

ENV_FILE="$PROJECT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    ENV_FILE="$PROJECT_DIR/.env.example"
    warn ".env is absent; validation will use .env.example"
fi

compose() {
    docker compose --env-file "$ENV_FILE" "${compose_args[@]}" "$@"
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        fail "Docker is required for the $LEVEL level" "docker info"
        return 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        fail "Docker Compose plugin is unavailable" "docker compose version"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        fail "Docker daemon is unavailable or permission was denied" "docker info"
        return 1
    fi
    return 0
}

static_checks() {
    log "Running static checks for mode=$MODE"

    local required
    for required in install.sh uninstall.sh docker-compose.yml .env.example \
        scripts/preflight-check.sh scripts/health-check.sh scripts/diagnose.sh \
        tests/test-scripts.sh; do
        if [[ -f "$PROJECT_DIR/$required" ]]; then
            pass "Required file exists: $required"
        else
            fail "Missing required file: $required" "test -f $required"
        fi
    done

    while IFS= read -r -d '' script; do
        run_check "Bash syntax: ${script#$PROJECT_DIR/}" bash -n "$script"
    done < <(find "$PROJECT_DIR" -type f -name '*.sh' -not -path '*/.git/*' -print0)

    if grep -q '^SHOG_MODE=' "$PROJECT_DIR/.env.example"; then
        pass ".env.example defines SHOG_MODE"
    else
        fail ".env.example does not define SHOG_MODE" "grep '^SHOG_MODE=' .env.example"
    fi

    local siem_profile_count
    siem_profile_count=$(grep -c '^[[:space:]]*- siem$' "$PROJECT_DIR/docker-compose.yml" 2>/dev/null || true)
    if [[ "$siem_profile_count" -ge 5 ]]; then
        pass "SIEM services are gated by the siem profile"
    else
        fail "Expected at least five services in the siem profile; found $siem_profile_count" "grep -c -- '- siem' docker-compose.yml"
    fi

    local stable_volume_count
    stable_volume_count=$(grep -c '^[[:space:]]*name: shog-' "$PROJECT_DIR/docker-compose.yml" 2>/dev/null || true)
    if [[ "$stable_volume_count" -ge 24 ]]; then
        pass "Persistent volumes have stable backup-compatible names"
    else
        fail "Expected 24 stable volume names; found $stable_volume_count" "grep -c 'name: shog-' docker-compose.yml"
    fi

    run_check "Script regression tests" bash "$PROJECT_DIR/tests/test-scripts.sh"

    if command -v ruby >/dev/null 2>&1; then
        run_check "Compose file is valid YAML" ruby -e \
            'require "yaml"; doc=YAML.load_file(ARGV.fetch(0)); abort "missing services" unless doc["services"].is_a?(Hash); abort "missing volumes" unless doc["volumes"].is_a?(Hash)' \
            "$PROJECT_DIR/docker-compose.yml"
    else
        warn "Ruby unavailable; basic YAML parse skipped"
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        record_command docker compose --env-file "$ENV_FILE" "${compose_args[@]}" config --quiet
        if (cd "$PROJECT_DIR" && compose config --quiet); then
            pass "Docker Compose config validates for $MODE mode"
        else
            fail "Docker Compose config is invalid for $MODE mode" "docker compose config --quiet"
        fi
    else
        warn "Docker Compose unavailable; Compose validation skipped at static level"
    fi
}

smoke_checks() {
    log "Running smoke checks"
    require_docker || return 0

    run_check "Docker reports healthy daemon state" docker info
    record_command docker compose --env-file "$ENV_FILE" "${compose_args[@]}" pull
    if (cd "$PROJECT_DIR" && compose pull); then
        pass "Images pulled for $MODE mode"
    else
        fail "Image pull failed for $MODE mode" "docker compose pull"
    fi
}

wait_for_health() {
    local timeout=240
    [[ "$MODE" == "full" ]] && timeout=480
    local waited=0

    while [[ "$waited" -lt "$timeout" ]]; do
        if (cd "$PROJECT_DIR" && ./scripts/health-check.sh --mode "$MODE" --quiet); then
            pass "All expected services became healthy"
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
    done

    fail "Services did not become healthy within ${timeout}s" "./scripts/health-check.sh --mode $MODE"
    return 0
}

integration_checks() {
    log "Running integration checks"
    require_docker || return 0

    record_command docker compose --env-file "$ENV_FILE" "${compose_args[@]}" up -d --remove-orphans
    if (cd "$PROJECT_DIR" && compose up -d --remove-orphans); then
        pass "Stack started in $MODE mode"
    else
        fail "Stack deployment failed in $MODE mode" "docker compose up -d --remove-orphans"
        return 0
    fi

    wait_for_health

    run_check "Pi-hole answers a DNS query" docker exec shog-pihole dig @127.0.0.1 cloudflare.com +short
    run_check "Unbound answers a recursive DNS query" docker exec shog-unbound dig @127.0.0.1 cloudflare.com +short

    if command -v curl >/dev/null 2>&1; then
        run_check "Portainer API responds" curl -kfsS --max-time 10 https://127.0.0.1:9443/api/status
        run_check "Uptime Kuma responds" curl -fsS --max-time 10 http://127.0.0.1:3001/
        run_check "Pi-hole web responds" curl -fsS --max-time 10 http://127.0.0.1:8080/admin/
        if [[ "$MODE" == "full" ]]; then
            run_check "Wazuh Dashboard responds" curl -kfsS --max-time 15 https://127.0.0.1:5601/
        fi
    else
        warn "curl unavailable; HTTP endpoint probes skipped"
    fi

    record_command docker compose --env-file "$ENV_FILE" "${compose_args[@]}" ps -a
    (cd "$PROJECT_DIR" && compose ps -a) > "$RUN_DIR/docker-compose-ps.txt" 2>&1 || true
    record_command docker stats --no-stream
    docker stats --no-stream > "$RUN_DIR/docker-stats.txt" 2>&1 || true

    if [[ "$KEEP_RUNNING" == false ]]; then
        record_command docker compose --env-file "$ENV_FILE" "${compose_args[@]}" down --remove-orphans
        if (cd "$PROJECT_DIR" && compose down --remove-orphans); then
            pass "Test stack stopped cleanly (volumes preserved)"
        else
            fail "Test stack did not stop cleanly" "docker compose down --remove-orphans"
        fi
    else
        warn "Services left running because --keep-running was specified"
    fi
}

write_summary() {
    local status="PASS"
    [[ "$FAIL" -gt 0 ]] && status="FAIL"
    cat > "$SUMMARY_FILE" <<EOF
# SHOG test run: $status

- Run: \`$RUN_ID\`
- Mode: \`$MODE\`
- Level: \`$LEVEL\`
- Passed: $PASS
- Warnings: $WARN
- Failed: $FAIL
- Transcript: \`test.log\`
- Exact commands: \`commands.log\`

## Reproduce

\`\`\`bash
cd $(printf '%q' "$PROJECT_DIR")
$TEST_REPRODUCE
\`\`\`
EOF
}

cd "$PROJECT_DIR"
log "SHOG test run started: mode=$MODE level=$LEVEL"
static_checks

if [[ "$LEVEL" == "smoke" || "$LEVEL" == "integration" ]]; then
    smoke_checks
fi
if [[ "$LEVEL" == "integration" ]]; then
    integration_checks
fi

write_summary

if [[ "$FAIL" -gt 0 ]]; then
    "$SCRIPT_DIR/diagnose.sh" \
        --reason "SHOG $LEVEL test run failed ($FAIL checks)" \
        --command "${LAST_FAILED_COMMAND:-unknown}" \
        --exit-code 1 \
        --mode "$MODE" \
        --source-log "$LOG_FILE" \
        --output-dir "$RUN_DIR/diagnostics" \
        --reproduce "$TEST_REPRODUCE" || true
    log "Result: FAIL — review $SUMMARY_FILE and $RUN_DIR/diagnostics/next-steps.md"
    exit 1
fi

log "Result: PASS — artifacts saved to $RUN_DIR"
