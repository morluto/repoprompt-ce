# Releasing RepoPrompt CE

RepoPrompt CE has two release lanes:

- Contributors can build an ad-hoc release-candidate archive with no secrets.
- Maintainers can publish a Developer ID signed, notarized, stapled GitHub
  Release with Sparkle EdDSA-signed update archive metadata through the
  protected `release` environment.

RepoPrompt CE starts a new public release line at `1.0.0 (1)`. Its separate
bundle identifier, Sparkle key pair, and appcast intentionally do not inherit
the closed app's version history.

## Release ownership

Ordinary contributors prepare release candidates. They do not need Apple
credentials, the Sparkle private key, or permission to create public tags and
GitHub Releases.

Trusted maintainers own public distribution. A maintainer reviews the release
PR, merges it, creates the immutable release tag, dispatches the protected
workflow, tests the resulting draft assets, and promotes the already-reviewed
draft without rebuilding it.

The intended process is:

1. A contributor opens a release PR that updates `version.env`, release notes,
   and any relevant changelog entry.
2. CI runs ordinary validation plus the secret-free release-candidate lane.
3. Contributors and maintainers test the ad-hoc release-candidate artifact.
4. A maintainer merges the PR and creates a new immutable tag for that exact
   commit.
5. A maintainer dispatches **Publish Release** in draft mode. CI imports the
   protected secrets, signs, notarizes, staples, and uploads the draft assets.
6. Maintainers test the draft ZIP and DMG without rebuilding them.
7. A maintainer promotes the existing draft, explicitly marks that tag as
   GitHub's latest stable release, and runs the anonymous post-publish checks
   below.

The current workflow implements draft creation. A separate protected
promotion workflow that publishes an existing reviewed draft, mirrors its
public update assets, and runs the post-publish checks remains a public-launch
hardening item.

## Contributor release candidate

Run:

```bash
make dev-release-preflight
make dev-release-artifact
```

The artifact is written under `dist/`. It exercises release-mode compilation,
app bundling, legal-file packaging, and archive creation. It is intentionally
ad-hoc signed and is not suitable for distribution.

The direct fallback commands are `make release-preflight` and
`make release-artifact`. The GitHub **Release Candidate** workflow runs the same
path on `main` and on manual dispatch, then uploads the archive as a workflow
artifact.

Contributors should not upload this artifact to GitHub Releases. It is useful
for packaging review and local testing only.

## Maintainer setup

Create a protected GitHub Actions environment named `release`. Require
maintainer approval before jobs can access its secrets. If the repository's
current GitHub plan or visibility does not expose required reviewers for
environments, resolve that limitation or enforce an equivalent maintainer
approval gate before treating the publishing workflow as protected.

Add these environment secrets:

