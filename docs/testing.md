# SHOG Testing and Failure Reproduction

SHOG has three repeatable test levels. Every run writes a timestamped artifact
directory under `logs/test-runs/`; these directories are intentionally ignored
by Git.

## Quick start

Run fast checks after every script or Compose change:

```bash
./scripts/test-stack.sh --mode lite --level static
./scripts/test-stack.sh --mode full --level static
```

Before a release, run the image and daemon smoke test:

```bash
./scripts/test-stack.sh --mode lite --level smoke
./scripts/test-stack.sh --mode full --level smoke
```

Run a real deployment test on a disposable Ubuntu host:

```bash
./scripts/test-stack.sh --mode lite --level integration
./scripts/test-stack.sh --mode full --level integration
```

Integration tests stop containers when they finish but preserve named volumes.
Use `--keep-running` when you want to inspect the test deployment manually.

## What each level checks

| Level | Checks | Changes the machine? |
|---|---|---|
| `static` | Bash syntax, required files, profile wiring, Compose config when Docker is available | No |
| `smoke` | Static checks, Docker daemon access, Compose plugin, image pulls | Downloads images |
| `integration` | Runs host preflight, generates `.env` if absent, deploys the chosen tier, waits for health, probes DNS and web endpoints, captures resource data | Creates `.env`; starts/stops containers |

## Deployment modes

| Mode | Included services | Starting point |
|---|---|---|
| `lite` | Unbound, Pi-hole, rsyslog, CrowdSec, Portainer, Uptime Kuma | 2 vCPU, 2 GB RAM, 20 GB disk |
| `full` | Lite mode plus Wazuh Indexer, Manager, Dashboard, and Filebeat | 4 vCPU, 8 GB RAM, 50–100 GB disk |

The lite numbers are a testable floor, not a universal guarantee. DNS volume,
log ingestion, retention, and host workload can require more. Record actual
resource use for at least 24 hours before treating a machine as production
ready.

## Test artifacts

Each test directory contains:

- `test.log` — timestamped transcript of the run;
- `commands.log` — exact commands executed, in order;
- `summary.md` — pass/warn/fail counts and the rerun command;
- `docker-compose-ps.txt` and `docker-stats.txt` after integration tests;
- `diagnostics/` when a check fails.

The diagnostic bundle includes system context, Compose state, recent container
logs, a redacted `.env`, classified next steps, and a command that reproduces
the test. It does **not** collect raw environment variables, and Compose config
is captured without interpolation. Applications can still print sensitive data
to their own logs, so review a bundle before sharing it.

Installer runs use the same idea: `logs/install/<run>/command.txt` records the
exact invocation, `install.log` records the transcript, and a failed run adds
`diagnostics/next-steps.md` with the same flags preserved for reproduction.

You can also capture a bundle after a manual failure:

```bash
./scripts/diagnose.sh \
  --mode full \
  --reason "Wazuh Dashboard stayed unhealthy" \
  --command "docker compose --profile siem up -d" \
  --exit-code 1 \
  --reproduce "./scripts/test-stack.sh --mode full --level integration"
```

## Resource-reduction protocol

Do not lower published requirements from a single successful boot. For each
candidate machine or VM:

1. Start from a clean host and record CPU, RAM, disk, kernel, and Docker versions.
2. Run the static, smoke, and integration levels in that order.
3. Leave the stack running for 24 hours and sample:
   `docker stats --no-stream`, `docker system df -v`, and service health.
4. Generate realistic DNS and log traffic; repeat the attack simulations in
   `evaluation-plan.md` only on systems you own or are authorised to test.
5. Reboot the host and verify automatic recovery.
6. Repeat at least three clean installs before changing the documented floor.

For small machines, prefer lite mode instead of shrinking Wazuh/OpenSearch heap
below a stable value. The lite tier removes the SIEM containers entirely, which
creates a real resource reduction rather than hiding memory pressure.

## Release gate

A release candidate should meet all of the following:

- static tests pass for both modes;
- smoke tests pass for both modes;
- three consecutive clean integration installs pass on Ubuntu 22.04 or 24.04;
- a host reboot returns all expected services to healthy state;
- backup and restore complete successfully;
- no secrets appear in committed files or diagnostic artifacts;
- failure artifacts contain enough information for another person to reproduce
  the same result.
