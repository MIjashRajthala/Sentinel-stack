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
expect_exit "diagnostics reject invalid mode" 2 \
    "$PROJECT_DIR/scripts/diagnose.sh" --mode invalid

if grep -q 'config --no-interpolate' "$PROJECT_DIR/scripts/diagnose.sh"; then
    pass "diagnostics never save interpolated Compose config"
else
    fail "diagnostics never save interpolated Compose config"
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

printf '1..%d\n' "$((PASS + FAIL))"
printf '# passed=%d failed=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