| Secret | Contents |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key exported as PKCS#12. |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used for the PKCS#12 export. |
| `CI_KEYCHAIN_PASSWORD` | Random password for the ephemeral CI keychain. |
| `REPOPROMPT_CE_PROVISIONING_PROFILE_BASE64` | Base64-encoded Developer ID provisioning profile for `com.pvncher.repoprompt.ce`. |
| `NOTARYTOOL_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key accepted by `notarytool`. |
| `NOTARYTOOL_KEY_ID` | App Store Connect API key ID. |
| `NOTARYTOOL_ISSUER_ID` | App Store Connect API issuer ID. |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key for the CE update channel. |

The optional `SIGN_IDENTITY` environment variable defaults to:

```text
Developer ID Application: Eric Provencher (648A27MST5)
```

The provisioning profile must authorize:

```text
648A27MST5.com.pvncher.repoprompt.ce
```

The release script validates that identifier before signing.

App Store Connect organization API access must be enabled before generating the
notarization `.p8` key. If **Users and Access → Integrations → App Store Connect
API** shows **Request Access**, complete that approval step before creating the
three `NOTARYTOOL_*` secrets. A team key with the least-privilege `Developer`
role is sufficient for the documented `notarytool` flow. After storing the
secrets, remove the one-time `.p8` download from the local machine.

## Build a draft release

1. Update `version.env` and commit the release state.
2. Create and push a tag pointing at that commit.
3. Run the **Publish Release** workflow with the existing tag and leave
   `draft` enabled.
4. Review and test the draft GitHub Release assets before promotion.

The workflow imports the Developer ID certificate into an ephemeral keychain,
embeds the CE provisioning profile, signs with hardened runtime entitlements,
notarizes and staples the app and DMG, creates a Sparkle appcast containing an
EdDSA signature for the update ZIP, and uploads ZIP, DMG, appcast, and checksum
assets to GitHub Releases.

The current app enables Sparkle's required update-archive verification through
`SUPublicEDKey`. It does not currently opt into the stronger optional
`SURequireSignedFeed` mode, so do not describe the XML feed itself as
cryptographically required.

## GitHub-hosted Sparkle feed

The appcast URL committed in the app is:

```text
https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml
```

The deliberately public, artifact-only
[`repoprompt/repoprompt-ce-updates`](https://github.com/repoprompt/repoprompt-ce-updates)
repository keeps the Sparkle feed and update ZIP anonymously downloadable while
the source repository remains private during release validation. The
organization currently disables GitHub Pages creation, so the feed uses public
GitHub Release assets rather than Pages. Draft releases stay invisible to
installed clients while maintainers review them.

Each appcast enclosure must use an immutable tag-specific ZIP URL:

```text
https://github.com/repoprompt/repoprompt-ce-updates/releases/download/<tag>/RepoPrompt-<version>-<build>.zip
```

Do not point update archive enclosures at `latest/download`. The moving
`latest/download/appcast.xml` URL is only for locating the current feed.

GitHub Releases in the artifact-only repository are a good initial host while
stable releases are linear and a one-item feed is sufficient. Prefer a
project-controlled static host later if CE needs cumulative feed history,
binary deltas, beta channels, backports, or feed promotion independent of
GitHub's latest-release selection.

## Private-repository updater smoke

After the protected workflow produces a Developer ID signed, notarized draft
ZIP, download that ZIP locally and run:

```bash
CONFIRM_PUBLIC_UPDATE_TEST=1 \
  ./Scripts/publish_public_update_test.sh /path/to/RepoPrompt-<version>-<build>.zip
```

This maintainer-only helper refuses ad-hoc archives. It verifies the Developer
ID signature, expected Apple team, stapled notarization ticket, bundle
identifier, marketing version, and build number before publishing the ZIP,
generated appcast, and checksums as a public updater-smoke release in
`repoprompt-ce-updates`.

The helper reads the CE Sparkle private key from the local Sparkle Keychain
account `repoprompt-ce`. It refuses to overwrite an existing public test tag.

## Promote and verify

Promotion must publish the existing reviewed draft without rebuilding its
artifacts. Explicitly mark the intended stable tag as GitHub's latest release.
Immediately verify anonymously:

```text
https://github.com/repoprompt/repoprompt-ce-updates/releases/latest
https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml
https://github.com/repoprompt/repoprompt-ce-updates/releases/download/<tag>/<zip>
https://github.com/repoprompt/repoprompt-ce/releases/download/<tag>/<dmg>
```

The promotion gate should confirm:

- `/releases/latest` resolves to the intended tag.
- `appcast.xml` returns HTTP `200` after redirects.
- The feed reports the expected marketing version and monotonically increasing
  `CFBundleVersion`.
- The enclosure uses the intended tag-specific ZIP URL.
- The ZIP EdDSA signature verifies against the public key embedded in the
  packaged app.
- ZIP and DMG SHA-256 values match `SHA256SUMS`.

Before public launch, add CI verification that the protected
`SPARKLE_PRIVATE_KEY` matches the committed `SUPublicEDKey`.

## Recovery

Never overwrite assets on a published release, reuse a public tag, or move an
existing release tag.

For an incomplete draft, inspect its assets and either delete the incomplete
draft before rerunning the protected build or resume only after checksum
comparison. For a public regression, withdraw the bad release if policy allows
it and publish a new hotfix tag with a higher `BUILD_NUMBER`; explicitly
promote the hotfix as latest.

## References

- [Sparkle: Publishing an update](https://sparkle-project.org/documentation/publishing/)
- [Sparkle customization keys](https://sparkle-project.org/documentation/customization/)
- [GitHub: Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
- [GitHub REST API: Get the latest release](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)
