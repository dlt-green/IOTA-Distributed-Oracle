# v2.0.14 — Build infrastructure security maintenance

## Scope

This is an operational documentation release. It records the BuildKit remediation on our VPS and provides an upgrade procedure for node managers. It includes the application dependency fixes from v2.0.13, but introduces no additional application code, API, Move, signing or environment-variable changes.

Updating this Git tag does not update a host's Docker Engine. Operators must update their own build infrastructure separately. Our running application images were not redeployed as part of this host maintenance.

## VPS remediation, 21 November 2026

| Component | Before | After |
| --- | --- | --- |
| Docker Engine and CLI | 29.5.0 | 29.10.0 |
| Embedded BuildKit, default docker driver | 0.30.0 | 0.35.0 |

BuildKit 0.35.0 exceeds the partner's requested minimum of 0.31.1. The daemon package, CLI and matching rootless extras were upgraded using Docker's official Ubuntu repository. Containerd was not upgraded. Docker live restore was enabled before the daemon upgrade; previous package files were retained for rollback.

## Verification

- The active default builder reports BuildKit v0.35.0 through `docker buildx inspect`.
- An actual build using `FROM scratch` and `COPY` succeeded with `--network=none`.
- All 56 previously running containers retained their process IDs, start timestamps and restart counters. Their final health states match the baseline.
- All 32 public hostname checks returned the same HTTP status as before maintenance. This includes expected authentication responses and application-root 400/404 responses; these checks do not exercise every business workflow.
- Six containers were initially stopped. The daemon temporarily started the previously stopped Unicore MongoDB container; it was explicitly stopped again to restore the original service state. Its historical start/restart metadata therefore changed. Its pre-existing stopped/unhealthy state is not a new service failure.
- No application source changed, so application regression suites were not rerun for this documentation-only release. The 111-test application validation belongs to v2.0.13, not to a new test run here.

## Operator upgrade guide

1. Inventory all containers, health states, restart policies and public service responses. Save daemon configuration and previous package versions securely. Include stopped containers in the inventory.
2. Identify the actual builder with `docker buildx ls` and `docker buildx inspect`. Buildx is a client plugin; its version is not the BuildKit backend version.
3. For the `docker` driver, update Docker Engine to a supported release embedding BuildKit 0.31.1 or later. Our Ubuntu 24.04 amd64 VPS used Docker Engine 29.10.0 from the official stable repository. Review the release notes and simulate the package upgrade first. Other distributions or repository configurations may require a different command.
4. If using live restore, merge `"live-restore": true` into the existing daemon JSON; do not overwrite other settings. Validate with `dockerd --validate --config-file=/etc/docker/daemon.json`, reload Docker and verify `docker info`. Live restore is not a universal guarantee of uninterrupted service; prepare a maintenance window and rollback.
5. On our host, the package upgrade was `apt-get install --only-upgrade docker-ce docker-ce-cli`; the matching rootless extras were selected automatically. Do not run broad package or container cleanup as part of this change.
6. Check the backend version again, perform a real build, compare every container against the baseline, wait for health checks to settle, and repeat public endpoint probes. Check that stopped containers stayed stopped.
7. A `docker-container`, remote or Kubernetes builder requires upgrading its own backend separately; updating the host Engine alone may not fix it.

No `.env` migration is required for this release.

## Remaining third-party reports

The requested Python, .NET and Go package upgrades must be attributed to an exact installed package, vendored file or container image before remediation can be confirmed. Request the advisory ID, detected version, full package/file path, and affected image name and immutable digest. This release does not claim those separate findings have all been resolved.

References: [Docker Engine 29 release notes](https://docs.docker.com/engine/release-notes/29/), [Docker live restore](https://docs.docker.com/engine/daemon/live-restore/), [BuildKit 0.31.1](https://github.com/moby/buildkit/releases/tag/v0.31.1).
