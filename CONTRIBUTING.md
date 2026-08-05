# Contributing to Verdant

Thanks for your interest! Verdant is an on-device, zero-cloud iOS health-insight app. This guide
gets you building and explains the conventions that keep it maintainable.

## Prerequisites

- macOS 26+ and **Xcode 26** (iOS 26 SDK). Verified on Xcode 26.6 / iOS 26.5.
- Command-line tools: `brew install xcodegen swiftlint swiftformat xcbeautify`

## Setup

The `.xcodeproj` is **generated**, not committed — always regenerate after pulling or editing
`project.yml`:

```bash
xcodegen generate
open Verdant.xcodeproj          # or build from the CLI:
xcodebuild test -project Verdant.xcodeproj -scheme Verdant \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

For real HealthKit data and on-device model inference, run on a physical, Apple-Intelligence-capable
iPhone (see the README's "Run on your iPhone").

## Before you open a PR

- `swiftformat Verdant VerdantTests` — formatting must be clean.
- `swiftlint lint --strict` — zero warnings.
- All tests pass.
- Add tests for new logic, especially in the deterministic engine, the stats provider, and the
  orchestrator loop (use the `SubagentRunning` seam to fake the model).

## Architecture & conventions

Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) first. Key principles:

- **The on-device LLM is an enhancement layer, never the spine.** The deterministic engine is the
  primary insight generator and must remain correct with the model entirely absent.
- **Verification and safety are deterministic** — never trust the model's numbers or phrasing.
- **Layering:** `Domain/` is framework-free; HealthKit/FoundationModels types stay in their layers.
- **Concurrency:** writes go through the single `StoreWriter` actor; `MetricStatsProvider` is the one
  source of numeric truth.

### Adding a tracked metric

Add a case to `MetricKey` (with its `source`, unit, framing) and, if needed, per-metric thresholds
in `MetricCatalog`. The `.anyOf` model vocabulary and the multiple-comparison count update
automatically. Add a `HealthTypeMapping` entry for non-quantity sources.

## Safety note

Verdant is a **wellness/informational** tool, not a medical device. The red-flag thresholds in
`MetricCatalog.swift` are engineering placeholders and **must be reviewed by a qualified clinician**
before any release. Never introduce diagnostic or prescriptive language; the `SafetyGuard` enforces
this on model output.

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).
