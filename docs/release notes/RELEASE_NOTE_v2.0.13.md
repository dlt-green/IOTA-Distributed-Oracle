# v2.0.13 — Transitive dependency security update

## Security corrections

This release updates the dependency graph in response to the reported proxy-addr, body-parser, form-data, Valibot, qs and Zod advisories. Package presence in an SBOM does not itself prove exploitation; these changes remove the affected versions regardless of whether their vulnerable functions were reachable in a particular deployment.

| Component | Previous locked version | Release version / action |
| --- | --- | --- |
| Express | 4.22.2 | 4.22.3; remains on major 4 |
| body-parser | 1.20.5 | 1.20.9 |
| proxy-addr | 2.0.7 | 2.0.8 |
| qs | 6.15.2 | 6.17.1 |
| form-data (daemon) | 4.0.5 | 4.0.6 |
| Valibot | client 1.2.0; other packages 1.5.0 | 1.5.0 across all three packages |
| Zod (daemon) | 3.25.76 | Removed: no application usage found |

The manifests include explicit transitive overrides and regenerated lockfiles. Express is kept on major 4; no forced migration to Express 5 or Zod 4 is included.

- body-parser fixes the compressed-body trailing-bytes denial of service and the invalid-size-limit issue.
- proxy-addr fixes unsafe IPv4-mapped IPv6 trust-subnet matching. Operators should still use correctly scoped trusted proxy addresses/CIDRs; an upgrade does not justify trusting arbitrary forwarding headers.
- form-data escapes multipart field names and filenames to prevent CRLF/header injection.
- Valibot safely flattens record validation errors containing inherited Object property names.
- qs updates cover the reported bracket/comma array parsing and hostile-object serialization advisories.

## Dependency upgrade carried forward from merged PR #8

This release also includes the previously merged IOTA SDK 1.17.0, Identity WASM 1.9.7-beta.1, dapp-kit 0.11.1 and undici 6.29.1 upgrade, along with its compatibility corrections:

- The Webview uses Node 24 and reproducible npm ci installs for both Webview and standalone client.
- Unsigned wallet transactions use Transaction.toJSON() instead of the removed serialize() API.
- Node management uses the current toBase64 utility.
- Recent-event queries explicitly retain descending order; chronological historical scans retain ascending order.
- The Traefik Compose image is pinned to 3.7.19. Treat upgrading a shared reverse proxy as a separate operational rollout.

## Upgrade guide

Rebuild and recreate the affected Webview and daemon containers from this release, preserving their .env files, wallet keys and persistent audit/state volumes. Updating source files without rebuilding an image does not update the installed dependency graph. Standalone client and development environments now require Node.js 24 or newer; run npm ci in each package directory.

No new environment variables, private keys, wallet authentication restrictions or Move contract deployment are required. Existing .env values can be retained. Review WEBVIEW_TRUSTED_PROXIES and prefer canonical IPv4 CIDRs over malformed IPv4-mapped IPv6 expressions. Preserve the configured audit volume and STORAGE_DIR.

For deployments with custom manifests or Dockerfiles, retain the security overrides and lockfiles; do not copy only package.json. After rebuilding, generate a fresh SBOM from the actual deployed images and compare package versions. The release does not automatically update partner nodes or the production VPS.

## Validation

- 111 automated tests passed: 37 daemon, 16 client and 58 Webview.
- New regressions cover multipart field/filename injection, unsafe proxy subnet matching, hostile qs serialization, invalid parser limits, valid gzip requests, malformed gzip handling and Valibot error flattening.
- TypeScript checks for all packages and the production Webview build passed.
- npm audit --omit=dev reported zero known production dependency vulnerabilities for all three lockfiles on 20 November 2026. This is a point-in-time registry result, not a guarantee against undisclosed or application-level defects.
- Production Dockerfiles and regression suites were verified in isolated Linux containers without replacing deployed services.

Existing SSRF destination validation, wallet authentication, preparation concurrency controls and persistent audit behavior remain covered by their regression suites.
