#!/usr/bin/env bash
# Regression tests for CLI validation, diagnostic classification, and redaction.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/shog-script-tests.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1"; }

expect_exit() {
    local name="$1"
    local expected="$2"
    shift 2
    local status

    "$@" > "$TEST_TMP/command.out" 2>&1
    status=$?
    if [[ "$status" -eq "$expected" ]]; then
        pass "$name"
    else
        fail "$name (expected exit $expected, got $status)"
    fi
}

expect_exit "test runner rejects invalid mode" 2 \
    "$PROJECT_DIR/scripts/test-stack.sh" --mode invalid --level static
expect_exit "test runner rejects a missing mode value" 2 \
    "$PROJECT_DIR/scripts/test-stack.sh" --mode
expect_exit "health check rejects invalid mode" 2 \
    "$PROJECT_DIR/scripts/health-check.sh" --mode invalid
expect_exit "preflight rejects invalid mode" 2 \
    "$PROJECT_DIR/scripts/preflight-check.sh" --mode invalid
expect_exit "environment preparation rejects invalid mode" 2 \
    "$PROJECT_DIR/scripts/prepare-environment.sh" --mode invalid
expect_exit "diagnostics reject invalid mode" 2 \
    "$PROJECT_DIR/scripts/diagnose.sh" --mode invalid

if grep -q 'config --no-interpolate' "$PROJECT_DIR/scripts/diagnose.sh"; then
    pass "diagnostics never save interpolated Compose config"
else
    fail "diagnostics never save interpolated Compose config"
fi

integration_teardown_block=$(sed -n '/docker stats --no-stream/,/if \[\[ "$KEEP_RUNNING"/p' \
    "$PROJECT_DIR/scripts/test-stack.sh")
if grep -q 'capture_failure_diagnostics' <<< "$integration_teardown_block"; then
    pass "integration diagnostics are captured before stack teardown"
else
    fail "integration diagnostics are captured before stack teardown"
fi

if grep -q 'image: pihole/pihole:2026.05.0' "$PROJECT_DIR/docker-compose.yml" && \
   grep -q 'FTLCONF_webserver_api_password:' "$PROJECT_DIR/docker-compose.yml" && \
   grep -q 'FTLCONF_dns_upstreams:' "$PROJECT_DIR/docker-compose.yml" && \
   ! grep -q '^[[:space:]]*WEBPASSWORD:' "$PROJECT_DIR/docker-compose.yml"; then
    pass "Pi-hole uses its pinned v6 image and v6 environment variables"
else
    fail "Pi-hole uses its pinned v6 image and v6 environment variables"
fi

if grep -q 'image: crowdsecurity/crowdsec:v1.7.8' "$PROJECT_DIR/docker-compose.yml" && \
   grep -q '^source: file$' "$PROJECT_DIR/configs/crowdsec/acquis.yaml" && \
   ! grep -q '^type: docker$' "$PROJECT_DIR/configs/crowdsec/acquis.yaml" && \
   grep -q 'CrowdSec acquisition validates in its pinned image' \
       "$PROJECT_DIR/scripts/test-stack.sh"; then
    pass "CrowdSec uses a supported release and acquisition schema"
else
    fail "CrowdSec uses a supported release and acquisition schema"
fi

if grep -q 'image: portainer/portainer-ce:2.39.2' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'test: ["CMD", "/portainer", "--version"]' "$PROJECT_DIR/docker-compose.yml"; then
    pass "Portainer health check works without a shell"
else
    fail "Portainer health check works without a shell"
fi

if grep -q "NTPSynchronized)=yes" "$PROJECT_DIR/scripts/preflight-check.sh"; then
    pass "preflight supports modern systemd NTP status"
else
    fail "preflight supports modern systemd NTP status"
fi

mapfile -t volume_names < <(awk '/^[[:space:]]+name: shog-/ {print $2}' "$PROJECT_DIR/docker-compose.yml")
missing_backup=()
missing_uninstall=()
for volume_name in "${volume_names[@]}"; do
    grep -Fq "\"$volume_name:" "$PROJECT_DIR/scripts/backup.sh" || missing_backup+=("$volume_name")
    grep -Fq "\"$volume_name\"" "$PROJECT_DIR/uninstall.sh" || missing_uninstall+=("$volume_name")
done

if [[ "${#volume_names[@]}" -eq 23 && "${#missing_backup[@]}" -eq 0 ]]; then
    pass "backup script covers every persistent volume"
else
    fail "backup script covers every persistent volume (missing: ${missing_backup[*]:-volume count mismatch})"
fi

if [[ "${#volume_names[@]}" -eq 23 && "${#missing_uninstall[@]}" -eq 0 ]]; then
    pass "uninstall script covers every persistent volume"
else
    fail "uninstall script covers every persistent volume (missing: ${missing_uninstall[*]:-volume count mismatch})"
fi

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-4 route get 1.1.1.1" ]]; then
    echo "1.1.1.1 via 192.0.2.1 dev eth0 src 192.0.2.10 uid 1000"
    exit 0
