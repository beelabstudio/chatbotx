# Bee Lab Studio fork of ChatbotX

This is `beelabstudio/chatbotx`, a **thin, pinned fork** of [ChatbotXIO/ChatbotX](https://github.com/ChatbotXIO/ChatbotX).
Why it exists: [beecreatorstudio#498](https://github.com/beelabstudio/beecreatorstudio/issues/498) (CTO verdict) — emit an
`AUDIT` line on stdout for every audit `record()`, behind `AUDIT_LOG_STDOUT`, until the same change is accepted upstream.

## Rules (binding, from the CTO verdict)

1. **Pinned, never following `main`.** `bee/main` = upstream tag in `.bee/UPSTREAM_TAG` + a minimal commit series.
   There is no `main` branch here on purpose.
2. **The patch is the upstream PR diff.** Nothing else lands in `packages/` or `apps/`. When upstream merges it, the
   exit is: point the compose back at the upstream image, keep the env var.
3. **Never touch** any `enterprise/` directory, `LICENSE`, or copyright notices.
4. **Rebase is deliberate**, at an upstream release tag (or for a security fix), at most monthly: bump
   `.bee/UPSTREAM_TAG`, rebase the patch, let CI build, then update the digests and ADR-004 in `chatbotx-infra`.
5. **Only builder + worker are built** (the only apps that depend on `@chatbotx.io/business`). realtime, mcp-server and
   javascript-executor stay the upstream images, pinned by digest in `chatbotx-infra`.
6. **Images go to a private GHCR package** (`ghcr.io/beelabstudio/chatbotx-builder`, `…-worker`) because they include the
   commercially licensed `enterprise/` directory. CI fails if a package is anonymously readable. Never make them public.
7. **Upstream workflows are disabled via the Actions API, not edited** (keeps rebases conflict-free). Do not re-enable
   `release.yml`: it publishes public images.

## CI (`.github/workflows/bee-build.yml`)

PR and push to `bee/main`: type-check + unit tests (business, worker) → build both images → smoke against the upstream
compose (`chatbotx-docker-compose@2a947fd`, the one production uses) → on `bee/main` only: push to GHCR, print digests in
the job summary, assert the packages are private. Tag format: `<upstream-tag>-bee.<sha12>`; **consumers pin the digest,
not the tag.**

Once the AUDIT patch is in the source, `.bee/audit-smoke.sh` is mandatory: it must trigger an audited action against
`http://127.0.0.1:3123` and exit non-zero unless an `AUDIT` line is in `$DC logs builder worker` (`$DC` is exported).
