---
name: rpce-release
description: Build or publish RepoPrompt CE release artifacts using the repository release scripts and GitHub workflows.
---

# RepoPrompt CE Release

Use this skill when preparing a RepoPrompt CE release artifact or orienting a
maintainer through a production release.

## Contributor artifact

Run the secret-free lane:

```bash
make dev-release-preflight
make dev-release-artifact
```

Report the files written under `dist/`. Clearly state that the archive is
ad-hoc signed, intended for packaging validation, and not distributable.

## Maintainer publish

Read [`docs/releasing.md`](../../../docs/releasing.md) before publishing.

Use the protected GitHub **Publish Release** workflow for production
draft creation. It requires an existing pushed tag and the `release`
environment secrets documented there. Review and test the resulting immutable
draft assets before promoting the existing draft without rebuilding it. Do not
paste private keys, profiles, certificate exports, or passwords into logs or
chat.

RepoPrompt CE starts its independent release history at `1.0.0 (1)`.
Increment `BUILD_NUMBER` monotonically for every later public update.

For an explicit private-source updater smoke test, use the maintainer-only
`Scripts/publish_public_update_test.sh` helper documented in
[`docs/releasing.md`](../../../docs/releasing.md). It publishes only verified
Developer ID signed, notarized ZIPs to the public artifact-only update
repository.

Before a tag, commit, or push, run the repository-local
`$rpce-contribution-check` skill and follow its approval requirements.