fi
exit 1
EOF
chmod +x "$TEST_TMP/bin/ip"

PREPARED_ENV="$TEST_TMP/prepared.env"
expect_exit "environment preparation detects the primary IPv4 address" 0 \
    env PATH="$TEST_TMP/bin:$PATH" SHOG_ENV_FILE="$PREPARED_ENV" \
    SHOG_ENV_EXAMPLE="$PROJECT_DIR/.env.example" \
    "$PROJECT_DIR/scripts/prepare-environment.sh" --mode lite

if grep -q '^SHOG_MODE=lite$' "$PREPARED_ENV" && \
   grep -q '^PIHOLE_DNS_BIND_IP=192.0.2.10$' "$PREPARED_ENV"; then
    pass "environment preparation records mode and DNS bind address"
else
    fail "environment preparation records mode and DNS bind address"
fi

sed -i.bak 's/^PIHOLE_DNS_BIND_IP=.*/PIHOLE_DNS_BIND_IP=198.51.100.20/' "$PREPARED_ENV"
rm -f "$PREPARED_ENV.bak"
env PATH="$TEST_TMP/bin:$PATH" SHOG_ENV_FILE="$PREPARED_ENV" \
    SHOG_ENV_EXAMPLE="$PROJECT_DIR/.env.example" \
    "$PROJECT_DIR/scripts/prepare-environment.sh" --mode full \
    > "$TEST_TMP/prepare-existing.out" 2>&1
if grep -q '^SHOG_MODE=full$' "$PREPARED_ENV" && \
   grep -q '^PIHOLE_DNS_BIND_IP=198.51.100.20$' "$PREPARED_ENV"; then
    pass "environment preparation preserves an explicit DNS bind address"
else
    fail "environment preparation preserves an explicit DNS bind address"
fi

cat > "$TEST_TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -u

if [[ "${1:-}" != "inspect" ]]; then
    exit 1
fi

container="${!#}"

# Optional containers are absent in this fixture.
case "$container" in
    shog-crowdsec-bouncer|shog-alerting|shog-opencti) exit 1 ;;
esac

if [[ "${MOCK_MISSING_WAZUH:-0}" == "1" && "$container" == shog-wazuh-* ]]; then
    exit 1
fi

case "${2:-}" in
    '--format={{.State.Status}}') echo running ;;
    '--format={{.State.Health.Status}}')
        if [[ "$container" == "${MOCK_STARTING_CONTAINER:-}" ]]; then
            echo starting
        else
            echo healthy
        fi
        ;;
    '--format={{.State.Running}}') echo true ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TEST_TMP/bin/docker"

expect_exit "lite health succeeds without SIEM containers" 0 \
    env PATH="$TEST_TMP/bin:$PATH" MOCK_MISSING_WAZUH=1 \
    "$PROJECT_DIR/scripts/health-check.sh" --mode lite --quiet
expect_exit "full health fails when SIEM containers are absent" 1 \
    env PATH="$TEST_TMP/bin:$PATH" MOCK_MISSING_WAZUH=1 \
    "$PROJECT_DIR/scripts/health-check.sh" --mode full --quiet
expect_exit "starting container does not count as healthy" 1 \
    env PATH="$TEST_TMP/bin:$PATH" MOCK_STARTING_CONTAINER=shog-pihole \
    "$PROJECT_DIR/scripts/health-check.sh" --mode lite --quiet
expect_exit "healthy full fixture succeeds" 0 \
    env PATH="$TEST_TMP/bin:$PATH" \
    "$PROJECT_DIR/scripts/health-check.sh" --mode full --quiet

cat > "$TEST_TMP/sample.env" <<'EOF'
TZ=UTC
PIHOLE_WEBPASSWORD=super-secret-password
API_TOKEN=super-secret-token
PRIVATE_KEY=super-secret-key
NORMAL_SETTING=visible
EOF

"$PROJECT_DIR/scripts/diagnose.sh" \
    --mode lite \
    --reason "port is already allocated" \
    --command "docker compose up -d" \
    --exit-code 1 \
    --output-dir "$TEST_TMP/diagnostics" \
    --env-file "$TEST_TMP/sample.env" \
    --reproduce "./scripts/test-stack.sh --mode lite --level integration" \
    > "$TEST_TMP/diagnose.out" 2>&1
diagnose_status=$?

if [[ "$diagnose_status" -eq 0 ]]; then
    pass "diagnostic collector completes without Docker"
else
    fail "diagnostic collector completes without Docker"
fi

if grep -q '^PIHOLE_WEBPASSWORD=<redacted>$' "$TEST_TMP/diagnostics/env.redacted" && \
   grep -q '^API_TOKEN=<redacted>$' "$TEST_TMP/diagnostics/env.redacted" && \
   grep -q '^PRIVATE_KEY=<redacted>$' "$TEST_TMP/diagnostics/env.redacted" && \
   grep -q '^NORMAL_SETTING=visible$' "$TEST_TMP/diagnostics/env.redacted"; then
    pass "diagnostic environment copy redacts secrets"
