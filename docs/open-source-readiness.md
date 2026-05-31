# Open-Source and Release Readiness Notes

Current as of 2026-05-31. This is a contributor/maintainer inventory for RepoPrompt CE's public-readiness work. It documents the current state and follow-ups; it is not legal advice, a substitute for legal review, or a complete third-party dependency audit.

## Release metadata and signing

Release/debug packaging currently derives app identity from [`version.env`](../version.env):

- `APP_NAME=RepoPrompt`
- `DISPLAY_NAME="RepoPrompt CE"`
- `MARKETING_VERSION=1.0.0`
- `BUILD_NUMBER=1`
- `BUNDLE_ID=com.pvncher.repoprompt.ce`
- `SIGNING_TEAM_ID=648A27MST5`

RepoPrompt CE starts a new public release line at `1.0.0 (1)`. The separate CE
bundle identifier, Sparkle key pair, and appcast intentionally do not inherit
the closed app's version history. Treat these values as maintainer-owned
release metadata. Contributors should not change bundle IDs, signing team IDs,
Sparkle keys, or release channels unless a maintainer has explicitly provided
the replacement values. Forks that need a branded app should override locally
or carry their own release metadata patch.

`./Scripts/package_app.sh release` produces a signed release `.app` bundle. A signed release requires `SIGN_IDENTITY` and a `REPOPROMPT_PROVISIONING_PROFILE` for `648A27MST5.com.pvncher.repoprompt.ce`, renders the CE entitlements template, uses timestamped hardened-runtime signing, verifies the signed bundle identifier/team, uses Keychain-backed secure storage, copies the root `LICENSE` and `THIRD_PARTY_NOTICES.md` files into `Contents/Resources/Legal`, and recursively copies root [`ThirdPartyLicenses/`](../ThirdPartyLicenses/) into `Contents/Resources/Legal/ThirdPartyLicenses/` in the packaged app.

[`Scripts/release.sh`](../Scripts/release.sh) adds a secret-free ad-hoc release-candidate lane plus the maintainer publishing lane: Developer ID signing, notarization, stapling, ZIP and DMG generation, Sparkle EdDSA-signed update archive metadata, checksums, and GitHub Release draft creation. The contributor and maintainer process, protected GitHub workflow, required environment secrets, and public Sparkle follow-ups are documented in [`docs/releasing.md`](releasing.md).

## Sparkle metadata

[`AppBundle/Info.plist.template`](../AppBundle/Info.plist.template) currently contains Sparkle fields:

- `SUFeedURL=https://github.com/repoprompt/repoprompt-ce-updates/releases/latest/download/appcast.xml`
- `SUPublicEDKey=<public EdDSA key committed in the plist>`
- `SUBundleName=RepoPrompt CE.app`

These are documented as maintainer-owned release/update-channel values. Do not replace them with guessed fork values. The inherited Sparkle EdDSA key pair was rotated to a CE-specific pair on 2026-05-31: only the new public key is committed, the private key is stored in the GitHub `release` environment, and the app-side Sparkle integrity checks agree with the plist values.

