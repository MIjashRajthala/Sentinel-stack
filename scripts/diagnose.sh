#!/usr/bin/env bash
# =============================================================================
# SHOG diagnostic bundle collector
# Captures failure context without copying secrets from .env.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

REASON="Manual diagnostic capture"
FAILED_COMMAND="not provided"
EXIT_CODE="unknown"
MODE="full"
OUTPUT_DIR=""
SOURCE_LOG=""
REPRODUCE_COMMAND=""
ENV_FILE="$PROJECT_DIR/.env"

usage() {
    cat <<'EOF'
Usage: ./scripts/diagnose.sh [options]

Options:
  --reason <text>       Short description of the failure
  --command <text>      Command that failed
  --exit-code <code>    Exit code from the failed command
  --mode <lite|full>    Deployment mode (default: full)
  --output-dir <path>   Directory for the bundle
  --source-log <path>   Existing log to include and analyse
  --reproduce <command> Exact command to rerun
  --env-file <path>     Environment file to redact (default: project .env)
  --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason|--command|--exit-code|--mode|--output-dir|--source-log|--reproduce|--env-file)
            option="$1"
            [[ $# -ge 2 ]] || { echo "$option requires a value" >&2; exit 2; }
            value="$2"
            case "$option" in
                --reason) REASON="$value" ;;
                --command) FAILED_COMMAND="$value" ;;
                --exit-code) EXIT_CODE="$value" ;;
                --mode) MODE="$value" ;;
                --output-dir) OUTPUT_DIR="$value" ;;
                --source-log) SOURCE_LOG="$value" ;;
                --reproduce) REPRODUCE_COMMAND="$value" ;;
                --env-file) ENV_FILE="$value" ;;
            esac
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$MODE" != "lite" && "$MODE" != "full" ]]; then
    echo "Invalid mode: $MODE (expected lite or full)" >&2
    exit 2
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/logs/diagnostics/$RUN_ID}"
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR" 2>/dev/null || true

capture() {
    local filename="$1"
    shift
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n\n'
        "$@"
    } > "$OUTPUT_DIR/$filename" 2>&1 || true
}

write_system_context() {
    {
        echo "captured_at=$(date -Iseconds 2>/dev/null || date)"
        echo "reason=$REASON"
        echo "exit_code=$EXIT_CODE"
        echo "failed_command=$FAILED_COMMAND"
        echo "mode=$MODE"
        echo "project_dir=$PROJECT_DIR"
        echo "hostname=$(hostname 2>/dev/null || echo unknown)"
        echo
        uname -a 2>/dev/null || true
        echo
        [[ -r /etc/os-release ]] && sed -n '1,40p' /etc/os-release
        echo
        command -v nproc >/dev/null 2>&1 && echo "cpus=$(nproc)"
        command -v free >/dev/null 2>&1 && free -h
        df -h "$PROJECT_DIR" 2>/dev/null || true
    } > "$OUTPUT_DIR/system.txt" 2>&1
}

write_redacted_env() {
    local env_file="$ENV_FILE"
    [[ -f "$env_file" ]] || return 0

    awk -F= '
        BEGIN { OFS="=" }
        /^[[:space:]]*#/ || NF < 2 { print; next }
        {
            key=$1
            if (toupper(key) ~ /(PASSWORD|PASS|TOKEN|KEY|SECRET)/) {
                print key, "<redacted>"
            } else {
                print
            }
        }
    ' "$env_file" > "$OUTPUT_DIR/env.redacted"
    chmod 600 "$OUTPUT_DIR/env.redacted" 2>/dev/null || true
}

