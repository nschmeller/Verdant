# Verdant

![Platform](https://img.shields.io/badge/platform-iOS%2026-1FA971)
![Swift](https://img.shields.io/badge/Swift-6-F05138)
![License](https://img.shields.io/badge/license-MIT-1FA971)

An iOS app that uses **Apple's on-device Foundation Models** to reason about your Apple Health
data — autonomously surfacing a few subtle, high-signal findings and answering questions on demand.
**Everything runs on-device. No cloud, no network calls for inference, ever.**

> Informational and wellness only — not medical advice, diagnosis, or treatment.

---

## The core idea: every decision is an agent's, and the numbers are never the model's

Verdant's bar is that **every finding, insight, and string in the app is amazingly useful** — subtle,
non-obvious, and worth a person's attention. Nothing is shown that a glance at the Health app would
already tell you. Two design commitments fall out of that:

1. **No deterministic findings.** Nothing reaches the feed unless on-device intelligence *reasoned*
   about it and produced safety-vetted prose. There is no templated phrasing and no template
   fallback — if the model can't make something of a candidate, that candidate is simply dropped. On
   a device without Apple Intelligence the feed just doesn't grow; it is never padded with filler.

2. **Agents decide; tools compute.** The app is an *agentic workflow that calls logical tools*, not
   a logical workflow that calls agents. Worth, novelty, safety, feed slots, what to investigate
   next — all are agent judgments. The deterministic engines are kept for what they are good at:
   producing numbers. They no longer *drop* anything on the agents' behalf; each candidate carries
   its own evidence (p-values, effect sizes, sample counts, which device recorded it) and an agent
   rules on it.

   The model still never states a figure. It names a metric and a kind through closed, registry-
   resolved vocabularies, and the numbers shown are resolved from source at persist time. That
   *tool surface* is the anti-hallucination boundary — structural, not a re-derivation gate.

## The finding pipeline

```
HealthKit ─ingest─▶ daily rollups ─▶ AnalysisSubstrate (every scan computed once, up front,
                                     in parallel — so tool calls never stall a generation)
                                          │
                                          ▼
              scouts survey the map ──▶ leads ──▶ investigator fleet (one specialist per lens:
              (coverage, strange days,            thematic angles, every metric in rotation, the
               deep time, missed links)           scouts' leads, the director's own angles)
                                          │        each runs twice: explore, then commit
                                          ▼
                              novelty judge (re-tread, or a real update?)
                                          ▼
                              safety panel (perspective-diverse; fails CLOSED)
                                          ▼
                     skeptic panel (fixed challenges + ones written for this claim)
                                          ▼
              replication panel (armed: re-tests the claim against the data, not the prose)
                                          ▼
                         persist (InsightLog / CorrelationLog, SwiftData)
                                          ▼
              curator agent: keeps the few strongest, most distinct findings; retires the rest,
              and names the standouts the feed shows first
```

A correlation is the premium finding — a subtle cross-signal link that survives an activity control,
FDR correction, and both verification panels. Every finding records its own provenance: which lens
proposed it, what each panel tallied, and a panelist's own words.

The single-metric detectors each find something the mean comparisons structurally cannot: a metric
that grew more erratic while its average held (**volatility**), a record stretch (**milestone**), a
step to a new sustained baseline (**regime**), and months that run high or low year after year
(**seasonal** — measured against a per-year trend line, so a steady drift cannot pose as a season).
Each produces NUMBERS; whether any of them is worth telling is the agents' call, never a threshold.

## The agent control loop

```
 collect        →  reason                 →  verify            →  persist + curate  →  direct
(HealthKit         (ephemeral Foundation     (safety, skeptic,    (SwiftData,          (a director
 deltas, run        Models sessions, one      and armed            single writer        agent picks
 UNDER the          per lens, serial at       replication          actor; bounded)      the next
 previous pass)     full power)               panels)                                   pass)
```

The **Orchestrator owns no `LanguageModelSession`** — every session is an ephemeral, single-purpose
leaf created inside a subagent call and immediately discarded. This is how the app respects the tiny
context window: there is no long-lived transcript, only compact `@Generable` structs as handoffs,
and closed `.anyOf` vocabularies so the model can only ever name a metric the registry resolves.

The research program is the app's default state, not a button: it starts itself and reasons for as
long as the app is open. Keeping the Neural Engine working is the point, so the loop is built to
remove idle gaps — scans start before the first generation, and each pass's HealthKit collection
runs underneath the previous pass's reasoning rather than pausing it.

## Project layout

```
Verdant/
├─ App/            App entry, AppModel (composition root), ModelContainer (cloudKitDatabase:.none)
├─ Capability/     LLMCapability (availability gating), TokenBudget (hard structural caps)
├─ Domain/         MetricKey / ComparisonKey / MetricDomain vocabularies, value types (framework-free)
├─ Persistence/    @Model entities (InsightLog, CorrelationLog, …), VersionedSchema, StoreWriter (@ModelActor)
├─ HealthKit/      HealthStore (actor), Ingestor, ObserverManager, MetricStatsProvider (truth source)
├─ Engine/         CorrelationEngine; Volatility/Milestone/RegimeShift/Seasonality/UnusualDays/
│                  Coverage/Provenance scans; AnalysisQueryEngine (agent-defined views); NumericFidelity
├─ Memory/         NLEmbedding store, insight/correlation read/write (novelty, tombstone, search, curation)
├─ Agent/          Orchestrator (+ per-arm extensions), Subagents & Instructions, Tools (local), @Generable handoffs
├─ Background/     BackgroundScheduler (two task classes), RateLimitBackoff
└─ UI/             Feed, finding detail, Chat (Q&A), deep-analysis live feed, Settings, disclaimer
VerdantTests/      Agent governance, panels, persistence, engines & determinism, tools, token harness, zero-cloud
docs/              ARCHITECTURE.md (full verified design), VERIFIED-CLAIMS.md (fact-checked API
│                  claims, incl. open [UNVERIFIED] ones), METRIC-CATALOG.md (historical)
```

## Requirements

- **Xcode 26+** and the **iOS 26 SDK** (this repo is verified on Xcode 26.6 / iOS 26.5).
- Dev tools (the `.xcodeproj` is generated from `project.yml`, not committed): `brew bundle`
  (installs xcodegen, swiftlint, swiftformat, xcbeautify from the `Brewfile`).
- Surfacing findings requires an **Apple-Intelligence-capable device with Apple Intelligence
  enabled**. Without it, ingest and Q&A scaffolding still run, but no findings are produced (the app
  never shows deterministic filler in their place).

## Build, run, test

```bash
xcodegen generate                       # regenerate Verdant.xcodeproj from project.yml

# Build + run tests on a simulator
xcodebuild test -project Verdant.xcodeproj -scheme Verdant \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO

swiftformat Verdant VerdantTests         # format
swiftlint lint                           # lint (clean)
```

## Run on your iPhone

The Simulator has limited Health data and **no Apple Intelligence**, so it can ingest and exercise
the deterministic detectors but won't produce reasoned findings. For real HealthKit data and
on-device model inference, run on a physical iPhone (any Apple-Intelligence-capable device with
Apple Intelligence turned on in Settings → Apple Intelligence & Siri):

1. `xcodegen generate` and open `Verdant.xcodeproj` in Xcode 26.
2. Select the **Verdant** target → **Signing & Capabilities** → check *Automatically manage
   signing* and pick your **Team** (a free personal Apple ID works). Xcode provisions the HealthKit
   + background-delivery entitlements automatically.
3. Plug in your iPhone, trust the computer, and select it as the run destination.
4. Press **Run** (⌘R). First launch on a personal team: open Settings → General → VPN & Device
   Management on the phone and trust your developer certificate, then relaunch.
5. Grant the Health permission sheet. Findings appear after the first foreground catch-up; tap
   **Run a deep analysis** to watch the full agent pipeline live.

Background jobs: the agent-running enhancement job runs **while charging** (it requires external
power) and reschedules itself; everything else is covered by foreground catch-up.

## Using it

- **Insights tab** — the feed of surfaced findings, newest first; pull to refresh. Tap any finding
  to open a detail view explaining what it means and how Verdant found it.
- **Run a deep analysis** — runs the *same* pipeline as the background task in the foreground,
  streaming a live feed of exactly what the agents are doing at each moment (no filler messages).
- **Ask tab** — grounded Q&A over your metrics. Each question runs fresh sessions (measure, then
  answer), with a hard-clamped tail of the conversation replayed — the last two exchanges, 220
  characters a side — so a follow-up like "why?" has something to refer to without the window growing
  as the conversation does.
- **Settings** — privacy posture, the metrics tracked (grouped by body system), last-analyzed
  state, and "delete all insights".

## Tracked metrics & defaults (easily changed)

The closed vocabulary (`Domain/MetricKey.swift`) spans **nine body systems** — activity, heart &
circulation, breathing, body measurements, mobility, hearing, nutrition, sleep, and mindfulness —
across **five comparison lenses** (vs. your recent norm, week-over-week, weekday vs. weekend, vs. a
year ago, and vs. all time). To add a metric, add ONE row to
`MetricRegistry.table` (its key, display name, HealthKit source, unit, aggregation and domain).
`MetricKey` is registry-backed rather than an enum, so ingestion, authorization, the `.anyOf`
vocabularies, Settings, and the redundancy rules all follow from that row automatically — and
`MetricKey.init?(rawValue:)` resolving against the registry IS the anti-hallucination boundary.

Default product decisions (see `docs/ARCHITECTURE.md`):
- **Regulatory posture:** wellness/informational, non-diagnostic. No clinical thresholds or red-flag
  tier — a notably high reading is treated as an ordinary material change for the model to reason
  about, never a diagnosis.
- **At-rest protection:** `FileProtectionType.completeUnlessOpen` (HealthKit's own model).
- **Background jobs:** the agent-running enhancement job runs **only while charging** (external
  power) and, within that window, uses resources liberally — scheduled as often as the OS allows.
  Agents run strictly **one at a time** (`maxConcurrentSubagents = 1`): on-device inference
  serializes on the Neural Engine anyway, and issuing sessions in parallel makes the OS split each
  one's resources and burn the rate limit in bursts. Volume comes from many long passes, not
  concurrency.
- **Ineligible devices:** no findings are produced; the rest of the app still functions.

## Privacy

All analysis is on-device. SwiftData runs local-only (`cloudKitDatabase: .none`); the store is
encrypted at rest (`FileProtectionType.completeUnlessOpen`) and excluded from device backups;
embeddings are treated as PHI and deleted with their insight; health values never enter logs (only
non-PHI diagnostics do). The app stores no secrets, so there is no keychain usage. "Delete all
insights" (Settings) hard-deletes, overriding the append-only audit policy.
