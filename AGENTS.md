# AGENTS.md — Radroots Apple Kit

These instructions apply to the complete standalone `radrootslabs/apple_kit`
repository. A more specific `AGENTS.md` may refine them for its subtree.

## Repository role and authority

This repository owns the public Swift package that adapts Apple platform
services for Radroots applications. `RadrootsKit` owns the protocol-first and
live Apple adapters; `RadrootsKitTesting` owns reusable public test doubles and
launch configuration. Application presentation and product policy remain in
host apps, while domain, wire, signing, storage-engine, and relay policy remain
with their public producer packages.

`Package.swift`, `Package.resolved`, and
`Sources/RadrootsKit/PrivacyInfo.xcprivacy` are machine-readable package and
privacy authority. Swift source and tests are implementation evidence, and the
root `README` is concise public routing material. Keep the package at its
declared Swift tools version and supported iOS/macOS floors unless an approved
breaking change updates source, tests, public routing material, and consumers
together.

The `swift-secp256k1` dependency must use its canonical public Git source and
one exact immutable revision in both `Package.swift` and `Package.resolved`.
Never replace it with a path dependency, floating branch or tag, private
mirror, implicit sibling checkout, or unrecorded binary artifact.

Human specifications, decisions, runbooks, migration history, qualification
records, and execution evidence are parent-owned and absent from standalone
clones. They are not package, build, test, or release inputs. Physical or
tracked `docs/**`, `.github/**`, and `.act/**` roots are forbidden, including
symlinks. Public commands must remain forge agnostic and independent of an
enclosing monorepo.

## Apple platform and security boundaries

- Keep secret material in the Security/Keychain boundary with explicit access
  policy. Do not downgrade device-local, accessibility, or user-presence
  requirements, or silently migrate secrets into `UserDefaults`, files,
  telemetry, fixtures, or application models.
- Identity metadata storage is metadata-only, namespaced, bounded, and
  synchronized. It must not become private-key custody or canonical domain
  storage.
- Local Authentication prompts require an explicit, human-readable reason.
  Callback bridges must complete exactly once and remain bounded, cancelable,
  race-safe, and correctly classified for user cancellation, permission
  denial, temporary failure, and unavailability.
- Permission, location, media, document, background task, background transfer,
  notification, and external-action adapters must be explicit host requests.
  Do not add hidden polling, unbounded work, ambient authority, or automatic
  external mutation.
- Telemetry must apply the canonical redaction policy before rendering, bound
  identifiers and payload length, and never expose keys, credentials, tokens,
  sensitive locations or media, private event contents, or raw platform error
  internals.
- Keep the privacy manifest synchronized with every required-reason API and
  collected-data behavior. A framework link or new platform API is incomplete
  until privacy impact and tests are reviewed.

## API, concurrency, and testing rules

- Prefer protocol-first interfaces and injected adapters so live platform
  behavior has deterministic test substitutes. `RadrootsKitTesting` must not
  contain production credentials, hidden global state, or behavior that
  weakens production invariants.
- Preserve Swift 6 concurrency correctness. Public values crossing concurrency
  boundaries must be genuinely `Sendable`; every `@unchecked Sendable` use
  requires a narrow, documented synchronization invariant and race-oriented
  tests.
- Keep callbacks single-resolution, release locks before invoking foreign or
  async code, and bound data sizes, timeouts, and resource lifetime. Avoid
  detached tasks and process-global ownership unless a public contract assigns
  them explicitly.
- Public errors must be typed, stable, actionable, and secret-safe. Avoid force
  unwraps, `fatalError`, unchecked casts, and production assertions for
  recoverable input or platform failures.
- A public API or behavior change requires implementation tests and consuming
  host review in the same ordered sequence. Do not add compatibility aliases,
  dual paths, or silent fallbacks for prototype behavior removed by the active
  clean-slate services-hardening refactor.

## Change and verification rules

Inspect status, package manifests and locks, privacy declarations, affected
protocols/adapters, all relevant tests, and public routing text before editing.
Make one coherent, reviewable target-state change at a time and preserve
unrelated work.

The standalone package lanes are `swift build` and `swift test`; run the
smallest relevant test selection while iterating and the complete suite before
a checkpoint. Verify `Package.swift` and `Package.resolved` still select the
same exact dependency revision, inspect privacy-manifest changes, prove no
forbidden root exists, run `git diff --check`, and review final status and diff.

In an extbuild-enabled checkout, run `cargo extbuild doctor` before the first
mutating build, test, dependency, package, install, or generated-artifact
command and route those commands through `cargo extbuild run -- ...`. Any
future Xcode command must pass the explicit extbuild-owned derived-data,
source-package, and package-cache paths required by the active configuration;
extbuild does not rewrite child arguments. An ordinary standalone clone must
not require parent-only tools or configuration.

Never claim a lane passed unless it ran successfully. Report unavailable SDK,
platform, signing, network, or dependency prerequisites exactly; do not treat
parent-only workflow proof as a substitute for standalone package validation.

## Git and external gates

Use focused commits in the established `<scope>: <imperative summary>` style.
Do not reset, discard, rewrite, push, tag, sign, publish, deploy, change package
ownership, change signing identities or entitlements, or rotate credentials
without the corresponding explicit authority.

The change is complete only when it is implemented at the correct Apple or
protocol boundary, relevant standalone validation is green, dependency and
privacy evidence is current, forbidden roots remain absent, and final review
finds no secret exposure, concurrency regression, hidden platform authority,
private dependency, or unreported skipped lane.