write_next_steps() {
    local evidence_file="$OUTPUT_DIR/evidence.txt"
    {
        echo "$REASON"
        echo "$FAILED_COMMAND"
        [[ -f "$SOURCE_LOG" ]] && tail -n 500 "$SOURCE_LOG"
        [[ -f "$OUTPUT_DIR/docker-compose-logs.txt" ]] && cat "$OUTPUT_DIR/docker-compose-logs.txt"
    } > "$evidence_file" 2>/dev/null || true

    {
        echo "# SHOG diagnostic next steps"
        echo
        echo "- Captured: $(date -Iseconds 2>/dev/null || date)"
        echo "- Mode: \`$MODE\`"
        echo "- Failure: $REASON"
        echo "- Exit code: \`$EXIT_CODE\`"
        echo "- Failed command: \`$FAILED_COMMAND\`"
        echo
        echo "## Recommended actions"
        echo

        if grep -Eqi 'permission denied.*docker|docker.*permission denied|connect.*docker daemon' "$evidence_file"; then
            echo "1. Confirm Docker is running: \`docker info\`."
            echo "2. On Linux, add your user to the Docker group, sign out and back in: \`sudo usermod -aG docker \$USER\`."
        elif grep -Eqi 'failed to resolve reference|manifest unknown|pull access denied|image.*not found' "$evidence_file"; then
            echo "1. Identify the missing image and tag in \`source.log\`."
            echo "2. Verify the candidate tag: \`docker manifest inspect IMAGE:TAG\`."
            echo "3. Update the pin only after checking the publisher's official release and image pages."
        elif grep -Eqi 'address already in use|port is already allocated|port .*already in use|bind.*failed' "$evidence_file"; then
            echo "1. Find the conflicting listener: \`sudo ss -lntup\`."
            echo "2. Stop the conflicting service or change the corresponding host binding in \`.env\`/Compose."
            echo "3. For Pi-hole port 53, set \`PIHOLE_DNS_BIND_IP\` to a stable LAN address instead of disabling Ubuntu's resolver."
        elif grep -Eqi 'no space left|disk quota|filesystem.*full' "$evidence_file"; then
            echo "1. Inspect storage: \`df -h\` and \`docker system df -v\`."
            echo "2. Remove only confirmed-unused Docker data; do not prune volumes containing SHOG data."
        elif grep -Eqi 'unbound\.conf.*error|could not read config file.*unbound|rsyslogd.*error during parsing|config.*syntax error' "$evidence_file"; then
            echo "1. Locate the first configuration error in \`docker-compose-logs.txt\` or \`source.log\`."
            echo "2. Run \`./scripts/test-stack.sh --mode lite --level smoke\` to validate the config inside its pinned image."
            echo "3. Rerun smoke tests before another deployment attempt."
        elif grep -Eqi 'unhealthy|health check.*fail|starting.*timeout' "$evidence_file"; then
            echo "1. Identify the unhealthy service in \`docker-compose-ps.txt\`."
            echo "2. Inspect its section in \`docker-compose-logs.txt\`."
            echo "3. Rerun \`./scripts/health-check.sh --mode $MODE --diagnose\`."
        elif grep -Eqi 'max_map_count[^[:cntrl:]]*(too low|below|must be|at least|262144)|virtual memory areas.*(too low|increase)' "$evidence_file"; then
            echo "1. Set \`vm.max_map_count=262144\` in \`/etc/sysctl.d/99-shog.conf\`."
            echo "2. Apply it with \`sudo sysctl --system\`, then rerun the failed command."
        elif grep -Eqi 'exit(ed)? .*137|oom|out of memory|killed process' "$evidence_file"; then
            echo "1. Check memory pressure: \`free -h\` and \`docker stats --no-stream\`."
            echo "2. Retry with \`--mode lite\`, or lower \`WAZUH_INDEXER_HEAP\` only after reviewing Wazuh requirements."
        elif grep -Eqi 'network.*overlap|pool overlaps|subnet.*conflict' "$evidence_file"; then
            echo "1. Review existing routes and Docker networks: \`ip route\` and \`docker network ls\`."
            echo "2. Change \`MGMT_SUBNET\`, \`SEC_SUBNET\`, or \`MON_SUBNET\` in \`.env\`."
        else
            echo "1. Start with \`docker-compose-ps.txt\` and \`docker-compose-logs.txt\`."
            echo "2. Compare the failing command with \`commands.log\` or the source log."
            echo "3. Rerun the exact reproduction command below."
        fi

        echo
        echo "## Reproduce"
        echo
        echo '```bash'
        echo "cd $(printf '%q' "$PROJECT_DIR")"
        echo "${REPRODUCE_COMMAND:-./scripts/test-stack.sh --mode $MODE --level static}"
        echo '```'
        echo
        echo "If it fails again, compare the newest bundle under \`logs/diagnostics/\` or \`logs/test-runs/\`."
    } > "$OUTPUT_DIR/next-steps.md"
}

write_system_context
write_redacted_env

if [[ -n "$SOURCE_LOG" && -f "$SOURCE_LOG" ]]; then
    cp "$SOURCE_LOG" "$OUTPUT_DIR/source.log" 2>/dev/null || true
fi

if command -v docker >/dev/null 2>&1; then
    capture docker-version.txt docker version
    capture docker-info.txt docker info
    if docker compose version >/dev/null 2>&1; then
        capture compose-version.txt docker compose version
        # Resolved Compose output can contain passwords and tokens.
        capture docker-compose-config.txt docker compose --profile "*" config --no-interpolate
        capture docker-compose-ps.txt docker compose --profile "*" ps -a
        capture docker-compose-logs.txt docker compose --profile "*" logs --no-color --tail 250
    fi
    capture docker-stats.txt docker stats --no-stream
    capture docker-disk.txt docker system df -v
fi

command -v ss >/dev/null 2>&1 && capture listeners.txt ss -lntup
write_next_steps

cat > "$OUTPUT_DIR/summary.md" <<EOF
# SHOG diagnostic bundle

- Reason: $REASON
- Exit code: \`$EXIT_CODE\`
- Mode: \`$MODE\`
- Failed command: \`$FAILED_COMMAND\`
- Captured at: $(date -Iseconds 2>/dev/null || date)

Review \`next-steps.md\` first. Secrets in \`.env\` were redacted, Compose variables were not interpolated, and raw environment variables were not collected. Review service logs before sharing the bundle because applications can print sensitive data.
EOF

echo "Diagnostic bundle: $OUTPUT_DIR"