else
    fail "diagnostic environment copy redacts secrets"
fi

if grep -R -q 'super-secret' "$TEST_TMP/diagnostics"; then
    fail "diagnostic bundle contains no sample secret values"
else
    pass "diagnostic bundle contains no sample secret values"
fi

if grep -q 'Find the conflicting listener' "$TEST_TMP/diagnostics/next-steps.md"; then
    pass "diagnostic classifier recommends port-conflict steps"
else
    fail "diagnostic classifier recommends port-conflict steps"
fi

if grep -q './scripts/test-stack.sh --mode lite --level integration' "$TEST_TMP/diagnostics/next-steps.md"; then
    pass "diagnostic bundle records the reproduction command"
else
    fail "diagnostic bundle records the reproduction command"
fi

cat > "$TEST_TMP/image-pull.log" <<'EOF'
failed to resolve reference "docker.io/example/service:old": not found
EOF

"$PROJECT_DIR/scripts/diagnose.sh" \
    --mode lite \
    --reason "image pull failed" \
    --command "docker compose pull" \
    --exit-code 1 \
    --output-dir "$TEST_TMP/image-diagnostics" \
    --source-log "$TEST_TMP/image-pull.log" \
    --reproduce "./scripts/test-stack.sh --mode lite --level smoke" \
    > "$TEST_TMP/image-diagnose.out" 2>&1

if grep -q 'docker manifest inspect IMAGE:TAG' "$TEST_TMP/image-diagnostics/next-steps.md"; then
    pass "diagnostic classifier recommends image-tag verification"
else
    fail "diagnostic classifier recommends image-tag verification"
fi

cat > "$TEST_TMP/config-error.log" <<'EOF'
vm.max_map_count is not required in lite mode
/opt/unbound/etc/unbound/unbound.conf:113: error: syntax error
fatal error: Could not read config file: /opt/unbound/etc/unbound/unbound.conf
EOF

"$PROJECT_DIR/scripts/diagnose.sh" \
    --mode lite \
    --reason "container is unhealthy" \
    --command "docker compose up -d" \
    --exit-code 1 \
    --output-dir "$TEST_TMP/config-diagnostics" \
    --source-log "$TEST_TMP/config-error.log" \
    --reproduce "./scripts/test-stack.sh --mode lite --level integration" \
    > "$TEST_TMP/config-diagnose.out" 2>&1

if grep -q './scripts/test-stack.sh --mode lite --level smoke' "$TEST_TMP/config-diagnostics/next-steps.md" && \
   ! grep -q 'Set `vm.max_map_count=262144`' "$TEST_TMP/config-diagnostics/next-steps.md"; then
    pass "diagnostic classifier prioritises configuration syntax errors"
else
    fail "diagnostic classifier prioritises configuration syntax errors"
fi

cat > "$TEST_TMP/crowdsec-error.log" <<'EOF'
crowdsec init: while loading acquisition config: field type not found in type fileacquisition.FileConfiguration
failed to update hub: bad http code 403
EOF

"$PROJECT_DIR/scripts/diagnose.sh" \
    --mode lite \
    --reason "container is unhealthy" \
    --command "./scripts/health-check.sh --mode lite" \
    --exit-code 1 \
    --output-dir "$TEST_TMP/crowdsec-diagnostics" \
    --source-log "$TEST_TMP/crowdsec-error.log" \
    --reproduce "./scripts/test-stack.sh --mode lite --level integration" \
    > "$TEST_TMP/crowdsec-diagnose.out" 2>&1

if grep -q 'Inspect CrowdSec acquisition and hub errors' \
    "$TEST_TMP/crowdsec-diagnostics/next-steps.md"; then
    pass "diagnostic classifier recommends CrowdSec acquisition checks"
else
    fail "diagnostic classifier recommends CrowdSec acquisition checks"
fi

cat > "$TEST_TMP/crowdsec-watcher-error.log" <<'EOF'
failed to update hub: bad http code 403
api server init: unable to run local API: authenticate watcher (shog): API error: Forbidden
EOF

"$PROJECT_DIR/scripts/diagnose.sh" \
    --mode lite \
    --reason "container is unhealthy" \
    --command "./scripts/health-check.sh --mode lite" \
    --exit-code 1 \
    --output-dir "$TEST_TMP/crowdsec-watcher-diagnostics" \
    --source-log "$TEST_TMP/crowdsec-watcher-error.log" \
    --reproduce "./scripts/test-stack.sh --mode lite --level integration" \
    > "$TEST_TMP/crowdsec-watcher-diagnose.out" 2>&1

if grep -q 'local detection database and agent registration do not need to be deleted' \
    "$TEST_TMP/crowdsec-watcher-diagnostics/next-steps.md"; then
    pass "diagnostic classifier preserves CrowdSec state on central watcher mismatch"
else
    fail "diagnostic classifier preserves CrowdSec state on central watcher mismatch"
fi

printf '1..%d\n' "$((PASS + FAIL))"
printf '# passed=%d failed=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