The stable feed is hosted in the deliberately public, artifact-only
[`repoprompt/repoprompt-ce-updates`](https://github.com/repoprompt/repoprompt-ce-updates)
repository. This keeps the appcast and signed updater ZIP anonymously
downloadable while the source repository remains private during validation.
The organization currently disables GitHub Pages creation, so the feed uses
public GitHub Release assets in that repository rather than Pages.

## Dependency pins

The root [`Package.swift`](../Package.swift) uses exact versions or fixed revisions. The CE fork dependencies previously expressed as branch references are now pinned to the resolved revisions:

| Dependency | Current manifest form | Current `Package.resolved` state | Readiness note |
| --- | --- | --- | --- |
| `https://github.com/provencher/swift-sdk.git` | `revision` | `cb6a62f7c266ed535792b3e9e6e05dc3f0dac8e4` | Pinned. |
| `https://github.com/jamesrochabrun/SwiftAnthropic` | `revision` | `b7d030cd7453f314c780f5492385f73d704cbd5d` | Pinned. |
| `https://github.com/provencher/SwiftOpenAI` | `revision` | `1211782eb337e7968124448a20d9260df1952012` | Pinned. |

Fixed-revision tree-sitter grammar packages are immutable from SwiftPM's perspective, but they still require license attribution like other dependencies. The seven migrated C, Dart, Go, Java, JavaScript, Python, and Rust grammars use source-preserving exact revision pins, and the curated [`ThirdPartyLicenses/tree-sitter/`](../ThirdPartyLicenses/tree-sitter/) bundle maps those pins plus the other directly linked Tree-sitter grammar products, `SwiftTreeSitter`, its embedded runtime, and the runtime's ICU subset notice. `Package.resolved` should stay committed so local and CI resolutions match unless maintainers intentionally update dependency versions.

Clean coordinated SwiftPM root graphs compile the exact-pinned upstream JavaScript and Python parser objects but omit their external-scanner objects. CE therefore carries the narrow internal [`Sources/TreeSitterScannerSupport`](../Sources/TreeSitterScannerSupport/) compatibility target: byte-for-byte exact-snapshot copies of only those two upstream scanner implementations and their required helper headers. The package URLs, revisions, and upstream products remain unchanged. [`ThirdPartyLicenses/tree-sitter/scanner-support.sha256`](../ThirdPartyLicenses/tree-sitter/scanner-support.sha256) records the copied-file checksums. Remove the support target, guardrails, checksums, and documentation exception together only after validated upstream revisions or SwiftPM behavior compile the scanners directly from the dependency products in a clean graph.

The in-repo provider package at [`Packages/RepoPromptAgentProviders`](../Packages/RepoPromptAgentProviders) is intentional: it is a path dependency used by the root app while provider code is staged for a future external package split.

## Third-party license/notice inventory

Contributor-visible license expectations before public distribution:

| Component | Location | Current notice source | Follow-up |
| --- | --- | --- | --- |
| Sparkle | `Vendor/Sparkle/Sparkle.xcframework` | Sparkle 2.9.2 license, release asset provenance, and SHA-256 are copied under `Vendor/Sparkle`; the license is also copied under `ThirdPartyLicenses/sparkle`. | Included in packaged legal files. |
| UniversalCharsetDetection / uchardet | `Vendor/UniversalCharsetDetection` | License and author notices are copied under `ThirdPartyLicenses/universal-charset-detection`. | Included in packaged legal files. |
| PCRE2 | `Sources/CSwiftPCRE2/src` | License header is copied to `ThirdPartyLicenses/pcre2/LICENSE.txt`. | Included in packaged legal files. |
| SLJIT | `Sources/CSwiftPCRE2/deps/sljit` | License is copied to `ThirdPartyLicenses/sljit/LICENSE`. | Included in packaged legal files. |
| wildmatch / OpenBSD-derived fnmatch material | `Sources/RepoPromptC/src/wildmatch/wildmatch.c`, `Sources/RepoPromptC/include/wildmatch.h` | Both checked-in files contain BSD-style notice blocks; `wildmatch.h` includes its existing advertising acknowledgement condition. | Source headers remain preserved. Their full checked-in notice text is reproduced in root `THIRD_PARTY_NOTICES.md` and bundled under `Contents/Resources/Legal` during app packaging. |
| Tree-sitter grammar packages, `SwiftTreeSitter`, embedded runtime, and runtime ICU subset | `Package.swift`, `Package.resolved`, [`ThirdPartyLicenses/tree-sitter/`](../ThirdPartyLicenses/tree-sitter/) | The curated Tree-sitter README maps exact package/runtime pins to full copied license files, including the embedded ICU subset notice. | Included under `Contents/Resources/Legal/ThirdPartyLicenses/tree-sitter/` during app packaging. |
| Other SwiftPM dependencies | `Package.swift`, `Package.resolved` | Upstream packages provide their own license files in their repositories. | Generate or curate a comprehensive third-party notice inventory for remaining release dependencies. |

The root [`LICENSE`](../LICENSE) provides the Apache License, Version 2.0 for original RepoPrompt CE code. The root [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) is intentionally labeled as a partial inventory: it records the directly bundled attribution material and points to copied legal files, while notice curation for other SwiftPM dependencies remains outstanding before a public distribution.

## Remaining public-release blockers

Completed account setup on 2026-05-31:

- Registered the explicit Apple Developer App ID `com.pvncher.repoprompt.ce`.
- Created and validated the `RepoPromptCEDeveloperID` Developer ID provisioning profile for `648A27MST5.com.pvncher.repoprompt.ce`.
- Enabled App Store Connect API access, created a least-privilege `Developer` team key for notarization, and verified its credentials with a read-only `notarytool history` request.
- Created the GitHub `release` environment, stored its Developer ID PKCS#12, export password, ephemeral CI keychain password, CE provisioning profile, CE Sparkle private key, and `NOTARYTOOL_*` secrets, and set the `SIGN_IDENTITY` environment variable.
- Moved the contributor cohort into the `APPROVED_CONTRIBUTORS` repository secret. The future tree no longer tracks the cohort or the private claims-refresh script.

Remaining blockers:

- Enable a GitHub configuration that exposes required-reviewer protection for the `release` environment, or document and enforce an equivalent maintainer approval gate before treating the publishing workflow as protected. The current private-repository settings do not expose a required-reviewer control.
- Scrub the historical contributor cohort from existing git history before the repository is made public.
- Finish the comprehensive notice inventory for SwiftPM dependencies.
- Harden the public Sparkle promotion path before treating automatic updates as production-ready: validate that the CI private key matches the committed public key, publish an existing reviewed draft without rebuilding it, explicitly mark the intended stable tag as GitHub's latest release, and run anonymous post-publish feed, archive-signature, and checksum smoke checks.
- Automate mirroring reviewed release assets into the public `repoprompt-ce-updates` repository. The maintainer-only [`Scripts/publish_public_update_test.sh`](../Scripts/publish_public_update_test.sh) helper provides the explicit private-repository smoke path in the meantime.

## Contributor validation touchpoints

Docs-only or metadata-documentation changes should at minimum run:

```bash
make guardrails
```

When changes touch dependencies or provider-package code, add:

```bash
swift package resolve
cd Packages/RepoPromptAgentProviders && swift test
```

When changes touch packaging, MCP runtime, debug CLI behavior, Agent Mode runtime behavior, or a running-app feature, run the live CE MCP smoke flow documented in the root [`README.md`](../README.md) after the smallest relevant build/test command.
