# Verdant — Architecture

Verdant is an iOS 26 app that reasons over your Apple Health data **entirely on-device** (Apple
Foundation Models + HealthKit, zero cloud) to surface a small set of subtle, high-signal findings,
and lets you ask questions about your own data.

> **Design note (2026-06-25).** This document describes the *current* design. An earlier iteration
> made a deterministic "materiality engine" the primary insight generator with templated phrasing
> and a clinical red-flag tier. That has been **removed**. Per the product owner's direction, the
> guiding principle is now: *every surfaced finding is the product of on-device reasoning, and every
> finding/insight/string must be amazingly useful — no deterministic findings, no filler, nothing
> obvious or predictable.*

> **Design update (2026-07-17) — the architecture is now agent-driven.** Per the product owner's
> direction, the app is an **agentic workflow that calls out to logical tools**, not a logical workflow
> that calls out to agents, and **all decision-making is made by agents**. Concretely:
> - **Stats are tools, not a pipeline.** `MetricStatsProvider`, the `CorrelationEngine`, and the
>   Volatility/Milestone/RegimeShift scans are exposed as agent-callable tools (`metricStats`,
>   `correlationScan`, `patternScan`, `metricsOverview`). An **investigator agent** drives them itself —
>   reading the overview, following leads, pulling real numbers — and proposes the findings it judges
>   worth telling. This replaces the old Discovery → Analyst → Verifier → Phraser chain, which has been
>   removed along with the `Verifier` (the agent never states a number, so the shown figures are resolved
>   from source at persist time — anti-hallucination is now *structural*, at the closed-vocabulary tool
>   surface, not a re-derivation gate).
>   **Correction (2026-08-02):** "structural" was overstated, and this is the app's most important
>   property, so it is amended in place rather than left to a later entry. It holds for the metric,
>   the kind, and every figure the CARD renders — those are registry-resolved and re-read from
>   source. It never held for the summary PROSE, which is free text the model writes and the app
>   displays verbatim; the schema only *instructs* it to use tool numbers. That gap is now covered by
>   a numeric-fidelity skeptic lens (see the 2026-08-02 entry), which is an agent check, not a
>   structural guarantee.
> - **No logical decision-guards.** The deterministic worth/quality gates are gone: the materiality
>   threshold, the ordinary-insight salience floor, and the pattern-finding quality floor. The model
>   decides what is worth surfacing; the numbers/stats it reasons over are still produced deterministically.
> - **Safety is an agent panel.** The `SafetyGuard` substring blocklist is replaced by a fan-out of
>   perspective-diverse safety-reviewer agents (`reviewSafety`), which **fails closed** (a finding is shown
>   only if the panel actively confirms it is safe). *(For a wellness app, a deterministic safety backstop
>   is a reasonable defense-in-depth option to re-add; the current design is agent-primary per direction.)*
> - **Compute runs at max saturation.** Agents run **serially** (`maxConcurrentSubagents = 1`) so each gets
>   full Neural-Engine resources rather than the OS splitting them across parallel sessions; Deep Analysis
>   runs deep and long (raised pass/duration caps, `.userInitiated` priority). Volume comes from many long
>   passes, not concurrency.
>
> The deterministic *statistics* (partial-r, BH-FDR, nEff, CV ratios, Cohen's-d steps) and the *plumbing*
> (single-writer `@ModelActor`, `RunGate`, ingest idempotency) are unchanged — those produce numbers and
> serialize writes; they are not decision-guards. Sections below still describe the pre-inversion pipeline
> in places and are being updated.
>
> **Further updates (2026-07-17, later):**
> - **Data-driven `MetricRegistry`** — `MetricKey` is now a registry-backed struct, not an enum. One table
>   row per data source (`Domain/MetricRegistry.swift`, ~72 rows spanning every major HealthKit daily
>   type: sport distances, running/cycling dynamics, blood pressure, glucose, temperatures, HR recovery,
>   gait quality, daylight, alcohol, full nutrition macros). Ingestion, authorization, the `.anyOf`
>   vocabularies, Settings, and rule-based redundancy (exertion tautologies, body-composition clique,
>   HR-vs-activity) all derive from the table; `MetricKey.init?(rawValue:)` resolving against the registry
>   IS the anti-hallucination boundary. Registry integrity (identifiers + unit compatibility) is validated
>   against the real SDK in CI.
> - **Fleet fan-out** — every pass fans out 11 lens-specialist investigators; findings face a 5-reviewer
>   safety panel and a 6-skeptic panel. Serial execution keeps each agent at full ANE power; a per-run
>   `AnalysisSubstrate` memoizes every scan so tools return instantly.
> - **Agent-defined views** — the `analyze` tool lets agents run custom queries (any window, day-filter,
>   statistic, custom-window/lagged correlations) instead of a fixed comparison menu.
> - **Agentic Ask** — the Q&A router is gone; each question is one agentic session over the full tool
>   surface (relational questions included), safety-panelled before display.
> - **Observability** — live feed narrates investigators/panels/drop-reasons per event; Settings shows a
>   device-compute meter (per-core CPU, app CPU, memory, thermal, inference activity — no public ANE API
>   exists, stated honestly) and last-background-run breadcrumbs.
>
> **Further updates (2026-07-17, evening — field fixes + drill-down):**
> - **Context-window discipline** — on-device runs overflowed the 4,096-token window mid-exploration
>   (`singleExtend` errors). Fixes: tool output ceilings cut (`correlationScan` ≤ 6 rows, `patternScan`
>   ≤ 3/kind), floats rounded to 4 significant digits at the tool boundary (`toolRounded`), the
>   72-key `.anyOf` dropped from `ProposedFinding.metric` (registry resolve at persist is the boundary),
>   a terse per-pass prompt with an explicit ≤4-tool-call budget, and ONE fresh-session retry (2-call
>   budget) on `exceededContextWindowSize`/`decodingFailure` before a pass is skipped.
> - **Authorization re-arming** — `try?`-and-forget authorization stranded types as "not determined"
>   (every query throws). Now `getRequestStatusForAuthorization` is checked at bootstrap AND every
>   foregrounding; the sheet re-requests until satisfied; Settings surfaces the pending state; ingest
>   failures log their reason and the feed aggregates unreadable sources into one honest line.
> - **Progress for everything** — `AppModel.activeProgress` is the one switch for "what's narrating":
>   the catch-up gets the same live feed as a deep run, on the Insights tab (even with findings
>   present), in the Deep Analysis screen (which now also narrates catch-ups instead of a dead
>   "Catching up first…" button), and the feed persists after a run finishes. Ingest narrates
>   per-source new-reading counts.
> - **Measured Neural Engine duty cycle** — `InferenceActivity` accumulates monotonic busy-time at the
>   model-call choke point; the meter shows the share of the last minute spent generating as a
>   "Neural Engine" bar (per-generation ANE% has no public API; when and how continuously it runs is
>   measured exactly).
> - **Finding drill-down** — tapping a finding offers "Investigate this further" (`runFocusedDiscovery`:
>   the same fleet/panels but 5 lenses anchored on that finding's metric(s), including one lens tasked
>   with knocking it down) and "Ask about this" (stages a question and jumps to the Ask tab).
> - **BGTask expiration crash fixed** — expiration handlers fire on a background queue;
>   `MainActor.assumeIsolated` there trapped in the field. `CompletionGuard` is now a `Mutex`-latched
>   `Sendable`; the handler calls only thread-safe operations.
> - **HealthKit field fixes** — `HKStatisticsQuery` reports an empty day as `.errorNoData`; treating
>   it as a failure aborted the metric's ingest AND left the anchor unadvanced, so deletion-triggered
>   recomputes re-failed forever (hit all high-churn Watch metrics). Empty days now resume `nil`.
>   The prewarm session is retained (deallocation cancels the warm-up — "PrewarmSession … Canceled"
>   in the field meant every run started cold).
>
> **Further updates (2026-07-17, night — hypothesis-driven depth):**
> - **Every-data-point sweep** — `UnusualDaysScan` tests EVERY day of EVERY metric against its own
>   robust baseline (median/MAD; std fallback for mostly-constant series); the strangest days surface
>   through the new `unusualDays` tool as hypothesis seeds, each carrying a `daysAgo` that plugs
>   straight into `analyze` windows ("what else moved around that day?"). Memoized per run.
> - **Per-metric hypothesis fleet** — deep-run passes now use `Instructions.deepLenses(pass:metrics:)`:
>   the 11 thematic angles PLUS a rotating 12-metric slice of dedicated per-metric investigators
>   ("form and TEST hypotheses about X specifically"), so across passes every metric with ≥30 days of
>   data gets an investigator of its own. Bounded (catch-up/background) passes stay at 11.
> - **Rejected-hypothesis ledger** — every panel-rejected proposal is recorded in a per-run `RunLedger`
>   and injected into subsequent investigator prompts ("Rejected this run — do NOT re-propose"), so a
>   run iterates instead of re-litigating dead ends (each avoided re-panel saves ~11 model calls).
> - **Scientist framing** — investigator instructions now direct explicit hypothesize-then-test method;
>   the token harness re-verified the 6-tool prefix under the half-window budget with the real
>   tokenizer (it caught a 1-token overflow, fixed by trimming tool prose).
>
> **Further updates (2026-07-17, late — the indefinite research program):**
> - **Deep runs are INDEFINITE** — a foreground deep analysis now runs for as long as the app stays
>   open, ending only by cancellation (Stop button, or the app leaving the foreground). Dryness is a
>   STRATEGY SWITCH, not a stop: after `dryStreakToStop` dry breadth passes the run drills into its
>   own strongest findings (`activeInvestigationFoci` → focused lens fleet), then returns to breadth.
>   The substrate rebuilds every `substrateRefreshPasses` (12) passes so hours-long runs fold in
>   newly-arrived Health data and cross day boundaries. `maxPasses` (1000) is a runaway backstop only.
>   Background tasks are UNCHANGED (deadline-bounded, power-gated).
> - **Lifecycle** — `startDeepAnalysis`/`stopDeepAnalysis` on AppModel; backgrounding cancels cleanly
>   and arms an auto-resume on return to foreground; the screen stays awake during a run
>   (`isIdleTimerDisabled`, defer-restored) since auto-lock would silently end it. The Start button
>   becomes a live Stop while running.
> - **Structured cancellation** — the `discoveryStream` (detached work task + AsyncStream teardown)
>   is replaced by `AppModel.narrate(into:job:)`: the job runs in the caller's task, cancellation
>   reaches it directly, and the run gate is released only after the work has genuinely stopped —
>   fixing a latent race where the gate freed while a detached run was still winding down. Ordered
>   progress delivery is preserved via a single serial stream to a main-actor consumer.

---

## 0. Where things stand

This document is chronological below: numbered sections describe the design, and dated "Further
updates" record how it changed. Several numbered sections still describe the PRE-INVERSION pipeline
(deterministic detectors proposing, a `Verifier` re-deriving, a `SafetyGuard` vetting) — that design
is gone. Read this section for what is true now; read the dated entries for how it got there.

**What moves this system and what does not — measured 2026-08-03, and the most useful thing on this
page.** Nine attempts across the codebase have now tried to change agent behaviour by changing TEXT:
four safety-panel instruction rewrites, a symmetric rule for the replication analysts, a rephraser
prompt, a re-reader role, and stating the engine's own detected regimes in Ask's prompt. Every one
improved legibility and none changed behaviour. In the last of them the agent was handed
"Resting heart rate stepped from 63 bpm to 56 bpm about 69 days ago" and still answered "your resting
heart rate has not changed recently".

**The sharpest version of this, measured last.** `MetricStatDigest` was given a `sustainedStep`
field, so the fact arrived inside the TOOL RESULT rather than the prompt — the reasoning being that
agents demonstrably quote `pctChange` and `z` back verbatim, so they clearly read tool output. The
field was verified populated by calling the tool directly: `pctChange=0.0`,
`sustainedStep="stepped from 63 bpm to 56 bpm about 69 days ago"`, in one result. Over eight
questions the answerer mentioned the step **zero times**, quoted the 0% and told the user nothing had
changed. It reads one field of a result and ignores another field of the same result. Reverted.

So the distinction is not prompt-versus-tool-output. Information the agent is not being ASKED ABOUT
is not used, wherever it sits.

What HAS worked, every time, is structural:

    lever                                            measured effect
    change what a lens ASKS (not how it is phrased)  safety lens 1 false-flags 35% -> 5%
    change a TOOL surface                            replicator re-tests 0/5 -> 5/5
    change a SCHEMA (.anyOf, a new field)            unforgeable metric keys; z reaches the agent
    change the AGGREGATION                           the open `panelHolds` decision: 4.5% -> 38%
    change what is TRUNCATED                         the replicator saw 229 of a 763-char basis

The rule that falls out: **an agent's judgement is worth trusting; its compliance is not.** The
individual reviewers are good — skeptics separate a true finding from a false one at 24.4% against
4.6% (p ≈ 0.0002), and the safety reviewers are right about the prose they flag. What they do not do
is follow an instruction, notice a fact placed in their context, or apply a rule stated in advance.
Design accordingly: put the decision in front of them, and put everything else in code.

**The shape.** An agentic workflow that calls logical tools. Statistical engines produce numbers;
agents make every judgment — what is worth telling, whether it is novel, whether it is safe, which
findings keep a feed slot, what to investigate next. There are no deterministic worth gates left.

**One research pass.** A research director (with a `researchJournal` tool over cross-run memory)
picks the pass strategy and may compose extra angles → scouts survey and hand over leads → a fleet
of lens-specialists investigates, each running twice (explore, then commit on a fresh window) →
every proposal faces a novelty judge, a safety panel that fails closed, a skeptic panel sized to the
claim, and an armed replication panel that re-tests against the data → survivors are persisted with
their provenance → a curator keeps the strongest few and names the standouts.

**What the detectors find.** Correlations (the premium finding — cross-signal links, above all
lead-lag ones), and four single-metric shapes the mean comparisons structurally cannot see: a metric
grown more erratic while its average held (volatility), a record stretch (milestone), a step to a new
sustained baseline (regime), and months that repeat high or low year after year (seasonal, measured
against a per-year trend line so a drift cannot pose as a season). Each emits every computable
candidate with its uncertainty attached; nothing is dropped for being small.

**What is structural, not agentic.** Numbers are resolved from source at persist time and metrics
resolve through the registry, so the model can name a thing but never invent a figure. Writes go
through one `@ModelActor`; whole runs serialise on `RunGate`; agents run strictly one at a time so
each gets the full Neural Engine. Everything the model reads is canonicalised: day keys are UTC
(`Calendar.civil`), and agent-facing numbers and dates carry no locale — three live defects came
from breaking that, and CI cannot catch any of them because it runs in UTC/en_US, so all of it is
enforced by source-scanning invariant tests instead.

**What is measured.** `InferenceActivity` counts generation time at the one choke point every model
call passes through; the Settings meter shows it as a duty cycle over a window it names honestly.
There is no public ANE-utilisation API, and the app does not pretend otherwise.

**What the fleet remembers.** A research journal spans runs: what was confirmed, what the panels
rejected and why, what the audit retired, and which invented angles were chased for no yield. The
first three are pushed at every agent as a do-not-repeat list. The fourth deliberately is not —
barren ground bears fruit once more data lands, so it reaches the research director as a fact to
weigh rather than a ban, which is the same facts-to-agents rule the rest of the design follows.

**What is enforced by tests, not prose.** Zero-cloud (no networking API, `cloudKitDatabase: .none`,
no iCloud entitlement); every `LanguageModelSession` built in one file; no template generator for
finding prose; the wellness disclaimer on every screen that interprets health data; every subagent
role's prompt prefix inside the 4k window, measured against the tool sets the app actually ships.

More were added as it became clear which mistakes this codebase repeats. Every closed
vocabulary the model may emit is DERIVED from its Swift type rather than re-typed in a guide. No
`.anyOf` may be a hand-written literal. No prompt may name a tool its session does not hold. Day
attribution never touches the device calendar, and agent-facing numbers and dates never touch the
device locale — both invisible to the suite, which runs in UTC/en_US, and both sources of live
defects. Every tool respects its output cap against hostile arguments. And `switch` over a closed
domain enum carries no `default`, so the compiler — not a reviewer — catches the next case that
forgets to say what the user is told. Every tool a session HOLDS is named in its prompt, not only the
reverse. Every identifier a prompt names — tool, schema field or enum case — exists. Prompts that
describe another panel state its size correctly. Every `@Model` is registered in the schema, and the
background task identifiers match `Info.plist`, both being silent-and-total failures otherwise. And
the runtime prompt budgets that no prefix check can see — the panel basis lines, the director's
assembled state, any single lens — are bounded by measurement rather than by reasoning about clamps,
which came out ~20% low the one time it was checked.

**What is open.** Two kinds — the owner's calls, and the ones needing a real device. (No count is
given here on purpose: it was "four things" and went stale the same week, which is the failure this
document keeps recording about numbers restated in prose.)

*The owner's to decide.* **Sleep day attribution** — `Calendar.civil` is UTC, so where a night lands
depends on the user's time zone (wholly on the wake day west of UTC, wholly on the sleep-onset day
east of it, split only near UTC). Changing it re-keys every stored sleep rollup, so it is expensive;
meanwhile the investigator is told the device's actual boundary rather than a blanket caveat. **What
"weekend" means** — Sat/Sun for everyone, which is simply wrong in Fri/Sat regions; cheap to change,
since it re-keys nothing. **Whether a relationship that ENDED deserves its own finding type** — the
app can now detect one (see the per-third coefficients below) and cannot present it faithfully: it
persists as a correlation, whose card states the whole-record strength beside prose saying the link
faded. Nothing shown is false and the card cannot express the claim, which is a new card, not a
refactor.

*Needs a real device to settle* (both now written up in `docs/VERIFIED-CLAIMS.md` as `[UNVERIFIED]`
entries, with the experiment that settles each — that file is where API claims belong, and it had
only `[CONFIRMED]`/`[PARTLY]` ones until now). **Multi-source HealthKit sums** — `HKStatisticsQuery(.cumulativeSum)`
sums every sample whatever wrote it, and iPhone and Watch both write step count; if the Health app's
source-merging is not reproduced, the headline metric is inflated for every Watch user. **Whether the
store opens on a locked device** — the in-memory fallback is now guarded, but whether
`.completeUnlessOpen` actually blocks the overnight background launch is unconfirmed. Neither is
observable in the simulator, and each has a five-minute experiment recorded with it below. **Whether
`.separateBySource` leaves an aggregate untouched** — the option is what makes provenance readable for
QUANTITY metrics and is now on the query behind every number they store (the interval path reads
sample sources directly and is unaffected); Apple documents it as additive, and if that is wrong
every rollup changes. The same paired-device run settles it and the step-count question together.

**What the agents are given about EQUIPMENT.** A new watch shifts resting heart rate, a new scale
reads heavy, a new phone counts steps differently — each a real, sustained, statistically sound level
change that is about hardware rather than the person, and one no amount of re-measuring can tell
apart. HealthKit records which sources wrote each day and the app now stores it (`SourceSignature` on
every rollup). Two capture paths, not one: quantity metrics get it from `HKStatistics.sources`, which
`.separateBySource` populates inside a query that was already running; sleep and mindful minutes have
no statistics query at all and take it from the `sourceRevision` of the samples that survived their
`include` filter. `ProvenanceScan` reports the transitions with how
long each setup ran; regime, milestone and volatility findings carry the nearest one as a caveat in
the basis the panels read; the replication analyst holds a `provenance` tool, being the role whose
re-computation of an artifact reproduces it faithfully every time. Seasonal deliberately carries no
caveat — measured, not assumed: cross-year averaging attenuates a device step ~7x, and stating it on
every seasonal finding would be a note on all of them and therefore on none.

**Asking follow-ups.** Each question still runs two fresh sessions, and a hard-clamped tail of the
conversation — the last two exchanges, 220 characters a side — is replayed into both. The screen had
always shown a conversation while the model answered unrelated questions; "why?" arrived with no
referent. The clamp is the feature: an unbounded replay grows with the chat and eventually kills the
session mid-answer, which is the failure the original no-replay decision was avoiding.

**How much actually reaches a person, measured.** Nothing, in a full run, and after a day of fixes
the reason has narrowed to one gate. Measured end to end on 2026-08-03 over six metrics with real
structure, given budget enough to vet (623 s): eleven proposals reached the safety panel, **five
passed it** (45%), four reached the skeptics, **none passed**, and the replication panel — the only
reviewers with tools — never convened at all.

Safety was the main blocker that morning (benign prose passed 1 time in 7) and is not any more:
rewriting the two lenses that invited inference took it to 45% on real proposals. The **skeptic
panel** is now the single binding constraint — five holds across thirty-six verdicts, a 14% per-lens
rate against a strict majority of nine — and it rejects on figures it cannot compute, a tool-less
reviewer writing "the confidence interval includes zero" and "a shift of 0.1 standard errors" that
recurs verbatim across unrelated findings.

Separately and additively, the on-power window is arithmetically too small: vetting a finding costs
~3x what proposing one does, so a 540 s budget buys thirteen investigators and then vets one or two
of their ~20 proposals. None of this is retuned here — which knob moves changes what the app will
tell someone about their own health, so all of it is the owner's call. The 2026-08-03 entries below
carry the numbers.

## 1. Principles

1. **On-device only.** No network. Health data and derived insights never leave the phone
   (`cloudKitDatabase: .none`, file protection `.completeUnlessOpen`, excluded from backups).
2. **No deterministic findings.** Nothing is shown unless on-device intelligence reasoned about it
   and produced safety-vetted prose. If the model is unavailable, the feed simply doesn't grow.
3. **High signal only.** A bounded feed (≈3–12 active findings). Cross-source correlations are the
   premium finding. NOTE: "single-metric leads must clear a quality floor" described the
   pre-inversion design — the deterministic worth floors are gone, and what keeps a feed slot is the
   curator agent's decision (see §0).
4. **Not recency-biased.** The engine reasons across *years* — same-day, lagged, and season-over-
   season — not just this week.
5. **Deterministic NUMBERS, agentic judgment.** The on-device LLM is small (~3B, ~4k-token window)
   and not trustworthy on arithmetic, so every figure is computed by an engine and re-resolved from
   source at persist time: the model can name a thing but never invent a number. That half is
   unchanged and load-bearing.

   The other half of this principle used to read "prose is *safety-vetted* deterministically", and
   that is no longer true — it is the "deterministic guards around an unreliable model" thesis §0
   records as overridden. `SafetyGuard`'s substring blocklist is gone; safety is now a panel of five
   independent reviewers with distinct lenses that fails CLOSED, and worth, novelty and curation are
   agent decisions too. Judgment moved to the agents; arithmetic did not.

---

## 2. The finding pipeline

```
HealthKit ──ingest──▶ MetricRollup (daily aggregates, SwiftData)
                         │
                         ├─▶ MetricStatsProvider ── the single numeric-truth source
                         │        (means, %change, z, multi-horizon partitions, daily series)
                         │
   ┌─────────────────────┴──────────────────────────────────────────────┐
   ▼                                                                      ▼
(A) Cross-source correlations                              (B) LLM discovery leads
   CorrelationEngine (pure stats)                             Discovery digest (multi-horizon)
   → Pearson, same-day + lagged                               → model proposes candidates
   → Benjamini–Hochberg FDR guard                             → Analyst calls MetricStats tool
   → mechanical-redundancy filter                             → deterministic Verifier re-derives
   → strongest, non-obvious survive                              the numbers (fidelity check)
   → model writes a *story* (worthTelling gate)               → model phrases (quality floor)
   │                                                          │
   └───────────────► SafetyGuard (language) ◀─────────────────┘
                         │
                         ▼
                   Adversarial skeptic panel (3 diverse reviewers; majority must hold)
                         │
                         ▼
                   SwiftData (InsightLog / CorrelationLog)
                         │
                         ▼
                   Curation: keep the top ≈11 by quality; tombstone the rest
                         │
                         ▼
                   Unified feed (Insights) + Trends dashboard + Q&A
```

Both finding types require the model to produce prose, pass `SafetyGuard`, and — on every
LLM-enabled run — survive an **adversarial skeptic panel** before they are persisted. Neither uses a
template fallback.

### (A) Cross-source correlations — the signature finding

`Engine/CorrelationEngine.swift` (pure, `nonisolated`, fully unit-tested). Daily health series are
trend-, season-, and weekly-rhythm-dominated and highly autocorrelated, so correlating **raw levels**
would surface mostly confounded junk (two metrics drifting together over years; both dipping on
weekends). The engine is built to be statistically honest:

- It correlates **day-to-day changes** (winsorized first differences), not levels — removing shared
  trend/season/level so a surviving link is genuine co-movement, not a shared calendar.
- It reports **`partialR`**: the change-correlation after **partialling out same-day activity**
  (active energy) — the relationship that holds *even after accounting for how active you were*,
  which deterministically kills the "activity halo" family.
- Significance uses an **autocorrelation-corrected effective sample size** (`nEff`), so "significant"
  means something instead of every |r| passing because raw `n` is in the hundreds.
- Same-day and ±1-day **lagged** in both directions, but only the chosen lag (pre-registered
  preference for same-day) enters the **Benjamini–Hochberg** family — **one test per pair**, so the
  FDR guard isn't fooled by near-duplicate lag tests.
- **Spearman** is computed alongside Pearson; their divergence flags a nonlinear/outlier-driven shape.
- A **mechanical-redundancy filter** (`MetricCatalog.isMechanicallyRedundant`) drops tautological
  pairs (steps↔distance, weight↔BMI, HR↔resting-HR) so a correlation is never an obvious fact.
- Survivors must clear floors on **both** raw `|r|` and `|partialR|`, plus significance and a minimum
  paired-day count; one correlation per unordered pair is kept, ranked by `|partialR|`.

The engine is the single numeric source for correlations (analogous to `MetricStatsProvider` for
single-metric stats), so there is no separate verifier to disagree with it. The model then judges
whether the association is a *meaningful, non-obvious story* (`CorrelationNarrative.worthTelling`)
and, if so, tells it in 2–4 sentences. A bald "X correlates with Y" is exactly the superficial
filler that the `worthTelling` gate exists to reject.

### (B) LLM discovery leads — single-metric

`Discovery → Analyst → Verifier → Phraser`:

- **Discovery** reads a compact multi-horizon `HealthDigest` (direction/magnitude buckets per metric
  per horizon — never raw numbers) and proposes candidate (metric, comparison, hypothesis) tuples
  from a closed `.anyOf` vocabulary.
- **Analyst** calls the `metricStats` tool exactly once and judges; it copies the tool's numbers and
  never computes its own.
- **Verifier** (`Agent/Verification`) re-derives the numbers from source and confirms the model
  copied them faithfully; then `MaterialityRules.buildFact` decides materiality deterministically.
- **Phraser** writes a short, high-signal note. A **salience quality floor**
  (`EnhancementPolicy.minOrdinaryInsightSalience`) drops routine, predictable movement before the
  model is even asked to phrase it.

### (C) Pattern findings — single-metric, beyond the mean

Three detectors surface things the mean-comparisons structurally cannot. Each only *proposes*
candidates; the model still judges worth (`worthTelling`) and narrates them, gated and curated like
everything else (no deterministic findings). All are pure, unit-tested engines:

- **Volatility shift** (`VolatilityScan`) — a metric has become markedly more/less erratic (recent
  vs. baseline coefficient of variation), even when its average held.
- **Milestone** (`MilestoneScan`) — the latest rolling 7-day stretch is a record high/low over a
  long span (produces the `.milestone` kind).
- **Regime shift** (`RegimeShiftScan`) — binary-segmentation finds the day a metric stepped to a new
  *sustained* level (Cohen's-d step, both segments long enough to be settled, plus a median guard so
  a brief spike can't masquerade as a new baseline).

These persist as `InsightLog` rows with a sentinel `comparison` (`"volatility"`/`"milestone"`/
`"regime"`) so they never collide with mean-trend findings for the same metric.

### Quality gates (summary)

| Gate | Where | Rejects |
|------|-------|---------|
| Detrend + partial-out-activity | `CorrelationEngine` | trend/season/weekday and activity-halo confounds |
| Significance (nEff) + FDR | `CorrelationEngine` | chance correlations, honestly corrected for autocorrelation |
| Mechanical redundancy | `MetricCatalog` | tautological/obvious pairs |
| `worthTelling` story gate | `phraseCorrelation` (given trust signals) | superficial / statistically flimsy associations |
| Salience floor | `Orchestrator.persist` | routine single-metric wiggle |
| Numeric Verifier | `Verifier` | model-invented numbers |
| `SafetyGuard` | persist paths | diagnostic / prescriptive / alarmist language |
| Adversarial skeptic panel | `Orchestrator.survivesScrutiny` | anything a critical reader could dismiss — 3 perspective-diverse skeptics (triviality / coincidence / artifact), each reasoning from the verified stats; a majority must hold it up (fail-open on infra error) |
| Trust-weighted, diverse curation | `StoreWriter.curateFindings` | everything beyond the top ≈11; over-concentration of one metric/body-system |

---

## 3. Beating recency bias — multi-horizon analysis

`ComparisonKey` spans short to multi-year windows: `recentVsBaseline`, `weekOverWeek`,
`weekdayVsWeekend`, **`yearOverYear`** (last 90 days vs. the same window a year ago), and
**`recentVsAllTime`** (last 30 days vs. the entire prior history). `MetricStatsProvider` reads
every ingested rollup — there is no day floor — and the correlation engine uses the full history,
so associations can emerge across every season and year on record.

The discovery digest is built across **multiple horizons** by default, and the exhaustive Deep
Analysis runs discovery through several time-horizon **lenses** (recent, year-over-year, all-time,
weekday/weekend) so leads are never limited to "what moved this week."

---

## 4. Two run modes

The same `Orchestrator.runDiscovery` job powers both; `exhaustive` selects depth.

- **Bounded pass** (foreground catch-up + background processing task): correlations (capped) + one
  discovery round, deadline-bounded. The background processing task is **power-gated**
  (`requiresExternalPower = true`); the background *refresh* runs no agents at all (findings need
  the model, which only runs in the foreground/on-power window). The adversarial skeptic panel runs
  here too — the everyday foreground catch-up is the most-travelled path, so it gets the same bar.
- **The research program** (foreground, indefinite, AUTO-STARTED): the app's default state — it
  starts on its own whenever Verdant is open and keeps reasoning until the user stops it (the Stop
  holds until they start it again) or the app leaves the foreground (it resumes on return). Each
  pass runs the three tracks (collect / discover / reason+verify — see the dated updates); dryness
  switches strategy to self-directed drill-downs rather than ending the run, and
  `DeepAnalysisPolicy.maxPasses` is only a runaway backstop. Its live status, counts, and event
  feed render directly on the Insights tab (which pair is being tested, what's being challenged,
  what was kept) with a ~2-second heartbeat advancing only the elapsed clock — never rotating
  filler. A tapped finding's "Investigate this further" interrupts the program for a focused
  drill-down, then the program resumes on its own.

First launch backfills the user's ENTIRE recorded HealthKit history — one range query per metric
starting from `HealthStore.earliestSampleDate` — so the analysis has all data immediately; later
passes only revisit the recent window.

---

## 5. Safety & privacy

- **Deterministic safety, not a prompt.** A ~3B model won't reliably honor "don't give medical
  advice," so `SafetyGuard` rejects any prose containing diagnostic, prescriptive, or alarmist
  language (and disease names). The model's prose is *language*, vetted outside the model; the
  numbers are *verified* against source. Verdant makes no diagnosis and surfaces no clinical
  thresholds (the former red-flag tier was removed).
- **HealthKit is read-only.** Authorization requests `toShare: []` (no write types); only
  `NSHealthShareUsageDescription` is declared; the entitlement grants read + background delivery
  only. The app contains no HealthKit write/save call. *(If a device's Health "Data Access" screen
  still shows write toggles, that is stale state from an earlier build — toggle them off or
  reinstall; the current build never requests write.)*
- **Zero cloud, encrypted at rest.** Local-only SwiftData store, `cloudKitDatabase: .none`,
  `FileProtectionType.completeUnlessOpen`, excluded from iCloud/iTunes backups.

---

## 6. Context-protection & concurrency

The Orchestrator owns **no** `LanguageModelSession`; every model call is an ephemeral leaf session
created inside `Subagents`, used once, and discarded — so no long-lived transcript accumulates
against the ~4k-token window. Handoffs between stages are small `@Generable` structs with closed
`.anyOf` vocabularies, so the model can only ever name metrics/comparisons the deterministic layer
can recompute. On-device inference serializes on the Neural Engine; concurrency
(`EnhancementPolicy` / `DeepAnalysisPolicy`) sets the issue depth, and `RateLimitBackoff` drains the
queue against the system's generation rate limit.

FoundationModels facts (verified against the iOS 26.5 `.swiftinterface`): `tokenCount(for:)` and
`contextSize` live on `SystemLanguageModel`; the rate-limit error is
`LanguageModelSession.GenerationError`. The default guardrails refuse health prompts, so sessions
use `SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)` —
relaxing the *model's* guardrail while `SafetyGuard` still enforces ours.

---

## 7. Persistence (SwiftData, `SchemaV1`)

- `InsightLog` — one surfaced single-metric finding (LLM prose + verified numbers + embedding for
  semantic search + lifecycle: `tombstoned`, `jobRunID`).
- `CorrelationLog` — one surfaced cross-source correlation (the two metrics, lag, coefficient,
  sample count, the narrative story/title, a feed-quality score, lifecycle).
- `MetricRollup` — deterministic daily aggregate per metric (the substrate the stats provider
  reduces); upserted idempotently by `"<metric>#<dayEpoch>"`.
- `SyncAnchor` — resumable `HKQueryAnchor` per sample type.

All writes funnel through one `@ModelActor` `StoreWriter`, so they never race. **Curation**
(`curateFindings`) ranks the union of active insights + correlations by quality and tombstones
everything beyond the budget; tombstoning (not deleting) preserves the audit trail.

---

## 8. UI

- **Insights** — the unified feed of findings: single-metric cards (with a sparkline) and
  correlation cards (with a dual-line normalized chart + the story). Merged and sorted by recency,
  with the best pinned to a "Worth your attention" zone. **Tapping any card opens
  `FindingDetailView`** — the card plus a kind-specific "what this means" and when it surfaced.
- **Trends** — a dashboard held to the same quality bar: a **connection-map constellation**
  (`ConnectionMap`, a node-link diagram of the discovered correlations, with the most-connected
  signal called out) and per-connection detail cards (also tappable), sorted by connection strength
  (|coefficient|, so a strong inverse link isn't buried). *No* obvious per-metric "%change" readout.
- **Ask** — free-text Q&A about a single metric; the router maps the question to a metric/comparison,
  numbers are resolved deterministically, and the model's answer is safety-vetted (or an honest
  "unavailable"). Relationship questions are out of scope and surface as findings instead.
- **Deep Analysis** — runs the exhaustive job, streaming a **live feed of the real steps in flight**
  (data read, relationships tested, each pair reasoned about, the skeptic challenges, what was kept),
  newest-first with older lines fading. The "Done" button never blocks: the run continues on the app
  model and new findings land in the feed when it finishes.
- Green "Verdant" design system (`UI/Theme.swift`); Swift Charts throughout.

---

## 9. Module map

```
Verdant/
  App/         AppModel (composition root), AppContainer, VerdantApp
  Domain/      MetricKey, MetricCatalog, ComparisonKey, CoreValues, Correlation, AnalysisProgress
  Engine/      CorrelationEngine, Volatility/Milestone/RegimeShift scans, MaterialityRules, FindingPhrasing
  HealthKit/   HealthStore (read-only), Ingestor, ObserverManager, MetricStatsProvider, mappings
  Agent/       Orchestrator, Subagents, Handoffs (@Generable), Tools, Verification, Safety, policy
  Memory/      StoreWriter insight/correlation writes + curation, Embeddings, InsightSearch
  Persistence/ SwiftData models + SchemaV1
  Background/  BackgroundScheduler (power-gated), RateLimitBackoff
  UI/          Insights feed, Trends + ConnectionMap, Charts, DeepAnalysis, Chat, Settings, Theme
```

---

## 10. Testing

Comprehensive Swift Testing suite (pure-stats, materiality, verifier, safety, formatting,
sleep/day math, persistence + curation, rate-limit backoff, `CorrelationEngine`, and full
`Orchestrator` integration with a fake `SubagentRunning` + injected capability). The fake exercises
the verify → story/worthTelling → safety → curate path without the on-device model. CI runs build +
test + SwiftLint + SwiftFormat.

---

## 11. Known limitations & open decisions

- **Simulator** has no Apple Intelligence and limited Health data, so it exercises only the
  deterministic substrate; real findings require a physical iPhone with Apple Intelligence enabled
  and a signing team.
- The on-device model's editorial judgment (`worthTelling`, phrasing) is inherently variable; the
  deterministic gates bound *what it can claim*, not *how interesting* a kept item feels. Tuning the
  thresholds (`minAbsR`, salience floor, budget, FDR α) is ongoing.
- Correlations are associations, not causation, and are framed as such; Verdant is informational and
  wellness-only, not a medical device.

**Further updates (2026-07-20 — the three-track loop: collection and verification at reasoning depth)**

The deep-run loop's depth used to be lopsided: reasoning got fleets, drill-downs, and indefinite
passes, while data collection was a one-shot scan set and verification a single prose-only panel
per finding. Each pass now runs three tracks at comparable depth:

- **COLLECT.** *(Horizon since superseded to ALL-TIME — see the later entry with the same date.)*
  Ingestion reaches the full 1,825-day analysis horizon: first ingest backfills the
  whole horizon with ONE `HKStatisticsCollectionQuery`/range-sample query per metric
  (`HealthStore.dailyValuesRange`) instead of the per-day loop that capped backfill at 730 days —
  years 3–5 of a new user's history used to be invisible to every scan that claimed to read them.
  `Ingestor.deepenHistory` recovers the missing older span once for existing installs (markers ride
  in `SyncAnchor` sentinel rows so a cache reset re-deepens automatically). Range buckets are
  validated against the fixed-UTC civil-day grid (24-HOUR intervals, not `day:1` — DST-proof), with
  any misaligned bucket recomputed via the proven per-day path; the deletion-blind range API is
  confined to stale-free spans (first ingest, strictly-older deepening). Mid-run, the deep loop's
  `collector` hook (wired in `AppModel`) runs a real delta ingest + deepen at every substrate
  refresh — previously the refresh re-read rollups that could not have changed, because observer
  ingests skip while the run holds the gate.
- **DISCOVER.** A new scout subagent role surveys the data and hands back testable leads: rotating
  survey angles (unexplored corners, strange-day clusters, deep time, missed links, data quality,
  the open question), a scout-only `coverage` tool over the new `CoverageScan` (the map of what
  data exists — spans, density, gaps — which every other tool is blind to), and a lighter 5-tool
  surface (no 72-key metric vocabulary). Leads become extra investigator lenses in the same pass,
  capped and deduped, with a ledger ring steering later scouts away from re-proposing; dry breadth
  passes push scouts explicitly into unvisited ground.
- **VERIFY.** Two arms. New proposals: after the prose-skeptic panel, an ARMED replication panel
  (`replicate` role, analyze + unusualDays in its own hands) re-tests each claim against the data —
  outside its window, without its outliers, against day-structure artifacts; a kept finding now
  costs 14 verdict sessions (5 safety + 6 skeptic + 3 replication). Standing findings: at every
  substrate refresh, the audit (`auditStandingFindings`) re-tests the feed's strongest findings
  against TODAY's substrate and retires (tombstones, defensively by UUID) any that no longer hold,
  narrated in the live feed and remembered in a dedicated retirement ring so the fleet doesn't
  re-surface them. Both panels share the skeptic's aggregation (strict majority of rendered, tie
  rejects, fall open only on total infra failure) and its deadline discipline (fail closed).

Token discipline holds throughout: the scout (1,024-char instructions, 3-call budget) and
replicator (749 chars, the roomiest 2-tool session) get their own token-harness prefix tests; the
generic `respondWithOverflowRetry` now serves all four exploring roles; every model-written string
that rides into another session (lead hypotheses, audit claims, steering rings) is clamped at its
boundary. Background/bounded runs gain the replication panel (their findings share the feed) but
keep their scheduling, deadline posture, and no scouts/audit/collector — background remains as-is.

**Further updates (2026-07-20, later — all-time horizon)**

The 1,825-day analysis cap is gone: the horizon is now **each metric's entire recorded history**.
`MetricStatsProvider` reads every rollup (no day floor — `recentVsAllTime` means genuinely
all-time, milestones are true all-time records, correlations and drifts can span a decade); first
ingest backfills from the metric's earliest HealthKit sample (`HealthStore.earliestSampleDate`,
one limit-1 probe + one range query per metric — HealthKit began in 2014, so "all of it" is
bounded by reality); and `deepenHistory` recovers the pre-cap years on existing installs via the
pure `Ingestor.deepenSpan` helper, under a re-versioned marker (`deepenedAll#`) so 1,825-era
installs deepen once more to their true beginning. The only remaining day constant is
`AnalysisQueryEngine.maxDaysAgo = 7300` — a schema-side ceiling for the `analyze` tool's window
guides, not a data bound; the `coverage` tool tells agents how far back the real data goes.

Also: `ingestAll` now separates "Authorization not determined" failures (types that have never
been through the Health permission sheet — routine for blood pressure) into their own calm
"awaiting Health permission" progress line, distinct from genuine read failures; the anchor
doesn't advance for those metrics, so their full history backfills the moment access lands.

**Further updates (2026-07-31 — governance moves to agents; engines stop dropping)**

Purpose restated by the owner: the app exists to run the Neural Engine for as long as possible —
agentic workflows always go for maximum effort and detail; never optimize to reduce model calls,
only to remove idle gaps and deepen per-pass detail. This round moves the remaining DECISIONS to
agents (deterministic paths survive only as infra-failure fallbacks) and stops the stat engines
from silently dropping what agents could judge:

- **Research director** (`direct` role, `PassPlan`): each deep-run pass's strategy — breadth /
  drill / frontier, plus a one-sentence fleet directive that becomes the pass's first lens — is
  now the director agent's decision, briefed with the run's state (yield, dry streak, feed
  contents, this run's rejections, prior runs' dead ends). The old dry-streak arithmetic remains
  only as the fallback when the director can't render a plan.
- **Curator** (`curate` role, `CurationDecision`): the feed budget is enforced by an agent that
  reads the numbered roster — every active finding with computed quality/age/shared-metric/
  near-duplicate FACTS (`StoreWriter.curationRoster`) — and picks what keeps its slot; everything
  left out is retired. The greedy deterministic trim survives only as the model-unavailable /
  infra-failure fallback. Curation also now runs at every deep-run substrate refresh, not only at
  run end. The dead `minOrdinaryInsightSalience` / `minPatternFindingQuality` floors are deleted.
- **Novelty judge** (`judgeNovelty`, `NoveltyVerdict`): the 14-day `hasRecent*` windows no longer
  DROP colliding proposals — the window only SELECTS the standing finding, and the judge decides
  re-tread vs meaningful update (an update appends alongside; the curator then weighs both).
  Novelty is judged BEFORE the safety/skeptic/replication panels, so a re-tread costs one judge
  session instead of a full 14-session vetting; the embedding is computed only after the judge.
- **Persistent research journal** (`ResearchJournalEntry`, `StoreWriter.recordJournal` /
  `journalSteering`, pruned to 400 rows): every drop (with its reason), audit retirement, and
  kept finding is recorded ACROSS runs. Investigators, scouts, and the director are steered with
  prior runs' dead ends — the research program now iterates day over day instead of starting
  amnesiac (the in-memory `RunLedger` still handles within-run steering).
- **Panel reasoning is kept** (`Verdict.why`, generated BEFORE the boolean so the small model
  commits to reasoning first): skeptic and replication verdicts narrate their strongest
  consideration in the live feed instead of discarding it.
- **Engines inform, agents decide** (in progress): the correlation scan returns all judged pairs
  flagged with significance/thirds-consistency instead of dropping sub-floor ones; regime shifts
  carry a `suspectedDeviceSwap` flag instead of being cluster-suppressed, and the Cohen's-d floor
  drops to a computability epsilon; volatility emits every computable shift with an `seZ`
  uncertainty statistic; milestones emit any true record with margin/span as facts; unusual days
  keep the full ≥2σ pool with numeric z and tool paging. Ranking (strongest first) plus the
  tool-layer output caps remain the size bound for the 4k window — a memory bound, not a worth
  gate.
- **Hardware**: the power-gated background budget rises 150s → 540s (the expiration handler stays
  the hard stop); the deep run re-prewarms the model at every substrate-refresh boundary so the
  warm-up overlaps the CPU-bound collect instead of stalling the next generation.

**Further updates (2026-08-02 — the engine stops waiting on the CPU; the program stops dying)**

Same purpose, applied to idle time: no model calls were removed, and none were added as
compensation. Every change here either overlaps CPU-bound work with generation, or removes a way
the device could end up reasoning for zero seconds.

- **Substrate scans are pre-started, off-actor, and parallel** (`AnalysisSubstrate.precompute()`).
  Each scan previously computed lazily *inside* the first tool call that needed it, so a live
  generation stalled while the CPU re-crunched years of rollups. The substrate now memoizes a
  `Task` per scan rather than the value, and every construction site (`runDiscovery`, the deep-run
  refresh boundary, the focused drill-down, Q&A) starts all seven immediately. Three consequences:
  the scans run on the cooperative pool instead of serialized on the actor, they occupy every core
  at once, and they overlap the model's warm-up and first tokens. Memoizing the task (not the
  value) is what lets a lazy caller and the precompute converge on ONE run of each scan whichever
  arrives first.
- **COLLECT is prefetched a pass early** (`Orchestrator+DeepRun.startCollection`). The deep run's
  HealthKit ingest + history deepening used to run *at* the refresh boundary with nothing
  generating. It is now launched at the start of the preceding pass and joined at the boundary, so
  minutes of I/O and CPU run underneath a full pass of reasoning. Safe because every write goes
  through the single-writer `StoreWriter` actor and the in-flight pass reads its own already-built
  substrate — one pass, one coherent snapshot; the *next* substrate picks the new data up. The task
  is unstructured, so the loop cancels it on every exit path.
- **`metricStats` is served from the cache, not re-queried** (`MetricStatsTool`). It used to fetch
  the named metric's whole history and recompute on every call — *during* generation, and it is one
  of the most-called tools. The substrate's memoized `scanAll` is the full metric × comparison
  cross-product produced by the very same `computeStat`, so the tool now does an in-memory lookup
  for an identical answer. It also drops the tool's own `now` parameter, so the tool and the
  substrate can no longer disagree about which day it is.
- **The model warms across the launch backfill** (`Orchestrator.prewarm()`, called by `AppModel`
  before `ingestAll`/`deepenHistory`). `runDiscovery` prewarms too, but that fires *after*
  collection — so on a first run the model loaded cold at exactly the moment reasoning began.
- **The research program can no longer die silently** (`AppModel.superviseResearchProgram`). If
  Apple Intelligence was still downloading at launch — the common first-launch case — the program
  returned within milliseconds and nothing ever restarted it; the app then sat idle until the user
  happened to background and foreground it. A supervisor now keeps it alive, re-checking every 20s
  and starting the moment the model is usable. Only an explicit Stop, backgrounding, or
  `unavailableForever` hardware ends it. The feed distinguishes waiting from stopped
  (`isAwaitingModel`), and Stop/Start acts on whether the program is *alive* (`isProgramActive`),
  not on whether a generation happens to be in flight.
- **The engines are deterministic again.** `VolatilityScan`, `UnusualDaysScan`, `DeviceSwapFilter`,
  and `AnalysisQueryEngine`'s correlation path read each metric's days straight out of a
  `[Date: Double]` dictionary. Swift's dictionary iteration order is **not** stable across
  separately-built dictionaries holding the same pairs, and both the float summation in
  `mean`/`sampleStandardDeviation`/`pearson` and the unstable rank sorts (whose tie order follows
  input order) are order-sensitive — so identical history could yield last-ULP-different statistics
  and a different set of candidates past the tool caps from one run to the next. All four now read
  chronologically. (`CorrelationEngine.evaluate`, `MilestoneScan`, `RegimeShiftScan`, and
  `CoverageScan` already sorted.) Pinned by `SubstratePrecomputeTests`, which deliberately compares
  two independently-built fixtures.

**Further updates (2026-08-02, later — the tool surface stops lying; the last silent deletion goes)**

- **`analyze` honoured its `dayFilter` everywhere except correlations** — and still printed the
  filter in the result. An agent asking "does this link hold on weekends?" got the ALL-days number
  labelled "weekends only", then proposed a finding on it; the armed replication panel, which
  re-tests claims through this same tool, could be fooled the same way. The filter now applies to
  the correlation pairing (on the leading metric's day). This mattered more than a normal bug: the
  closed tool surface is the app's whole anti-hallucination story, so a tool that misdescribes its
  own output undoes the guarantee agents are trusted under.
- **`analyze`'s `slope` is now genuinely per-day.** It regressed on array *position*, which equals
  per-day only when readings are consecutive and unfiltered — under gaps, or a day filter where
  Mondays sit 7 days apart, it returned a per-READING slope while labelled "per-day trend",
  overstating the trend by the spacing factor. Precisely the long-horizon, gappy, filtered queries
  the multi-year-drift lens is instructed to run. `slope` is now `slope(x:y:)` and the query path
  feeds it day offsets.
- **`DeviceSwapFilter` reports instead of removing.** `removingSuspectDays` erased every suspected
  recalibration day from every metric before any agent saw the data — the last place in the pipeline
  where real observations were destroyed rather than judged, and a deterministic verdict ("that was
  hardware, not you") taken silently on the agents' behalf. The days now stay; the detector's
  verdict rides along as `UnusualDay.suspectedDeviceSwap` and is stated in the `basis` prose the
  investigator reads, matching the `RegimeShift.suspectedDeviceSwap` precedent. "Body event or
  hardware event?" is now the agents' call and the skeptic panel's "measurement artifact?" lens.
  Nothing was added to compensate — the fact simply travels with the data instead of being acted on.

  *Trade-off, stated plainly:* swap days can now reach the correlation/volatility/milestone
  detectors, which is what the filter existed to prevent. The signature is rare (it needs ≥2 Watch
  vitals each jumping >3σ on the same day), so most histories are unaffected, and the flag reaches
  the agents that judge — but this does trade a guaranteed exclusion for an agent judgment, which
  is the direction's explicit intent.

**Further updates (2026-08-02, later still — the last worth-judgment leaves the view)**

- **"Worth your attention" is a curator decision.** `InsightFeedView.pinned` was
  `feed.count >= 5`, `prefix(3)`, and `quality >= 60` — three deterministic worth-judgments living
  in a SwiftUI view, the last place in the app where a threshold decided what mattered. The curator
  agent already reads the numbered roster with every finding's quality, age, shared-metric and
  near-duplicate FACTS, so it now also names the standouts: `CurationDecision.highlight`, persisted
  as `InsightLog.highlighted` / `CorrelationLog.highlighted` via `StoreWriter.setHighlights`, and
  the view simply renders `feed.filter(\.highlighted)`.

  Written as a whole set each round, so highlights can never accumulate stale promotions; bounded
  by the same closed-roster rule as `keep` (a promotion for something the curator retired is
  ignored); and empty when the model is unavailable — an uncurated feed has no highlights rather
  than a rule inventing some. No new agent role and no new session: the decision rides on the
  curator call that already happens at every substrate refresh and run end.

**Further updates (2026-08-02, later still — findings remember how they were judged)**

- **Per-finding provenance.** The safety, skeptic, and replication panels are the most expensive
  reasoning the app does, and their verdicts scrolled past in the live feed and were gone — a user
  could see THAT a finding survived scrutiny, never what it survived. Both panels now return a
  `PanelOutcome` (tally + the deciding panelist's own words) instead of a `Bool`; each proposal is
  paired with the investigator lens that found it through the fleet dedup; and the rendered line —
  who proposed it, what each panel tallied, one quoted sentence — is persisted as
  `InsightLog.provenance` / `CorrelationLog.provenance` and shown under "How Verdant found this".
  It rides in the same save as the numbers (a defaulted `provenance:` parameter on the five
  `append*IfNovel` methods), not a follow-up write.

  A panel that never convened contributes no clause rather than an honest-looking "0/0", so the
  line never overstates what was actually run.

**Further updates (2026-08-02, later still — the investigator gets a second window)**

- **Two-session investigator: explore, then commit.** Each lens ran ONE session with an explicit
  "at most FOUR tool calls" budget — a limit the 4,096-token window forces, not a judgment about
  how much exploration is worth doing. A lens now runs two sessions: an `explorer` that MEASURES
  and reports terse readings (`ExplorationNotes`, ≤5 lines, clamped), then the existing
  `investigator` on a fresh window that starts already holding those numbers and spends its own
  four calls on TESTING rather than re-discovering. Roughly twice the tool round-trips per lens and
  twice the sessions per pass, with neither half nearer the window than before — depth bought with
  more model calls, which is the direction (never fewer calls; only fewer idle gaps).

  The explore pass is best-effort: if it fails, the commit pass runs with no notes, which is exactly
  the previous single-session behaviour. `TokenHarnessTests` pins the new role's prefix like every
  other. `Instructions` moved to its own file (`Agent/Subagents/Instructions.swift`) — the prompt
  surface is edited far more often than the session plumbing, and `Subagents.swift` had crossed the
  500-line limit.
- **Ask gets the same two passes.** A question that needs several lookups had to fit them, the
  reasoning, and the written answer into one 4k window. The Q&A path now runs the same `explorer`
  gather pass first, so the answerer starts with the readings already paid for.

**Further updates (2026-08-02, later still — the follow-up the agents were told to make)**

- **`eventWindow` tool.** The investigator instructions say "unusualDays hands you the strangest
  single days on record — chase what else moved around them" — but doing that meant one `analyze`
  call per metric (~72) against a four-call budget, so the most valuable follow-up in the whole tool
  surface was, in practice, unreachable. `eventWindow` answers it in ONE call, and needs no new
  computation: `UnusualDaysScan` already tests every day of every metric against its own robust
  baseline and the substrate memoizes the ranked pool, so this is a view over numbers already in
  memory — filter to the window, keep each metric's strongest day, rank (with the metric key
  breaking |z| ties, so the set past `limit` is stable).

  It goes to the EXPLORE session only. That is both principled — measurement belongs to the pass
  whose job is measuring — and what makes it affordable: tool schemas dominate these prefixes (six
  tools ≈ 1,900 of the 2,048-token bound), and the commit session is already close to it. The tool's
  own description is terse for the same reason, spending its tokens on the one thing that matters:
  that a metric's *absence* from the result is not evidence it held steady.
- **The supervisor's decision is now a pure function** (`AppModel.nextProgramStep`, in
  `App/AppModel+ResearchProgram.swift`). The state machine that keeps the engine working was the
  app's most consequential untested code — and testing it in place would have meant standing up
  HealthKit, a model container, and a real `SystemLanguageModel`. Extracted, every branch is pinned
  by `ResearchProgramSupervisorTests`, including the distinction the whole thing turns on:
  `downloading` and `notEnabled` RESOLVE (wait), `unavailableForever` never will (stop).

**Further updates (2026-08-02, later still — two arbitrary drops, and a director that can compose)**

- **Scout leads are no longer dropped by arrival order.** `runScoutSweep` ended in
  `prefix(maxLeadsPerPass)`, so scout 1's fourth idea always beat scout 2's first — a worth judgment
  nothing was qualified to make, on the output of agents that had just done the work. Every distinct
  lead now becomes a lens. The width it was protecting is already bounded at the schema
  (`maxLeadsPerScout` × `scoutsPerPass`), each lens is its own bounded session, and more leads cost
  time rather than context — which is the resource the app is trying to spend.
- **The research director can compose its own lenses** (`PassPlan.extraLenses`, 0–3). It set each
  pass's STRATEGY but the fleet's roster was a fixed rotation of 11 thematic angles, so anything the
  roster structurally cannot ask went unasked. Its angles are ADDED to the fleet, never substituted,
  so a terse director can never make a pass narrower — and blank entries are dropped rather than
  spending an investigator session on no instruction.
**Further updates (2026-08-02, through the day — hardening, and auditing the claims)**

- **The audit docket rotates.** `auditCandidates` returned the strongest `limit` findings at every
  refresh, forever — with a feed of 11 and a docket of 4, anything ranked 5+ was re-tested exactly
  never, so a mid-ranked claim that had quietly stopped holding could sit there for the life of the
  app. A `round` counter, advanced once per refresh boundary, walks the window through the whole
  ranked feed (which the fetch now spans). This is coverage plumbing, not a worth judgment: it
  decides WHEN a finding faces the panel, never whether it survives, and round 0 is still
  strongest-first.
- **`researchJournal` tool for the director.** Every agent has the fleet's cross-run memory PUSHED
  at it as a clamped do-not-repeat list — right for an investigator, which needs steering rather
  than a research question. The research director is the one agent whose actual job is deciding FROM
  history, and it was making that call from three lines chosen for it. It can now query the record
  by kind (confirmed / rejected-with-reason / retired). Its session is prose-only and tiny, so it
  has room for a tool the crowded investigator sessions could never afford; `TokenHarnessTests`
  keeps it under a third of the window.
- **The drill-down is tested.** `runFocusedDiscovery` — the user-facing "Investigate this further" —
  was the one user-triggered path with no coverage. `FocusedDiscoveryTests` pins the three things
  that make it a drill-down rather than another sweep: every lens is anchored on the tapped
  finding (including the one whose job is to knock it down), a pass that finds nothing closes with
  an honest note, and without a model it refuses outright rather than reporting a clean bill.
- **Nine dead throughput knobs deleted.** `maxCorrelations` / `maxVolatility` / `maxMilestones` /
  `maxRegimeShifts` existed in BOTH policy enums, plus a second `maxConcurrentSubagents` on
  `DeepAnalysisPolicy` — none referenced anywhere. They were leftovers from the logical pipeline
  that picked the strongest N of each kind to hand the model, and they became inert the moment the
  investigator agent started choosing for itself. Worth removing rather than leaving: they read as
  live caps on how much the app reasons (the deep-run one implied deep passes parallelise, which
  the whole design deliberately rejects), so anyone reasoning about throughput from this file was
  being misled by constants that did nothing.
- **The skeptic panel is sized to the claim** (`Instructions.challenger`, `ChallengeSet`). It posed
  the same six questions to every finding — a bland single-metric trend and a causal-sounding
  cross-metric claim faced identical scrutiny. A challenger agent now reads the specific finding and
  writes the questions the fixed six would miss (0–3), each becoming another skeptic. Strictly
  ADDITIVE: the fixed lenses always run, blanks are dropped, and a challenger that goes quiet or
  fails leaves the panel exactly as strong as before — so this can only deepen scrutiny, never
  thin it. Costs one prose-only session plus the extra skeptics it buys, which is the trade the
  mission asks for.
- **The armed panel is sized to the claim too** (`Instructions.retestPlanner`, `RetestPlan`). Same
  move as the challenger, for the panel that re-tests against DATA rather than prose: a planner
  names the computation that would expose THIS claim — the specific window, lag, day-filter or
  median swap, plus what result would contradict it — and each becomes another analyst driving
  `analyze`/`unusualDays`. It applies to the standing-finding audit as well, since that path runs
  through the same function. Additive on both sides, and pinned in both directions by test.
- **The Ask tab narrates.** A question now costs two model passes plus a five-reviewer safety panel,
  and it showed a bare `ProgressView` for all of it — the one screen in an app built around watching
  it reason that told you nothing. `Orchestrator.answer` takes a `ProgressReporter`,
  `AppModel.askProgress` carries it (deliberately separate from `activeProgress`, which is the
  research program's), and `ChatView` shows the live line. Narrated only at the granularity the
  function actually knows — same rule as the research feed, no rotating filler — so the panels
  narrate themselves and nothing claims a step that isn't happening.
- **`analyze`'s sample floor is per-statistic, unlocking the raw single-day read.** A blanket
  `xs.count >= 3` gated every query, which quietly made the app's most obvious follow-up impossible:
  `unusualDays` and `eventWindow` hand the agent a specific strange day and the instructions tell it
  to chase that day, but a one-day window holds one reading, so "what was the actual value?" always
  returned unavailable. Floors are now what each statistic needs to be DEFINED — mean/median 1,
  stdDev/CV/slope 2, correlation 5 — and a refusal says how many readings it had and how many it
  needed, instead of a flat "not enough data". No new tool and no schema change: the capability was
  already there, behind a floor that was never a computability limit.
- **Stop no longer blocks on an in-flight collection** (found by writing the test for a claim this
  document already made). The refresh boundary joined the prefetched ingest with `await
  task.value`, which ignores the AWAITING task's cancellation — so pressing Stop, or backgrounding,
  during a boundary blocked until the entire ingest finished. On a first run that is minutes, with
  the run gate still held and the UI still reporting work. The join is now wrapped in
  `withTaskCancellationHandler`, which forwards the cancellation to the collection; the run still
  awaits it afterwards, because releasing the gate while an ingest it owns is mid-write would be
  worse than waiting for it to unwind. `DeepRunCollectionTests` pins it — before the fix that test
  took 60 seconds and failed.
- **CI no longer pins a simulator by name.** `.github/workflows/ci.yml` asked for `iPhone 16 Pro`,
  which the iOS 26 runtime does not ship — locally that runtime offers the iPhone 17 family and no
  16 Pro at all, so `xcodebuild` fails before running a single test. A "Pick a simulator" step now
  resolves the newest available iPhone's UDID and passes `-destination id=…`; any booted-capable
  iPhone runs this suite identically, so there was never a reason to name one.
- **The zero-cloud promise is now enforced by tests** (`ZeroCloudTests`). "Entirely on-device, zero
  cloud" is the one claim a user cannot verify for themselves and the one whose failure matters
  most — and it rested entirely on absences plus a single argument: `cloudKitDatabase: .none` in one
  initializer (SwiftData syncs to the user's private CloudKit database BY DEFAULT), and the fact
  that nobody had imported a networking API. Dropping either was silent and no test would have
  noticed. Three tests now scan the shipping source: no `URLSession`/`CKContainer`/
  `PrivateCloudComputeLanguageModel`/`NLContextualEmbedding` USAGE (comments are stripped, because
  the code deliberately names the APIs it avoids in order to explain why), the store's explicit
  CloudKit opt-out, and the absence of any iCloud entitlement. The sweep asserts it actually found
  the source tree and >50 files, so it cannot pass vacuously — and it was verified to FAIL against
  an injected `URLSession.shared`. `docs/VERIFIED-CLAIMS.md` says why each item is load-bearing;
  this is that document's enforcement.
- **User-facing prose caught up with the architecture.** Two documentation defects, both found by
  auditing claims rather than code. (1) `FindingDetailView` promised each finding faced "six
  independent skeptics … and three analysts" — exact when every finding faced identical panels, but
  a floor quoted as a fact once the panels started sizing to the claim, and it *understated* the
  scrutiny. It now describes the process and lets the finding's own provenance line report the real
  tallies. (2) The README still described the pre-inversion pipeline — "deterministic guards around
  an unreliable model", deterministic detectors proposing candidates, a `Verifier` re-deriving
  numbers, a `SafetyGuard` vetting language, a 3-reviewer skeptic panel, quality floors on
  single-metric findings. Every one of those was removed weeks ago; the repo's front page described
  roughly the opposite of what the app does. Rewritten around agents-decide, the current pipeline
  and control loop, the registry-row way to add a metric, and the deliberate one-agent-at-a-time
  concurrency (it had claimed "many concurrent subagents").
- **Two more stated invariants made mechanical** (`ArchitectureInvariantsTests`), the direct response
  to the README having described a deleted pipeline for weeks without anything failing. (1) *"The
  Orchestrator owns no `LanguageModelSession`"* — the discipline the whole 4k-window design rests on
  — is now enforced as "every session is constructed in `Subagents.swift`". A session held anywhere
  longer-lived reintroduces the accumulating transcript the design exists to avoid, and fails slowly
  and confusingly rather than loudly. (2) *"No template fallback"* — `FindingPhrasing` must stay a
  plain carrier, because the moment it grows a generator the app can show prose no agent wrote and
  no safety panel saw. Both were verified to FAIL against injected violations. The source scanner is
  shared with `ZeroCloudTests` as `SourceScan`, and asserts it reached the real tree so no check can
  pass vacuously.

  The general rule this round settled on: **a claim worth stating in the docs is usually worth
  pinning in a test.** Prose and code drift silently, and the only defence that survives a refactor
  is one that runs in CI.
- **The anti-hallucination claim had a hole, and it is now watched.** Auditing the app's central
  promise — "the agent never states a number… anti-hallucination is *structural*" — showed it true
  of everything except the part users actually read. `ProposedFinding.metric`/`kind`/`comparison` are
  registry-resolved (unforgeable), and the figures on the card are re-read from source at persist
  time. But `story` is free prose, persisted as the summary and displayed verbatim, and the only
  thing standing between it and an invented statistic was a `@Guide` sentence asking the model
  nicely: *"Use ONLY numbers you read from the tools."* A mistyped or hallucinated figure in that
  prose reached the user unchecked.

  Closed in the app's own idiom — **engines inform, agents decide**. `NumericFidelity` (pure,
  `Engine/`) compares every figure stated in the prose against the numbers in the `Verified basis`
  and returns the ones nothing supports, with a 5% tolerance so honest rounding ("about 12,000" for
  11,847) is never flagged. That fact is appended to the claim the skeptic panel already receives,
  and a seventh fixed lens rules on it. Deliberately not a drop: an unsupported figure may be a
  window reference, and that judgment is the agent's.

  Two corrections to it, both found by pressure-testing against what the system actually produces
  rather than fixtures written to match my own mental model. First, and worse: the check compared
  prose only against numbers parsed out of the `Verified basis` SUMMARY — but
  `VerifiedFact.verifiedBasis` prints "a ~48% shift over 7 days, about 6.1 standard deviations" and
  never renders the means, which are exactly what a trend finding's prose quotes. On the app's most
  common finding kind it would have condemned correct figures wholesale. Each persist path now
  passes the finding's ACTUAL computed values (`fact.recent`, `corr.partialR`, `shift.cvRatio`, …)
  alongside the basis. Second: the app converts metres to kilometres and 0–1 fractions to percent for display
  (`UnitKind.display`), so a tool hands the model `5200` while the verified basis prints `5.2 km`.
  The same quantity in two units. The first version flagged that as invented, which would have cried
  wolf on every distance and percentage metric — and a check that cries wolf is one the panel learns
  to ignore, leaving the app worse off than with no check. It now accepts a figure that matches a
  verified number under exactly the conversions the app itself performs, and nothing looser.

  The first attempt was just the lens — asking a skeptic to eyeball digits. That contradicts the
  premise the whole architecture rests on, that a small on-device model is good at judgment and bad
  at arithmetic, so the arithmetic moved to where the arithmetic belongs. The doc's original claim
  was amended in place rather than superseded by a later entry: for a safety property, a reader
  meets the overstatement first.
- **The wellness disclaimer is pinned to every interpreting screen.** "Informational and wellness
  only — not medical advice, diagnosis, or treatment" is the app's regulatory posture, and it is
  carried by `DisclaimerBar` on the four surfaces that show a health judgment: the feed, a finding's
  detail, the trends charts, and the agent's answers. A new screen, or a refactor of an existing
  one, could drop it silently. `ArchitectureInvariantsTests` now fails if any of the four loses it
  (verified against a removal). `SettingsView` is deliberately excluded and the test says so — it
  shows permissions, tracked metrics and the compute meter, never an interpretation; if it ever
  grows one it belongs on the list.
- **CI boots the simulator before testing it.** `xcodebuild test` will start installing onto a
  device that is still coming up and then fail the entire run with
  `FBSOpenApplicationErrorDomain 6` — "Application failed preflight checks (Busy)". That is a launch
  race, not a test failure, and it reproduced regularly on this machine while verifying today's
  work. The workflow now boots the resolved device and blocks on `simctl bootstatus -b` before
  running anything, which is the targeted fix; blanket-retrying the test step would have hidden real
  flakiness instead of removing an infrastructural one.
- **The hypothesis loop closes.** The journal recorded WHAT was established but never what kind of
  looking established it, so nothing in the system could learn that lead-lag sweeps keep paying off
  while (say) volatility sweeps never do — least of all the research director, whose entire job is
  deciding where to point the fleet next. A confirmation now carries the ANGLE that produced it, in
  the `reason` field that was empty for confirmations, and reaches the director through
  `researchJournal`. It costs one parameter: the lens was already threaded to the persist path for
  provenance, and `journalSteering` reads only rejections and retirements, so the signal cannot leak
  into the do-not-repeat list and teach the fleet to avoid its own successes — which the test pins
  explicitly.

**Open question (2026-08-02) — sleep day attribution**

Sleep is aggregated as a plain civil-day duration: each interval is clamped to the day, so a night
spanning midnight is **split** across two days. 23:00→07:00 yields 1h on the first day and 7h on the
second; the same eight hours starting at 01:00 land wholly on one. Both ingest paths
(`HealthStore.categoryDurationValues`, `HealthStore+Range.mergedDailyRollups`) do this identically,
so the data is consistent — this is not a bug in the sense of one path disagreeing with another.

It is, however, a measurement choice with consequences, and it was undocumented:

- A user's daily sleep series carries variation driven by **bedtime relative to midnight** rather
  than by how much they actually slept. Two identical eight-hour nights can appear as `8` or as
  `1 + 7` depending only on when they started.
- It contradicts how the app reasons about sleep. `Instructions.investigationLenses` includes
  "sleep and its downstream effects on **next-day** recovery and physiology", which presumes a night
  belongs to one day — and lead-lag correlations involving sleep are the premium finding type.
- The conventional alternative is to attribute a sleep session to the day it ENDS (the wake day), or
  to bucket on a 6pm–6pm window.

**Deliberately not changed.** Redefining what a health metric means is a product decision, not a
passing fix, and it would re-key every stored sleep rollup (the same clobber/migration treatment the
civil-day boundary move needed). The current behaviour is now documented at
`SleepAggregation` and pinned by a test, so whatever is decided is decided on purpose.

**Mitigated in the meantime by telling the agents.** The sleep lens previously asked for "downstream
effects on next-day recovery" while the investigator had no way to know a night is split across two
days — so a lag-1 result reads as a night→morning link when part of that night already sits inside
the same day's figure. The lens now states the attribution. That does not fix the data, and is not
a substitute for deciding the question; it just stops the fleet reasoning confidently from a premise
its own inputs do not support.
- **The numeric-truth source now reads chronologically too.** The earlier determinism fix covered
  the scan engines but missed `MetricStatsProvider.dailyValues`, which fetched a metric's rollups
  with no `sortBy`. `partition` preserves that unspecified order into its arrays and `mean` /
  `sampleStandardDeviation` sum in it, so identical data could produce last-ULP-different means,
  percent changes and z-scores — and those are precisely the figures persisted onto a finding and
  shown to the user, from the one source every trend statistic passes through. Now sorted by day in
  the fetch, which the database does for free. (`recentSeries` already sorted, for the charts;
  `dailySeries` builds a dictionary, so order there is immaterial.)
- **Backoff sleeps are bounded by the deadline, not just started before it.** `RateLimitBackoff`
  documented that it "counts its own sleeps against an optional wall-clock deadline", but only
  checked whether the deadline had already passed — so a window with 200ms left could start a
  full-second backoff and wake up over budget, spending the tail of an OS-granted background grant
  on waiting rather than reasoning. It now refuses a backoff that would overrun.
- **Audited clean, reported as such:** the five `ComparisonKey` partitions (correct anchoring on the
  last complete day, no overlap between recent and baseline slices), the correlation statistics
  (Fisher-z SE correctly losing a degree of freedom per covariate, `normalCDF` via `erfc`,
  Bartlett's `nEff` floored so autocorrelation can never inflate it), the Benjamini–Hochberg
  step-up (largest-k, reject-all-below), `SleepAggregation`'s interval merge, and
  `BackgroundScheduler`'s expiration handling (cancels and completes without awaiting, so the OS
  deadline holds). No changes needed in any of them.
- **The Neural Engine duty cycle was overstating itself, worst when it mattered most.** The meter
  that measures the app's entire purpose sampled `InferenceActivity.busySeconds` once a second and
  divided the delta by the SAMPLE COUNT — treating "one sample" as "one second". But
  `Task.sleep(for: .seconds(1))` guarantees a floor, not a period: under load the sampler drifts,
  and this app is designed to run the device hot. A real 1.5s interval reported 150% of the true
  duty cycle, clamped to a flat 100% — so the instrument would show a saturated engine while it
  actually idled a third of the time, precisely when someone would be watching it.

  Samples now carry a monotonic timestamp and the ratio divides by MEASURED elapsed time. The
  calculation is extracted as a pure `ResourceMonitor.dutyCycle` and pinned by `DutyCycleTests`,
  including the drift case that motivated it. `InferenceActivity` itself audited clean — the
  begin/end bookkeeping measures the union of busy stretches, which is the right semantics for a
  duty cycle.
- **…and the duty-cycle label no longer claims a minute it hasn't measured.** The row read "last
  minute" from the instant the meter appeared, while averaging over whatever few seconds of history
  it had. Small, but on the one screen whose entire job is honest measurement, and against the same
  rule the live feed follows — what you read is literally what is happening. It now names the real
  window ("last 20s") until the window has genuinely filled. Audited clean alongside it: the
  per-core tick deltas (wrapping subtraction, first-sample guard), `phys_footprint` for memory, and
  "% of one core" correctly matching what `sampleAppCPU` actually returns.
- **The first-launch backfill no longer blocks reasoning — the last multi-minute ANE idle.**
  `runDeepAnalysis` ran `ingestAll` then `deepenHistory` then discovery, in series. The incremental
  ingest genuinely gates pass one (it needs today's rollups), but *deepening* backfills OLDER
  history — minutes of pure I/O on a first run — and nothing about reasoning over what already
  exists has to wait for it; the next substrate refresh folds the recovered years in. It now runs
  underneath the reasoning, joined before the run returns so the gate is never released with a
  backfill still writing, and with cancellation forwarded (`Task.value` ignores the awaiting task's
  own cancellation — the same trap that made Stop hang at the refresh boundary).
- **`AppModel` split at a real seam.** It hit the 500-line limit three times today; rather than
  shave a comment again, the drill-down, the progress narration and the Ask entry point moved to
  `AppModel+ResearchProgram.swift` alongside the supervisor state machine. Four members widened from
  `private` to internal to cross the file boundary, noted at their declarations.
- **The prefetched collection is now JOINED on the way out, not merely cancelled.** Found by
  checking one of this file's own promises — `narrate`'s "the run gate is released only when the
  work has genuinely stopped, so a catch-up can never overlap a still-winding-down deep run".
  The prefetch's `defer` cancelled the task and returned immediately, but a cancelled ingest keeps
  writing until it reaches its next suspension point, so the gate could be released with it still in
  flight. The loop has a single exit, so it now cancels and awaits there (a `defer` could not have
  awaited anyway). Writes were never at risk — `StoreWriter` serialises them — but the documented
  invariant was, and it is the invariant everything else assumes.
- **`ConnectionMap` no longer claims to show "every significant association".** An edge is an active
  `CorrelationLog`: a pair an investigator proposed, all three panels cleared, and the curator kept.
  The engine judges far more pairs than reach the feed, and since the FDR floor stopped being a
  drop-gate a surfaced link need not be statistically significant at all. It maps what the app
  decided was worth telling, not the correlation structure of the data.

**Sweep (2026-08-02) — absolute claims in doc comments**

Prose drifting from code has been the most productive defect class this session, so the 229
doc-comment claims containing "every", "always" or "never" were swept and the load-bearing ones
checked against the code. Two were stale, both from changes made earlier the same day:

- `setHighlights` claimed the "Worth your attention" section "can never accumulate stale
  promotions". True of every curation round that RUNS — but `curate` returns early on a roster of
  one and falls back to the deterministic trim when the model is unavailable, and neither calls it,
  so the last decision an agent did make stands. That is the better behaviour (clearing would make
  highlights flap whenever Apple Intelligence is briefly away) — the doc now says so instead of
  promising more.
- `activeProgress` was "the one switch every screen uses to show live activity". Adding narration to
  the Ask tab made that false: a question narrates through `askProgress`, deliberately separate so
  the Insights feed does not claim the research program is running whenever someone types in chat.

Everything else checked held, including the ones most worth doubting: no rotating filler in the
progress feed, the safety panel failing closed, curation running at both refresh and run end, and
the background refresh producing no findings off-power.
- **The commit session's instruction now knows it is the second pass.** Splitting the investigator
  into explore-then-commit left `Instructions.investigator` still saying "start with metricsOverview
  and correlationScan, dig with metricStats and patternScan" — telling the pass that already HAS the
  measurements to go and take them again. The per-pass prompt mentioned the supplied readings, but
  the instruction carries more weight than the prompt, so half the point of buying a second window
  was at risk of being spent re-discovering the first one's work. Rewritten to "verify what you lean
  on, then spend your calls EXTENDING them" — and rewritten at the same length, because this
  instruction sits inside the prefix `TokenHarnessTests` pins under half the context window.
- **The Ask path had the same stale instruction, and no budget test.** `Instructions.answerer` still
  said "decide what to look up yourself: start broad with metricsOverview if unsure" after the Q&A
  path gained a gather pass — telling the session that already holds the readings to go and take
  them again. Now "verify what you lean on, then look up only what is still missing". Found by
  re-reading every prompt against the code rather than only the one I had just changed.

  It was also the only role with NO prefix test, despite carrying the widest tool surface in the app
  (the investigator's six plus `insightSearch`) — the session most likely to blow the 4k window
  unnoticed. `TokenHarnessTests` now pins it like the rest.

  General rule this session earned: in this app the prompts ARE behaviour, so a stale instruction is
  a stale implementation that no compiler will catch. `Instructions.swift` belongs in the same
  re-read as the doc comments whenever the agent loop changes.
- **Delete-all now clears the research journal — it was silently haunting the clean slate.** The
  Settings footer promises delete-all removes "every insight and connection Verdant has surfaced,
  and its memory of what it's already shown you", and that "Verdant can rediscover findings over
  time". It deleted `InsightLog` and `CorrelationLog` and left `ResearchJournalEntry` untouched —
  which broke that promise twice. The journal IS the memory of what was shown (every confirmed
  finding is a row), and `journalSteering` pushes its rejections and retirements at every
  investigator as "do NOT re-propose", so the fleet went on avoiding exactly the ground the user had
  just asked to clear. Rediscovery was not merely unhelped, it was suppressed. The civil-day
  migration got the same fix, and for the sharper reason: its journal entries would have blocked
  regeneration of the corrected findings the migration exists to produce.
- **The rest of the privacy sentence is enforced too.** Settings tells the user findings are
  "encrypted, never copied to iCloud or backups". `ZeroCloudTests` covered the iCloud half; the
  encryption and backup-exclusion half rested on code nothing checked. Now pinned (and verified to
  fail against a flipped `isExcludedFromBackup`), including that both protections are applied over
  the WAL/SHM sidecar set rather than the main store file alone — the sidecars are created lazily on
  first write, so protecting only the file named at container-init would leave real health-derived
  content exposed. All three Privacy claims audited and found true, and all three now have a test
  behind them rather than a comment.
- **"That's a clean bill" is no longer claimed after a degraded pass.** The closing note had two
  states: wholly-failed inference, or everything else. So a run where a quarter of the fleet never
  answered — rate-limited, contended — read identically to a thorough pass that genuinely found
  nothing: *"Nothing new rose above the noise this pass — that's a clean bill, not an empty one."*
  The app's own stated rule is that telling the user their data is clean when nothing was reasoned
  is its worst failure; a partially-reasoned pass is a quieter version of exactly that.
  `ProgressReporter.inferenceWasDegraded` (>25% of calls lost, but not all) now earns its own honest
  note. The threshold is pinned by test at both ends: one miss in twenty-one is noise, four in ten
  is not, and a wholly-failed run stays its own case.
- **Two banner promises became true today rather than being reworded.** "Preparing on-device
  intelligence — your findings will appear once it's ready" and "Turn it on in Settings … and
  they'll start appearing" were both FALSE before the research-program supervisor landed: the
  program died on a model-unavailable start and nothing restarted it, so findings would not appear
  until the user happened to background and foreground the app. Audited as part of reading the
  user-facing copy as a specification; the fix had already made them honest.
- **The Ask tab stopped steering people at the one question the data answers worst.** Its example
  prompts led with "Does my sleep affect my resting heart rate the next day?" — precisely the
  sleep→next-day lag that the civil-day attribution contaminates (a night crossing midnight is split
  across two days). The examples shape what people ask, so while that question is open the lead
  example is now "What moves together with my resting heart rate?", with a note to restore the sleep
  one once attribution is settled. The Ask path is also the one place with no sleep caveat: the
  investigation lens carries it, `Instructions.answerer` does not, and its prefix is now budget-pinned
  so it cannot simply be added to.
- **`ChatView`'s own header described a deleted architecture** — "a fresh Router + Answerer session",
  when the Router went in the agent inversion and Q&A now runs gather-then-answer. Corrected, and
  while there: made explicit that not replaying the transcript is also why each question is answered
  without conversational memory. That is a real product limitation, not just a context-window virtue,
  and the comment previously only mentioned the flattering half.
- **Audited clean:** the finding-detail "what this means" copy for all five kinds. "Stayed moved" for
  a regime shift is well-founded (`minSegmentDays = 21` on both sides of the change point), and
  "unlikely to be noise" for a trend still holds — `buildFact` requires a confident stat and the
  skeptic panel explicitly challenges coincidence.

**Open question (2026-08-02) — what "weekend" means**

`Calendar.civil` sets no locale, so `isDateInWeekend` resolves to Saturday/Sunday for every user.
Verified rather than assumed: the same calendar with `ar_SA` returns Friday/Saturday. This affects
the `weekdayVsWeekend` comparison and `DayFilter.weekdays`/`.weekends`, which agents reach through
`analyze`.

It is deterministic across devices, which is the point of the fixed civil calendar — but it is
simply wrong for a user in a Friday/Saturday-weekend region, where the app would label their working
week "the weekend" and hand the agents a comparison whose premise is inverted.

**Deliberately not changed**, for the same reason as sleep attribution: what "weekend" means is a
product decision. `Locale.current` would respect the user's region but makes the split move when
they travel or change region — a tension with the fixed-calendar design, though a weaker one than
for day boundaries, since weekend membership re-keys no stored data. That makes this a cheap change
whenever it is decided, unlike the sleep question. Documented at `Calendar.civil`.
- **Two load-bearing units had no tests at all; they do now.** `concurrentMap` is the fan-out under
  EVERY agent panel — the investigator fleet, the safety reviewers, the skeptics, the replication
  analysts and the persist loop all run through it — and nothing exercised it. A dropped result
  there would silently shrink a panel and shift its majority threshold, with no other test noticing.
  Pinned: nothing is dropped, the concurrency bound holds (and genuinely overlaps, so the bound
  means something), a limit of 1 is strictly serial as the panel design assumes, and empty / zero-
  limit / fewer-items-than-workers all complete rather than hanging.

  `InferenceActivity` is the bookkeeping the entire ANE story rests on — `busySeconds` is what the
  duty cycle differences, `totalCalls` is the odometer on the meter. Pinned: busy time accumulates
  and is monotonic, idle time does not accumulate, a read MID-generation includes the running
  stretch (otherwise sampling during a long generation would read as idle — backwards for the
  metric's purpose), overlapping generations measure wall-clock rather than summed durations (a sum
  would let the ratio exceed 1 and mean nothing), and an unmatched `end` cannot drive the counter
  negative and strand the meter on "generating". Tests use their own instance so they neither depend
  on nor disturb the process-wide counter.
- **`toolRounded` is now total.** It sits on the boundary where every number enters the model's
  transcript — correlation coefficients and p-values, metric means, percent changes, z-scores,
  custom query results — and for a subnormal input the scale factor overflowed, making the result
  **NaN**: a statistic handed to an agent as "not a number". Nothing reaches that range today (every
  value is a health measurement, ratio, z-score or percentage, and the one candidate that could
  underflow — a p-value from an extreme correlation — collapses to exactly 0.0 long before going
  subnormal), but this is the wrong place to depend on that.

  Worth recording how it was fixed, because the first attempt was wrong: guarding `scale` and
  `self * scale` still let `greatestFiniteMagnitude` through, where the multiply stays finite and
  the DIVISION overflows. The test caught it. It now checks the actual result and returns the value
  untouched if rounding would leave the finite range — anything in that territory is already far
  past four significant digits of meaning. `ToolPrecisionTests` pins the property that matters: no
  finite input may ever produce a non-finite figure.
- **A perfectly steady metric was being reported as the app's most significant volatility shift.**
  `VolatilityScan` guarded a zero baseline SD but not a zero RECENT SD. A flat recent window — a
  weight logged identically each day, a device reporting a constant — gives a CV ratio of exactly 0,
  and both the scan's statistic and its ranking are `log(cvRatio)`. log(0) is −infinity, so `seZ`
  came out INFINITE and `abs(log(ratio))` sorted that metric FIRST: the steadiest possible signal
  presented to the agents as the biggest volatility change in the data, carrying a non-finite
  uncertainty statistic, and crowding genuine shifts out of `patternScan`'s per-kind cap.

  `recentSD > 0` now sits with the other computability guards, where it always belonged. A metric
  going flat is a real event, but it is a regime or level story — `analyze` reports stdDev directly —
  not a log-ratio one. Found by carrying the property lens from `toolRounded` to the next place a
  logarithm meets a possible zero, and pinned by a test asserting every emitted candidate carries
  finite numbers.
- **A net for the whole degenerate-input class** (`EngineFinitenessTests`). The volatility bug above
  was one instance of a general risk: the engines are well covered for ordinary data, and the gaps
  live at the edges — a weight logged identically for a month, a sensor stuck on a constant, a metric
  that is zero every day. Real health data does that. One property, asserted across eight degenerate
  shapes: **no number an agent can read may ever be infinite or NaN**, because the model will quote
  it. Covers `VolatilityScan`, `MilestoneScan`, `RegimeShiftScan`, `UnusualDaysScan`, `CoverageScan`,
  `CorrelationEngine`, and every `AnalysisStatistic` through `AnalysisQueryEngine` over four windows,
  each also re-checked through `toolRounded` at the tool boundary. Verified to fail by reverting the
  `recentSD > 0` guard — it names the shape ("frozen recent, varying baseline") and the field.

  A sweep of the remaining engines while writing it found every other division and logarithm already
  guarded: `MilestoneScan` handles a zero prior extreme, `RegimeShiftScan` requires positive pooled
  variance, `residualize` requires positive covariate variance, `pearson` a positive denominator,
  `nEff` floors its autocorrelations, and `CoverageScan.density` guards a zero span. Volatility was
  the single gap.
- **Tool OUTPUT caps are now pinned, not just tool schema sizes.** `TokenHarnessTests` measures each
  role's prefix; nothing measured what the tools actually return. Those caps are load-bearing rather
  than cosmetic — a maxed-out `patternScan` was ~1,400 tokens of a 4,096-token window, and the field
  overflows this document records ("singleExtend errors") trace to exactly that. Blowing a cap does
  not produce a wrong number; it kills an investigator mid-exploration.

  `ToolOutputCapTests` drives every capped tool against a deliberately rich substrate (twelve
  metrics, 200 days, a wild day each) so truncation is genuinely exercised, with hostile arguments
  including values the `.range` guides call impossible — a guide constrains generation, it is not a
  promise about what reaches the function. Also pins two shape properties worth keeping: `eventWindow`
  returns one row per metric, and `unusualDays` never repeats a day within a page for any offset,
  including negative. Verified to fail by removing `patternScan`'s upper clamp, and it names the
  argument and the kind.
- **A model-written string reached a prompt unclamped — the drill-down title.** Every lens,
  challenge and provenance line handed to an agent is assembled from strings a *model* wrote, and
  none of them has a schema-side length bound: a `@Guide` reading "a single sentence" or "a 3-6 word
  headline" shapes generation without promising anything about what comes back. The codebase already
  treats this as a standing hazard and clamps at nearly every site — `provenanceLine` (90/160),
  `leadLenses` (200/40), `directorLenses` (200), `composedChallenges` (220), the feed digest (50).

  `focusedLenses` was the exception. It interpolated `focus.title` — the stored, model-written
  `oneTapTitle` — straight into a lens, on the user-triggered drill-down path. Measured with an
  11,400-character runaway title, the resulting lens ran to 11,551 characters: roughly 2,900 tokens
  of a 4,096-token window from a single lens string, which is a dead session rather than a wrong
  number.

  Fixed at the type, not the use site: `InvestigationFocus.init` clamps to `maxTitleLength` (80,
  matching `RunLedger`'s title clamp), covering all four construction sites — two in the UI, two in
  `activeInvestigationFoci` — and any future one. `PromptClampTests` is the net for the whole class,
  driving a runaway string through every prompt-composing helper, and additionally pins that clamping
  never *empties* a lens: a blank lens spends a whole agent session on no question, which on this
  device costs exactly what a real one costs.
- **Cross-run learning about where to look was positive-only; `barren` closes it.** The research
  journal recorded `confirmed`, `rejected` and `retired` — every one an outcome of something that was
  actually *proposed*. An angle a scout invented, that the fleet genuinely chased, and that produced
  no proposal at all left no trace outside the run's in-memory `RunLedger`, which dies with the run.
  The next run's scouts could re-propose it indefinitely with no way to know, and each re-chase is a
  pass spent re-covering ground instead of going deeper.

  `runInvestigation` now carries each lens through even when it yields nothing, and journals the
  barren ones. Two distinctions make the signal worth having:

  - **Chased-and-empty is not the same as never-chased.** A session that never rendered — rate
    limited, model blip, deadline — says nothing about the angle. `llm`'s optional already carried
    that difference; the loop was collapsing it with `?? []`. Conflating them would steer the director
    away from ground nobody has examined.
  - **Only INVENTED angles are learnable.** Scout leads and the director's composed angles are new
    each pass, so their yield is information. The fixed thematic rotation comes back empty constantly
    and by design; journaling it would bury the signal in its own noise.

  It is deliberately NOT another prohibition. `journalSteering`'s do-not-repeat list stays
  rejected/retired; barren angles reach the research director as a fact to weigh ("not a ban — judge
  whether new data changes it") and are readable on demand through `researchJournal`. Barren ground
  bears fruit once more data lands, and only an agent reading the run's state can judge when — which
  is the standing direction: facts to agents, decisions by agents. Capped at
  `maxBarrenPerPass` (4), because the journal prunes to a bounded row count globally and a dry pass
  of two dozen investigators could otherwise evict the history that actually steers the fleet.

  `BarrenAngleTests` pins both halves. Verified to fail by collapsing the blip/empty distinction —
  the "never rendered" test is the one that catches it.
- **`Instructions.swift` went stale the moment the loop changed — again.** Adding the barren briefing
  line left the director's own instructions enumerating four kinds of state when the briefing now
  carries five, and — the part that mattered — saying nothing about how to read the new one. A
  director told only "Chased with no yield: …" alongside "Prior runs ruled out: …" will read the two
  the same way, which collapses precisely the distinction the feature exists to make. The prompt now
  says it outright: *"Angles chased with no yield are evidence, not a ban — re-try one when new data
  could change it."* This file is executable; a stale prompt is a stale implementation no compiler
  catches.

  Fitting it also settled a standing question about `TokenHarnessTests`. The director test asserts on
  real token counts when the tokenizer is available and falls back to `count < 1200` when it is not,
  and it was not obvious which branch actually runs. Padding the prompt by 360 characters (past 1200)
  still passed, so the tokenizer path is the live one; padding it by ~16,000 characters failed with
  `prefix → 3147 < 1365`, so the harness genuinely bites rather than being vacuous. The real director
  prefix is roughly a third of its allowance. The prompt was nonetheless compressed to stay under
  1200 characters as well, so the fallback stays honest on a device where the tokenizer is missing —
  and a tighter prompt leaves more of every director session for the briefing itself.
- **Closed vocabularies are now derived, not re-typed.** Every vocabulary the model may emit exists
  twice by nature: as the Swift type the code switches on, and as the `.anyOf` list in the
  guided-generation schema. Most already shared one expression (`MetricKey.allRawValues`,
  `AnalysisStatistic.allRawValues`, `ComparisonKey.allRawValues`) and so could not disagree. Three
  were typed out by hand, and each had a distinct silent failure waiting:

  - `researchJournal`'s kinds — add a journal kind, forget the guide, and the director can never ask
    for that history. Nothing fails; the record is simply invisible. (This one had just been
    hand-edited to add `barren`.)
  - `PassPlan.strategy` — the loop switches exhaustively over `PassStrategy`, and the comment beside
    it said it "mirrors" the schema. A mirror maintained by proofreading. A strategy the schema
    offered but the switch did not handle would route to the fallback and read, from outside, as a
    director changing its mind for no reason.
  - `patternScan`'s kinds — the only one that could disagree in BOTH directions, because the schema
    list and the `kind` strings the tool constructs were separate literals in the same file.

  All three now derive from `CaseIterable` types (`ResearchJournalKind`, `PassStrategy`, and a new
  `PatternKind` that also replaces the constructed literals). `ClosedVocabularyTests` pins the
  agreement and adds the structural rule that keeps it: no `.anyOf` may be a hand-written string
  literal. Verified to fail by re-inlining `patternScan`'s list and emitting a `"regimeShift"` — the
  scanner names the file and the line, and the round-trip check names the bad value.

  This is the mechanically checkable slice of a wider gap. Prompt-carried semantics — what
  `Instructions.swift` tells an agent about the facts it is handed — remain uncovered by any test,
  and are where the previous two entries each found a defect.
- **A prompt names its tools by hand — and two prompts named tools their session did not have.**
  `Instructions.explorer` says "use eventWindow"; `Instructions.answerer` lists all seven of its own;
  the scout angles name `coverage`. Nothing in the compiler connects those sentences to the array a
  session is constructed with. Two had drifted:

  - **Ask's gather pass.** `Instructions.explorer` is shared by the investigator's explore pass and
    by Ask's gather pass, and they carried DIFFERENT tools. The gather pass had `insightSearch` and
    no `EventWindowTool`, so it was instructed to reach for `eventWindow` in exactly the "when a day
    looks strange" case the sentence describes — burning one of only FOUR permitted calls, on the
    user-facing path, with nothing failing loudly.
  - **The scout.** A scout angle read "…worth an `analyze` hypothesis", describing what an
    INVESTIGATOR would later do. The scout carries no `analyze` and has three calls to spend, and a
    tool name in reach of a small model is an invitation to try it. Reworded to name the hypothesis
    rather than the instrument.

  The first fix was initially wrong in an instructive way: handing the gather pass `eventWindow` on
  top of `insightSearch` measured **2,118 tokens against the 2,048** the harness allows — the new
  budget test caught it on its first run. The right split is by JOB. The gather pass MEASURES, so it
  carries exactly `explorerTools` (same prompt, same tools, so the shared instructions are true by
  construction rather than by coincidence); `insightSearch` searches past findings, which is context
  for composing an answer, and stays with the answering pass that already names it.

  `Subagents+Tools.swift` makes each session's surface a named set — the checkable form of what were
  inline literals duplicated between `investigate` and `answer`. `SessionToolsTests` pins that no
  prompt names a tool its session lacks, that the scan is non-vacuous (each prompt really does name
  its own tools), and that the two sessions sharing `Instructions.explorer` carry identical sets.
  Verified to fail by reverting the gather pass to `investigatorTools`.
- **The token harness was measuring a replica, not the app.** Each prefix test built its own copy of
  the session's tool array — a THIRD hand-maintained transcription of a set already written twice —
  so a tool added to a shipped session would not have moved the number the harness checks. It could
  pass while the app carried something else entirely: the same drift class as the prompts, one level
  up, in the test meant to catch it.

  With the sets extracted into `Subagents+Tools.swift`, every prefix test now measures the real
  factory. Verified by adding three heavy `metricStats` schemas to `investigatorTools`: before, that
  edit was invisible to the harness; now the investigator test fails at `3709 < 2048` and the
  explorer test fails with it, because `explorerTools` composes the same set.

  `SessionToolsTests` additionally pins each role's surface BY NAME. That is a snapshot, which is the
  right shape here: these sets are deliberate, documented decisions (the scout carries neither
  `analyze` nor `metricStats` because a surveyor reads the map; the replicator carries two so
  re-tests get headroom; the commit pass omits `eventWindow` because its prefix already sits near the
  bound), and the budget tests would only notice a change large enough to blow a budget — not a
  quiet swap.
- **Every tool bound was written three times.** A cap like `patternScan`'s 3-per-kind appeared in the
  guide's prose ("(1-3)"), in the `.range(1...3)`, and again in the clamp — three transcriptions of
  one number, where a change to any one leaves the model reading a contradiction. `@Guide` turns out
  to accept both a static constant and string interpolation, so each tool now states its cap ONCE
  (`PatternScanTool.maxPerKind`, `CorrelationScanTool.maxRows`, `CoverageTool.maxMetrics`,
  `UnusualDaysTool.maxDays`, `EventWindowTool.maxMetrics`/`maxRadius`, `ResearchJournalTool.maxLines`)
  and `ToolOutputCapTests` asserts against those constants rather than re-typing them a fourth time.
  A grep for a literal bound beside a `.range` now returns nothing.

  Two things the sweep turned up on the way:

  - `researchJournal` was the one capped tool with no coverage in `ToolOutputCapTests`. It does clamp
    correctly; it is now pinned, along with its refusal of an unrecognized kind. Verified to fail by
    removing the clamp (30 rows returned against a cap of 8).
  - `analyze`'s `lag` is the ONLY `calendar.date(byAdding:)` offset in the app whose value comes from
    the model rather than a constant, and it was force-unwrapped. Probed with `-3`, `500`, `Int.max`
    and `Int.min` across every statistic and degenerate shape: Foundation absorbs all of them, no
    crash, every result finite. That is undocumented behaviour to be force-unwrapping on a shipping
    path, so the unwrap is now a `guard … else { continue }` — no target day simply means no pair —
    and the hostile lags stay in `EngineFinitenessTests` as the net.

  Also confirmed genuinely derived, not transcribed: `EnhancementPolicy.maxCandidates`,
  `DeepAnalysisPolicy.maxLeadsPerScout` and `Orchestrator.maxHighlights` all feed their `.count`
  guides directly, so the "cannot drift apart silently" claim beside `maxHighlights` is true.
- **A new finding class: annual rhythm (`SeasonalityScan`, surfaced as `patternScan`'s `seasonal`).**
  Nothing in the app could see a metric that runs high every winter. `analyze`'s `dayFilter` reaches
  weekday shape but not month-of-year; the `yearOverYear` comparison measures a LEVEL against the
  same window last year, not a repeating cycle; volatility, regime and milestone all compare one
  stretch against another. With a few years of history "your resting heart rate climbs every winter
  and settles every spring" is exactly the app's premium territory, and it was structurally
  unreachable.

  The engine is built around one confusion — **a trend is not a season** — and both of its defences
  were put there by a test that failed:

  - De-trending against each year's MEAN is not enough. A steady climb leaves January below its
    year's average and December above it in *every* year, so all years "agree" on a rhythm that does
    not exist: a pure straight line scored a **1.52 SD** seasonal peak. The fix is to remove a
    per-year least-squares LINE, which is right because a genuine annual cycle returns to where it
    started each year and so has almost no linear component within one, while a multi-year drift is
    almost entirely linear within one.
  - `scale > 0` is not enough either — the second time that exact insufficiency has bitten here
    (`VolatilityScan`'s `recentSD > 0` was the first). When the per-year line explains essentially
    all the variance, the residuals are floating-point noise near 1e-14, and dividing noise by noise
    gave the same straight line a **0.71 SD** peak. The floor is now relative to the data's own
    magnitude.

  `verifiedBasis` states the swing in SDs *and* in the metric's own units, because an effect measured
  only against a nearly-flat residual can read as enormous while being physically nothing — a "2.3 SD
  winter swing" that amounts to 0.002 kg — and the agent cannot tell without the raw figure. It also
  always states `yearsAgreeing` of `yearsObserved`: one memorable January is not a season, and that
  is carried as a number rather than gated on, like every other scan.

  **Adding a fourth kind did not grow the response.** `patternScan`'s per-kind cap alone used to
  bound the whole reply because the kind count was fixed; a fourth would have taken the worst case
  from 9 rows to 12 — a third more of the single biggest contributor to the overflows this document
  records. There is now a `maxTotal` of 9 filled ROUND-ROBIN across kinds, so a new detector buys
  diversity inside the same budget, and flat truncation cannot starve `seasonal` (last in the enum
  and the rarest to be computable) out of every response. Even so, the investigator prefix measured
  at exactly 2,048 against a 2,048 bound once the vocabulary and description grew — the tool's prose
  was tightened rather than the bound relaxed.

  Verified by injecting mean-only de-trending: both trend tests fail (1.52 SD and 1.46 SD).
- **Wiring the seasonal detector into the fleet, and the drift class it opened.** A detector nothing
  points the fleet at is dead code, so `Instructions.investigator` now names the kind in its DO-surface
  list and there is a dedicated `ANNUAL RHYTHMS` lens. The lens is its own angle rather than a clause
  on the multi-year-drift one on purpose: a rhythm and a drift are opposite shapes, `seasonal` is the
  only detector that can tell them apart, and a lens asking for both would invite exactly the
  confusion the engine removes a per-year trend line to prevent. It also tells the investigator what
  to weigh — how many years agreed, and the swing in real units rather than only in SDs.

  The prefix had no room (it measured at the 2,048 bound), so the addition paid for itself: the
  prompt stated the no-invented-numbers rule TWICE ("ALWAYS pull the real numbers from a tool" and
  "NEVER state a number you did not get from a tool"), and cutting the duplicate more than covered
  the new clause.

  Naming a kind in prose is a new instance of an old class — the same failure as naming a tool a
  session lacks, since an agent told to hunt a kind `patternScan` never emits spends a call finding
  nothing. `ClosedVocabularyTests` now scans every prompt and lens for `patternScan <word>` and
  requires the word to be a real `PatternKind`. Verified to fail by changing the lens to say
  "patternScan cyclical".
- **The detector was only half the finding: completing the seasonal chain.** `patternScan seasonal`
  gave the fleet something new to SEE, but carrying a finding from proposal to card runs through five
  separate hand-written correspondences — an `InsightKind` to be proposed AS, a persist route that
  resolves numbers from the matching scan, a sentinel `comparison` so novelty doesn't collide with
  unrelated findings, card copy, and a chart span. Volatility, milestone and regimeShift each have
  all five. `seasonal` had none, and a missing case does not fail — it inherits `default`.

  That default is the ANOMALY treatment, so an annual rhythm would have been: proposed as `trend`
  (the only kind available), persisted with recent-vs-baseline numbers that answer a different
  question than the prose, titled "Insight", explained to the user as "a change that stood out from
  its usual day-to-day range", and charted over 30 days — every one of them false for a claim about
  January. The numbers would have been real, which is the dangerous part: the anti-hallucination
  boundary guarantees a number came from an engine, not that it supports the sentence beside it.

  All five are now written. Two details worth keeping:

  - `verifiedRecent`/`verifiedBaseline` hold the peak and opposite months' effects in SDs, and the
    card deliberately does NOT render them through `MetricFormatting` — "+1.2 bpm" for a standardised
    score is meaningless. `verifiedPctChange` carries the swing in the metric's OWN units, which is
    the figure a person can actually judge.
  - The sparkline spans the years the claim is about rather than the default 30 days, or the chart
    would show none of what the card describes.

  `SeasonalFindingTests` pins the correspondence for EVERY `PatternKind`, not just this one, so the
  next detector cannot repeat it. Verified to fail by removing `seasonal` from
  `investigatorFacingRawValues`.
- **`default` over a closed domain enum is the bug, not the safety net.** The seasonal chain was
  missing at four separate `switch insight.insightKind` sites — navigation title, "what this is",
  "how Verdant found this", and the sparkline span — and each ended in `default`. That default is not
  neutral: it is the ANOMALY presentation. A new kind therefore inherited four user-facing statements
  that were all false for it, with no test failure and no compiler warning, because the failure mode
  is *unwritten code* — which no test can see.

  `FindingPresentation` now decides all of it in ONE exhaustive switch, and the numbers line in
  `Components` (which claims what a specific set of stored fields MEANS, so a fallthrough would print
  real figures under a false label) is exhaustive too. Every case is listed explicitly, including
  `redFlag` — a reserved raw value the app no longer produces — and `correlation`, which renders as
  its own card and never reaches here. Naming them is the point: the exhaustiveness IS the protection.

  Verified the only way a compile-time guard can be: adding a hypothetical `weeklyRhythm` case fails
  the build at `FindingPresentation.swift:51`, and once that switch is satisfied it fails again at
  `Components.swift:63`. Both sites are independently protected, so the next kind cannot be added
  without deciding what the user is told about it.
- **Sweeping the remaining `default`s over closed domain enums.** Having converted the finding-card
  presentation to exhaustive switches, the same question was worth asking everywhere: where else does
  a case nobody wrote yet inherit an answer that is wrong rather than absent? Four real ones, each a
  different flavour of silent:

  - **`persistProposal`'s router** — the same bug that had just been fixed for `seasonal`, still open
    for the next detector. It decides which SCAN a finding's numbers come from, so a fallthrough
    persists real figures answering a different question than the finding's own prose. The
    anti-hallucination boundary does not catch this: the numbers ARE from an engine.
  - **`recentPriorDescriptor`'s comparison lookup** — each pattern kind stores under its own sentinel
    comparison, so a kind falling through looks itself up under an empty `ComparisonKey`, finds no
    prior, and SKIPS THE NOVELTY JUDGE. Nothing fails; the same finding is just free to resurface.
  - **`DayFilter.allows`** — a new case (a locale-aware weekend, which the open weekend question
    would need) would have compared against a weekday number of 0 and excluded every day. This file
    has already shipped the mirror-image bug once: `correlate` ignored `dayFilter` while still
    labelling its answer "weekends only".
  - **`UnitKind.display`** — the nastiest shape available in this app. A unit needing conversion but
    inheriting "no conversion" shows the canonical value under the NEW unit's label: metres per
    second presented as miles per hour, with nothing failing anywhere.

  Left alone deliberately: `default` over `ScenePhase` (an Apple enum that genuinely may grow),
  `isContextFailure`'s fail-safe `false`, and the two `switch` statements over Double RANGES
  (`MaterialityRules.magnitude`, `CorrelationStrength.word`), where a default is required for
  exhaustiveness and carries no such risk.

  The property to keep: a `default` is right when the cases are open (someone else's enum, a
  continuous range) and wrong when they are ours and closed. Adding a hypothetical `InsightKind`
  case now fails the build; so does adding a `DayFilter` one, at both its label and its predicate.
- **The sleep caveat the agent reads was itself inaccurate.** Two places in the repo described sleep
  attribution and they did not agree. `HealthStore.dailyValues` had it right — the window is fixed
  UTC, so "a given night is attributed largely to ONE civil day rather than split at local midnight".
  The investigator's sleep lens, which is the description that actually reaches the fleet, said "a
  night crossing midnight is split across two days".

  That is only true near UTC. `Calendar.civil` is pinned to UTC (deliberately — a stable boundary is
  what stops a traveller double-counting a physical day), so the split point falls at a local hour
  that varies: around 4-5pm for a US-Pacific user, whose night therefore lands WHOLLY on the day they
  woke; mid-morning for a user in Japan, whose night lands wholly on the day they fell asleep. Only
  near UTC is a night actually divided. Telling the fleet "it is split" makes it discount a genuine
  one-day lead-lag link in two of those three cases — and sleep lead-lag is the app's premium finding
  type, so the caveat was costing exactly the findings it was meant to protect.

  The lens and the Ask tab's comment now state the real behaviour. This changes no semantics: the
  ATTRIBUTION question is still the owner's open product decision, and nothing about the UTC boundary
  moved. What changed is that the description matches the code.
- **The corrected sleep caveat was accurate but useless; it is now a fact.** Saying attribution
  "depends on your time zone" is true and unactionable — the fleet cannot weigh a one-day lead-lag
  result against an unknown. The offset is something the device knows, so
  `Calendar.civilDayBoundary(in:)` turns it into a sentence the investigator can act on: *"the day
  boundary falls at 16:00 local time, and a full night therefore lands wholly on the day the user
  WOKE."*

  For most users that is the good news the old caveat was hiding. West of UTC the boundary sits in
  the late afternoon, so a night completes inside ONE civil day and is attributed to the wake day —
  the conventional attribution, needing no discount at all. East of UTC it lands wholly on the
  sleep-onset day. Only at (or very near) UTC is a night genuinely divided. The blanket "it is split"
  was suppressing the app's premium finding type for nearly everyone.

  This is facts-to-agents, not a decision: the helper states where the boundary is and the
  investigator judges what that means. No semantics moved, and the attribution question remains the
  owner's.

  `CivilDayBoundaryTests` covers all three regimes, the half- and quarter-hour zones that really
  exist (India, Nepal, Chatham), and that the sentence is never half-formed. Verified by replacing
  the modulo normalisation with a naive `offset % 86400`: it yields "the day boundary falls at -8:00
  local time … the day the user FELL ASLEEP" — a malformed clock AND the opposite conclusion, for
  every user in the Americas.
- **The UTC day boundary is now mechanically enforced.** Working on the sleep caveat surfaced how
  much rests on `Calendar.civil` and how invisible a breach would be. `startOfDay` on a LOCAL
  calendar returns an instant that moves when the user travels, so the same physical day re-keys to a
  second `MetricRollup` row and every statistic downstream double-counts it — a wrong number behind
  every finding, with nothing failing anywhere. Worse, no ordinary test can catch it: **CI runs in
  UTC, where local and civil agree exactly.** Every timezone-dependent bug in this app is invisible
  to the suite by construction.

  An audit found the rule already held — every day attribution (ingest keys, read bucketing,
  comparison windows, detector arithmetic, the charts) goes through `Calendar.civil`, and every
  `Calendar.current` use is a wall-clock freshness cutoff, exactly as `CivilCalendar` documents. So
  the value here is not a fix but a latch: `ArchitectureInvariantsTests` now fails on a local
  `startOfDay` anywhere, and on any `Calendar(identifier:)` outside `CivilCalendar` (a fresh calendar
  carries the device time zone — the same bug in different clothes). A companion test asserts the
  civil calendar really is UTC, since the scan is pointless if that ever changes.

  Verified by pointing one line of `Ingestor` at `Calendar.current.startOfDay`: the scan names the
  file and the line.
- **Agent-facing numbers were locale-formatted, and on a German device the model read them 1000×
  wrong.** `MetricFormatting.formatted` groups thousands through a `NumberFormatter` with no locale
  set, so it follows the device. Three of its five call sites were agent-facing — including
  `AnalysisQueryEngine`, whose string IS the `analyze` tool's answer. On a German device that read
  "= 8.400 steps", which a model takes as 8.4: a thousandfold error in the one place the app promises
  real numbers, in the output agents lean on most.

  `NumericFidelity` makes it worse rather than catching it. It reparses those strings with
  `Double(...)`, which is POSIX, so it agrees with the wrong reading — the anti-hallucination check
  would confirm 8.4 as "supported". In French the separator is a narrow no-break space, which splits
  "8 400" into two tokens instead. And none of it can surface in the suite: **CI runs in en_US, where
  the grouped form is exactly what everything downstream assumes** — the same blind spot as the UTC
  calendar, one axis over.

  Numbers now have two forms, because the two readers want opposite things. `formatted`/`number` stay
  locale-aware for the SCREEN — a German user should read "8.400 Schritte". `canonical`/
  `canonicalNumber` are for the MODEL: no grouping at all, POSIX decimal point, identical in every
  locale. Dropping the separator rather than pinning a locale is deliberate — grouping exists for
  human readability, the model does not need it, and its absence cannot be misread.

  `CanonicalFormattingTests` asserts the round-trip property that matters (an agent-facing number
  survives `NumericFidelity.numbers`) and demonstrates the hazard the way this codebase verifies its
  other locale claims — by building the de_DE and fr_FR formatters and showing what they really
  produce: "8.400" reads back as 8.4, and the French form splits into two tokens.
  `ArchitectureInvariantsTests` keeps locale-aware formatting inside the UI; verified by pointing
  `AnalysisQueryEngine` back at `formatted`, which names the file.
- **The strange-day date was off by one for the whole Americas.** `UnusualDaysScan` built its basis
  line with `day.formatted(date: .abbreviated, time: .omitted)`, which renders in
  `TimeZone.current`. The day itself is a UTC-midnight key, so west of UTC it displays as the
  PREVIOUS date — measured, not reasoned: the same instant prints "Jul 17, 2026" in UTC and Tokyo and
  "Jul 16, 2026" in Los Angeles. The agent read the wrong date and told the user the wrong date, on
  the tool whose entire job is "here is the strange day, go look at it".

  It was also locale-rendered, so the same day reads "17.07.2026" in Germany — and `NumericFidelity`
  scrapes basis text for figures, so those digits joined the pool of "verified" numbers that a
  hallucinated figure is checked against.

  `Calendar.civilDayLabel` replaces it: ISO `2026-07-17`, civil calendar, no locale. ISO order is
  deliberate — unambiguous everywhere and it sorts. The invariant scan now rejects
  `.formatted(date:` outside the UI, where showing the user their own convention is exactly right.

  Third live defect from the same question — **what does the test environment hold constant that the
  world does not?** UTC hid this one and the day-boundary story; en_US hid the thousands separator.
  All three were silent, user-visible, and unreachable by any test that runs only on CI's machine.
- **A date in the basis was verifying invented figures.** `NumericFidelity` scrapes the basis line
  for numbers and treats them as the VERIFIED pool a story's figures are checked against.
  `UnusualDaysScan` names the day a spike happened, so that pool quietly gained the day-of-month and
  the year: with a basis reading "… on 2026-07-17 …", a story claiming "your steps rose 17%" was
  judged supported — by a calendar day. A false negative in the only check that catches invented
  numbers, and it predates the date-format change (the old "Jul 17, 2026" leaked 17 and 2026 too).

  `numbers(in:)` now strips ISO dates before tokenising, which fixes both directions: a date cannot
  lend its digits to the verified pool, and a date the model quotes in its prose is no longer
  reported as an unsupported figure — it is not a statistic, and flagging it would send the skeptic
  panel after a correct sentence. Verified by removing the strip: the "17%" case flips to supported.

- **OPEN QUESTION — multi-source HealthKit sums (unverified, needs a real device).** Quantity days
  are read with `HKStatisticsQuery(.cumulativeSum)` over a plain date predicate, which sums every
  matching sample regardless of which device wrote it. On a phone with a paired Watch, step count is
  written by BOTH, and the Health app does its own source-priority merging that a raw
  `cumulativeSum` does not reproduce. If that is what happens, the app's most prominent metric is
  inflated for every Watch user — and no test here can see it, because the fixtures have exactly one
  source per metric.

  Deliberately NOT changed: this cannot be settled from a simulator, and a speculative
  de-duplication could as easily discard legitimate multi-device data. It is five minutes to settle
  on a real device — compare a day's `cumulativeSum` against the figure the Health app shows for the
  same day — and the fix (an `HKSourceQuery`, or Apple's own merged sources) depends on the answer.

  **Sharpened later by an asymmetry.** The CATEGORY path already solves exactly this problem and says
  so: `SleepAggregation.mergedSeconds` clamps and merges overlapping intervals specifically "so
  overlapping stages or multiple sources (Watch + phone) aren't double-counted". So multi-source
  duplication was on the author's mind for sleep and mindful minutes, and the quantity path does a
  raw `cumulativeSum` with no equivalent. That is evidence rather than proof — HealthKit may well
  handle quantities differently — but it makes the question worth answering rather than assuming.
- **Seasonality was missing from the substrate and determinism nets.** `SubstratePrecomputeTests`
  covers the six older scans; the new one was not in either check, and adding it naively would have
  been vacuous — the fixture is 180 days and `SeasonalityScan` needs two years before it will speak
  at all, so every seasonal assertion would have compared two empty arrays. It now has its own
  multi-year fixture, with a non-empty guard so that cannot silently regress.

  One honest limitation is recorded in the test rather than papered over. The determinism assertion
  passes, but it does not currently DISTINGUISH the scan's `keys.sorted()` calls from unordered
  iteration: removing them was tried and the test still passed. The reason is that the year and
  (year, month) keys are `Int`s, and two Int-keyed dictionaries built the same way iterate the same
  way — unlike the `[Date: Double]` series, which the same test explicitly asserts DO differ, and
  which is what makes the older scans' ordering genuinely load-bearing. Attempts to force a
  difference with float-unfriendly fixture values did not change that.

  The sorts stay: they are cheap defence against a hashing or capacity change making that untrue. But
  a test that cannot fail is worth less than the comment saying so, so the comment says so.
- **A 26-second scan that turned out to be a Debug artifact — and the correction matters more than
  the finding.** Profiling the substrate on thirty metrics × five years measured 26 s, of which
  `CorrelationEngine` was 26.9 s and every other scan together 0.76 s (seasonality: 0.145 s). Scaling
  measurements confirmed O(metrics² × days) with no accidental quadratic — 2× metrics gave 3.9-4.3×,
  2× days gave 1.93×.

  Two hypotheses about the constant factor were tested and **both were wrong**: hoisting the
  per-candidate row sort bought 28%, and re-keying the inner loop from `Date` to integer day numbers
  bought ~1%. Bisecting then showed row-building was only 0.73 s of it — the ~18.7 s was the
  statistics themselves, about 6 ms per candidate for 1,800 rows, which is roughly a hundred times
  what ten linear passes should cost.

  That last number is what gave it away. `xcodebuild test` builds the UNOPTIMISED configuration, and
  Swift numeric array code is pathologically slow there. The identical statistical work — 3,045
  candidates × 1,800 rows through pearson, residuals, ranks and autocorrelation — takes **0.217 s
  under `swift -O`**, about 86× faster. There is no production performance problem, and the
  "~143 seconds on a real library" that the Debug figure extrapolated to was simply wrong.

  What was kept and what was not:

  - The sort hoist STAYS. Sorting each metric's change series once (30 sorts) instead of once per lag
    candidate per pair (~3,000) is less work by construction, whatever the build.
  - The integer day keys were REVERTED. They were introduced on a hypothesis the measurement
    disproved, bought ~1%, and added a conversion step to a delicate, heavily-tested engine.
  - The wall-clock test was DELETED. A bound loose enough to pass in Debug says nothing about shipped
    behaviour; one tight enough to mean something fails every run. `@testable import` requires
    testability, which Release disables, so Release cannot be measured from the test target at all.
    What remains is a coverage test — every detector fires on a realistically shaped corpus — shrunk
    to ten metrics × three years so it costs one second instead of twenty-one.

  The standing rule: **performance claims about these engines require an optimised build.** Profile
  the app, or measure the algorithm standalone with `swift -O`. A number from `xcodebuild test` is
  evidence about Debug and nothing else.
- **Day one had no coverage at all.** Every numeric suite works on years: `EngineFinitenessTests`
  covers degenerate SHAPES (flat, all-zero, one spike) but always at 900 days, and the substrate
  suites use 180 or more. Nothing covered a tiny LENGTH — one day, two days, a first week — which is
  the state every user passes through on the very first run, when a crash or a nonsense number is
  least recoverable. The scans are full of length-sensitive arithmetic: sample SDs divide by (n − 1),
  milestones want a 7-day stretch, regimes split a window in two, thirds-consistency slices in three,
  seasonality needs whole years.

  `DayOneTests` runs every scan, every stat tool and every `AnalysisStatistic` × window over lengths
  0, 1, 2, 3, 5, 7, 10, 14 and 30, plus a completely empty library. **No defect found** — the
  computability guards hold at every length, and an unanswerable query returns `available: false`
  with a zero rather than an invented reading, exactly as documented. The value is that this is now
  pinned rather than incidentally true.

  The vacuity anchor earned its place immediately: it failed, and the fault was the FIXTURE. A tight
  synthetic sawtooth has no outliers, so `UnusualDaysScan` correctly found nothing and the loops were
  asserting over empty collections. Adding one wild day fixed it — and a single outlier among five
  days is itself the hardest case for a MAD baseline, so the short lengths now exercise more than
  they did.
- **The in-memory fallback was right for the foreground and harmful in the background.** When the
  on-disk store cannot be opened, `VerdantApp` substitutes an in-memory container so the app still
  starts. That is correct for a user launching the app — a usable session beats a refusal to launch.
  It is the wrong answer for a background launch, and the background launch is the likeliest cause of
  the failure: the store is written with `.completeUnlessOpen`, so a NEW handle cannot be opened
  while the device is locked, and a `BGProcessingTask` on a charging phone overnight launches a fresh
  process into precisely that state.

  Unguarded, that pass reasons over an EMPTY history and writes its findings, its research journal
  and its HealthKit anchors into a store that evaporates when the task ends. A whole granted
  on-power window — the app's scarcest resource, and the one its purpose is measured in — spent
  producing nothing, with no error raised anywhere to say so.

  `AppModel.storeIsEphemeral` now records the substitution instead of swallowing it, and both
  background arms yield the window immediately when it is set. Yielding is strictly better than
  working: the system reschedules, and the next attempt may find the store openable.

  **Unverified premise, stated as such.** The simulator does not enforce data protection, so whether
  the open genuinely fails on a locked device cannot be confirmed from here. The guard is safe
  regardless — it is conditioned on a fact the app KNOWS (the fallback happened), not on a guess
  about why — and it can only skip work in a state where that work could not have persisted anyway.
  Settling it needs a device: lock it while charging and confirm whether the overnight enhancement
  task finds an openable store.
- **Two stale claims in the sections a reader treats as rules.** §0 warns that the numbered sections
  below it describe the pre-inversion pipeline, and that convention handles history fine — but the
  **Principles** list is read as normative, not archival, so a wrong principle there misleads in a
  way a wrong dated entry does not.

  Principle 5 read "Deterministic guards around an unreliable model … prose is *safety-vetted*
  deterministically". That is precisely the thesis §0 records as OVERRIDDEN: `SafetyGuard`'s
  substring blocklist is gone (verified — the symbol appears nowhere in the app or tests) and safety
  is a five-reviewer agent panel that fails closed. Rewritten to keep the half that is still true and
  load-bearing — every figure is engine-computed and re-resolved from source, so the model can name a
  thing but never invent a number — and to say plainly that judgment moved to the agents while
  arithmetic did not. Principle 3's "single-metric leads must clear a quality floor" got the same
  treatment; the deterministic worth floors are gone.

  Also corrected: "What is open" claimed sleep attribution was "the one outstanding issue". It is
  four, and they divide usefully — two are the owner's product decisions, two need a real device —
  so the summary now says which is which and what experiment settles each.

- **`unusualDays` paging was pinned against duplicates but not against standing still.** The existing
  check proves a page has no repeats WITHIN itself, which an offset that was silently ignored would
  satisfy just as well: every page would be page one. An agent working through the pool would spend
  its whole call budget re-reading the same six days and conclude there was nothing more to find —
  no error, just a quietly truncated search. Now pinned that page two is disjoint from page one, and
  that paging past the end stops rather than wrapping (an agent must be able to tell it has reached
  the bottom). Verified by neutralising the offset: both halves fail.
- **Do the tools answer the question that was ASKED?** Nearly every real defect in this codebase has
  the same shape: a well-formed answer to a different question. `unusualDays` paging was pinned
  against duplicates within a page, which an offset that was silently ignored satisfies perfectly.
  `correlate` once ignored `dayFilter` while labelling its answer "weekends only". A finding carried
  real numbers that answered a different question than its own prose. None throw, none are malformed,
  and none fail a test that checks only structure.

  `ToolArgumentsHonouredTests` asks the other question for every argument an agent can set: does
  changing it change the answer the way the tool's own description promises? `eventWindow` must
  CENTRE on the day it is given and widen with its radius; `unusualDays` must honour its metric
  filter, and must return nothing for an unrecognised key rather than falling back to everything;
  `coverage` must really return "sparsest first" and `correlationScan` "the strongest", since the cap
  tests take a prefix of whatever order exists and would faithfully return the least interesting rows
  if the sort were wrong.

  **No defect found — but the exercise caught a bad test of my own.** Injecting a reversed `coverage`
  sort did NOT fail the check, because the fixture gave every metric contiguous daily data: all
  densities were 1.0, so any order was "sorted". The assertion was fine; the fixture was the weak
  part. With per-metric gaps added (densities now 0.89–1.0) the reversal fails, and so do injected
  argument-ignoring bugs in `eventWindow`'s centre and `unusualDays`' filter.

  That is twice in this session that a vacuity check has failed on the FIXTURE rather than the code —
  the seasonality determinism net was the other. Writing the assertion is the easy half; proving the
  data can make it fail is the half that decides whether the test is worth anything.
- **Panel diversity was asserted in prose and nowhere else.** The code justifies panels by diversity
  in several places — "giving each reviewer its own angle catches failure modes that identical
  reviewers would all miss together" — and it is the entire reason a panel beats one reviewer. The
  existing tests checked panel SIZE, that no lens is blank, and that a composed challenge reaches a
  skeptic. A fan-out that handed the SAME lens to every member would satisfy all three.

  The result would be six copies of one skeptic, agreeing for one reason, and a finding clearing a
  majority vote it never actually faced. It matters more on the safety panel, which fails CLOSED on a
  unanimous rule: five identical reviewers would agree five times over about whichever single concern
  they were all given, while every other concern — diagnosis, medical advice, alarmism, body shaming,
  overstated certainty — went unasked entirely.

  Both panels now pin that the questions are DISTINCT, that there is one per roster entry, and that
  the set is the real roster rather than five of something else. `SubagentCallRecorder` gained
  `safetyLenses` to make the safety half observable at all. Verified by collapsing the safety fan-out
  to a single lens: it fails and prints the four concerns that stopped being reviewed.
- **The knob the whole Neural-Engine argument rests on was pinned as `>= 1`.**
  `EnhancementPolicy.maxConcurrentSubagents` is the single value every fan-out in the app reads —
  discovery, the safety, skeptic and replication panels, the deep run's fleet — and the design's core
  claim is that it is exactly ONE: on-device inference serialises anyway, so issuing several sessions
  at once makes the OS split each one's resources and burn the generation rate limit in bursts,
  producing more errors and less completed reasoning. Set it to 4 and nothing failed; the app would
  quietly run four throttled agents where it promised one at full power, which is the opposite of the
  stated purpose. Now pinned to `== 1`, with the reasoning beside it.

- **Replication panel diversity, completing the set.** The skeptic and safety panels now pin that
  every reviewer gets a different question; the armed replication panel needed the same, and it is
  the case where identical reviewers do the most damage. Its job is to re-test a claim from angles
  its author did not choose, so three analysts running the same check would re-confirm exactly the
  weakness the finding already survived — and report it as three independent confirmations. Verified
  by collapsing its roster to one lens; the failure names the two re-tests that stopped running.
- **The feed's SIZE had no test, only its constant's range.** Which findings keep a slot is entirely
  the curator agent's call — that is the architecture, and the deterministic worth floors were
  deliberately removed. How MANY keep a slot is not: "a handful of exceptional findings, not a wall"
  is a promise the feed makes to the user, and the agent can return any keep-list it likes, including
  all of them. What actually holds the line is a `prefix(budget)` and a roster-range filter in the
  persist path — plumbing, sitting inside a decision path where the surrounding philosophy ("agents
  decide, no deterministic gates") is a standing argument for deleting exactly that kind of clamp.

  `PureMathTests` asserted the CONSTANT sits in 3...12. Nothing asserted the feed did.
  `CurationBudgetTests` now seeds more findings than the budget, has the curator ask to keep 64, and
  requires the feed to come out bounded — plus that keep-list numbers the roster never offered
  (`99`, `-3`, `5000`) are ignored rather than honoured. Verified by deleting the clamp: 17 findings
  survive against a budget of 11.

  This is the third claim in a row that was load-bearing, user-visible, and enforced only by a line
  of code nobody was watching. The pattern to keep asking: what does this codebase promise in prose
  that no test would notice becoming false?
- **Provenance was promised on every finding and enforced on one route out of six.** "Every finding
  records its own provenance — which lens proposed it, what each panel tallied, and a panelist's own
  words" is a promise the detail screen keeps to the user, and it is what makes a finding auditable
  at all. The `append*IfNovel` writers take `provenance` with a DEFAULT of `""`, so omitting it is
  entirely silent: no compiler error, no test failure, just a finding that cannot say where it came
  from.

  That default is not a mistake — the many tests that construct findings directly should not have to
  care — which is precisely why a source scan is the right enforcement rather than deleting it. The
  one behavioural test that reads provenance exercises the trend route; there are six, and one of
  them (`seasonal`) was added in this same session, when the defaulted parameter was already in place.

  `ArchitectureInvariantsTests` now requires every `append*IfNovel` call site in the persist file to
  pass `provenance:`, and asserts it found at least six of them so the scan cannot pass by matching
  nothing. Verified by dropping the argument from the seasonal route — it names the offending call.

  Widened immediately, because provenance is not the only one. Those writers default FOUR arguments,
  each silent when omitted and each losing something different: `embedding` makes a finding invisible
  to semantic search and to novelty-by-similarity; `within` swaps the run's novelty lookback for a
  hardcoded 14 days; `now` swaps the run's anchor for the wall clock, which is how a pass and its own
  persisted rows come to disagree about what day it is. All six routes pass all four today; the scan
  is what keeps that true. Verified again by dropping `now:` from the correlation route.

  The general shape, worth stating because it has now produced three defects' worth of risk in one
  session: **a convenience default that makes omission silent, plus a code path added later, is a
  reliable way to lose a guarantee.** The default is usually right — tests should not have to supply
  a provenance string — so the enforcement belongs at the call sites, not in the signature.
- **The run's own clock, checked across the agent layer.** `recordJournal` defaults `now` to the wall
  clock, and every agent pass carries `ctx.now` — injected in tests, and in production the instant
  the pass BEGAN rather than the instant a particular write happens to land. Omitting it is silent
  and the damage is subtle: journal entries drift out of step with the run that produced them, so
  `journalSteering`'s "within the last N days" window can include or exclude an entry the run itself
  would place differently.

  An audit found all four call sites already correct, including the `barren` write added in this
  session — so this is a latch on good behaviour rather than a fix, and it now spans the whole agent
  layer rather than a single file. Verified by dropping `now:` from the barren write.

  Two negative results are worth recording alongside it, because they are what made a latch the right
  move instead of a repair: every `append*IfNovel` route already passes all four of its defaulted
  arguments, and every journal write already passes the anchor. The discipline is real; what was
  missing was anything that would notice it lapsing.
- **Mechanism tested, wiring not: the barren-angle feature could have shipped inert.** The barren
  journal was unit-tested by calling `runInvestigation` directly with a `learnable` set. What that
  never touched is the DEEP LOOP computing that set from the pass's invented angles and passing it —
  and those are different failures. With `learnable:` dropped at the call site, every existing test
  stayed green and not one barren angle would ever have been journaled in production: a feature fully
  implemented, fully tested, and completely inert.

  Now covered end to end — a deep pass with a scout lead that comes back empty must leave a journal
  entry naming that lead. The fixture deliberately keeps the thematic rotation productive, so the
  entry cannot be an artifact of a uniformly dry pass. Verified by dropping the argument: only the
  new test fails, which is exactly the point.

  Worth generalising, since the same gap could exist for any recently added feature: a unit test that
  calls the mechanism directly proves the mechanism. It says nothing about whether anything calls it.
- **Two more inert-feature gaps in the seasonal chain, found by asking the same question.** After the
  barren-angle wiring gap, the obvious follow-up was whether the other feature added this session
  could also have shipped inert. Two levels of it could:

  - **`patternScan` surfacing the kind.** The detector runs, the substrate memoizes it, `PatternKind`
    has the case, and the cap tests iterate every kind — but a kind with ZERO rows satisfies a cap
    trivially. Deleting the block that appends seasonal rows to the tool's reply failed nothing: the
    rhythm would be computed on every substrate build and no agent would ever see one.
  - **The persist route.** The router is exhaustive now, so a `.seasonal` case must exist — but it can
    point at the wrong function. Routing it to `persistTrendProposal` failed nothing either, and the
    finding would be stored with recent-vs-baseline numbers under a claim about January, which is the
    exact defect the exhaustive switch was introduced to prevent.

  Both now covered end to end from seeded three-year rollups, so the run builds its substrate through
  the provider exactly as production does. Verified by making the detector inert and by misrouting
  the persist case; each fails only its own test.

  The lesson generalises past this feature: **exhaustiveness proves a case EXISTS, never that it does
  the right thing**, and a cap or a vocabulary check passes happily on an empty set. Both are
  structural guards, and structure is not behaviour.

  So both checks were widened from `seasonal` to EVERY `PatternKind` — and the gap was never
  seasonal-specific. Nothing asserted that `patternScan` surfaces volatility, milestone or regime
  either, and nothing asserted that a proposal of any kind reaches its own persist route: misrouting
  `milestone` to `persistTrendProposal` stored it as an ANOMALY and failed nothing. The four kinds
  had simply been correct for longer.

  Generalising it also caught a fixture that could not test what it claimed. A repeating seasonal
  pattern never sets a record, so `milestone` never fired; adding a recent high stretch fixed that,
  but only once it was confined to EXACTLY the last seven days. The rolling windows overlap, so an
  eight-day boost makes the final window tie the one before it, and `latest.mean > maxPrior` is false
  — a record that is not strictly a record. That is the third fixture this session that could not
  make its own assertion fail.
- **Suite cost, kept honest.** The generalised pattern-kind tests took the suite from ~7 s to ~20 s
  on their own — the persist check rebuilds a fixture and runs a full discovery once per kind. Cut to
  2.0 s (whole suite ~9 s) by seeding ONE metric over just-over-two-years rather than two metrics
  over three: the smallest history where all four detectors still fire, since seasonality needs two
  Januaries and milestone needs 120 days and 60 rolling windows. The second metric only added
  correlation pairs these tests never assert on, and the fixture is rebuilt per kind, so the saving
  was fourfold.

  Shrinking a fixture is normally how a test goes quietly vacuous. It was safe here only because the
  non-vacuity guards are explicit — the surfacing test requires EVERY kind present, and the persist
  test records an issue if a detector fired on nothing — so a fixture trimmed too far fails loudly
  instead of passing emptily. Re-verified after the cut by misrouting `regimeShift`: still caught,
  and it reports the wrong kind it was stored as.
- **The device-swap caveat could have gone silent, and it is the one caveat that matters most.** The
  existing test hands `suspectDays` to `UnusualDaysScan` itself. Production does not: the substrate
  runs `DeviceSwapFilter` and threads the result in through `unusualDaysTask`. And `suspectDays` is
  DEFAULTED to `[]`, so dropping that argument compiles silently — the caveat vanishes from every
  basis the agent reads, and the existing test stays green.

  The cost is not cosmetic. That caveat is the only thing standing between a Watch recalibration and
  a confident finding about the user's physiology. The day is deliberately kept in the data — flagged
  rather than deleted, because deleting real observations by rule was the practice this architecture
  moved away from — and an agent can only judge what it is told.

  Now pinned through the real memoized path: the substrate must flag the day AND the agent-facing
  basis must say so. Verified by dropping the argument; only the new test fails.

  Both patterns at once, and neither is specific to this feature: a **defaulted argument** makes
  omission silent, and a **unit test that hand-supplies it** proves the mechanism while saying
  nothing about whether production supplies it. Every remaining defaulted argument in this codebase
  is a place to ask the same question.
- **The highest-stakes default in the codebase, and a false positive in the check for it.**
  `DiscoveryContext.adversarial` gates BOTH verification panels — `survivesScrutiny` and
  `survivesReplication` each open with `guard ctx.adversarial else { return .notConvened }` — and it
  defaults to `false`. The flag exists so tests can isolate the pipeline, and both production
  contexts set it correctly. But the default points the wrong way for safety: a third context that
  simply forgot it would surface findings the user reads that no skeptic and no replication analyst
  ever saw, and nothing would fail, because "not convened" is a state the panels report calmly.

  Defaulting it to `true` would fail safe but would switch panels on inside every test relying on the
  current default — a large, quiet behaviour change. Requiring the argument at the call sites gets
  the same protection without touching test semantics.

  **The first version of that check was itself wrong**, in precisely the way these invariants exist
  to catch. It read a call's arguments with `prefix(while: { $0 != ")" })`, which stops at the inner
  paren of `jobID: UUID()` — so it reported `Orchestrator+Focus` as missing an argument that sits two
  lines further down. A scan that answers a slightly different question than the one asked is the
  same defect as a tool that does; it just fails in the test suite instead of in front of a user.
  `SourceScan.callBody` now walks to the BALANCED closing paren, and the two older argument scans
  (persist routes, journal writes) were switched to it as well — they happen to have no nested parens
  today, which is not a property worth depending on.
- **Every scan's `now` is defaulted, and the substrate has ten call sites.** Omitting it at any one
  compiles silently, and the result is not a crash: that detector anchors on today while the other
  nine anchor on the run's `now`. A deep run whose context is hours old — or any run at all, once the
  two cross a midnight — then reports days-ago figures from two different calendars, and the agent
  reads "3 days ago" and "20 days ago" about the same day with no way to tell.

  An audit found all ten correct (the two that pass no anchor, `CorrelationEngine` and
  `DeviceSwapFilter`, take none by design). Pinned behaviourally rather than by source scan, because
  the anchor is observable: the fixture's `now` is a fixed past date, so a scan reaching for the wall
  clock places its days weeks further back.

  The first version of the check was too weak in one half, which the injection exposed. "Volatility
  fired at all" does not notice a slipped anchor — a wall clock a fortnight ahead still overlaps this
  fixture, so it fires either way. The sensitive figure is `n`, the observations inside the 30-day
  recent window, which is full only when the window sits over the data: 30 when anchored correctly,
  13 when anchored on today. Verified separately for each half — `unusualDays` reports 19 days-ago
  instead of under 10, and volatility reports 13 observations instead of 30.
- **What ranks a single-metric finding, pinned at last.** `MaterialityRules.buildFact` takes
  `requestedSalience` defaulted to `nil`, and falling back computes salience from `|z|` and
  `%change`. The persist route passes the agent's `worth`, and the reason is written where it is
  done: for a lone metric the statistical term measures BIGNESS, which usually means OBVIOUSNESS, so
  blending it in "would promote the loud, predictable changes this app exists to filter out".

  Drop that one argument and nothing fails — the feed simply re-sorts toward the biggest numbers,
  which is the editorial failure the whole product defines itself against, with no error and no test
  noticing. Measured: the same finding the agent rated 90 comes out at **46** when ranked by its own
  statistics.

  Now pinned behaviourally, with an explicit non-vacuity guard asserting the fixture's computed
  salience is NOT also 90 — otherwise the check would pass whichever source was used. (Correlations
  and the pattern kinds deliberately DO blend a stat term; there it measures trustworthiness of a
  subtle link rather than bigness. This is only about single-metric leads.)

  That completes the defaulted-argument sweep begun three entries ago: persist arguments, journal
  clocks, suspect days, `adversarial`, scan anchors, and now salience. Every one was correct in
  production; not one had anything that would notice it changing.
- **The feed's empty state was an equality chain ending in `else`.** Every capability state has copy
  written for it — Apple Intelligence off, unsupported device, model downloading, and "nothing stands
  out yet" — but they were selected by `if model.capability == .notEnabled { … } else if …` with a
  trailing `else`. A capability case added later would silently inherit the LAST branch and tell
  someone whose model is, say, mid-update that their data is unremarkable. Same defect as the finding
  cards, in copy the user reads on an otherwise empty screen.

  Extracted to `capabilityEmptyState`, an exhaustive `switch` with `.available` named rather than
  inherited. Verified by removing a case: the build fails at that switch.

  The audit also turned up two other switches over `LLMCapability` (`Components`, `Orchestrator`)
  that were already exhaustive — which is how a hypothetical new case surfaces one file at a time
  rather than all at once. Worth knowing when checking this kind of guard: the compiler bails on the
  first file, so "the build failed" is not evidence that YOUR switch is the one enforcing anything.
- **`aggregation == .sum` in the ingest path — the worst place to lose a case quietly.** Both
  HealthKit read sites wrote `let isSum = metric.aggregation == .sum` and branched on the boolean,
  choosing `.cumulativeSum` or `.discreteAverage`. Correct for exactly two cases and silently wrong
  for a third: a new aggregation would be AVERAGED, and an averaged step count is a plausible-looking
  number that simply is not the day's total. Wrong daily values feed every statistic, every finding
  and every card, so a lost case here is invisible and total.

  Now `Aggregation.wantsCumulativeSum`, an exhaustive switch on the enum itself — decided once,
  next to the cases, instead of re-derived at each query. Verified by adding a hypothetical
  `.median`: the build fails on the property rather than silently averaging it at two call sites.

  A sweep of the remaining `== .case` comparisons found nothing else of this shape: they are single
  booleans whose fallback is genuinely correct (`dayFilter == .all` choosing a label suffix,
  `statistic == .correlation` routing to a branch whose alternative is itself an exhaustive switch,
  and HealthKit's own `HKError.code == .errorNoData`).
- **The charts' honesty promise had no test.** `recentSeries` feeds every sparkline and the dual-line
  correlation chart, and documents a specific claim: it excludes today's still-accumulating partial
  day "matching `dailySeries`", because the coefficient runs on the today-excluded substrate and the
  chart is described to the user as showing the same signal. The existing tests covered upsert
  behaviour and non-emptiness — not that.

  Including today would end every sparkline on a partial value (a step count read mid-morning looks
  like a collapse) and would put a point on the correlation chart the coefficient never saw, under a
  caption saying otherwise. Nothing throws, nothing is malformed, and both are wrong in precisely the
  way a person would believe.

  Now pinned twice over: no plotted day is today and the partial value appears nowhere, AND the days
  the chart plots are a subset of the days the statistics ran on with the VALUES agreeing point for
  point — the "same signal" claim checked directly rather than by proxy. Verified by dropping the
  `dayStart < today` clause; the partial 900 lands as the final point.
- **The correlation chart had no tests at all, and its helpers were unreachable.** It is the only
  place a user can SEE a finding rather than read it, and it makes two claims nothing checked: that
  it plots the same signal the coefficient was computed on (winsorized first differences, not raw
  levels), and that a lead/lag finding's two lines are aligned so co-moving days share an x.

  Both were already correct — `changeSeries` calls the engine's own `firstDifferences` and
  `winsorize`, and the trail series is shifted by `-lag`. Both also fail quietly if broken: plot
  levels and two metrics whose CHANGES track can look unrelated; flip the shift and the lines are
  misaligned by twice the lag. Either way the caption still says they move together, and the picture
  argues against the number beside it.

  `changeSeries`, `normalize` and `NormalizedPoint` are now internal rather than private, because
  "agrees with `CorrelationEngine`" is not a property a view can assert about itself. The tests check
  the change series point-for-point against the engine, that normalising puts both metrics on one
  axis, that a flat series draws nothing rather than NaNs, and that the shift moves the trailing
  metric BACKWARD — verified by flipping the sign, which lands points four days out for a lag of two.

  Stated in the test rather than glossed: this pins the helper, not that `load()` passes `-lag`.
  `load()` is private, async and bound to the view's model, so the call site is out of reach — the
  same mechanism-versus-wiring gap that nearly shipped the barren-angle feature inert.
- **The volatility card's sparkline, which is the card's whole argument.** A volatility finding says
  a metric grew more erratic *while its average held*, so the chart plots day-to-day SWING rather
  than level — a level line would look flat and quietly contradict the sentence above it. That
  transform lived in a private computed property over `@State`, untestable, and nothing checked it.

  Extracted to `MetricSparkline.swingSeries`, pure and internal. The test that matters builds exactly
  the case the card exists for: a series oscillating around 100 the whole way, ±1 early and ±12 late,
  with the two halves asserted to share a mean — so the level line genuinely IS flat — and then
  requires the swing line to show the widening. Also pinned that a perfectly steady metric swings
  zero, and that a fall counts as much as a rise (otherwise a metric that dropped sharply would look
  calm on a card about how erratic it has become).

  Verified by making the transform return levels: the widening case fails at 100 against a required
  300, and the steady case stops being zero. A chart that contradicts its own caption is the same
  defect as a wrong number, and the last three entries have all been that shape — the picture and the
  prose disagreeing, with only the prose under test.
- **The connection map's VoiceOver description — the one string with no picture behind it.** For a
  sighted user the Canvas is the finding and the caption summarises it; for a VoiceOver user the
  sentence IS the map. Dropping an edge, or rendering a negative coefficient as "move together", is a
  wrong statement about someone's health data with nothing to contradict it — and it is exactly the
  kind of string no test reads.

  `graph`, `accessibilityDescription` and `hubCaption` are now internal and tested: every surfaced
  link is spoken with both metrics named, a negative link is NEVER described as moving together, an
  empty map says so rather than describing nothing, and the hub caption names the most-connected
  metric with its links split correctly by direction (plus: a single link is not a web, so it gets no
  hub). Verified by hard-coding the relation to "move together" — two tests fail and print the
  sentence a screen-reader user would have heard.

  That closes the view layer's transforms: correlation chart, volatility sparkline, connection map.
  All three were correct; none had ever been executed by a test, because each lived as a `private`
  helper inside a `View`. Making them internal was the entire unlock, and it is worth remembering as
  a place where "untestable" was a property of the access modifier rather than of the code.
- **The meter's window label — a fixed lie with no test behind the fix.** The duty-cycle figure is
  the one number that says whether the app is achieving its purpose, and the meter names the window
  it is averaged over. It used to say "last minute" from the moment it appeared, holding a few
  seconds of history: a small lie on the one screen whose entire job is honest measurement, against
  the same rule the live feed follows. That was fixed; the fix lived in a `private var` on the view,
  so simplifying the label back to a constant string would have restored the lie silently.

  Moved to `ResourceMonitor.dutyCycleWindowLabel(spanSeconds:)`, beside the window constant it reads,
  and tested — including the property rather than only examples: for every span below the window it
  must NOT claim a minute. Verified by hard-coding "last minute" again.

  `dutyCycle` itself was already well covered (drifted sampling, zero, saturation, clamping), which
  is why this was the only gap left on the meter.
- **"Delete everything" — the strongest promise the app makes, and the least checkable by the person
  relying on it.** Two callers depend on it: Settings offers it to the user outright, and the
  civil-day migration uses the same four writers to clear rows keyed to the OLD local-midnight
  boundary, which would otherwise coexist with UTC-keyed ones and double-count every statistic.

  The existing coverage was one insight, deleted, checked through `snapshotsForSearch` — a FILTERED
  read that skips tombstoned rows. A retired finding left on disk would have satisfied it while still
  being the user's health data, unerased. `deleteAllCorrelations` had no test at all, and the
  journal's own delete-all has already had a real bug of exactly this shape (its rows survived, and
  the fleet went on avoiding ground the user had just cleared).

  `DeleteEverythingTests` counts RAW rows through a plain `ModelContext` — the only view that cannot
  hide a survivor — across insights (active and tombstoned), correlations, every journal kind,
  rollups and anchors, with pre-assertions so an empty fixture cannot pass as success. It also pins
  that running the four twice is harmless, which the migration depends on: it marks itself complete
  only on success, so a failure part-way through replays all four next launch.

  Verified by making `deleteAllInsights` skip tombstoned rows — the old filtered check would not have
  noticed; both new tests do.
- **Two tests were making the same assertion about opposite behaviours.** Both the "a refuted
  finding is dropped" and "the audit retires a standing finding" tests ended in
  `snapshotsForSearch(now:).isEmpty`. That read filters tombstoned rows, so it cannot distinguish
  NEVER WRITTEN from WRITTEN AND HIDDEN — and those are precisely the two behaviours the two tests
  exist to separate.

  Rewriting the first to count raw rows made the second FAIL, which is the proof the distinction was
  real: the audit's finding is supposed to still be on disk, tombstoned. Each now asserts its own
  claim — the refuted proposal is never persisted at all (zero raw rows of either kind), and the
  retired one is present, tombstoned, and no longer surfaced. Verified by skipping the retirement
  call: the audit test fails on both halves.

  Generalising the earlier delete-everything lesson: **a test that reads through the same filter as
  the production code cannot see what the filter hides** — and when one filtered assertion is doing
  duty for two opposite behaviours, at least one of them is not being tested.
- **The safety panel's "dropped" claims, strengthened from hidden to never-written.** Four tests
  asserted that nothing is surfaced — the model proposing nothing, prose the safety panel vetoes, a
  finding whose safety verdict cannot be rendered (the fail-CLOSED case), and an unavailable model —
  all through `snapshotsForSearch`, which filters tombstoned rows. Every one of those claims is
  actually "never written": the safety gate runs before any persist, and an unavailable model writes
  nothing at all. Raw row counts say that; a filtered read only says "not visible".

  Left alone deliberately: `tombstone hides insights` and the audit's retirement genuinely mean
  hidden-not-deleted, so the filtered read is the correct instrument there. The rule is not "always
  count raw rows" — it is that the assertion has to match the claim.

  Verified by making `passesSafety` always return true: the veto and fail-closed tests both fail on
  the raw count. (A first attempt injected into the `guard` body and did not compile — a
  non-compiling injection proves nothing, and the absence of a failure line was the only clue.)
- **The sleep merge's multi-source shapes were the untested ones.** `mergedSeconds` is tested for
  partial overlap ([1,5] with [3,7] → 6h, not 8), but not for the two shapes the merge exists to
  handle: two devices recording the SAME night (identical intervals), and one source's session
  CONTAINING another's fragment. The second is the dangerous one — simplifying
  `max(last.end, interval.end)` to `interval.end` compiles, passes every existing test, and turns an
  eight-hour night recorded by a Watch plus a two-hour phone fragment inside it into **two hours of
  sleep**, on the app's most prized metric.

  Now pinned, in both arrival orders (the merge sorts by start, so order should not matter and the
  test proves it does not), plus adjacent stages touching end-to-start merging into ONE run rather
  than three — otherwise `mergedCount` would misreport how fragmented a night was. Verified by making
  that exact substitution: the containment test fails at 3h against 8h and nothing else notices.
- **The other half of the delete promise is a NON-deletion.** The Settings footer says the tap
  "permanently deletes every insight and connection Verdant has surfaced, and its memory of what it's
  already shown you. Your Apple Health data is untouched — Verdant can rediscover findings over
  time." The previous entry pinned the deleting half. Nothing pinned the preserving half.

  The user-facing path must NOT clear the ingest cache: those rollups are how the app rediscovers
  anything without re-reading years out of HealthKit, and the anchors are how it knows where it left
  off. Adding `resetIngestCache()` there would compile, satisfy every "everything is gone" test, and
  quietly turn a clean-slate tap into a multi-minute backfill — while the footer promised the data
  was untouched. It is a plausible edit precisely because the migration path DOES call all four.

  Now pinned: findings, connections and journal go to zero while rollup and anchor counts are
  unchanged. Verified by adding the reset — both preservation assertions fail while every deletion
  assertion still passes, which is the shape that makes this worth a separate test.
- **Verdant only ever READS Apple Health — a negative promise with nothing enforcing it.**
  `requestAuthorization(toShare:read:)` takes the WRITE set as its first argument, so adding a type
  there is a one-word edit. The user would then be shown a write-permission sheet by an app that only
  reads, and the app would hold the capability to modify their Health data. Both call sites pass
  `toShare: []`; nothing checked that they kept doing so, and no test exercises a permission dialog.

  Injecting a real write scope produced the most informative failure of the session: the test runner
  **crashed before any test ran**. iOS refuses to launch an app requesting Health write access
  without `NSHealthUpdateUsageDescription`, and the app declares only the read one. So the property
  already had a second guard — but its failure mode is a crash on first launch, and the obvious fix
  for that crash is to add the key, which removes the guard. The key's ABSENCE is therefore
  load-bearing in its own right, and is now pinned too: a diff that adds it has to argue with a test
  rather than quietly unlocking writes.

  The scan itself needed two corrections before it was worth anything. It first matched the wrapper's
  own DEFINITION (`func requestAuthorization()`) and the zero-argument calls to it, reporting both as
  missing an argument they never had; it now only inspects calls naming `read:`. That is the third
  scanner this session to answer a slightly different question than the one asked — the same defect
  class these invariants exist to catch, which is worth remembering when writing one.
- **Fixing the scanners at the root instead of one at a time.** Three call-site scans written for
  these invariants answered a slightly different question than the one asked, which is precisely the
  defect class they exist to catch. Two shared a cause: matching `func name(` as though it were a
  CALL, so the scan reported that a function "does not pass" an argument its own signature was
  declaring. (The third read arguments with `prefix(while: { $0 != ")" })` and stopped at the inner
  paren of `jobID: UUID()`.)

  `SourceScan.callSites(of:in:)` now returns each call's balanced argument text and skips
  declarations, and the journal-clock and Health-authorization scans both use it. Domain filtering
  stays the caller's job — when a wrapper shares a name with the API it wraps, only the caller knows
  which is which, which is why the authorization scan still selects on `read:`.

  Both re-verified after the refactor against their own regressions, because a helper swap is exactly
  the kind of change that can turn a working scan into one that matches nothing and passes forever.
- **A documented precondition with nobody enforcing it: the embedding model id.** `Embeddings` says
  every stored vector shares one model id, "so all comparisons are always valid; if it's ever bumped,
  callers (`curateFindings`, `InsightSearchTool`) should start skipping cosine comparisons across
  differing ids — they don't yet, which is safe only while the id is constant."

  That is an honest limitation rather than a defect, and the audit confirmed it: the id IS constant,
  so the risk is inert, and `embeddingModelID` is written at five sites and read at none. But the
  condition the safety rests on was enforced by nobody. Bump the id — after an OS change to
  `NLEmbedding`, say — and vectors from two different spaces get compared by cosine, which does not
  fail: it returns confident, meaningless similarity. `insightSearch` would offer unrelated findings
  as "related", and curation would judge distinctness on noise.

  `EmbeddingsTests` now trips on the id changing, with a failure message naming the work required:
  project `embeddingModelID` through `InsightSnapshot`/`snapshotsForSearch` (which does not carry it
  today, so the filter cannot even be written without that), then filter in both comparison sites.
  Verified by bumping the id to v2 — the test fails and prints the instructions.

  This is a different shape from the rest of the session's findings. Nothing is wrong, and the
  comment was already accurate and complete. What was missing is that a future edit could invalidate
  it silently, and a prose warning does not fire.
- **The deletion-blind range query, and the highest-consequence unenforced invariant found.**
  `dailyValuesRange` fetches a whole date range in ONE HealthKit query — what makes multi-year
  backfill affordable — but it cannot express a deletion: "empty day → no row" does not REMOVE a
  stale rollup the way the per-day path's `DayDeletion` does. Its doc states the rule plainly: only
  the first ingest (no rollups yet) and history deepening (strictly older than any rollup) may use
  it; the deletion-triggered window recompute must stay per-day.

  Both call sites honour it. Nothing enforced it, and breaking it is TEMPTING precisely because the
  range query is far faster than the per-day loop the recompute uses. The consequence is not a crash:
  a sample the user DELETES from Apple Health leaves its rollup behind, and Verdant keeps analysing
  and reporting data the user removed — a correctness failure that is also a trust failure.

  Enforced as a tripwire on the call sites rather than behaviourally, and the reason is worth
  recording: `Ingestor` holds a CONCRETE `HealthStore`, so there is no seam through which to fake a
  HealthKit deletion. Testing the property itself would mean putting HealthKit behind a protocol —
  a real option, and the right one if this area is ever touched again. Verified by adding a call
  inside the `hadDeletions` branch: the tripwire fires and names the invariant.

  Sweeping the codebase for other conditional safety claims ("safe only while…", "must stay…") found
  the rest to be descriptive rather than load-bearing, and the one real MUST — "the feed must stay
  bounded even then" — was pinned earlier by `CurationBudgetTests`.
- **HealthKit behind a protocol, so the ingest path can be tested at all.** The previous entry
  enforced the deletion-blind invariant as a tripwire on call sites and recorded WHY: `Ingestor` held
  a concrete `HealthStore`, so there was no seam through which to fake a HealthKit deletion. That was
  the right diagnosis, so the seam now exists — `HealthReading`, four methods, with `HealthStore`
  conforming and `Ingestor` taking `any HealthReading`.

  The ingest path is where wrong data ENTERS. A stale rollup, a mis-advanced anchor or a missed
  deletion sits upstream of every statistic, finding and card, and no downstream safeguard can catch
  it — the numbers are real, they just describe data that is no longer there. It was the least
  testable code in the app and is now covered for the property that matters: a day the user deletes
  from Apple Health loses its rollup; the FIRST ingest does take the one-query range path (the reason
  that API exists); and the deletion recompute never reaches for it.

  Getting the verification right took two attempts, which is the part worth recording. The first
  "violation" was injected into the wrong `if scan.hadDeletions` block — there are two — so the
  recompute still ran correctly and only the call-count test fired. Had I accepted that, I would have
  reported the deletion test as proven when it was untouched. Removing the `DayDeletion` emission
  instead is the real violation, and it fails with `after[dayA] → 9000.0` where `nil` belongs: the
  deleted day still being reported, which is exactly the user-visible failure.
- **Two more ingest properties, now that the seam exists.** Both were untestable an hour ago and both
  are user-visible:

  - **A deletion retires the findings built on that metric.** `Ingestor` tombstones a metric's
    insights and correlations whenever HealthKit reports a deletion, because findings derived from
    removed samples no longer hold. This is the visible half of the delete promise: a user who
    removes a bad reading and still sees Verdant asserting a conclusion drawn from it has been told
    something false. The test also pins that the finding is RETIRED rather than erased — tombstoned,
    like an audit retirement — so it asserts the right one of the two behaviours.
  - **An incremental pass leaves old days untouched.** The 40-day window is what keeps an observer
    wake cheap; re-reading a whole history on every wake would matter on a phone. But the window is a
    performance boundary, not a licence to lose data: a day outside it that vanishes from HealthKit
    must keep its rollup, because this pass never looked.

  Verified separately — skipping the tombstone call fails the first; widening the recompute window to
  ten years fails the second with `values[ancient] → nil`, the old rollup silently dropped.
- **The one ingest failure that cannot be recovered by trying again.** The anchor is the sole carrier
  of the deletion signal — HealthKit will not re-report a deletion once its anchor is consumed — so
  `Ingestor` deliberately does not swallow errors around the recompute and invalidation: the pass
  throws, the anchor stays put, and the deletion replays. Advance it anyway and one transient error
  strands stale findings on deleted data permanently.

  That reasoning was written in a comment and enforced nowhere; the fake `HealthReading` can now
  throw mid-recompute, so it is a test. Verified by changing one `try` to `try?`: the pass stops
  throwing AND the anchor advances from 1 byte to 3 — both halves of the failure visible at once.

  Also pinned alongside it: a metric HealthKit holds nothing for still records an anchor, or every
  later pass retakes the expensive first-ingest probe for a metric that will never have data.
  Verified by gating the anchor save on `addedCount > 0`.

  Five ingest properties are now covered where there were none two turns ago — deleted rollups
  removed, findings on deleted data retired, the window not overreaching, the anchor safe under
  failure, and the empty-metric case. Every one of them sits upstream of every finding, and none was
  reachable before HealthKit went behind a protocol.
- **History deepening, which the newest detector depends on.** Deepening is the only path that
  reaches back years: a first ingest on a capped-era install stops short, and the incremental window
  covers 40 days. `SeasonalityScan` needs TWO YEARS before it says anything, so if deepening silently
  no-opped the annual-rhythm finding would never fire for anyone — and nothing would report an error.
  The app would just be quieter than it should be, which is the hardest kind of failure to notice.

  Now covered end to end: deepening recovers the older day, leaves existing rollups alone, and marks
  the metric done so the expensive probe runs once. Verified by dropping `markHistoryDeepened` and by
  inverting the anchor guard (`!= nil` → `== nil`), which makes deepening skip every metric that has
  ever been ingested — the shape a plausible "only deepen fresh installs" misreading would take.

  A detail worth keeping: with the marker never set, the SECOND deepen still does not re-probe,
  because the first pass recovered the old day and `deepenSpan` then finds nothing older and marks it
  through the nil-span branch. The two tests are therefore not redundant — one covers the marker, the
  other covers the outcome the marker exists to produce, and they fail independently.
- **The background task's once-latch, extracted so it can be tested.** `CompletionGuard` guarantees
  `setTaskCompleted` is called exactly once. Called TWICE it traps; called NEVER, the system kills
  the app and cuts its future background windows — which for this app means less Neural Engine time,
  the one thing it is measured by. Both callers race by design (the work task finishes on one queue
  while the OS fires the expiration handler on another), and this file already records a field bug in
  that exact area: `MainActor.assumeIsolated` in the expiration handler, which trapped.

  `BGTask` cannot be faked, so the guard around it stays untestable — but the latch does not have to
  be, and is now `OnceLatch`.

  **The concurrency test's sensitivity was measured, not assumed, and the result is worth recording.**
  Splitting the latch's read and write across two lock acquisitions — a genuine race — did NOT fail
  it: 32 claimers over 50 rounds never landed inside so narrow a window. Widening the window with a
  spin between them fails immediately, at 11-12 winners. So the concurrent test catches a race with a
  non-trivial window and can miss an instruction-width one; the reliable guarantee is the sequential
  property, and the single `withLock` is what actually makes the narrow case impossible.

  That limitation is written into the test. A concurrency test that passes is weak evidence, and
  saying so is more useful than the green tick.
- **When a concurrency test is worth trusting — measured on the two in this codebase.** Both use the
  same shape: 32 racers, exactly one may win. Their evidential value turns out to be completely
  different, and the difference is not obvious from reading them.

  - `RunGateTests` is RELIABLE. The realistic regression is an `await` inside `tryAcquire`, which
    breaks atomicity through actor reentrancy; injecting it fails the test every time, 31 winners
    against 1. A suspension point is a real, scheduler-visible interleaving opportunity, so every
    racer piles into it.
  - `OnceLatchTests`' equivalent is NOT. Splitting the latch's read and write across two `withLock`
    calls is a genuine race, and 32 claimers over 50 rounds never hit it. Only a widened window (a
    spin between them) fails, at 11-12 winners. An instruction-width window is invisible to this
    shape of test.

  Both limitations are now written where the tests are. The general point: a passing concurrency test
  is evidence about the size of the window you failed to hit, not about the absence of a race —
  unless the mechanism makes the interleaving deterministic, as an actor's suspension point does.
- **A test comment that claimed more than the test showed.** `precompute is idempotent and safe to
  race against a tool call` said its equality assertions were how you observe that a racing caller
  JOINS the in-flight scan rather than starting a second one. They are not. The scans are
  deterministic and pure, so a duplicated scan returns an identical result and equality cannot
  distinguish the two. Timing cannot either — unmemoized scans would run concurrently, so wall-clock
  would barely move.

  The property is real and load-bearing (a duplicated scan is pure CPU burned while the Neural Engine
  waits, which is the substrate's whole reason to exist), and it IS implemented — memoizing the
  `Task` rather than the value. It is simply not observable from outside without a counter inside the
  substrate, i.e. test-only state in production code, which is worse than the gap.

  The comment now says what is verified, what is not, and why. Same standard applied to the tests as
  to the app: a claim in prose that nothing checks is the thing this whole exercise is about, and
  test comments are not exempt.
- **`analyze` was the only tool with no direct test.** A file-by-file sweep for source whose types no
  test ever names over-reports extensions, but it surfaced a real gap: of the nine tools, `analyze`,
  `metricStats` and `metricsOverview` had none. `analyze` is the one that matters most — it is the
  tool that lets an agent define its OWN view of the data rather than pick from a menu, so its
  boundary is where four model-written strings become a query.

  The ENGINE beneath it is covered thoroughly, which is not the same thing. The tool's own job is
  resolving those strings against closed vocabularies and refusing what it cannot resolve. Now
  pinned: an unknown metric, statistic or day-filter is REFUSED rather than coerced; a valid query
  really does answer (so the refusals are not passing trivially); every value is finite and rounded
  at the boundary across all statistics and windows; and a reversed window is read the way it was
  obviously meant rather than as an empty range.

  Verified by making an unknown metric fall back to `.stepCount` — the shape a well-meaning "be
  lenient with the model" change would take. It fails with `available: true, value: 9281.0,
  description: "mean of Steps…"`: a real, confident number about a metric the agent never asked for,
  which is precisely the failure the closed vocabulary exists to prevent.
- **The last two tools, and the background breadcrumbs.** `metricStats` and `metricsOverview` were
  the remaining tools with no direct test. `metricStats` is served from the substrate's memoized
  cross-product rather than by re-querying, and that design has a consequence worth pinning: the
  number it hands the agent must be the SAME one the rest of the session reasons over, or a session
  ends up holding two values for one statistic. Also pinned: an out-of-vocabulary key reports
  `confident: false` rather than a plausible zero, because a confident zero is a number the model
  would quote. `metricsOverview` must actually name the metrics that have data (an empty digest sends
  every investigator in blind) and stay coherent on an empty library.

  `BackgroundRunDiagnostics` is two lines of `UserDefaults`, but it is the only evidence a person has
  that on-power background compute happens at all — and this app's purpose is measured in how much of
  it happens. The failure worth guarding is a copy-paste one: two stamps sharing a key, so a cheap
  power-independent REFRESH lights up the enhance row and Settings reports a full agent pass that
  never ran. Same class as the duty-cycle meter claiming "last minute" before it had one. Verified by
  pointing both stamps at the same key.

  Every tool the agents call now has direct coverage, and every claim the Settings screen makes about
  background compute is pinned.
- **One observer fire, and the placement of a single call.** `ObserverManager` takes the run gate so
  an observer ingest's deletion-tombstones cannot interleave with a discovery run's appends — a
  finding built on just-deleted data could otherwise survive. When the gate is held the ingest is
  skipped, which is safe: the delta sits at the saved anchor and the next gated ingest picks it up.

  What is easy to lose is where `onIngested` sits. It is the call that ASKS for an enhancement pass,
  and it must fire whether or not the gate was free. Moved inside the `if`, every observer fire that
  lands during a run stops requesting one: nothing errors, the app simply gets less background
  compute — the single thing its purpose is measured in, and a loss that would show up only as the
  app being quieter than expected.

  The per-fire logic is now `handleObservedChange`, testable because `Ingestor` takes
  `any HealthReading` — the same seam paying off a third time. Pinned: a free gate ingests and
  signals; a held gate skips the ingest and STILL signals; and the gate is released afterwards, or
  the first observer fire of a session would block every later run permanently. Verified by moving
  the call inside the gate.

### 2026-08-02 — Provenance: the evidence the numbers cannot contain

Buy a new Apple Watch and resting heart rate steps a few bpm and stays there. Replace a scale and
body weight reads two pounds heavy forever. Upgrade a phone and step count moves, because a
different device is now deciding what a step is on a desk.

Every one of those is a genuine, sustained level shift. `RegimeShiftScan` detects it correctly. The
skeptic panel finds nothing wrong with it, because nothing IS wrong with it. A replication analyst
re-computing the claim a different way agrees — re-computing the same rollups reproduces the shift
faithfully every time, since the shift is really in the data. Every safeguard in the app passes, and
the user is told their body changed when their equipment did.

No amount of measuring can separate the two cases, because the difference is not in the numbers. It
is in who wrote them. So the app now records that.

**Capture is free.** `HKStatistics` already knows which sources contributed; the property is simply
nil unless the query asks with `.separateBySource`. Both quantity paths (per-day and the
statistics-collection backfill) now ask, inside queries that were already running. Interval metrics
(sleep, mindful) take the names from the samples that survived the `include` filter — a sleep source
whose every stage was filtered out did not contribute and must not appear as though it did.
`SourceSignature` canonicalises the result: sorted (HealthKit's order is unspecified, and an
unsorted signature would read as a device change every time the order flipped) and de-duplicated
(hundreds of stage samples a night, one watch). It rides on `MetricRollup.sourceSignature`, empty
for days ingested before this existed.

**`ProvenanceScan`** walks each metric's stored days in order and reports the transitions, with the
run length either side. It skips unknown days rather than treating `""` as a source — otherwise
every pre-existing stretch would sprout two spurious changes at its edges, for every existing user,
on nothing but our own upgrade.

**Delivery is split by where the token budget is.** Adding a `provenance` tool to the explore pass
measured its prefix at 2,210 tokens against the 2,048 `TokenHarnessTests` allows. So the evidence
reaches that pass the way `suspectedDeviceSwap` already does — woven into the `patternScan` regime
basis it reads anyway (`RegimeShift.sourceChangeNote`), which costs nothing in the prefix, nothing
on rows with no change to report, and puts the caveat in the same sentence as the claim rather than
behind a call the agent must think to make. The tool itself goes to the replication analyst, which
has headroom and whose whole job is doubt — and which is otherwise structurally unable to catch this
class of error, since every recomputation of an artifact reproduces it.

**It complements the existing heuristic rather than replacing it.** `suspectedDeviceSwap` infers a
device change from several Watch vitals stepping together. That catches a firmware recalibration
that leaves the source name unchanged, which provenance cannot see, so it stays. But it is
structurally blind to a change affecting ONE metric — and a new scale moves body weight and nothing
else, a new phone moves step count and nothing else. `ProvenanceWiringTests` pins that gap: the
fixture's swap is invisible to the heuristic (`suspectedDeviceSwap == false`) and plain to
provenance.

**No threshold anywhere.** The annotation attaches the NEAREST source change with the distance
stated, so a change eleven months from a step is visibly irrelevant and one on the same day is
visibly damning, without this code deciding which. It states how long the new setup held, which is
what separates a watch swap from a watch left on the charger overnight. A device change and a real
change can land in the same week, and a rule that suppressed the finding would throw that away — so
nothing is suppressed. Numbers inform, agents decide.

**The scan order changed.** `regimesTask` now awaits `provenanceTask`, the one scan dependency in
the substrate. It costs the regime scan a single indexed fetch (provenance does no arithmetic) and
buys the one caveat that can invalidate a regime shift outright. Both still start inside
`precompute()`, so the wait overlaps the model's warm-up rather than stalling a tool call.

**Proven connected, not merely present.** `scan` takes `sourceChanges` defaulted to `[]` — the exact
"defaulted argument plus a hand-supplied unit test" shape that has produced dead features here
before. `ProvenanceWiringTests` runs the whole chain (fake HealthKit → `Ingestor` → `StoreWriter` →
`MetricStatsProvider` → `AnalysisSubstrate` → basis line) and was verified by reverting the
substrate to the default: the caveat silently vanishes and only that test notices.

### 2026-08-02 — Provenance, continued: the other two claims a swap fakes

The first pass annotated `RegimeShift` only, which left the feature looking finished while two of the
three vulnerable pattern kinds were still exposed.

A new scale reading two pounds heavy produces a **milestone** — "your highest 7-day weight ever" —
the most alarming of the three to get wrong, and one requiring no change in the person at all. A
device that samples differently produces a genuinely different spread, so a **volatility** shift
becomes a statement about the sensor. Both now carry `sourceChangeNote`, surfaced in their
`verifiedBasis` as an explicit `Caveat:` clause.

**The window is the claim's own, and that is what keeps this from being a threshold.** A record that
stands 90 days is a comparison against the last 90 days, so a swap 200 days back predates everything
compared and is irrelevant in fact rather than by judgment. `ProvenanceScan.noteForClaim` takes that
span from the caller and reports only changes inside it — which is also what keeps the note
affordable, since an unconditional "the source changed 1,100 days ago" on every row would spend the
token budget the whole delivery design was shaped around to say nothing.

**Milestone needed both of its spans, and the test is what proved it.** Keying on `spanDays` alone
looked obviously right and was wrong: `spanDays` is how long the record has STOOD, while
`config.window` is the rolling stretch whose mean SET it. Because those windows overlap, a scale used
for exactly the last seven days sets a record that stands only a day or two — so `spanDays` was
smallest in precisely the case the feature exists for. The annotation reaches back
`max(spanDays, config.window)`.

Two fixtures, because one could not do both: the watch swap steps DOWN across 60 days and sets no
record at all, and a step longer than seven days makes the final rolling window TIE its predecessor
(`latest > maxPrior` false — a record that is not strictly a record, the same trap the seasonality
fixture hit). The scale fixture changes on exactly the last seven days. Verified by reverting both
substrate wirings: the caveats vanish and only the wiring test notices.

### 2026-08-02 — Why `seasonal` has no provenance caveat, and what actually prevents the artifact

Three pattern kinds now carry a device-swap caveat. `seasonal` deliberately does not, and the reason
given when the others were annotated was an argument rather than a measurement — offered in the same
breath as three annotations that all turned out to be necessary. `SeasonalProvenanceTests` settles
it with numbers.

Against a real 3-unit January effect recovered at **2.80**, the same-magnitude device step reads
**0.404** mid-history (~7x attenuated) and **0.0016** when dated to a year boundary (~1,800x). The
scan still emits a swing in both cases, because it emits every computable one and lets the agent
weigh it — so the question was never whether a number appears, only how big.

Adding the caveat here would also be actively harmful rather than merely unnecessary. A seasonal
claim's comparison window is the metric's WHOLE history, so the window rule that keeps the other
three notes rare would annotate every seasonal finding of any metric that ever changed device — on
the rarest and most valuable finding type. A note on every finding is the same as a note on none.

**The mechanism is not the one it looks like.** The obvious explanation is the per-year
least-squares de-trending — it sounds like exactly what absorbs a step, and getting it wrong was a
real bug during this scan's development. It is not what does this job: reverting it to a per-year
mean leaves every assertion in `SeasonalProvenanceTests` passing. What protects the scan here is
**cross-year averaging** — a month's deviation is the mean of that month over every year it appears
in, so a one-time step speaks in one year and is divided by the others. Letting the most extreme
year speak for a month instead triples the artifact (0.40 → 1.21) and breaks the bound.

**Both defences are real; they just guard different things.** The sentence above must not be read as
"the line de-trending is unnecessary" — the same injection run against `SeasonalityScanTests` fails
two tests immediately, a straight-line series scoring a 1.52 SD "seasonal" peak, exactly the figure
the engine's own doc cites. So:

- per-year **line** de-trending stops a multi-year TREND from posing as a season;
- cross-year **averaging** stops a one-time STEP (a device swap) from posing as one.

Neither substitutes for the other, and both are now pinned by injection rather than by argument.

### 2026-08-02 — Ask remembers the last two exchanges

The Ask screen kept a transcript and rendered it as a conversation, and replayed none of it. Asking
"How have my steps been?" and then "Why?" sent the agent the bare word "Why?" — it could only guess
or decline, on a screen that had just implied it would know.

That was documented rather than accidental: withholding the transcript kept the 4,096-token window
at arm's length. The constraint is real; what was excessive was the remedy. Never replaying anything
is the maximally conservative reading of "don't overflow the window", and a bounded replay costs a
fixed few hundred tokens no matter how long the conversation runs.

`ConversationTurn.context` renders the last **two** completed exchanges, **220 characters a side**.
Two, because the referent a follow-up reaches for lives in the immediately preceding turn, while
older ones cost the same tokens and are likelier to point the gather pass at something the user has
moved on from. The clamp cuts each side's TAIL, since a follow-up refers to what was asked and to
the opening of what was answered.

Both passes get the identical text from one renderer. The **gather** pass needs it more than the
answering pass: it must resolve "why?" into something measurable before it can choose a tool at all,
and a tool call made against the wrong referent spends one of its four on the wrong metric.

`Instructions.answerer` is told earlier exchanges may arrive (1,055 → 1,230 characters, bound 1,300).
`Instructions.explorer` is deliberately NOT — it is shared with the investigator's explore pass,
where no conversation exists, and its prefix already had to give up a tool to stay under the harness
bound. The gather pass gets the context in its prompt instead.

**Wiring, not clamping, is where this would die.** `history` is defaulted at all four links —
`ChatView` → `AppModel.ask` → `Orchestrator.answer` → `Subagents.answer` — so every one compiles and
runs while forwarding nothing. `SubagentCallRecorder` now records what each Q&A call received, and a
source-scan invariant pins the one link a runtime test cannot reach: `ChatView` is a SwiftUI view, so
nothing exercises the call that starts the chain, and an edit to `send()` that dropped `history:`
would compile and silently restore the old behaviour. Both were verified by injection.

### 2026-08-02 — Provenance needed a backfill, or it covered only the future

`MetricRollup.sourceSignature` was added with a default of `""`, which is what makes it a lightweight
SwiftData migration: every existing row keeps the empty value and nothing breaks. Correct, and
useless. `ProvenanceScan` skips unknown days by design, so on an install that has already ingested,
the only days carrying provenance would be the ones arriving after the upgrade — and a device swap is
historical by nature, since the whole point is explaining a step from months ago. The feature would
have been silently inert on precisely the installs with enough history to have swapped a device.

`backfillProvenanceIfNeeded` clears the derived ingest cache once, keyed on a `UserDefaults` flag set
only on success, so the next catch-up rebuilds the full window with provenance captured throughout.
Rollups are a pure cache of HealthKit, so this is safe by construction.

**Its scope is the load-bearing part.** It sits next to the civil-day migration, which also clears
findings, correlations and the journal — right for that one, whose rollups were WRONG so everything
derived from them was too. These rollups are right and merely lack a caveat they could have carried.
Deleting a person's feed to re-derive findings that would mostly come back identical is a destructive
answer to a non-problem, and clearing the journal would additionally un-teach the fleet every dead
end it has learned across runs. The standing-finding audit re-examines what is already there with the
new evidence available.

That distinction is a comment away from being "tidied" into a copy of its neighbour, and no such edit
would fail to compile — so `ProvenanceBackfillTests` pins it three ways: `resetIngestCache` alone
leaves findings and journal intact, the migration body calls none of the three destructive writers,
and something actually invokes it at bootstrap. All three verified by injection.

`AppModel` crossed the 500-line limit here, so both migrations moved to `AppModel+Migrations.swift`.
The source-scan invariants deliberately search the whole target rather than a named file: an
invariant that names a file stops checking anything the next time one moves, silently — which is the
failure mode this very split would have caused.

### 2026-08-02 — The interval path was computing provenance from bucketing, not contribution

`mergedDailyRollups` — where sleep and mindful minutes become daily rollups — had no coverage of any
kind. It is reachable only through `HealthStore`, and the ingest tests enter one level above it via
`HealthReading`, so its arithmetic had gone unexercised since it was written and the provenance added
to it days ago was never run at all. It is now internal, for that reason, and tested.

Writing those tests surfaced a real defect in the new code. `DayMath.daysTouched` is inclusive of the
END day, so a sleep session finishing at exactly midnight is bucketed onto the following day while
contributing zero seconds to it. Reading a day's sources from what was BUCKETED there put that source
into one day's signature and no other — a one-day flicker, manufactured by us at a midnight boundary,
that `ProvenanceScan` cannot distinguish from a genuine brief change of device. Rare, but systematic,
and exactly the noise provenance exists to cut through rather than add to.

Sources are now taken from intervals with a positive clamped duration in the day
(`Interval.seconds(within:)`). It is the same distinction already made in the per-day path, where
sources come from the samples that survived the `include` filter rather than from everything fetched:
being bucketed onto a day is not the same as having recorded any of it.

The suite also pins the arithmetic the provenance assertions rest on — overlapping stages from one
source merge rather than sum, two devices on one night give one duration and two sources, and a night
crossing midnight credits its source to both days, because it did record on both.

### 2026-08-02 — A coverage sweep, and the two silent-catastrophe invariants it found

Asking "what does nothing exercise?" had found three defects in as many days, so it was worth asking
mechanically rather than by intuition: for every file in the app target, does any test reference a
symbol it declares?

The first sweep's list was mostly noise — my own `\bToolPrecision\b` failed to match
`ToolPrecisionTests`, which is thoroughly covered and pins both of that function's documented
regressions. Worth recording as its own lesson: a scan that under-matches produces a list of things
to "fix" that are already fine, and acting on it wastes exactly the effort the scan was meant to
direct. Corrected, the list came down to eight files, of which two guarded failures that would be
both silent and total.

**Background task identifiers.** They exist twice — in `Identifiers` and in `Info.plist` under
`BGTaskSchedulerPermittedIdentifiers` — and `Identifiers`' own doc says "that list can't reference
Swift, so keep the two in sync". `BGTaskScheduler.register` fails for an identifier the system has
not been told to permit; it fails at REGISTRATION, on a launch path nobody watches, with no
user-visible symptom. The app keeps working in the foreground and never wakes up again — and the
compute it does while nobody is looking is the whole point of it. A bundle rename, a third task, or a
typo on either side all produce the same silence. `BackgroundIdentifierTests` reads the built app's
plist (not the source tree) and checks both directions, plus that the identifiers are namespaced
under the bundle id. Verified by renaming one in Swift alone.

This one genuinely cannot be derived away: a plist cannot reference Swift, and reading the plist at
registration time relocates the risk to a different string rather than removing it.

**Schema completeness.** Every `@Model` must appear in `SchemaV1.models`, and the two lists are
written independently. Omitting one compiles, and passes every other test in the suite — because the
tests build their containers from the same incomplete schema and are consistent with it. On device
the container cannot open, and `VerdantApp` deliberately falls back to an in-memory container, which
is right for a foreground launch and means the app would run normally while discarding every write.
`SchemaCompletenessTests` scans `@Model` declarations from source (a hand-written list would be a
third copy drifting alongside the two it reconciles), checks both directions, and opens a container
against the result. Verified by dropping `ResearchJournalEntry` from the array.

### 2026-08-02 — `consistentAcrossThirds` answered the wrong question

The app detects regime shifts in a metric's LEVEL and had nothing for a shift in a RELATIONSHIP. It
looked as though it did: every correlation carries `consistentAcrossThirds`, "held its direction
across most of the record". Reading how that is computed shows it cannot mean what it is being asked
to mean.

`signHoldsAcrossThirds` counts a third as agreeing when `|r| >= 0.1` and the sign matches the overall,
and passes on two of three. So a link running **0.55, 0.51, 0.04** scores two of three and is reported
as CONSISTENT — while what actually happened is that it ended. And one running **0.02, 0.08, 0.61**
scores one of three and is reported as inconsistent, i.e. unreliable — while what happened is that it
began. Both are exactly the findings a person cannot see for themselves, and the flag points away
from both.

This is not a defect in the flag. "Is this one lucky stretch?" is a real question and the flag answers
it correctly; "is this still true?" is a different question it was never asked. The failure was
letting a boolean stand where the numbers should have travelled — the engine rendering a verdict and
hiding the evidence behind it, which is precisely what this codebase's stated principle forbids.

So the thirds are carried as numbers (`MetricCorrelation.thirdsR`) and no rule is applied to them.
Whether a faded link means a changed body, a changed routine, a changed device or noise is the
agents' judgment.

**Delivered twice, sized to each budget.** `verifiedBasis` — read by the skeptic and replication
panels — states all three, at a few tokens on a line already being sent. The `correlationScan` row,
where the transcript budget actually binds, gets ONE number: the newest third. Paired with the
whole-record `coefficient` it already carries, that is enough to see a fade (0.40 overall, 0.04
lately) or an emergence (0.20 overall, 0.61 lately) at a glance, and it is the only addition that
says something neither existing field can.

Its fallback matters as much as its value: with a record too short to split it reports the OVERALL
figure, not zero. Defaulting to zero would tell the agent a short record's link had vanished —
manufacturing the very finding this exists to enable.

`consistentAcrossThirds` stays, unchanged in meaning, and is now derived from the same split as the
numbers stated beside it so the two can never describe different thirds. No prompt changed: no
instruction names any `correlationScan` row field, and `@Guide` is how every one of its siblings is
already explained.

### 2026-08-02 — Sweeping for the same defect: verdicts standing in for numbers

The thirds finding was an instance of a pattern this codebase names as a principle — "numbers inform,
agents decide" — so it was worth checking the other engine-produced booleans rather than waiting to
trip over the next one. Every `Bool` on the domain types was read against the question: does the
evidence behind it travel too, or does the flag replace it?

Most passed. `MetricStat.confident` is derived from `recentCount`, `baselineCount` and `baselineSD`,
all present on the struct. `VolatilityShift.meanHeld` thresholds a mean change whose two means are
both carried. `activityControlled` and `mechanicallyRedundant` are facts about what was done, not
judgments about evidence. `significant` travels with its `pValue`.

`RegimeShift.suspectedDeviceSwap` did not. `flagDeviceSwaps` computes how many Watch-measured vitals
stepped within a few days of each other and then tests `cluster.count >= 2`, discarding the count.
Two vitals moving together is thin evidence for a device change; five on the same day is near-certain
hardware — and the agent was told the same thing in both cases.

It is now carried as `coJumpingVitals` and stated in the basis. The inconsistency that made this
worth fixing rather than merely noting: it sits directly beside `sourceChangeNote`, added days
earlier, which states its own distances and run lengths. An inferred caveat should not be the vaguer
of the two when its evidence is just as countable.

`suspectedDeviceSwap` keeps its exact meaning (`coJumpingVitals >= 2`), so nothing downstream shifts.
The test uses THREE vitals rather than two, because a hard-coded 2 would satisfy a two-vital fixture —
verified by injecting exactly that.

### 2026-08-02 — Finishing the sweep: dropping guards, and the second copy of the same flag

The boolean sweep had a companion question: does any engine still DROP a candidate on a worth
judgment, rather than emitting it with weak numbers attached? Every `guard … else { return nil }` in
`Verdant/Engine` was read. They are all computability floors or definitions — `sd > 0`, `isFinite`,
`count >= minSamples`, a milestone window that must be calendar-dense to mean anything, two months
needed before a "swing" exists. The worth-guards really were removed earlier; nothing has crept back.

The sweep did surface `DeviceSwapFilter`, whose name still says "filter". It no longer filters — the
destructive `removingSuspectDays` was deleted earlier and the days now travel flagged — but it was
carrying the SAME defect just fixed in `RegimeShiftScan`, in the other of the two places this
signature is computed: `jumpsPerDay.filter { $0.value >= minVitals }.keys` throws the count away and
returns a `Set<Date>`. So two Watch vitals jumping together and five jumping together reached the
agent as the same fact, on the strange-day path, days after the same thing was fixed on the regime
path.

It now returns `[Date: Int]`, `UnusualDay` carries `coJumpingVitals`, and the basis line states it.
`suspectDays()` remains for callers that only need membership. Both fixes use a THREE-vital fixture
because every existing fixture in the suite uses two, and a hard-coded 2 would pass against those —
verified by injecting exactly that constant on each path.

The general lesson is about where to look after a fix, not about device swaps: this signature is
computed in two places, and fixing the one that prompted the thought left the other reporting less.
Worth asking, after any "the evidence should travel" change, whether the same evidence is computed
somewhere else too.

### 2026-08-02 — A lens for relationships that changed, and an invariant on what prompts may name

The thirds work added evidence and nothing that asks for it. `correlationScan` now reports each
pair's newest-third coefficient beside its whole-record one, but no lens told the fleet to compare
them — so the fleet would mostly not have. That is the "a new detector is only half the work" lesson
in its other form: the evidence existed and the prompt did not.

`investigationLenses` gains one: relationships that CHANGED — a link that was strong and has faded,
or one that has only recently appeared. It names the two coefficients rather than
`consistentAcrossThirds`, and says so, because that flag actively misdirects here (it calls a faded
link consistent and an emerging one unreliable). A lens costs no prefix tokens — it is one more
investigator session, which is work the engine should be doing anyway.

**And a new invariant, because the lens names a FIELD.** `SessionToolsTests` pins that a prompt may
only name tools its role holds, which exists because a prompt naming a missing tool was a real bug
here. Prompts also name schema fields, and nothing checked those: a lens naming a renamed field sends
an investigator hunting for a number it can never find, burning a session with no crash and no error
— the same cost, the same silence. `PromptIdentifierTests` reads the RUNTIME prompt strings (so doc
comments full of Swift identifiers are excluded by construction), extracts every camelCase token, and
requires each to be a tool name, a `@Generable` property, or an enum case.

Its first run reported two false positives — `stdDev` and `coefficientOfVariation`, both real
`AnalysisStatistic` cases reaching the model through `.anyOf`. The vocabulary was collecting
`@Generable` properties and tool names only. That is the second time in two days an under-matching
sweep has produced a list of correct code to "fix", so the fix was made generic rather than curated:
every enum case anywhere, not a maintained list of the vocabularies exposed today. Over-permissiveness
only weakens this check; it can never make it lie, and a curated list would fail in the direction
that wastes effort and trains you to wave the next real hit through.

The same reasoning applies to its own canaries, which pin `holdsUp` and `stdDev` — one per collection
path, both long-lived — rather than the newest field, so a legitimate rename does not fail the test
that exists to catch illegitimate ones.

### 2026-08-02 — The new lens's findings would have been rejected, and the test that said otherwise was vacuous

Adding the "relationships that CHANGED" lens invites an agent to write "it ran 0.78 early and 0.22
lately". `NumericFidelity` drops a finding whose prose states figures nothing verified supports, so
the question is whether the thirds are reachable by that check — if not, the lens invites work that
is thrown away, which costs sessions and shows up as nothing at all.

They are reachable, but only through the basis: `unsupportedFigures` parses the basis prose as well as
the explicit `verified` list, and `persistCorrelationProposal` passes `corr.verifiedBasis`, which now
states the thirds. `persistCorrelationProposal`'s explicit list does NOT include them. So the lens
works because of a line added in a different file for a different reason — a real cross-file
dependency, and dropping the thirds from the basis to save tokens would silently start rejecting
these findings rather than merely making the basis terser.

**The first test of this was vacuous and passed anyway.** It used thirds of 0.55 and 0.04, and
`unitFactors` multiplies every verified value by 1, 1000, 0.001, 100 and 0.01 — with `n = 90` and
`nEff = 60` in the list, that puts candidates at 0.9, 0.6, 0.09 and 0.06, and a 5% tolerance floored
at 1 covers roughly [0, 0.14], [0.35, 0.45], [0.55, 0.65] and [0.85, 1]. Both figures sat inside those
bands, so the test passed whether or not the basis stated the thirds at all. Removing the thirds from
the basis did not fail it.

The control was wrong for the same reason before that: 0.87 was not flagged as invented because
`n = 90` × 0.01 = 0.9 sits within tolerance. That is the documented leniency working as designed
("a figure that happens to be 1000x a real one is possible but rare") — a bad control, not a bad
check.

Both are now chosen from the gaps between the covered bands (0.78, 0.51, 0.22, control 0.32), and
injection confirms the dependency: strip the thirds from the basis and the check reports
`["0.78", "0.22"]` as invented.

The lesson is narrow and worth keeping: when a fidelity check is deliberately generous, a fixture
number picked without regard to that generosity can make a test agree with you for free. Reading the
test did not reveal it. Injecting did.

### 2026-08-02 — A day count was vouching for a correlation

Chasing why a fixture number made a test pass for free led to the same leniency in production.
`NumericFidelity.unsupportedFigures` multiplies every verified value by 1, 1000, 0.001, 100 and 0.01
so a stored measurement can be restated in another unit — 8.4 km for 8,400 m, 97 for 0.97. Applied
to a SAMPLE SIZE, `n = 90` puts a candidate at 0.9. So on a correlation whose real coefficient is
0.40, prose claiming "these two move together at 0.90" passed the honesty check unremarked, and the
skeptic panel — which is told about unsupported figures and rules on them — was never told.

Measured across all two-decimal values on a typical correlation: **78 of 101 accepted**. Counts are
dimensionless and are never restated in another unit, so they now match at face value. That is
`counts:`, threaded through `survives` and every persist route (the `Double(…)` casts marked them
already). **78 → 66.**

Two things worth recording about the shape of this work rather than its result.

**A correction.** The intermediate numbers suggested adding the per-third coefficients to the basis
had "cost 29 points of precision". It had not. Those three figures are real evidence, and prose citing
one of them is honestly supported; more true numbers legitimately means wider coverage. The defect
was never the count of numbers, it was one kind of number vouching for another. Comparing like with
like — same basis, same evidence — the fix is 78 → 66.

**A revert.** Confining basis-parsed figures to face value as well took it to 52, and rested on
"every route passes its unit-bearing values explicitly", which is true of all six today. An existing
test failed and was right to: a caller may pass only a basis printing "5.2 km" while the prose says
"5,200 metres", which is a documented, sensible use. That change traded a standing safeguard against
crying wolf for a bounded gain, and a check that cries wolf is one the panel learns to ignore. Kept
the fix that needed no such bargain; the reasoning is recorded at the call site so it is not
rediscovered and re-attempted.

### 2026-08-02 — Nearly duplicated an invariant; extended it instead

Reading `InsightWriter` turned up `Calendar.current` where the codebase pins `Calendar.civil`, which
is the class of bug that already produced a live off-by-one here (the strange-day date was a day out
for every user west of UTC). The usage is correct — `CivilCalendar`'s own doc carves out exactly one
exception, the wall-clock "within the last N days" freshness cutoffs, and all fourteen uses are
those — but the rule was prose, so it looked worth mechanising.

It was already mechanised, and better. `ArchitectureInvariantsTests.day attribution never uses the
device calendar` bans local `startOfDay`, `autoupdatingCurrent`'s version, device-formatted dates,
and constructing a `Calendar` anywhere but `CivilCalendar`. The new suite was a strict subset of it
and was deleted. The miss was procedural: the source tree was grepped for `Calendar.current` and the
TEST tree was not.

Writing it did surface one real gap, so the existing invariant was extended rather than paralleled.
It named `startOfDay` and nothing else, while `component(.month, from:)` and `isDateInWeekend` are
the same bug in different clothes — both read the device zone, both slip a boundary west of UTC.
Neither is used today; they are banned because the rule is "no attribution on the device calendar",
and a rule listing only the operation that has already gone wrong invites the next one in.
`dateComponents(from:to:)` is deliberately still allowed: with two dates it measures a difference,
which is what the freshness cutoffs legitimately do. Verified by making `SeasonalityScan` read a
month from the device calendar — the ban names the file, the operation and the line.

The deleted suite also had a defect worth recording: it scoped a check with
`source.path.contains("/HealthKit/")`, but `SourceScan.swiftSources()` returns BASENAMES. That check
matched nothing and passed. A sibling assertion failing is the only reason it came to light — the
third time in two days that a sweep's own matching, rather than the code it sweeps, was the thing
that was wrong.

### 2026-08-02 — The zero-cloud ban had no positive control

Three times in two days a sweep's own matching, rather than the code it swept, was the thing that was
wrong. That made it worth auditing the existing source scans for the same flaw, most of which turned
out to be guarded already — `authorizationSites >= 1`, `#require` on the file being read, an
entitlements check that asserts the HealthKit key IS present to prove the file was parsed.

`the app links no path off the device` was not. Every assertion in it is a NEGATIVE — URLSession,
CKContainer, CKDatabase, PrivateCloudComputeLanguageModel and NLContextualEmbedding are each absent —
and `SourceScan.uses` is a hand-written matcher. Had it stopped working, all five would have been
satisfied while reading nothing, on the one guarantee this app cannot get wrong. It now proves the
matcher finds a type and an import the app demonstrably uses before it asserts anything is missing.
Stubbing `uses` to return false fails it by name.

Writing the control also exposed a real gap in the matcher. It recognised `Token(`, `Token.` and
`import Token`, but not a type ANNOTATION — `let session: URLSession = .shared` contains none of the
three and would have passed the networking ban unremarked. Unlikely to be written, but the entire
value of that ban is that it holds for code nobody reviewed. Added and verified by putting exactly
that declaration into a source file: previously invisible, now named.

The general rule this settles into: a suite of negative assertions needs one positive one. "Nothing
matches" and "the matcher is broken" are the same observation, and only a control can tell them
apart.

### 2026-08-02 — The changed-relationships lens outran the card (open item)

Following the new lens through to what a user would actually see turned up a limitation worth stating
rather than quietly leaving.

A faded relationship still persists as a `.correlation`, and that card shows a `StrengthBadge` with
the WHOLE-RECORD coefficient plus "Move together … across ~N days". So a finding whose story is "these
tracked each other closely until spring and have not since" appears beside a badge asserting they move
together at 0.40. Nothing displayed is false — that coefficient is real over the whole record, and the
dual-line chart above genuinely shows the divergence — but the card cannot express the claim its own
story is making, and the headline number reads as the current one.

This is milder than the case that justified a whole new finding type for `seasonal`, where the default
treatment was actively WRONG (anomaly copy and recent-vs-baseline numbers under a claim about January).
Here it is true and incomplete. That difference is the reason for not building a fifth card type on my
own judgment: a faithful one needs its own copy, its own resolved numbers and its own chart span, which
is a product decision rather than a refactor, and the current treatment misleads nobody outright.

Two things done instead. The lens now tells the investigator that the whole-record strength is printed
beside its words, so the prose must name the stretch it means and give both figures rather than let the
headline number read as current. And the limitation is recorded at `verifiedFacts` itself, where anyone
changing that card will meet it.

**Open item for the owner:** whether a relationship that ENDED deserves its own finding type. It is the
one class of finding the app can now detect and cannot present faithfully.

### 2026-08-02 — The retest planner was told its analysts had a tool they now do have

Verifying a claim made in an earlier entry — that the standing-finding audit re-examines old findings
with provenance available — traced the chain and confirmed it: `auditStandingFindings` →
`survivesReplication` → `subagents.replicate` → `replicatorTools`, which carries `ProvenanceTool`.
True as written.

But following it one step further found the gap. Replication runs three fixed generic lenses plus
extras composed by a PLANNER agent, and `Instructions.retestPlanner` told that planner each check
"must be something an analyst can actually compute with analyze or unusualDays". So the one agent
whose entire job is choosing what to re-test had been told the new tool did not exist, and would never
propose the check that matters most for a level shift: re-computation reproduces an artifact
faithfully every time, and only the record of which device wrote the data separates a changed body
from a changed watch. Adding a tool to a session is not finished until every prompt that reasons
ABOUT that session knows.

`SessionToolsTests` gains the reverse invariant it lacked — every tool a session HOLDS must be named
in its prompt, not merely every named tool held. An unmentioned tool costs its schema in the prefix on
every call and earns nothing.

Two corrections worth recording over the result itself.

The first injection appeared to show the new test was vacuous. It was the injection that was
incomplete: it removed the mention from `retestPlanner` while `Instructions.replicator` — concatenated
into the same role prompt — still contained the word. Replacing every occurrence fails the test by
name. An injection that does not fail is a claim about the test, and it has to be verified as
carefully as the test itself.

The second is that the new invariant would NOT have caught the bug that prompted it, and the comment
first written on it said otherwise. A role's prompt is the concatenation of what its sessions read, and
the analyst instruction did mention the tool. Nor can it be tightened to catch it: the planner is a
session with no tools of its own, so there is no held set to compare against — its knowledge of the
analysts' toolset is prose about a different session. Recorded at the test, since a comment claiming
coverage that does not exist is worse than no comment.

### 2026-08-02 — A live drift: the challenger was told there were six skeptics

Generalising the retest-planner fix — a prompt that reasons ABOUT another session can go stale
invisibly — found only two such prompts in the app, and one of them had already drifted.

`Instructions.challenger` sets the agenda for the skeptic panel. It opens "Six reviewers will already
ask the generic questions" and enumerates them, so the agent can answer the one question it exists to
answer: what would the generic set MISS? `Orchestrator.scrutinyLenses` has SEVEN. Numeric honesty was
added there and never here.

The consequence is not a crash and not a wrong number. The agenda-setter believed nobody was checking
whether the prose's figures match the verified ones, which makes "has anyone verified these numbers?"
among its most natural proposals — a whole extra session spent restating a lens that already exists,
which is precisely what the prompt's own closing line forbids. A slower panel arriving at the same
place, invisibly. A count that is merely stale is also worse than one that is absent: it reads as
deliberate, so a reader checks it least.

`PanelAgendaTests` pins both describers against the arrays they describe — the stated count matches,
no OTHER count is stated (a corrected sentence can sit beside a stale one), and the enumeration
reaches the newest lens, since a count alone would pass while the list rotted. Verified by adding an
eighth scrutiny lens: the failure names the array, its length, and the words the prompt should now
use.

Both remaining describers are now pinned. The class is small — most prompts describe only their own
session — but it is exactly the class nothing else in the suite could see, because a prompt saying
"six" is valid Swift no matter what the array holds.

### 2026-08-02 — The two-pass scaffolding was written twice, and had already drifted

Sweeping prompts for numbers that transcribe code constants found the good pattern in one place
(`keep at most \(budget)`, interpolated, undriftable) and a duplication in another.

The investigator's explore pass and Ask's gather pass are documented as the SAME pass — same
instructions, same tools, pinned by `SessionToolsTests`. Their scaffolding was typed out twice: the
budget sentence ("Use at most FOUR tool calls…"), the clamp on how many readings carry into the second
pass (5), and the clamp on each reading's length (160).

It had already drifted. One site formatted the carried-over readings with a single leading newline,
the other with two. Cosmetic, and precisely the shape that is not cosmetic next time: tuning 5 or 160
on one path would have left the other on the old budget, silently, on the 4,096-token window this app
overflows soonest and whose overflows are recorded here as real field failures.

Now one expression — `Subagents.measuredBlock` with `maxReadings`/`maxReadingCharacters`, and
`gatherBudgetClause` for the sentence. Standardised on the two-newline form. The third "FOUR" (the
commit pass) is deliberately left alone: it is a different instruction in a different sentence, and
collapsing genuinely different prose into a shared constant to make a number appear once would trade
a real duplication for a fake one.

`SessionToolsTests` pins that the clamps and the sentence each appear once. Verified by re-inlining
one of them.

### 2026-08-02 — The director was choosing "frontier" without being shown the frontier

A capability gap rather than a consistency one. The research director picks each pass's strategy —
breadth, drill into what the run already has, or FRONTIER, "push into unvisited ground" — and
`directorState` told it the pass yield, the dry streak, the feed's titles, what this run rejected and
what prior runs ruled out. Nothing about the data itself.

The shape of the territory did reach the fleet, through `coverage`, but only to the SCOUTS — and the
scouts run after the strategy is already chosen. So the one agent whose whole job is deciding where to
look next could not name a single unexplored metric, and "frontier" carried little more meaning than
"try harder".

`directorState` now ends with the metrics that have usable history and that nothing currently on the
feed covers. A correlation's second metric counts as covered, or the fleet would be aimed at half of a
finding already showing. The line is capped at five names and says how many it left out, because the
director's state is a prompt and a user with thirty unexamined metrics must not push the rest of the
state out of the window.

Phrased precisely, because it is weaker than "never investigated": findings get retired and curated
off the feed, so a metric listed here may well have been looked at. It is evidence for the director to
weigh, not a work list, and nothing acts on it automatically — the same posture as the barren-angle
line directly above it.

It costs no computation. `metricsWithData` reads the substrate that is already built and the feed foci
were fetched for the line above, so this is a fact the run already had and was throwing away before
the one agent that could use it.

Verified by injection twice: dropping the secondary-metric union reports a metric that is half of a
displayed correlation, and removing the call from `directorState` fails the wiring check — a helper
nothing calls being the failure mode these tests exist for.

### 2026-08-02 — The shape signal set 45% of a finding's quality and reached no agent

Continuing the "a fact the run already has and throws away" thread that found the co-jump count and
the per-third coefficients.

`MetricCorrelation.spearman` is computed for every pair. It is not dead — it feeds
`monotoneAgreement` (how well the rank correlation agrees with the linear one) which feeds
`trustStrength`, which is 45% of the finding's stored quality. So a nonlinear or outlier-driven link
was already being scored down.

It reached no agent. Not the tool row, not the basis, nowhere. And one of the seven standing scrutiny
lenses asks, in as many words, "would this still hold if the few most extreme days were removed, or
does it rest on a handful of outliers?" — so the skeptic panel was being asked a question the engine
had already answered, and not shown the answer. A deterministic term was quietly outranking findings
on evidence the agents judging them could not see, which is the arrangement this architecture exists
to avoid.

The basis now states it: "rank-vs-linear agreement 0.60 (1.00 = same shape; lower means a curve or a
few extreme days, not a line)". A few tokens on a line that is sent regardless — the same delivery
that carried provenance and the thirds, chosen for the same reason.

It is also passed explicitly to `NumericFidelity` rather than left to basis parsing. That dependency
was fine for the thirds and was recorded as fragile at the time; a figure the panels are now invited
to reason about should not stay quotable only because a sentence continues to render it.

### 2026-08-02 — Sweeping "computed but unseen", and correcting an earlier judgment

Three finds in a row came from noticing a computed fact no agent could see, so the question was worth
asking mechanically: for every field on the domain types, does it appear in that type's
`verifiedBasis` or in any tool row? Most of what the sweep returned was noise or fine —
`UnusualDay`'s fields are false positives (its basis is a stored string the script did not read),
`VerifiedFact.salience` is a ranking output agents have no use for, `RegimeShift.changeDay` is
derivable from the `postDays` the basis already states.

One was a genuine miss, and specifically a correction of an earlier entry here. The boolean sweep two
entries ago examined `VolatilityShift.meanHeld` and passed it, on the grounds that "both means are
carried on the struct". They are, and **no agent reads the struct**. The basis is what the panels see,
and it said only "while the average barely moved" or "and the average also shifted" — a threshold at
10%, so the first covers everything from 0% to 9.9%. The entire appeal of a volatility finding is that
the spread changed while the LEVEL did not, which is a claim about exactly the number being withheld.

The basis now states it: "while the average barely moved (0.8%)". A zero baseline prints no
percentage, since there is none to state.

The lesson is about the earlier sweep's criterion rather than about volatility. "Is the evidence
carried?" was the wrong question; "does it reach the agent?" is the right one, and a field on a struct
reaches nobody. That is the same distinction that made `spearman` invisible while feeding 45% of a
correlation's quality — checked against the wrong bar twice before the mechanical sweep caught it.

### 2026-08-02 — The record that never said what it was

The "computed but unseen" sweep flagged `Milestone.recentMean` and it was initially waved through with
the rest of the noise. It was not noise.

Every finding kind's basis states the figure its claim is about: a regime prints "from X to Y",
volatility both standard deviations, a season its swing in real units. Milestone printed a margin and
a span — "beats the prior extreme by 8% and has stood for 30 days" — and never said what the record
WAS. The most human part of "your highest week ever" is the number, and the agent writing that card
either left it out or spent one of four tool calls looking up something the detector had already
computed and was holding.

The persist route already passed `recentMean` to `NumericFidelity`, so prose quoting the value was
supported the whole time. It simply could not be known. Supported-but-unknowable is its own small
category of waste, and worth watching for wherever a `verified` list is richer than the basis beside
it.

The value goes through `MetricFormatting.canonical`, not `formatted`, and there is a test for that
specifically: this line is read by the MODEL, and the locale-aware path would hand a German device
"12.400" — the bug already found once in agent-facing numbers, which is exactly the kind that comes
back when a new call site is added by pattern-matching on a neighbouring one.

### 2026-08-02 — Bounding the basis lines, after growing five of them in a day

A check on my own work rather than the codebase's. The `verifiedBasis` strings are not log lines: the
persist path concatenates them into the claim that every skeptic and every replication analyst reads,
so each clause is paid once per panelist per finding out of a 4,096-token window.

Five clauses went in today — a provenance caveat on three kinds, the per-third coefficients, the
rank-vs-linear agreement, the mean-shift percentage, and the record's own value. Each was individually
cheap, each was well-motivated, and nothing measured the total. That is how a budget goes: not in one
bad decision but in five good ones.

Measured, with every optional caveat firing: correlation 337 characters, volatility 384, regime 616 —
about 154 tokens at the worst. Comfortable against a session that carries no tools. So the additions
were affordable, which is worth stating plainly rather than implying a near miss.

`BasisLengthTests` bounds them at 900 characters, leaving roughly one more clause of room and failing
before the next author discovers the ceiling on a device instead of in CI. Each case asserts its
caveats actually FIRED before measuring, so the worst case is really the worst case rather than a
short string passing easily. Verified by padding the regime core: 1,032 characters, named and
measured in the failure.

The general point is about cadence, not length. A series of individually justified additions to a
shared budget needs someone to measure the sum, and the person best placed to do that is whoever made
them — while they still remember that there were five.

### 2026-08-02 — Measuring the director's state, and being wrong about it by 20%

Applying the previous entry's lesson to the other thing that grew today: `directorState` gained a
seventh line (the untouched-metrics territory) and nothing measured the sum, exactly the gap that had
just been written up for the panel claims.

Reasoning through the clamps first gave ~1,900 characters. The measurement is **2,350** — about 590
tokens, comfortable against the director's window (its instructions plus one tool schema), but 20%
above the estimate. That is the third time here that adding up clamps by hand came out under the
real figure, and it is a good argument for making `directorState` internal purely so the number can be
taken rather than derived.

`DirectorStateSizeTests` bounds it at 2,600, asserting first that every line is actually present so
the measurement is not of an empty string. Two things are deliberately separated in that file:

- The 2,350 is the CLAMPS' worst case, not production's. The fixture writes 90-character reasons onto
  every journal row where the app uses short literals. Bounding the mechanism is the point — it stays
  honest if a reason gets longer later, which is the change that would otherwise slip through.
- Because of that, a real trim made here is invisible to it. Barren journal entries carried the
  constant reason "chased, nothing proposed" on every row, under a line whose own heading already
  reads "Chased with no yield" — the same fact stated four times in one line, diluting the lens text
  the director is meant to weigh. Now recorded with no reason, pinned by its own source-scan check in
  `BarrenAngleTests`, since the size test cannot see it.

### 2026-08-02 — The lens I added was five times the median length

Third and last application of "measure the sum". The investigator's window is the tightest in the app
— a ~2,048-token prefix of tool schemas and instructions, then the lens, the steering rings, the first
pass's readings, and whatever the tools return, inside 4,096 — and the sessions that overflowed on
device are recorded here.

Measured, the thirteen investigation lenses run 57 to 244 characters, median about 92. The
changed-relationships lens added today was **509**, more than twice the next longest and five times
the median. It had grown in two steps: the angle itself, then a clause appended later about how the
card presents a faded link.

It went unnoticed because lenses are not in any bounded budget. `TokenHarnessTests` measures the
PREFIX, and a lens is runtime — each session gets one as its focus line, so a long one costs only its
own session and no existing check could see it. Every budget in the app stayed green while one line
quintupled.

Trimmed to 379 without dropping a single instruction: the same three things are said (compare the two
coefficients, do not trust the flag, name the stretch in the prose) in fewer words. `LensBudgetTests`
bounds any single lens at 400 — generous on purpose, since the multi-year angle and the
sleep-attribution caveat both earn their ~244, so this guards against an essay rather than pushing
toward terseness. The focused drill-down's lenses are bounded too, built from a 200-character title to
make sure the clamp on that title is doing its job.

Three budgets measured today, three answers: the panel claims were affordable, the director's state
was 20% above my estimate, and this one was a genuine outlier I had created myself an hour earlier.
The pattern worth keeping is that none of them showed up as a failure — they showed up when someone
went looking for the total.

### 2026-08-02 — "Read 0 metrics across your logged history" was blaming the user for a failed read

Every run loaded its data with `(try? provider.dailySeries(now: now)) ?? []`, which makes a fetch that
THREW and a store that is genuinely empty the same value. The live feed then said "Read 0 metrics
across your logged history" — attributing to the person's history a read that may never have
succeeded.

The app's rule for that feed is stated plainly elsewhere in this document: no rotating filler, every
line is literally what is happening. This one was not. It is also the distinction that matters
practically — an empty store fills itself on the next ingest and needs nothing from anyone, while a
store that cannot be read does not, and is the single case worth a person noticing.

`Orchestrator.loadSeries` now returns the series with the line that describes it, in three forms:
what was read, "no logged history yet", or "couldn't read your stored history". Both run entry points
use it, pinned by a source check that the old collapsing expression is gone from each — the failure
mode being that one path is converted and the other quietly keeps the old message.

The focused drill-down says the load line BEFORE "Digging into …" when there is nothing to work from.
A drill-down that opens by naming the finding and then reports nothing reads as "your finding did not
survive", which is a different and more alarming claim than "the history could not be read".

The run still proceeds on a failed read, and the series is still empty. That is deliberate: the agents
find nothing and say so, which is honest, whereas refusing to start would require judging whether the
failure is transient — and `AppModel.storeIsEphemeral` already covers the case where writes would be
discarded, which is the one where continuing genuinely wastes a granted window.

### 2026-08-02 — "Breadth exhausted for now" was a reason the app no longer had

Sweeping the live feed for lines that claim more than the code knows, after the read-failure one.
Most survived — the safety panel's "N independent reviewers" derives N from the array it then
iterates, so it cannot drift, which is the pattern to copy.

One had not. Every drill pass announced "Breadth exhausted for now — drilling into …". That was true
when a dry streak was the only route into that branch. It stopped being true when the strategy became
the RESEARCH DIRECTOR's decision: the director may drill on pass two with nothing dry behind it,
having judged a standing finding worth deepening. The old dry-streak arithmetic survives only as the
fallback for when no plan renders — so the sentence was accurate in the rare case and wrong in the
normal one, telling a person watching the feed a why that belonged to a replaced architecture.

The claim is now made only when the fallback actually chose the drill. When the director chose, its
own directive is logged directly above, so the feed still says why — in the director's words rather
than in a guess about them.

This is the agent-inversion's shadow rather than a coding mistake: when a decision moves from
arithmetic to an agent, every sentence that explained the arithmetic becomes a claim about something
that no longer decides anything. Worth a sweep of user-facing text after any such move, which is
what turned this up.

### 2026-08-02 — A finding could reach the feed with no panel verdicts and no way to tell

Following the live-feed sweep into the copy on a finding's detail screen. Every kind's "How Verdant
found this" ends the same way: "…then put it through a panel of independent skeptics and analysts who
re-tested it against your data."

Two ways that could be false were checked. The panels are skipped entirely when `ctx.adversarial` is
false — but no production caller passes false (the flag is a test seam and the default is true), so
that path is fine.

The second was real. Both panels FALL OPEN when no verdict renders: a wholly rate-limited run keeps
its skeptic-passed finding rather than losing it to infrastructure, which is the right trade and is
documented as such. But `PanelOutcome.clause` returned `nil` whenever `rendered == 0`, so such a
finding arrived on the feed beside that promise with its provenance line simply missing the panel —
and a silent omission is indistinguishable from a detail nobody bothered to record. It is also the one
case where a person should trust a finding LESS, so silence is the worst available answer.

`PanelOutcome` now carries `convened`, because `rendered == 0` could not distinguish "the panel ran
and nothing came back" from "the panel never ran" — different facts, and only the first is worth
telling someone. A convened panel that heard nothing says "no skeptics could be reached"; one that
never convened still says nothing, since inventing a fact there would be the same failure pointing
the other way.

The fall-open behaviour itself is unchanged. This is about what the finding then admits.

### 2026-08-02 — Pinning the other half of the panel promise

The previous entry made a finding admit when a convened panel produced nothing. The complementary
risk is a panel that is never convened at all.

`survivesScrutiny` and `survivesReplication` both open with `guard ctx.adversarial`, and the flag
exists so tests can drive the persist path without the model. It defaults to true and no production
caller passes false, so today the promise holds. If one ever did — for a "fast" background pass, which
is exactly the tempting reason — every finding it produced would carry copy promising two panels that
never ran, and nothing in the suite would notice. The flag would be honoured correctly, the finding
would persist correctly, and the sentence contradicting both is a string in a different file.

`PanelSilenceTests` now sweeps the app target for any call that disables the flag, with a
non-vacuity check that the sweep sees files mentioning it at all. Verified by adding
`adversarial: false` to the background discovery call: the failure names the file and the line.

Together with the previous entry, the detail screen's claim is now guarded from both directions —
a panel that never ran cannot be silently skipped, and a panel that ran and heard nothing cannot stay
quiet about it.

### 2026-08-02 — Fixing a README drift and immediately creating another

The README said of the Ask tab: "each question is a fresh, context-bounded session." True of the
session and false of the experience since conversational memory landed this morning — a reader learns
the app has no memory, which is the thing that changed. This repo has a documented history of a README
describing an architecture deleted weeks earlier, so the line was corrected to say what happens: fresh
sessions, with the last two exchanges replayed at 220 characters a side.

Which introduced a transcription of two constants into a file nothing checks — in the very edit that
fixed a drift about the same feature. So it is pinned: `ConversationMemoryTests` reads the README and
requires the Ask paragraph to state `ConversationTurn.maxReplayed` and `maxCharacters` as the code
defines them. Changing `maxCharacters` to 300 fails it by name.

The check collapses whitespace before matching, which was not the first attempt. Markdown wraps at
100 columns, so "220" and "characters" sat on different lines and a literal search missed them —
a test that a reflow can break is a test that gets deleted rather than fixed.

Also corrected in passing: the README described each candidate's evidence as including "device-swap
suspicion", which was accurate when the co-jump heuristic was the only signal. It is now the recorded
source list, so the line says "which device recorded it".

### 2026-08-02 — The Trends screen ranked by the loudest number

`TrendsView` sorted its connections by `abs(coefficient)`, and the comment justifying that said it
"matches how the engine and curation value a correlation". Neither half was true: curation sorts by
`quality`, and the engine's internal `strength` is a lag-SELECTION term, not a verdict on worth.

The difference is the app's editorial premise, stated in `SalienceSourceTests` for single-metric
findings — a statistical magnitude measures BIGNESS, which usually means obviousness, so leading with
it "would promote the loud, predictable changes this app exists to filter out". The feed, the audit
docket and curation all rank by `quality`, which blends the agent's `worth` with the statistical
trust term. Trends showed the same findings, ordered by the one number the rest of the app
deliberately refuses to lead with.

Now ordered by `quality`, with magnitude as the tie-break so equally-judged links still order
sensibly — and the original bug that the magnitude sort fixed stays fixed, since a strong inverse link
must not be buried by a weak positive one. The comparison is extracted as `TrendsView.ordered` because
it is the only part of that view with a decision in it.

**A methodology note, because it nearly shipped unverified.** The first injection appeared to prove
the new tests vacuous: reverting to the magnitude sort left them green. The tests were fine; the test
RUN was wrong. `-only-testing:VerdantTests/ConnectionMapTests` selects a SUITE, and the new cases were
added to that file as a separate suite, so they never executed. Targeting `TrendsOrderingTests`
directly fails by name. Twice now an injection has "passed" for a reason that had nothing to do with
the code under test — once from an incomplete edit, once from a filter that did not select the tests.
An injection that does not fail is a claim about the test, and it needs checking as carefully as the
test itself.

### 2026-08-02 — Bringing §0 current, and making the same mistake inside the hour

§0 is this document's entry point and had gone stale in four ways after a day of work: no mention of
provenance (the day's largest addition), none of the Ask tab's conversational memory, a list of
enforced invariants missing roughly half of them, and — twice — a COUNT restated in prose. "What is
open. Four things" had become six; "Six more were added" had become more than that.

Both counts are gone rather than corrected. A number restated in prose is the failure this document
records more than any other, and §0 is the part most likely to be read and least likely to be
re-derived. Where a count carried real information it stayed and was made checkable; where it was
decoration it was removed.

Then, writing the new Ask paragraph, the clamp got restated — "the last two exchanges, 220 characters
a side" — into a file the check did not cover. That check had been written an hour earlier, for this
exact transcription, in the edit that fixed a different drift about this same feature. Same author,
same feature, same mistake, one hour apart, one file over.

The check now finds the claim wherever it is written rather than in a file it names, and requires
both docs to carry it. Changing `maxCharacters` fails with both filenames listed.

The useful part is not the fix. It is that knowing the failure mode, having just been bitten by it,
and having built the guard, was not enough to avoid repeating it — the guard was. A check that names
one file protects one file; the mistake it protects against does not stay there.

### 2026-08-02 — Widening one negative check found two more collapsed reads, one of them serious

The previous entry's lesson — a check that names one file protects one file — was applied to the
checks written here today. The vulnerable shape is a NEGATIVE assertion scoped to named files: a
fourth path elsewhere passes in silence, which is exactly the defect the test exists to prevent.

`no run collapses a failed read into an empty one` named the two files that happened to have the
pattern. Swept across the target it immediately found two more.

**`Orchestrator+QA.swift`** — the Ask path. A failed read there produces a confident-sounding answer
with nothing behind it, to a question the person just asked. It now loads through `loadSeries` and
says so when there is nothing to work from.

**`Orchestrator+DeepRun.swift`'s substrate refresh** — the serious one. At every boundary the deep run
REPLACES its substrate with a fresh read. A transient fetch error left every later pass of an
indefinite run reasoning over an empty history — hours of the engine's time spent on nothing, under a
line announcing that fresh data had been folded in. `loadSeries` now reports `failed` distinctly from
`empty`, and a failed re-read keeps the data the run already has and says so. An empty-but-successful
read is still adopted: the store genuinely is empty (a delete-all), and carrying on with rollups the
user just erased would be worse.

A test broke that was worth reading rather than fixing. The Ask narration test asserted the feed
contains "Reading your health data", and the new note evicted it: `maxLogEntries` is 8 and that flow
already emits exactly eight — opener, working, panel convening, five reviewers. The test had been
passing at the boundary. Seeding its fixture (a user with data does not get the note) restores it and
tests the more representative case, but the fragility was real and is worth knowing about the feed:
one added line pushes the oldest out.

### 2026-08-02 — Every other swallowed read, triaged (one open item)

Having fixed the `dailySeries` collapse, the same question was asked of every other
`(try? await writer…) ?? []` in the agent layer: does a FAILED read become a value the caller then
makes a decision on?

Most are benign. A failed `journalSteering`, `journalEntries` or `recentFindingDescriptors` omits a
steering line, so the fleet may re-chase something — self-correcting next pass. A failed
`auditCandidates` skips one audit round; a failed `curationRoster` skips one curation and the feed
stays a little long until the next run. A failed `activeInvestigationFoci` makes a drill report zero.
None of these claims anything false or bypasses a guard.

One is not benign. `recentPriorDescriptor` returns `nil` for "no standing finding collides with this
candidate", and `try?` gives the same `nil` when the fetch throws. The `if let prior` that follows
then skips the NOVELTY JUDGE altogether — so a transient store error puts a re-tread on the feed past
the single guard that exists to prevent it, and costs the full vetting the novelty check runs first
to avoid.

**Left open deliberately, and worth being explicit about why.** Falling open is the right trade and
matches the panels: losing a good finding to infrastructure is worse than showing a duplicate. The
defect is that it is silent — and the run cannot report what it cannot distinguish. Distinguishing
needs a throwing seam, and `Orchestrator` holds a concrete `StoreWriter`; protocolising the app's
most load-bearing type to narrate one rare failure is a large refactor with nothing existing to test
it against. Half-fixing it — a `do/catch` that logs, added untested to the persist path every finding
passes through — trades a rare invisible fault for a common code path nothing exercises.

The call site now says all of this where the next reader will meet it.

### 2026-08-02 — "Catching up…" over a fleet that had long since started

Found by looking at a screenshot of the app running, which is the only way it could have been found.

The live card's headline answered `model.isWorking` with a flat "Catching up…". That flag covers the
whole foreground job — the HealthKit catch-up AND the discovery run that follows it — so the headline
kept saying "Catching up…" while the line directly beneath it read "Investigator 3/13: VOLATILITY
shifts", the counter read three agent calls, and the Neural Engine sat at 100%. Two statements about
the same moment, one of them describing work that had finished minutes earlier.

Nothing was wrong in isolation. The string is right for what it names, the flag is right for what it
tracks, `AnalysisProgress.Phase` already carried the honest label, and the status line underneath was
correct throughout. They were only wrong together, in a place no test looks and no code review would
flag, because the defect is a relationship between two lines of a rendered screen.

The headline now defers to the live phase whenever a run is narrating, and "Catching up…" survives
for exactly what it describes: the stretch before any phase has been reported. Extracted as
`InsightFeedView.programTitle` — a pure function, since the selection is the only decision in that
view — and pinned, including that a deep run keeps its own headline and that "waiting" is still
distinguished from "stopped".

The general point is about what running the thing buys. Two days of source-scanning invariants,
injection tests and budget measurements did not surface this, and could not have: every component was
correct. Ten minutes with the app on a simulator did.

### 2026-08-02 — Two of the three live counters were never written to

Following the screenshot that found the stale headline, the same card's three counters were checked
against what feeds them. `newInsights` was maintained. **`correlationsSurfaced` and
`correlationsTested` were declared on `AnalysisProgress`, rendered on every run, and incremented by
nothing anywhere in the app.**

So the live card told a person that zero relationships had been tested while `CorrelationEngine` was
judging every computable pair in their history, and that zero cross-signal links had been surfaced —
when a cross-signal link is the app's premium finding. Both chips were permanently zero, on every run,
since they were written.

A plausible zero is the hardest wrong number to notice: early in a run it is correct, and it never
stops being displayed. The compiler had nothing to say either — an unwritten `var` with a default is
valid Swift, and nothing in a 550-test suite asserts on a number no code produces.

`correlationsSurfaced` increments where a correlation is actually kept. `correlationsTested` is filled
by `reportPairsTested`, which reads the count `CorrelationEngine.Scan` already carried and reports it
from a DETACHED task: `correlationScan()` awaits the scan, and blocking the run's start on it would
trade a live counter for the CPU/generation overlap `precompute` exists to create. The chip stays at
zero until the number is real, which is the honest order.

**The first test of the pairs counter was inert and the injection said so.** It called
`reportPairsTested` directly, so removing the call from `runDiscovery` left it green — the helper
worked and nothing proved the run used it, which is the same shape as a defaulted argument nobody
passes. The run-based test now polls for the counter after a full `runDiscovery`, and removing the
call fails it.

`ProgressSink` moved from private-to-one-suite into a shared file on the way, since the second suite
needing it would otherwise have copied it.

### 2026-08-02 — Making the dead-counter check mechanical

The two unwired counters were found by looking at a screenshot. That works once; it does not scale to
the next counter someone adds. `LiveCounterTests` now sweeps `AnalysisProgress` for stored counters
and requires each to have a writer somewhere in the app — the mechanical form of the same question,
so the next one cannot be displayed and never filled.

The sweep's first version flagged `elapsedSeconds`, which is written perfectly well — just as
`progress.elapsedSeconds =` on the reporter rather than inside a `progress.apply { $0.x = }` closure.
A pattern too tight reports correct code, and a sweep that reports correct code is one people stop
believing; it now accepts both forms the app uses. Verified from the other side by adding an unwired
counter, which it names.

The same sweep also turned up `AnalysisProgress.isFinished` — a computed property with zero uses
anywhere in app or tests. Removed. `elapsedText` looked identical to the regex and is used by the
feed, which is the reminder that "no writes" means nothing for a computed property.

Two limits worth stating. It only covers counters declared `= 0`, so a differently-typed display value
would slip through. And it proves a writer EXISTS, not that the writer runs on the path that matters —
which is a distinction this same file already had to learn the hard way, when a direct call to
`reportPairsTested` kept a test green while `runDiscovery` no longer called it.

### 2026-08-02 — Retired findings grew without limit; the journal already knew better

`pruneJournal` exists because "an INDEFINITE research program appends entries for as long as the app
stays open, so an unpruned table would grow without limit". Every word of that is equally true of
retired findings — curation retires some on every pass, a tombstoned row is never deleted otherwise,
and only a user's "delete all" clears them — and only the journal was bounded.

The cost lands twice. The store grows for as long as the program runs, each row carrying prose and an
embedding. And `setHighlights` is the one query that fetches rows WITHOUT filtering `tombstoned`, so
its per-round scan grows in proportion to how long the app has been running — on the app's headline
use case, which is running for days.

`pruneRetiredFindings` mirrors `pruneJournal` exactly, keeping the newest 200 (a just-retired finding
is the most likely thing someone asks about). It is called from `curate`, which is where tombstones
are made — the same placement the journal's prune has beside `recordJournal`. Both tables go through
one generic over a small `RetirableFinding` protocol rather than two near-identical functions.

Safe because nothing reads a retired row: every feed, novelty and curation query filters them out, and
the one fetch that does not skips them explicitly.

**Memory, measured while this was written.** RSS over three minutes of continuous agent work: 157 MB,
158 MB, 150 MB — flat, and falling at the end rather than climbing. No leak visible at that timescale.
Two honest limits: three minutes is not the "hours or days" the design targets, and the sample ended
early because `xcodebuild test` uses the app as its test host and terminated the running instance. RSS
also is not the number iOS jetsams on — the app's own meter reported 36–41 MB of `phys_footprint`
against 141–158 MB RSS, the difference being shared framework pages.

### 2026-08-02 — The rest of the unbounded-growth sweep

Having found the retired findings, the same question was put to every remaining table and in-memory
ring, since "grows without limit" only matters in an app whose headline mode runs for days.

All bounded, and each for a reason already written down: `ResearchJournalEntry` is pruned to 400;
active findings are held at `maxActiveFindings` by curation and their tombstones now pruned to 200;
`SyncAnchor` is one row per metric; `AgentState` is a keyed singleton, fetch-or-create;
`RunLedger`'s rings cap at 24 apiece; `activityLog` at 8.

`MetricRollup` grows forever and that is deliberate — `Ingestor` records that there is deliberately NO
backfill cap, because "the analysis sees the user's entire recorded history … HealthKit began in 2014,
so 'all of it' is bounded by reality", and multi-year arcs are the findings the lenses call the most
prized of all. Unbounded by design, with the bound supplied by the world.

That does make one of today's own justifications read cheaper than it is. `sourceHistory` was
described as costing "one extra fetch per substrate build". At real scale that fetch is every tracked
metric times every day since 2014 — order 10^5 rows. The comment now says so: it is affordable because
a build happens at a pass boundary and `precompute` runs it behind generation, NOT because it is
small. The conclusion is unchanged; the reasoning offered for it was flattering.

### 2026-08-02 — Auditing today's own claims, and finding the source of a wrong one

The most productive seam late in the day stopped being unfamiliar code and became claims written
earlier the same day. Several were checked; most held (the Ask flow really does emit exactly eight
feed lines — five safety lenses plus three — which is why one added line evicted the opener), and two
did not.

**§0 said provenance is "populated by `.separateBySource`".** True of quantity metrics and not of
sleep or mindful minutes, which have no statistics query at all and read `sourceRevision` from the
samples that survived their `include` filter. Two capture paths, described as one. `VERIFIED-CLAIMS.md`
had scoped it correctly ("Both quantity read paths"); the summary had flattened it.

**And the CI workflow contained the false claim that started a chain.** Its comment justified dynamic
simulator resolution by asserting `iPhone 16 Pro` "already fails locally, where the iOS 26 runtime
offers the iPhone 17 family and no 16 Pro at all, so `xcodebuild` fails before running a single test".
Running the README's pinned command settles it: 546 tests pass. `simctl list devices available` does
show only the 17 family, but the 16 Pro device TYPE is installed and Xcode instantiates a simulator
from a type plus an available runtime on demand.

That claim had already propagated into working notes as a reason to "fix" the README's build command —
a correct instruction that would have been changed on the strength of a comment nobody had tested.
Dynamic resolution in CI remains right for its real reason (runner images vary); the justification is
now the true one, and records how it was checked.

CI otherwise enforces exactly what is run locally: `swiftlint lint --strict`, `swiftformat --lint`, and
the full suite. Nothing has been passing here that would fail there.

### 2026-08-02 — A false "it doesn't work here" comment, and the 12-token margin it was hiding

Sweeping for the shape that produced the CI mistake — a comment making a NEGATIVE empirical claim,
the kind that stops anyone from trying the thing — turned one up immediately, in the token harness:
"On the simulator (no Apple Intelligence) token measurement returns nil."

It does not. Measured here: instructions 398 tokens, tool schemas 1,638. The real tokenizer runs, and
every token figure this document quotes from today was measured rather than proxied — which was worth
establishing, because the comment invites the reader to assume the opposite. The character-budget
fallback is still right, but for a machine WITHOUT the model (a bare CI runner), not for simulators as
a class.

**The number it was obscuring matters more than the correction.** 398 + 1,638 = **2,036 against a
2,048 bound. Twelve tokens of margin** on the tightest prompt in the app, and no one had seen the
figure — the assertion passes or fails and prints nothing when it passes. Anything added to
`Instructions.investigator`, or any field added to a schema in the investigator's tool surface, trips
it. That is now recorded at the assertion, and it retrospectively justifies a choice made earlier today
for weaker reasons: the changed-relationships angle went in as a LENS — runtime, one session — rather
than as a line in the prefix. Verified by adding one sentence to the instruction: 2,058, and the bound
fails by name.

Two "no public API"-style claims were checked and left alone: `ResourceMonitor`'s note that Apple
exposes no Neural Engine utilisation API, and the Ingestor's that HealthKit history begins in 2014.
Neither is refutable from here, and both are load-bearing in the honest direction — they explain why
the app does LESS than a reader might expect, rather than excusing it from trying.

### 2026-08-02 — Where the investigator's 1,638 schema tokens actually go

Having found the twelve-token margin, the obvious next question is what is spending the budget.
Measured per tool:

    metricStats 576 · analyze 524 · eventWindow 235 · unusualDays 198
    correlationScan 146 · patternScan 143 · metricsOverview 141

Two tools are 67% of it. `metricStats` spends nearly all of its 576 on
`.anyOf(MetricKey.allRawValues)` — thirty-eight metric keys enumerated into the schema — which is the
cost `TokenHarnessTests` already described in the abstract as "the real ceiling on more metrics", now
with a number against it.

**The available fix was deliberately not taken.** `AnalyzeTool` dropped `.anyOf` from its own metric
argument for exactly this reason and leans on the registry resolve to reject an unknown key; doing the
same to `metricStats` would free roughly 300 tokens, a 15% cut in the prefix. But `.anyOf` is what
makes the metric unforgeable through constrained decoding, and `MetricStatsTool.call` logs a missing
stat as an INVARIANT VIOLATION on the strength of it. Trading a safety property for headroom that
nothing currently needs is a product decision, not a cleanup, and the margin — while thin — is not
failing anything today.

So the numbers are recorded at the assertion instead, which is what was actually missing: the bound
was enforced and unquantified, so "the prefix sits near its bound" was folklore. Anyone who needs the
headroom now knows precisely where it is and what it costs to take.

### 2026-08-02 — Three roles share one tool surface, and all three are near the bound

Measuring one role's prefix understated the constraint. All six:

    investigator 398 + 1,638 = 2,036   (12 spare)
    explorer     180 + 1,855 = 2,035   (13 spare)
    answerer     245 + 1,723 = 1,968   (80 spare)
    replicator   227 +   879 = 1,106
    scout        230 +   708 =   938
    director     240 +   207 =   447

Three of the six sit within eighty tokens of the bound, and they are precisely the three built on
`investigatorTools`. The surface is SHARED, so a field added to `metricStats`, `analyze`,
`correlationScan`, `patternScan`, `unusualDays` or `metricsOverview` is paid three times and trips
three roles at once. **The effective budget for new evidence in a shared tool schema is about twelve
tokens.**

This is worth stating plainly because today added `recentThirdCoefficient` to `correlationScan` — a
shared tool — and the only thing that confirmed it fit was the suite going green afterwards. It did
fit. It was not sized beforehand, because the numbers did not exist, and a passing assertion prints
nothing.

It also sharpens the `metricStats` `.anyOf` question from the previous entry: freeing ~300 tokens
there relieves all three near-bound roles, not one, so the upside is three times what a single-role
reading suggested. Still a safety trade — constrained decoding is what makes a metric key unforgeable
— and still not taken unilaterally. But it is now a decision with both sides quantified, which it was
not this morning.

The general lesson is about enforced-but-unquantified limits. Every one of these bounds was already
checked by CI and had been for weeks; not one had a number a person could plan against, so "the prefix
sits near its bound" circulated as folklore and got acted on all day — including by me, choosing where
to put a new angle for roughly the right reason with none of the evidence.

### 2026-08-02 — Turning the silent bounds into a report

Every prefix bound in this app was enforced and invisible. The assertions had been passing for weeks
and printing nothing, so the numbers behind them did not exist until someone went and instrumented for
them — which is why "the prefix sits near its bound" travelled as folklore and got acted on, by me,
several times in one day, with no figure behind it.

`TokenHarnessTests` now prints the whole table on every run:

    PREFIX BUDGET (bound 2048)
      investigator instr 398  tools 1638  total 2036  spare 12
      explorer     instr 180  tools 1855  total 2035  spare 13
      answerer     instr 245  tools 1723  total 1968  spare 80
      replicator   instr 227  tools 879   total 1106  spare 942
      scout        instr 230  tools 708   total 938   spare 1110
      director     instr 240  tools 207   total 447   spare 1601

A report, not a tighter assertion. A twelve-token margin is a fact to see before adding a field, not a
build to break; failing at some invented comfort threshold would block work that is currently fine and
teach the next person to raise the threshold. And when the tokenizer is unavailable it says so rather
than printing an empty table, because a blank report reads exactly like a clean bill.

The pattern is worth keeping beyond this file: a bound that only speaks when it breaks gives no way to
plan, and the planning is where the decisions actually happen.

### 2026-08-03 — The other silent budgets, and a bound that only fitted what already existed

The prefix report made the case; the same treatment went to the two other bounds set the previous day,
both cheap to measure without fixtures.

    BASIS BUDGET (bound 900, worst case per kind)  regime 616  volatility 383  correlation 461
    LENS BUDGET (bound 400) count 13  longest 390  median 95  spare 10

The basis budget is comfortable. The lens report earned its keep immediately: **longest 390 against a
400 bound — ten characters spare** — and the 390 was the changed-relationships lens added the day
before, four times the roster's median of 95.

That is a bound doing nothing useful. It permitted exactly what already existed and nothing more, so
the next legitimate lens would have failed it, and the outlier setting the ceiling was mine. The
honest fix is to trim the lens, not to raise the bound: it is now 360 with forty spare, having lost
thirty characters and none of its five instructions (compare the two coefficients, name both shapes,
distrust `consistentAcrossThirds`, confirm with `analyze`, say which stretch the prose means).

It remains the longest lens by half again, which is accepted rather than hidden — it is the only one
that must name two schema fields, warn off a third, and constrain phrasing to avoid a card mismatch.

The reason this is worth an entry: the bound had been green since it was written. Reporting is what
showed it was green the way a bound is green when it has been fitted around the thing it is supposed
to constrain.

### 2026-08-03 — A failed background registration was discarded

Chasing the runtime seam into background scheduling. `BGTaskScheduler.register(forTaskWithIdentifier:)`
returns whether the registration took; `registerHandlers` threw both results away.

A false return means the app will never wake for that task — the identifier is absent from
`BGTaskSchedulerPermittedIdentifiers`, or registration came after launch finished. The app keeps
running, keeps calling `submit`, and never runs in the background again. For an app whose stated
purpose is the compute it does while nobody is looking, that is total failure, and it was silent in
both directions: nothing logged it, and nothing could have noticed it from the foreground.

`BackgroundIdentifierTests` already pinned the plist side, and could never have caught this. It
compares two lists of strings; it cannot see a registration that failed for any other reason. Both
results are now bound and a failure is logged with what to check. A log rather than a crash, matching
the trade `VerdantApp` already makes for a store that will not open — a foreground-usable app beats a
refusal to start.

Pinned by counting: every `BGTaskScheduler.shared.register` call must have its result bound, and the
failure message must exist. Dropping one binding fails it with "1 registration result(s) discarded".

Worth noting how it was found. The runtime check that prompted it — grepping a live app's log for
BGTask activity — found nothing conclusive, because registration is quiet when it succeeds. The
absence of evidence sent me to read what the call actually returns, which is where the real defect
was. A runtime probe that comes back empty is still worth following.

### 2026-08-03 — A finding that cleared every panel and failed to save said nothing

Sweeping the discarded-failure class beyond the background registration. `submit` already logs its
throws, and the swallowed READS were triaged the previous day. The writes had one real gap.

`appendXIfNovel` returns nil for "not novel", and `try?` made a thrown write return nil too. So a
finding that passed the novelty judge, the safety panel, the skeptic panel and the replication panel,
and then failed to save, was indistinguishable from a duplicate — and produced no line at all. Every
other outcome on that path narrates itself (`logKept` on success, `drop` with a reason on rejection),
which makes silence the one hole in a feed whose stated rule is that it says what is happening.

A `saved(_:_:)` helper now wraps all six appends and reports a failure as what it is: verified, lost,
and re-derivable next run. One helper rather than six identical `do`/`catch` blocks, because six
copies is the duplication this codebase spends most of its defects on.

The rest of the class was left alone deliberately. A failed `recordJournal` costs one steering line, a
failed `recordRun` a stale "last analyzed" in Settings, a failed `retire` one extra card until the
next curation — all transient and self-correcting, unlike the background registration, which was
permanent and total. Logging every one of them would trade a rare invisible fault for constant noise.

**The injection that verified this first produced no output at all, and that is the finding worth
keeping.** An earlier attempt edited the braces wrongly, the target did not compile, and the run
printed neither a failure nor a pass — which reads exactly like a clean run when grepping for `✘`.
Re-running it as a compiling edit fails with "1 append(s) still swallow a write failure". Twice today
an injection has been silently void; "no output" needs to be treated as its own result, not as green.

### 2026-08-03 — A comment of mine claimed something the code did not do

A coherence pass over the day's own changes: for each persist route, does what the basis STATES match
what the fidelity check is GIVEN? Five agreed. The volatility route did not, and the way it disagreed
is the point.

Its basis had gained the mean-shift percentage ("while the average barely moved (0.8%)"), and beside
the fidelity list sat a comment reading "The mean-shift percentage is now stated in the basis; pass it
too rather than rely on that sentence continuing to render it." The list passed `n` and nothing else.
The comment described an intention, was written in the same edit, and was never carried out — so the
site read as deliberate to anyone checking, which is worse than an obvious omission.

It worked anyway, because `unsupportedFigures` parses the basis. That is exactly the dependency the
comment existed to remove, and the same one recorded as fragile when the thirds relied on it.

Fixed as one expression rather than two: `VolatilityShift.meanShiftPercent` is computed once and used
by both the basis and the route, so they cannot state different numbers. It goes in `verified` rather
than `counts` — a percentage is precisely the case unit factors exist for, since prose may restate 20%
as 0.20.

The habit worth keeping is the check itself: after a run of changes, compare what each site SAYS with
what it DOES, because a stale comment is invisible to every test in the suite and is read as evidence
by the next person. This one was written, and then falsified, by the same author inside an hour.

### 2026-08-03 — Sweeping the day's own comments for claims that had stopped being true

The volatility comment that promised something the code never did prompted a sweep of the same shape:
comments asserting UNIQUENESS or completeness — "the ONE", "no other", "nothing else" — since those
are the claims a later change silently falsifies. Three were mine, written the same day.

**"Awaits provenance first — the ONE scan with a dependency"** on `regimesTask`. True when written and
false within the hour, when the device-swap caveat was extended to volatility and milestone: three
scans wait on it. The rationale now lives once on `provenanceTask` itself, where the dependents share
it, instead of three times at the dependents.

**"No other tool in its surface can raise the possibility"**, of the replication analyst's
`provenance`. False: an `unusualDays` row's basis already carries the co-jump SUSPICION for a day the
sweep flagged. The real distinction is what provenance adds — a record rather than an inference, for
any metric on any day, including the single-metric swaps that co-jumping vitals structurally cannot
reveal. That distinction was already written correctly elsewhere and got flattened here.

**"Nothing else ever deletes a retired row"**, beside the new pruning call. The user's delete-all does.
Narrowed to say so.

None of these changed behaviour and no test could have caught any of them. They are the residue of a
day's work: each was true when written, and each was falsified by a later change of mine that had no
reason to look at it. Uniqueness claims are the ones to grep for afterwards, because they are the
claims that go stale by addition elsewhere rather than by edit in place.

### 2026-08-03 — "The six independent scans" had been ten for some time

The uniqueness sweep has a numeric sibling: comments that count a collection. Same failure mode, and
worse in one way — a count looks like a checked fact.

`AnalysisSubstrate`'s type documentation explains why every scan runs in its own detached task, "so
the SIX independent scans occupy every CPU core instead of one". `precompute` starts **ten**:
correlation, volatility, milestones, regimes, seasonality, allStats, unusualDays, coverage,
suspectDays and provenance. Seasonality and provenance were each added later, and neither addition had
any reason to look at a sentence three screens above it.

Nothing breaks — but that number is what a reader uses to judge whether the parallelism argument still
holds, and "six scans across every core" reads differently from ten.

Corrected, and pinned by `SubstrateScanCountTests`: the count in the prose must equal the number of
scans `precompute` actually kicks off, and no other count may be claimed beside it. Removing a scan
fails it.

The other numeric claims checked out — `replicationLenses` really is "the three fixed checks",
`investigatorTools` really is "the six that measure", and "the two dozen specialists" is an
approximation of a per-pass fleet that genuinely runs around that many. Only the one that had grown
was wrong, which is the pattern: additive drift, in a line the adder never touched.

### 2026-08-03 — Driving the real model, and the silent drop it exposed

Nothing in the suite had ever run the actual on-device model: every orchestrator test uses
`FakeSubagents`. A throwaway probe drove the real one over seeded data — a resting heart rate stepping
down 4 bpm sixty days back — and it worked end to end. `RegimeShiftScan` found "a sustained step from
~61 bpm to ~57 bpm that has held for 58 days (effect size 4.9)", and the investigator proposed it as
`regimeShift` on `restingHeartRate` with `worth 100`: "Resting heart rate has transitioned to a new,
sustained baseline of 57 bpm, showing no further variation over the past 58 days." The prompts, the
tool surface and the output schema all hold up against the model they were written for, which until
now was an assumption.

**One proposal in three named the metric `steps`.** The registry key is `stepCount`.

That is not a defect — it is the documented design working. `ProposedFinding.metric` deliberately
carries no `.anyOf`, because the full key vocabulary in the OUTPUT schema sits at the transcript's
fullest moment and blew the 4,096-token budget on device; the registry resolve at persist time is the
anti-hallucination boundary, and it dropped the proposal exactly as intended.

What was wrong is that it dropped it in SILENCE. `guard let metric = MetricKey(rawValue:) else {
return false }` — no line in the feed, no counter, nothing. That guard is the only place anyone would
ever learn how often the model invents a key, on the one surface whose stated rule is that it says
what is happening, and every neighbouring outcome (`logKept`, `drop`, the failed-save narration added
hours earlier) already speaks. It now says which title was dropped and which key was not recognised.

Two lint limits were hit on the way and are worth noting as real constraints rather than nuisances:
the new test pushed `AgenticGovernanceTests` past 500 lines (split into `UnknownMetricDropTests`), and
splitting one guard into two pushed `persistProposed` past the complexity limit — merged back into a
single guard, since all three conditions mean "there is nothing to persist against".

The probe was deleted. Its value was one observation that no amount of reading would have produced:
the anti-hallucination boundary fires in normal operation, roughly a third of the time in this sample,
and until now did so without a trace.

### 2026-08-03 — The whole pipeline on the real model: 438 seconds, zero findings, and why that was right

The first end-to-end run of the actual pipeline against the actual on-device model — investigate,
novelty, safety, skeptics, replication, persist, curate. Nothing in the suite had done this; every
orchestrator test substitutes `FakeSubagents`. It ran 438 seconds without a crash and kept **nothing**.

That was correct. The store held two seeded metrics, and the fleet proposed "Weekend Temperature
Spikes", "Oxygen Variability Peaks on Weekends" and a body-fat finding — metrics with no data at all.
Every one was dropped at persist time because the numbers could not be resolved from source. The
architecture's central promise, that the model may name a thing but never invent a figure, held under
a fleet actively trying to invent things.

**What the run exposed is upstream of that.** The thematic lenses are a fixed roster — "respiration,
blood oxygen and wrist temperature", "body & metabolic measures" — and nothing tells them what the
person actually has. So investigators spend whole sessions on findings that cannot survive, and that
is not an exotic case: it is the first weeks of every install, and an iPhone-only user permanently.

`availableMetricsLine` now names the library when it is short enough for naming to be information —
twelve metrics or fewer — and rides on the runtime LENS, not the instructions. That matters: the
investigator prefix has twelve tokens spare, so this could not have gone in the prompt. It also
removes no model calls, which the direction here forbids: the same fleet runs, aimed at ground that
exists. Above the threshold it says nothing, because naming most of the registry back to an agent that
can see it in any tool result is a cost, not a fact.

`Orchestrator` crossed 500 lines, so this moved to `Orchestrator+Steering.swift` — a real seam rather
than an arbitrary cut, since per-run context appended to a lens is exactly the category that is free
in the prefix and is where future steering belongs.

Two things the run also settled quietly: the deep pipeline survives seven minutes of continuous real
inference without a crash or a stuck gate, and the panels, handoff schemas and persist routes all
function against the real model rather than only against a fake.

### 2026-08-03 — What the real pipeline actually does: 645 seconds, one finding, killed by one vote

The second end-to-end run against the real on-device model, this time over five metrics with genuine
structure — a sleep to resting-heart-rate link, a regime shift, weekend patterns in steps and energy.
It ran 645 seconds and kept nothing, and unlike the first run the feed said exactly why:

    ✗ Dropped "Weekend Energy Surge Tied to Resting Heart Rate Dip" — the safety panel couldn't confirm it
    · Safety reviewer 5/5: clear   · 4/5: clear   · 3/5: flagged   · 2/5: clear   · 1/5: clear

Four of five reviewers cleared a benign wellness observation. One flagged it. The finding died.

**That is the design.** `passesSafety` requires a majority to render AND every rendered verdict to say
safe, because a false negative on a health app's prose is worse than a lost finding, and
`SafetyVerdict`'s guide tells each reviewer "when in doubt, false". Five reviewers each erring toward
false will, between them, flag benign text at some rate; unanimity makes that rate the rate at which
good findings are lost. What is newly KNOWN is that it is not negligible — the one finding to reach
the panel in a realistic run was killed by a lone dissent.

**Left for the owner.** Loosening a safety gate is a product and liability decision. The options, none
taken: keep unanimity; require a majority of safe verdicts, as the skeptic panel does; or keep
unanimity but let a flagged concern be re-examined rather than final. Recorded in
`VERIFIED-CLAIMS.md` with the measurement behind it.

**What was changed is diagnosability.** A flagged reviewer's line now names the concern it was given.
The lens IS the concern and is already in hand, so this costs no schema field, no extra call, and
nothing on the four that cleared — where before the feed said "flagged" and there was no way to learn
which of the five fired, on the gate that decides whether anything reaches the user at all. Clear
verdicts stay terse: five lenses echoed on every safe finding would bury the feed.

Two things this run settled beyond the panel. The pipeline survives eleven minutes of continuous real
inference — investigate, novelty, safety, skeptics, replication, curate — with no crash, no stuck gate
and no schema failure. And the fleet, given metrics that exist, proposes findings about THOSE metrics:
the previous run's inventions were a consequence of a two-metric fixture, not a habit.

### 2026-08-03 — Asking the panels directly: two fixable defects and a confirmed policy cost

The full-pipeline runs died at the safety panel, so the skeptic and replication panels had never
judged a real claim. A targeted probe put a well-supported one to all three: a 62→58 bpm regime shift
with its actual verified basis.

**The skeptic misread the effect size as bpm.** It rejected the finding in these words: "The effect
size of 8.2 is extremely large … resting heart rate typically changes only by a few beats per minute,
and this change is far larger than any physiological factor could account for." The basis says "from
~62 bpm to ~58 bpm … (effect size 8.2)" — a four-bpm change at 8.2 standard deviations. A small model
took the standardized figure for the change itself, in a sentence that had stated the real change four
words earlier. The basis now says "effect size 8.2 standard deviations". Three words, and the reading
that killed the finding is gone.

**The replication analyst re-tested a metric with no data.** Its verdict was literally "No data for
Heart rate." — it had reached for `heartRate` when the claim was about `restingHeartRate`. The panel
scored 0 of 5 and rejected a claim whose own basis stated the numbers. The available-metrics shortlist
added for investigators earlier the same day did not reach the panel that re-tests their work; it does
now, with wording made role-neutral because "do not propose findings" is not an instruction an analyst
can follow.

**And safety rejected the bare sentence** "Your resting heart rate settled about 3 bpm lower roughly
two months ago and has stayed there." Nothing in that is a diagnosis, a condition, advice or alarm.
Together with the pipeline run that lost a finding on a 4-of-5 clear, this is now two independent
observations of the unanimity rule refusing benign prose — recorded for the owner in
`VERIFIED-CLAIMS.md`, and still not changed here, because loosening a safety gate is a product and
liability decision.

An existing test had to be adjusted rather than the code: it asserted the replication lenses arrive
VERBATIM, which per-run steering breaks. Its real claim is coverage and distinctness, so it now checks
each fixed re-test is asked as a prefix. Adjusting an assertion to fit a change is usually the wrong
move; it is right when the assertion was over-specified relative to what it meant to protect, and
saying which of those applies is the whole of the judgment.

### 2026-08-03 — Measuring the two fixes: one unproven, one that failed, and the real defect underneath

The panel probe was re-run after the effect-size wording and the replication shortlist. Before and
after, same claim, same panels:

    skeptics    4/10  →  3/10
    replication  0/5  →   0/5, verdict still "No data for Heart rate."

**Neither fix demonstrably worked, and saying so matters more than the fixes did.** One sample each
against a stochastic model cannot distinguish 4/10 from 3/10, so the effect-size wording is unproven
either way — it stays because "effect size 8.2 standard deviations" is unambiguous prose on its own
merit, not because it was shown to help. The shortlist plainly did not work: the analyst was told
which metrics have data and queried `heartRate` regardless.

**But the second failure exposed the actual defect, which is structural rather than a matter of
prompting.** `Verdict.holdsUp` was carrying two different meanings — "I re-tested it and the effect
vanished" and "I could not get the data to re-test" — and the replicator's instruction says "when in
doubt, false", so the second collapsed into the first. `panelHolds` then counted a failed lookup as
evidence AGAINST a true finding. An analyst that queries the wrong metric does not merely abstain; it
votes the finding down.

`Verdict` now carries `couldTest`, and untestable verdicts are excluded from the tally — the same
treatment the panel already gives verdicts that never rendered, on the same reasoning: no evidence is
not evidence against. The analyst is told to use it, the feed says "could not run this check" as its
own outcome rather than as a failure to replicate, and a genuine refutation still counts (pinned, or
the change would just be disabling the panel).

The sequence is the point. Two plausible fixes, measured, both unconvincing; the measurement of the
failure is what located a defect neither fix addressed. Had the shortlist appeared to work, the
conflation in `holdsUp` would still be there, and the next wrong lookup would still have voted down a
true finding.

### 2026-08-03 — The replication panel was never told which metric to re-test

Three probes against the real model, three datasets, and not one analyst completed a re-test. That is
not calibration — the panel whose entire job is checking findings against the DATA could not find the
data.

The reason is structural. An analyst receives the claim (prose plus a basis sentence) and its lens.
Neither carries a registry key, and `subject` — the one place a metric name appears — is a DISPLAY
name used only in a progress log line, never passed to the analyst at all. So it had to infer the key
from English. Asked to re-test a resting-heart-rate step, it queried "Heart rate", got nothing, and
reported that as a failure to replicate.

Every persist route already knows the exact keys, and the standing-finding audit can read them off the
row. They are now threaded through `survives` → `survivesReplication` → the analyst's own lens:
"The claim is about these exact metric keys, which is what the tools expect: restingHeartRate."
`AuditCandidate` carries them too, since the audit re-tests through the same panel and would have hit
the same wall.

This is the third fix aimed at the same observed failure and the first that addresses its cause. The
shortlist of available metrics did not work — the analyst was told which metrics HAVE data and still
guessed wrong, because knowing the library does not tell you which member the claim is about.
`couldTest` stopped the failure counting as a refutation, which was worth doing on its own, but it
made an honest abstention out of what should have been a successful test. Only naming the key
addresses why the test never ran.

Worth stating plainly: two of the three were treating symptoms, and the measurement after each is what
kept the search going rather than closing it.

### 2026-08-03 — Instrumenting the tool, a false alarm, and the dead end underneath

Three prompt-level fixes had failed to make a replication analyst complete a re-test, so the next step
was to stop guessing and call the analyst's own tool directly, with no model in the loop.

`analyze` returned `available=false, "Invalid query parameters."` for what looked like an obviously
valid query. That looked like a serious defect in the most flexible tool the agents have — it sits in
four of the six sessions.

**It was not. The probe was wrong.** The guide says "A second metric for a correlation; otherwise
repeat the first metric", and the probe passed `""`. Supplying the metric twice returns exactly the
right answer: mean 60.79 over days 61–120, 56.92 over days 0–59, the seeded 4 bpm step. Recorded
because the next reader deserves to know the tool was checked and is sound, and because it was one
step from being reported as a major bug.

**What the episode did expose is real.** The reply to a nearly-right query was the single sentence
"Invalid query parameters." — naming neither the offending argument nor the convention. An agent that
gets one argument wrong learns nothing from that and cannot correct itself; it reports that it could
not run the check, which is precisely the behaviour observed from every analyst in three runs. The
same sentence cost a round of investigation here, by a reader with the source open.

Two changes. An omitted second metric is now taken as a single-metric query — the intent the guide
expresses in a more demanding way, and rejecting it wins nothing. And an unrecognised argument is
named, all of them at once: "Not a valid query — unrecognised statistic “average”, dayFilter
“sometimes”. Use the exact metric keys the other tools report."

Whether this is what has been stopping the analysts is still a hypothesis, not a finding. It is the
most likely mechanism given the evidence, and it is worth fixing regardless — but the honest state is
that the panel's zero re-tests remain unexplained until a probe shows them running.

### 2026-08-03 — The analysts' own words: near-miss metric keys, not wrong guesses

Capturing the progress feed during a replication run finally showed what five analysts actually said,
rather than a tally:

    · Replication 5/5: could not run this check — No data for Heart rate.
    · Replication 4/5: could not run this check — No data exists for the metric "restingHear" …
    · Replication 3/5: could not run this check — No valid metric or data provided.
    · Replication 2/5: could not run this check — Could not find any data to analyze.
    · Replication 1/5: could not run this check — No data for Heart rate.

**"restingHear".** Not a guess at a different metric — a TRUNCATION of the right one. And "Heart
rate" is the display name of the right one. The analysts are calling `analyze`; they are mangling the
key on the way in. `AnalyzeTool.metric` deliberately carries no `.anyOf`, because the full vocabulary
would not fit the investigator's schema budget, so the model free-generates the string.

That also settles why three prompt-level fixes failed. Naming the key in the lens does not help a
model that is truncating what it emits.

The tool now names the key a near miss was near: matching prefix-or-contains on a case- and
separator-insensitive form, which covers both observed shapes — "restingHear" is a prefix of
"restingHeartRate", and "Heart rate" normalises into it. An unrelated string still gets the generic
pointer rather than a misleading guess.

**The fix that would actually be reliable is not taken here.** `.anyOf(MetricKey.allRawValues)` on
this argument would make a malformed key impossible through constrained decoding — and the REPLICATOR
has room for it, at 1,106 tokens against a 2,048 bound. The investigator does not, at 2,036. Same tool
type, two very different budgets, and varying an `@Generable` guide per call site means a second tool
type. That is a real design decision about the tool hierarchy, with a token measurement behind it, and
it belongs to the owner rather than to a fourth attempt at the same bug.

### 2026-08-03 — Why the app surfaces nothing: three multiplying constraints, measured

The previous entries traced one dropped finding at a time. This one measured the whole pipeline and
found that "the vetting stack rejects everything" is not one bug. It is three independent
constraints, each individually defensible, that multiply.

**1. The replication panel could not name a metric.** Across five runs it completed *zero* re-tests.
The analysts' own verdicts said `res`, `restingHear`, `resting_heart_rate`, `Heart rate` — not
guesses at a different metric, but truncations, snake_case, and a display name of the *correct* one.
All three tools the panel held take a free-generated `metric: String`. `metricStats` is the only tool
in the app whose metric argument carries `.anyOf(MetricKey.allRawValues)`, and the panel did not have
it. Adding it cost 659 of the role's 942 spare tokens (1,106 → 1,765) and the panel went to **5 of 5
analysts completing a re-test** on the next run. Three prompt-level fixes were tried first and none
could have worked: prompt text does not reach the decoder, only the schema does. Note the ceiling —
an anchored list in the *prefix* is a strong hint, not a constraint, and a later run still produced
one mangled key in five. `MetricVocabularyTests` now enforces the invariant.

**2. The safety panel blocks benign findings ~2 times in 3, and runs FIRST.** A deliberately benign
claim (resting heart rate stepped 63 → 54 bpm; no diagnosis, no condition, no advice) passed 1 time
in 7. Per-lens measurement at 20 trials each found the cause was two lenses that invite inference:
"state or *imply* a diagnosis … or at risk of" (35% false-flag) and "or otherwise *harmful in tone or
framing*" (60%). Rewriting both to name what they are actually for took them to 5% and 33% with
detection intact — every unsafe control still caught, with accurate quotes. Expected benign pass rate
~22% → ~37%. The same treatment applied to a third lens changed nothing (40% both wordings) and was
reverted; two lenses improved by that hypothesis and one refused it.

**3. The skeptic panel does not discriminate.** Nine reviewers, strict majority. A clean 4.5 SD
regime shift held 1/9, 1/9, 3/9. A correlation that failed FDR at p = 0.42 and flipped sign across
thirds held 3/9, 0/9, 1/9. Neither passes; 19% vs 15% is noise. One lens was removed for a real
defect — it asked a *tool-less* agent whether the effect survived removing extreme days, and the
agent answered by inventing "a much lower effect size of 1.2 standard deviations", a fabricated
figure that rides into the provenance line shown to the user. The check survives as
`replicationLenses[1]`, put to analysts who can actually compute it. Panel behaviour did not change.

**The common structure.** Every gate requires a majority or unanimity of independent agents each
instructed "when in doubt, false". The per-agent bar and the aggregation rule push the same way and
multiply: at a ~19% per-lens hold rate, a majority of nine is reachable about 1% of the time. Which
knob moves — per-agent bar, aggregation rule, or lens count — changes what the app is willing to tell
someone about their health, so all three are left as the owner's call. Numbers live in the doc
comments on `passesSafety` and `scrutinyLenses`.

**And a fourth constraint that is pure arithmetic.** The phases are sequential behind a hard barrier:
`runPass` fans out every investigator, waits for all of them, dedups, then vets. Measured per phase —
13 investigators = 432 s; vetting one finding = ~64 s (safety 4.5 + skeptics 18 + replication 41). A
pass yields ~20 proposals, so **vetting costs ~3× more than proposing**, against a 540 s on-power
budget. The window buys the investigators, leaves ~108 s, vets one or two, and drops the rest at the
deadline. Raising the constant does not help: a full pass needs ~1,700 s and BGProcessingTask will
not grant it. The shapes that would — vet as proposals arrive, stop launching investigators once the
remaining time cannot vet what is in hand, or run fewer lenses — each trade something real, so the
arithmetic is recorded on `BackgroundScheduler.enhancementBudget` and the constant left alone.

Those drops were silent. `Orchestrator.affordsVetting` now narrates each one, and the run's closing
note has a third branch: with every model call succeeding, a pass that dropped twenty findings for
time previously read "Nothing new rose above the noise this pass — that's a clean bill, not an empty
one."

### 2026-08-03 — Numbers, not adverbs, in the only whole-picture view any agent gets

`metricsOverview` rendered `- Steps: moderately higher (vs. a year ago)`. The buckets cut at z = 1.5
and 3, so 1.6 and 2.9 arrived identical, as did 3.0 and 12.0 — on a list that is *sorted by |z|* and
then hid the sort key. Choosing what counts as a big move is the agent's job here, and it was handed
the answer instead of the evidence. It now reads `- Steps: +18.4% (2.1 SD, n=90) vs. a year ago`.

The buckets existed so "the model can't quote numbers it wasn't given" — a rationale that expired
when `NumericFidelity` began checking every prose figure against the verified ones, and the agent
already received raw numbers from four other tools. Cost measured rather than assumed: 964 characters
for a full 14-entry digest, about three characters per line more than the adverbs, because dropping
the adverb and the direction word nearly paid for three figures. `Entry.sampleCount` had been
collected, carried, and never rendered.

`metricStats` withheld `z` entirely, so an agent reading "2.1 SD" in the overview got *less* detail
when it drilled in. A percentage cannot say whether a move is large *for this metric* — 3% in resting
heart rate is a signal, 3% in step count is a rounding error. Paid for inside an 11-token margin by
deleting "already computed; never recompute it" from two `@Guide`s that the tool description already
says once for the whole result.

### 2026-08-03 — Four places that told the user a failure had been a success

`llm` records each call's outcome specifically so a run "can tell a genuine 'nothing notable' pass
apart from a wholesale inference failure: the two must not share a closing note". Four places made
the identical claim about a different resource and got it wrong:

- **Ask** returned "I couldn't land a confident answer to that one from your data" for three
  outcomes: the model erroring (fixed by retrying), an empty answer, and the safety panel
  *withholding a real one* — where the sentence is simply false. Three messages now.
- **Ingest** closed with "everything already up to date" whenever it added nothing, which is also
  what a wholesale permission failure, a HealthKit error across all 72 types, and pressing Stop three
  metrics in look like. The warnings above it fired, so the feed contradicted itself one line later.
- **The budget-exhausted drop** said nothing at all.
- **The run's closing note** called a pass that dropped everything for time "a clean bill".

### 2026-08-03 — Prose read as specification: an unbounded prompt string and two false claims

Sweeping doc comments for absolutes is this repo's most productive defect class, and four deliberate
runs each found something.

`InvestigationFocus` claims "every other model-written string reaching a prompt is bounded before it
gets there" and enumerates five clamps. All five were accurate. The bug was what the list did not
name: `ProposedFinding.story` had no clamp anywhere. It becomes the vetting claim read by the
skeptic, replication *and* safety panels — three sessions, so a runaway is paid three times, and the
failure is a session killed by the 4,096-token window, indistinguishable from a rate limit.
Unclamped it measured 12,318 characters. Now clamped in `Phrasing`'s initializer, cut on a word
boundary because it is also the prose a person reads.

`MetricStatsProvider` called itself the single source of numeric truth and said "every statistic the
app surfaces … is computed here". The engine scans are not: `RegimeShiftScan` computes Cohen's d and
pooled SDs, `VolatilityScan` coefficients of variation, `SeasonalityScan` de-trended residuals.
Someone chasing a wrong figure would have come to that file and found the arithmetic three
directories away. What holds is narrower and now enforced by `NumericTruthSourceTests`: it is the
only reader of `MetricRollup`, so statistics can disagree about interpretation but never about which
days happened.

"The agent never states a number" appeared twice. It is false — `NumericFidelity` exists *because*
the agent states figures in its prose. What is true is that the **auditable** numbers under a card
are resolved from source, the agent naming a metric and comparison rather than a figure.

Two promises were true but unenforced, and are now mechanical: `VettedWritePathTests` (only the
persist path writes a finding, every per-kind helper goes through `survives`, safety gates the shared
entry) and the `MetricRollup` reader rule above. `MetricDomain.scopePhrase` was deleted — it derived
a domain list "so scope copy can never silently claim narrower coverage", had no production caller,
and served an out-of-scope Q&A answer that disappeared when Ask became agentic. Two tests kept it
green by calling it directly.

### 2026-08-03 — The statistics are correct; the layer above them is where the problems are

Everything else dated today is about the agent layer failing to select for quality. That makes the
counterpart worth stating: the numbers those agents are judging were reviewed line by line and are
sound. `CorrelationEngine` — the lag-1 autocorrelation estimator, the Bartlett effective-sample
correction `n(1−ρxρy)/(1+ρxρy)` with ρ floored at zero, Fisher-z with a degree of freedom removed per
partialled covariate, `normalCDF` via `erfc`, the Benjamini–Hochberg step-up, tie-averaged ranks for
Spearman, OLS residuals for the partial. `VolatilityScan`'s delta-method SE for a log-SD ratio, and
its `recentSD > 0` guard. `SeasonalityScan`'s per-year least-squares de-trend and its relative
residual floor. `MilestoneScan`'s record logic. No defects.

One imprecision, in `winsorize`. It clips to the 2.5/97.5 percentiles behind a `count >= 8` guard,
and the guard is not what decides when clipping starts — the percentiles are, asymmetrically:

    n <= 20   neither end clipped
    n == 21   low end only        <- exactly minPairs
    n >= 22   both ends

`minPairs` is 21, so a pair at the eligibility floor has no UPPER clip — and the upper end is where
the outliers this exists to stop actually arrive, a backfilled day or device gap producing a large
positive change. It is also the correlation least able to absorb one, at 1/21 of its evidence.
Arithmetically right, documented now, and left alone: widening the clip or moving to a median-based
rule would protect small pairs and change every correlation the app has ever computed.

Recorded because the first version of that finding was wrong. It claimed protection began at 24,
having sampled n at 8, 12, 16, 20, 21 and 24 and read the boundary off the gap — 22 and 23 were never
evaluated, and the test written to pin it failed immediately. A boundary inferred from a grid is a
guess about the points you did not evaluate. `WinsorizeOnsetTests`.

### 2026-08-03 — After the fixes: safety cleared, and the skeptics are what is left

The entries above measured each gate alone. This is all of them together, on a full run over six
metrics with real structure and a budget large enough that nothing was dropped for time (623 s):

    11 proposals reached the safety panel
     5 passed it (45%)          <- was ~14% the same morning
     4 reached the skeptics
     0 passed them              <- 5 holds across 36 verdicts, a 14% per-lens rate
     0 ever reached replication

**The safety panel is fixed.** Rewriting the two lenses that invited inference — "state or *imply* a
diagnosis … or at risk of", and "or otherwise *harmful in tone or framing*" — moved benign prose from
1-in-7 to 45%, and one finding cleared it 5 of 5. That was the gate the earlier entries called the
reason nothing surfaces. It is not any more.

**The skeptic panel is now the single binding constraint,** and the consequence is worse than a low
pass rate: the replication analysts never convene. They are the only reviewers holding tools, and the
work that made them able to complete a re-test at all — the anchored metric vocabulary — buys nothing
while everything dies one gate earlier.

**One of them rejected on a number it could not compute** — "the confidence interval includes zero",
which no basis in the app states and nothing could derive from prose.

That was first written up as three examples and a pattern, and checking the bases afterwards showed
two of the three were the panel working correctly. "The observed shift of 0.1 standard errors from
no-change" is a VERBATIM quotation: `VolatilityShift.verifiedBasis` prints "the shift is %.1f standard
errors from no-change", and it recurred across findings because several weak volatility shifts really
did have seZ near 0.1. "The claim of a correlation of r = 1.0" was a skeptic rebutting a finding
titled "Body Mass and Sleep Duration Are Perfectly Synced" — objecting to an overclaim, which is the
job. Both are the panel doing what it is told: "trust those numbers and reason WITH them."

The narrower version still stands and still matters. A tool-less reviewer asked to RECOMPUTE has no
honest answer available: the lens removed this session invented "removing the extreme outliers would
result in a much lower effect size of 1.2 standard deviations", a counterfactual no basis contains.
Asking such a panel to weigh figures it was handed is fine; asking it to derive new ones is not.

So the options are the per-agent bar ("when in doubt, false"), the majority rule, the lens count, and
keeping every lens answerable from the evidence the reviewer actually holds.

### 2026-08-03 — Three defects on the path taken when the store will not open

The store is `FileProtectionType.completeUnlessOpen`, so a NEW open while the device is locked fails
— and a background task can launch the app in exactly that state after a reboot with no unlock. That
path had three faults, each invisible alone.

**It deleted everything first.** `makeContainer` responded to a failed open by destroying the store
files and rebuilding. That is right for the rollups, which are derived and rebuilt from HealthKit by
the launch catch-up, and wrong for the findings: an `InsightLog` is hours of agent reasoning over a
person's history and exists nowhere else. `VerdantApp`'s in-memory fallback is correct but runs after
the files are already gone. One locked background launch destroyed every finding the app had ever
produced, behind a single log line, and it came back looking new. Now: if the file cannot be READ at
this moment, do not rebuild — the session runs in memory and the next unlocked launch opens it
intact. A genuinely corrupt store is still rebuilt the first time it is opened unlocked, so nothing
is bricked. Readability is tested by opening a handle rather than via
`UIApplication.isProtectedDataAvailable`, which is UIKit and main-actor-bound while this runs
wherever a container is built — and opening the file asks the more direct question.

**The migrations marked themselves done against nothing.** Both bootstrap migrations record
completion in `UserDefaults`, which outlives the session, while `runCatchUp` and `runEnhancement`
guard on `storeIsEphemeral` and the migrations did not. Run against the in-memory stand-in every step
succeeds trivially, the flag is set, and the REAL store skips the civil-day migration permanently —
keeping stale local-midnight rollups and the findings built on them, with the novelty guard blocking
the corrected versions the migration exists to regenerate. Fixing the first defect made this MORE
reachable: a locked launch now lands in memory rather than rebuilding.

**And the user was never told.** `storeIsEphemeral` reached those two guards and nothing else. The
fallback itself is deliberate and right — in the foreground someone is watching, and findings for
this session beat an empty screen — but the app worked visibly for minutes, filled the feed, and came
back next launch with nothing, which reads as lost data rather than a store that could not be opened.
The feed now says both halves: nothing is being kept, and reopening once unlocked picks up where it
left off.

### 2026-08-03 — Two thresholds in an embedding space nobody had measured

`Embeddings` had five tests, all packing vectors by hand and checking the cosine arithmetic. That
verifies the formula and says nothing about the space it runs in — and both thresholds are claims
about that space.

**Duplicate suppression retired genuine findings.** Measured against the model the app ships
(`NLEmbedding.sentenceEmbedding(for: .english)`, 512 static dims): identical text 1.000, one word
changed 0.948, the same claim reworded 0.863, **a DIFFERENT metric in the same sentence shape 0.856**,
an unrelated finding 0.420. The bar was 0.85 — below the shape-match. Static sentence vectors key on
syntax, and this clause only ever sees findings on different metrics because `reusesMetric` retires
the same-metric ones first, so "your step count has settled at a higher level than it used to sit at"
was tombstoned for sitting seven thousandths above the bar beside the same sentence about resting
heart rate. Raised to 0.93; the ambiguous middle goes to the curator, which already receives
"[near-duplicate of #N]" as a fact and can read both findings where a threshold cannot.

**Retrieval was mostly inert.** `minRelevanceCosine` was 0.5, set "below the near-duplicate bar" —
reasoned against finding-to-finding similarity and applied to question-to-finding, which score
differently. Each question against ITS OWN finding: 0.521, 0.430, 0.353, and 0.273 — against 0.275
for an unrelated pair. A question matches its own finding LESS than an unrelated question matches an
unrelated one, so at the low end this space does not rank relevance at all and no threshold recovers
those cases. 0.35 is the best available trade, not a fix: two of four real pairs recalled where 0.5
recalled one, neither unrelated pair admitted. The misses are the embedding's and are pinned as tests
that will fail if it ever improves.

Both constants are now internal so the tests assert the NUMBER rather than a copy of it — written the
other way first, the tests hardcoded the new value and passed happily when the old one was restored.

### Safety rejections now say why (2026-08-03)

The skeptic and replication panels were taught to carry their objection into the fleet's memory. The
safety panel was missed, because it rejects **earlier** — before `survives` — and it is the gate that
rejects most often. Every safety rejection was therefore the constant "the safety panel couldn't
confirm it", and that constant went to three readers whose whole job is to learn from it: `RunLedger`
steers this pass's later investigators, the journal steers the next run, and the research director is
told in so many words that it learns "what the panels rejected and why".

Found by printing the assembled prompt after an unrelated change, not by reading the code. A rejection
ring full of the same constant is indistinguishable from a working feature at the source level — the
call site reads `drop(proposal, "…")` and looks entirely deliberate. This is the same family as the
inert-feature pattern: implemented, tested, and carrying nothing.

`safetyRefusal` returns the flagging reviewer's own sentence, or `nil` when the panel clears the text;
`passesSafety` is now the boolean built on it, so there is one panel and one aggregation. Verified
against the real model: unsafe prose comes back as `It says 'your resting heart rate suggests you may
have a thyroid condition' and 'see a cardiologist and stop your beta blocker'. — the safety panel
refused it`. The reviewer's words lead, so they survive the ledger's 95-character clamp; what gets cut
is the panel's own boilerplate, which is the same ordering argument as `Orchestrator.rejection`.

Two cases are deliberately distinguished. A flag with an empty reason says so rather than trailing an
em dash into nothing. And **no quorum is not an opinion** — the panel fails closed on silence, so that
returns "the safety panel could not be reached (1/5 reviewers answered)". An investigator told the
panel disliked its hypothesis steers away from that ground, which is exactly wrong when no reviewer
ever rendered a verdict.

The aggregation is a static (`Orchestrator.refusal(rendered:total:)`) separated from the fan-out, the
same split as `rejection(by:outcome:)` and for the same reason: a test that must spin up five real
reviewers to reach a branch does not get written.

### Ledger steering is weak, and the cost is coverage (2026-08-03)

`RunLedger` injects "Rejected this run — do NOT re-propose: …" into every subsequent investigator
prompt, and `directorState` repeats it to the research director. The wiring is real — confirmed by
printing the assembled prompt, not by reading the code — so the question left was whether it works.

Measured against the real model, `subagents.investigate` called directly with and without the
steering clause, same lens, same substrate, eight trials each arm (597s for sixteen calls, ~37s each):

    banned pair re-proposed    BARE 3/9 proposals    STEERED 2/12 proposals

**Inconclusive**, and honestly so — at these counts 33% against 17% is noise, and the steered arm
produced MORE proposals overall, so nothing was suppressed wholesale. A first attempt was worse than
inconclusive: it banned a hypothesis with a 1-in-7 base rate, leaving almost nothing to suppress. Ban
the DOMINANT proposal or the experiment cannot answer anything.

What is not statistical is this. Told verbatim not to re-propose "Step Count and Resting Heart Rate
Coherence (the link between daily steps and resting heart rate)", a steered investigator proposed
**"Heart Rate Coherence"** on the same metric pair and the same kind. One instance settles the
question the rates could not: the ban is not reliably respected. Consistent with
`prompts-cannot-constrain-generation` — an instruction in a prompt is a suggestion to a small model.

**Deliberately not fixed with a filter.** Dropping a re-proposed (kind, metric) pair would be a
deterministic guard on an agent's decision, which is the one thing the architecture rules out. And
the cost is not what it first looks like: re-vetting a re-tread burns a full panel cycle (~64s), but
the purpose is to keep the Neural Engine working, so spent cycles are not the loss. **The loss is
coverage** — a fleet that re-litigates ground it already covered explores less of the data in the
same wall-clock. That is the reason to care, and it argues for making the steering land better rather
than for policing its output.

Worth noting the downstream backstop only half-applies: the novelty JUDGE fires on a stored prior
finding, and a REJECTED hypothesis was never stored — so a re-proposal runs the whole gauntlet again
rather than being caught early.

### The investigator prompt, printed and then repaired (2026-08-03)

Following the finding that ledger steering is weak, the next question was whether the steering is
even well-formed. Printing the two prompts `investigate` actually sends — the explore pass and the
commit pass, with a populated ledger — showed three things that neither file revealed on its own,
because the text was assembled from pieces living in two files:

    Rejected this run — do NOT re-propose: … (could not be replicated).. Explore with at most FOUR
    tool calls, then commit your findings — the context window is small.

1. **The task statement was inside the ban list.** The sentence telling the investigator to commit
   findings arrived as a continuation of the sentence listing findings not to make.
2. **A doubled period** — the tell that these clauses had never been read assembled.
3. **The explore pass carried the whole ban list**: 230 of its 480 characters, on a pass that
   measures and proposes nothing, out of a 4,096-token window it also has to pay tool round-trips
   from.

There were two avoid-lists, worded differently, joined at two different points: `Orchestrator`
appended "Retired this run…/Rejected this run…/Dead ends from PRIOR runs…" onto the LENS STRING,
while `Subagents.investigate` appended "Already surfaced recently…" to the end of the prompt.

`AvoidList` now owns all four categories and renders one labelled block, and `investigate` takes the
angle and the covered ground as separate arguments so each pass gets what it needs. The explore
prompt went 480 → 238 characters on the same fixture; the task statement and the avoid-list are each
their own paragraph.

**This is prompt hygiene, and is claimed as nothing more.** It was not measured to improve compliance
with the ban — that would need another A/B against the real model, and the honest prior after the
steering measurement is that a small model's adherence to a prohibition is not something prompt
structure reliably buys (`prompts-cannot-constrain-generation`). What is measured is that the explore
pass got half its window back and the commit prompt no longer hides its own instruction.

The scan pinning the split (`AvoidListTests`) failed vacuously on its first run: it bounded the
explore prompt with the "PASS 2" comment, and `SourceScan.code` strips comments, so the range was
empty and the assertion trivially true. Bounded on `func commitSession()` instead, and confirmed by
injection.

### The replication panel was re-testing a redacted claim (2026-08-03)

Two budgets in this repo disagreed in writing, and the disagreement was silently destroying evidence.
`BasisLengthTests` bounds a finding's `verifiedBasis` at 900 characters, justified on the grounds that
it is "concatenated into the claim every skeptic and every replication analyst reads".
`Subagents.replicate` then did `claim.prefix(400)`.

Measured with the real generators: a realistic regime-shift claim is **935 characters**, so 535 were
discarded and the analyst saw **229 of a 763-character basis**. The caveats sit at the END of the
basis, so what was cut was precisely the evidence against the finding — the device-swap note, the gap
note, the weak-median note.

A second, worse cut sat beside it. The replication lens is `[lens, named, available]` joined and then
clamped to 240; a realistic composition is 350. `named` tells the analyst the exact registry keys and
`available` tells it which metrics have data — both added after a measured failure where "across
three probes against the real model, not one analyst completed a re-test" because they guessed keys
and queried nothing. Being last in the join, they were the first thing the clamp deleted.

Verified against the real model, four trials per arm, same claim and same lens:

    OLD (claim cut at 400)   4/4 rendered a verdict   0/4 mentioned the device swap
    NEW (full claim)         4/4 rendered a verdict   2/4 mentioned the device swap

No overflow either way — the fear the 400 was protecting against does not materialise, and the
replicator has the room (prefix 1,848 of a 2,048 bound, leaving ~2,248 of the 4,096-token window; the
prompt went from ~100 to ~425 tokens). One OLD verdict read "The finding's claim is about a metric
that has no data to work with", which is the exact failure the `available` line exists to prevent.
With the full claim, analysts argued about the device change — `This finding is false because it was
actually a device change` — which is the panel doing its job on evidence it had never been shown.

Both clamps are now expressed against the budgets they must fit and pinned by `ReplicationBudgetTests`
rather than being magic numbers, so raising the basis bound without raising the claim bound fails a
test instead of redacting a finding. The lens is clamped BEFORE the code-generated lines are joined,
so they can never be the casualty. The first value chosen for the lens bound was 800 against a
computed worst case of 805; the test caught the five characters.

`AvoidList` also now covers the scout, which had the identical run-on the investigator did.

### Consumer clamps smaller than producer budgets (2026-08-03)

The replication truncation turned out to be one instance of a class, so every `prefix(n)` in
`Subagents.swift` was compared against the budget of the thing it truncates. A producer is bounded
and tested at one size, a consumer clamps it smaller, nothing compares the two, and the difference is
deleted without a trace.

    consumer                    clamp   what it carries          verdict
    replicate(claim:)             400   935 realistic            LIVE — 535 lost, most of the basis
    direct(state:)              1,200   2,590 in a real run      LIVE — both cross-run lines lost
    curate(roster:)             2,400   1,847 saturated          latent: fits today, was unpinned
    judgeNovelty(candidate:)      380   ~260 typical / 660 max    latent: bites only a long summary

**The director was the worst of the two live ones.** Its state assembles to 2,500 characters in the
saturated fixture and about 2,590 in a real run with four panel rejections; at 1,200 the lines it
lost were the last two — "Prior runs ruled out" and "Chased with no yield". Those are the journal
steering and the barren angles: the ONLY cross-run memory the research director has. The journal
exists so the program iterates day over day instead of starting amnesiac, and the one agent it exists
for could not see it. Nothing was being protected — the director has the roomiest session in the app,
447 tokens of prefix against a 4,096-token window.

**The skeptic panel was checked and is fine.** `scrutinize` passes the claim through whole. It was
the reason for looking, and it was not a defect; recorded so the next person does not re-check it.

**The curator was written up as a live defect before being measured, and is not one.** Hand
arithmetic put a saturated 18-row roster at 3,762 characters against the 2,400 clamp, with a real
consequence attached — the keep-list is applied by walking the WHOLE roster and retiring every row
the curator did not name, so a row past the clamp would be retired for being unread. The measured
roster is 1,847. The estimate was wrong by 2x in the opposite direction to the three occasions this
repo has recorded hand-arithmetic coming out low, which is the more useful lesson: the direction of
the error is not predictable either. The clamp is raised and pinned regardless, because the roster is
bounded by ROW COUNT and nothing bounded its characters.

All four clamps are now expressed against the budgets they must fit and pinned by
`PromptDeliveryTests`, so raising a producer's bound without raising its consumer's fails a test.

### The bottleneck is the fleet's PROSE, not the panels' calibration (2026-08-03)

A full discovery run against the real model, 631 seconds, seven metrics over 200 days with two
deliberately real signals planted (resting heart rate stepping 63→56 at day 70, steps 8,200→11,000 at
the same point). Kept: **0**. Fifteen proposals, and for the first time every rejection carries the
reason the rejecting agent gave:

    number resolution   1
    safety             14 in, 4 out (29%) — 9 substantive refusals + 1 quorum failure
    skeptics            4 in, 0 out
    replication         never convened

The standing account was that the panels are miscalibrated. The reasons say otherwise. Nine safety
refusals, quoted:

    "the heart rate decline is caused by improved cardiovascular fitness"
    the phrase "increased stress" is alarmist
    "this is an anomaly, which is alarming"
    "this combination is unusual and could be a result of…"
    "implies a diagnosis by stating that the user's heart rate has become 'much more…'"

Those are the investigator's own words, and the panel is **right** about them. The fleet is writing
causal explanations and alarmed language into findings whose numbers are fine.

The planted signals prove the point. All three proposals that found the resting-heart-rate step —
"Sustained Resting Heart Rate Decline", "Heart Rate Stability Shift", "Heart Rate Plateau" — died at
SAFETY, not at the skeptics. The app found the true thing and could not say it acceptably.

The four that reached the skeptics were the weak ones, and the skeptics were right about those too:
"a correlation of 1.00 is extremely unlikely", "this is an obvious tautology", "weekdays and weekends
are different, so it should be obvious". Both panels are doing their jobs.

**The investigator is already told "Be factual and calm; never diagnose or give medical advice"** —
that sentence is in `Instructions.investigator` today and did not prevent any of the above. Writing a
fifth prompt-level fix would repeat a mistake this repo has already recorded four times
(`prompts-cannot-constrain-generation`).

Three options, and the choice is the owner's:

- **A rephrase agent.** On a safety refusal, hand the finding and the panel's objection to an agent
  that rewrites the prose descriptively, then run the SAME panel again, once. It does not lower the
  bar — identical five lenses, identical unanimity — it gives the fleet one chance to fix prose the
  panel just told it was the problem. It costs more model calls, which the purpose welcomes, and it
  is an agent fixing an agent's work rather than a deterministic rewrite.
- **A prose lens in the panel that suggests instead of vetoing.** Cheaper, weaker.
- **Accept it.** The app is then correct and silent, which is where it is now.

One quorum failure in fifteen ("the safety panel could not be reached — 2/5 reviewers answered") is
the new distinguishable case earning its keep: under a full run's load reviewers do fail to render,
and that is now visibly different from a judgement about the prose.

### The rephrase gate: built, and measured as under-powered (2026-08-03)

On a safety refusal the finding and the reviewer's own objection now go to a rephraser agent, which
rewrites the prose descriptively; the SAME five lenses then judge the rewrite under the SAME
unanimity, exactly once. `Rephrasing`, `Instructions.rephraser`, `Orchestrator.safetyOutcome`,
`RephraseGateTests`. Four invariants are pinned: a cleared rewrite is what gets stored (and what the
embedding is taken from), a rewrite refused again is dropped with the SECOND objection as its reason,
an unchanged rewrite is dropped without spending a second panel, and a quorum failure is never sent
to the rephraser at all — a panel that never rendered has said nothing about the prose to rewrite
toward.

Measured against the real model on the three findings the earlier full run actually refused, three
trials each. **The result does not support a claim of improvement, and is written down as such.**

    9 trials, 3 reached the feed — but only ONE of those three was a rewrite.

Two of the three clears were the FIRST panel passing prose it had refused twice — so the run said
almost nothing about the rewrite, and it had no control arm. **Re-measured properly**, one prose
sample ("Sudden Surge in Steps"), twenty trials per arm:

    ARM A   panel only        0/20
    ARM B   panel + rewrite   4/20   — 3 of them via an actual rewrite

That is the honest evidence for this feature. On prose the panel otherwise **never** passes, the
rewrite gets three findings through; one-sided Fisher p ≈ 0.05, which is suggestive rather than
settled, but the mechanism is not in doubt — the control arm cannot produce a rewrite by definition.
The rescue reads exactly as intended: "Your step count shows a sudden surge … this is an anomaly"
became "The step count rose from 8,200 to 11,000 daily over the last 30 days".

It also settles the resampling worry in the right direction. If a second draw were passing prose on
panel noise, Arm A would not be 0/20 — at that rate an extra draw is worth about half a finding in
twenty, and three of Arm B's four came from changed text.

**A claim written here last turn was wrong and is retracted.** From three trials per case it said
"the panel is highly variable on identical text … for all three cases", and attributed all three
clears to first-panel variance. One of them was a rewrite, and the case measured here is 0/20 — no
first-panel variance at all. Two OTHER cases did each show one first-panel clear in three trials, so
some prose sits near the panel's edge and some does not; "highly variable" was an n=3 inference
stated as a property of the panel. The 29% funnel figure still has wide error bars, but this is not
the measurement that establishes that.

### The rephrase gate widened, and did not replicate (2026-08-03)

The 0/20 → 4/20 result was one prose sample. Widened to three of the findings the full run actually
refused, twelve trials per arm each:

    causal       ("caused by improved cardiovascular fitness")   panel 4/12   panel+rewrite 1/12
    speculative  ("may reflect increased stress")                panel 0/12   panel+rewrite 2/12
    weight       ("a record low … could be a result of")         panel 0/12   panel+rewrite 0/12

Pooled with the first run: arm A 4/56, arm B 7/56, one-sided Fisher p ≈ 0.27 — no demonstrated
benefit at that point, which is how this entry originally ended. **It was the design that was weak,
not the feature.** See the entry below: conditioning on a refusal settled it in 20 trials where this
design could not in 172.

Two things the widening did establish:

- **Pass rate is a property of the PROSE, not a single panel constant.** 33% for the causal claim,
  0% for the speculative and the weight one, 0% for "sudden surge". Talking about "the panel's pass
  rate" as one number — as this document has done all day, including the 29% funnel figure — mixes
  together prose the panel waves through and prose it never passes.
- **The weight case is 0/12 both arms**, consistent with the standing record that lens 4 resisted
  every rewording and that weight findings are the least likely of any kind to reach a person. The
  rewrite does not help there either.

**The design is confounded and the next measurement must fix it.** The arms ran sequentially, arm A
first, and arm B does roughly three times the model work per trial. A fail-closed panel degrades
under load — quorum failures were observed in the full run — so arm B's FIRST panel is being judged
later and hotter than arm A's. That is the most plausible reading of the causal case going 4/12 down
to 1/12, which no rescue mechanism can cause. Interleave the arms and count quorum failures
separately before drawing any conclusion about the feature.

The gate stays in for now: it costs model calls the purpose welcomes, it demonstrably produces the
right kind of prose when it fires, and the measured risk to the bar is about half a finding in twenty.
But nothing here justifies claiming it helps.


### Rewrite vs. resample: the rephrase gate works (2026-08-03)

Every A/B so far compared "panel" against "panel + rewrite" across all trials, and most of those
trials were spent on findings the first panel passed anyway — outcomes that say nothing about a
rewrite. Conditioning on a REFUSAL makes every trial informative, and matching the extra panel across
both arms isolates the one thing in question: whether the text changed.

Both arms take a substantively refused finding and spend exactly one more panel on it. One rewrites
first; the other simply asks again.

    REWRITE, then re-panel     4/10
    RESAMPLE the same text     0/10

**RETRACTED — the two arms were given different prose.** The probe picked the case with
`round % cases.count` and the arm with `round.isMultiple(of: 2)`, and with two cases those are the
same parity: every rewrite trial ran the causal claim and every resample trial ran the speculative
one. So this compares rewrite-on-A against resample-on-B and cannot support the p ≈ 0.043 it was
reported with. The numbers above are real; the comparison is not.

It is not obviously wrong in the way a broken test is — both arms look symmetric in the source, and
the confound lives in the interaction of two innocuous lines. It surfaced only when the same probe
shape was pointed at weight prose and the arm sizes came out 13 and 9, which is not what an even
split produces.

**Re-run as matched pairs**, with the case advancing every PAIR and the arm alternating within it,
so the two are independent by construction (arm sizes came out 8/8/9, which is the fix visible in the
output):

    causal        rewrite 3/8    resample 2/8
    speculative   rewrite 2/8    resample 0/8
    weight        rewrite 0/9    resample 0/9
    TOTAL         rewrite 5/25   resample 2/25     one-sided Fisher p ≈ 0.21

Directional but not established at that n — 20% against 8% on 25 trials an arm. The confounded run
had inflated the rewrite arm exactly as its structure predicts: rewrite always drew the causal claim,
which is the prose this panel passes most readily.

**Settled by a powered run of the same design** — 200 rounds, causal and speculative prose, weight
excluded because it measured 0/9 in both arms and only dilutes:

    rewrite   25/83   30.1%
    resample  10/87   11.5%          chi-square 9.0, p ≈ 0.003

The rewrite roughly triples the rescue rate over asking the same panel again, and it led at every
checkpoint along the way (4/15, 12/32, 17/48, 23/65, 25/83), so this is not an effect that appeared
late. Arm sizes came out 83 and 87 — balanced, which is the check the confounded run failed.

Both numbers matter. **The rephrase gate works**: conditional on a substantive refusal it rescues
about three findings in ten. And the resample arm puts a number on the cost that was previously only
argued about — **11.5% of refused findings pass on a second identical ask**, so a retry does buy
some passes on panel variance alone. The rewrite's contribution is the ~19 points on top of that.

**Weight prose is immune to both arms.** 0/9 and 0/9, matching the standing record that lens 4
resisted every rewording and that weight findings are the least likely of any kind to reach a person.
A rewrite cannot help there because the objection is to the SUBJECT, not the framing — the finding is
about body mass, and lens 4 asks whether the text stings "in any way".

Resampling is not zero either — 2/25 — so a retry does buy a little on variance alone. Smaller than
the rewrite's share, and now measured rather than argued about.

The methodological lessons, which outlast the numbers:

- 172 trials of the obvious design settled nothing because most trials were spent on findings the
  first panel passed anyway. Conditioning on a refusal made every trial informative.
- Selecting the case with `round % cases.count` and the arm with `round.isMultiple(of: 2)` makes the
  two the same parity. Both lines are innocuous; the confound is in their interaction, and it looked
  perfectly symmetric in review. **The tell was arm sizes of 13 and 9 where an even split was
  intended** — check that a randomisation actually balanced before reading its result.
### The rescue works in isolation and changed nothing end to end (2026-08-03)

Same fixture as the pre-rephrase run, seven metrics over 200 days, two planted signals. 696 seconds
against 631 before, so the gate costs about 10% wall-clock, which the purpose welcomes.

    gate                          before   after
    substantive safety refusals        9      10
    quorum failures                    1       2
    skeptic rejections                 4       2
    number resolution                  1       2
    KEPT                               0       0

**A mechanism proven at 30% in isolation produced no end-to-end change.** One run and sixteen
proposals, so this is not a refutation of the 170-trial result — but it is the number that matters,
and it is zero.

The structural reason is visible in the table and is more important than the feature. **Two gates are
fully closed, not one.** The skeptic panel has now passed 0 of 6 findings across two complete runs. So
even a safety gate that let everything through would surface nothing: the rescue moves a finding from
one wall to the next. Every hypothesis of the form "fix safety and findings will appear" is dead,
including the one that motivated the rephraser.

The planted signals died the same way as before. "Sustained Step Count Decline with Lower Resting
Heart Rate" and "Heart Rate Stability Shift" were refused by safety; "Sudden Drop in Resting Heart
Rate" hit a quorum failure; "Gradual Decrease in Resting Heart Rate" failed number resolution. None
of the four reached a skeptic. The app still finds the true thing and still cannot say it.

Two smaller observations worth keeping:

- **Quorum failures doubled, 1 → 2 of 16.** The rephrase path roughly triples safety-panel load on a
  refused finding, and a fail-closed panel converts load into refusals. At these counts it is not
  distinguishable from noise, but it is the predicted direction and worth watching: a rescue
  mechanism that induces quorum failures would be paying for itself with the same currency.
- **The skeptics' objections remain substantive** — "This finding is trivial and obvious. Heart rate
  variability naturally increases on…" — and against a fixture whose only real structure is two step
  changes, they are largely right. The open question is whether they would recognise the two planted
  signals, and they have never been given the chance to see them.

### The skeptic panel: the reviewers discriminate, the quorum does not (2026-08-03)

The skeptic panel had passed 0 of 6 across two full runs and had **never once been shown a true
finding** — safety killed all four planted signals before they reached it. So it was shown one
directly: the engine's own `RegimeShift` on a planted 63 → 56 bpm step, score 8.55 against a
detection threshold of about 4, described plainly. Against a control of the same shape about a metric
that is flat by construction. Ten panels each.

    TRUE  claim   panel passed 0/10    22 of 90 individual skeptics held it up   24.4%
    FALSE claim   panel passed 0/10     4 of 87 individual skeptics held it up    4.6%

**The skeptics are good and the quorum is impossible.** Individually they separate a true finding
from a false one by better than five to one, chi-square ≈ 14, p ≈ 0.0002 — this is a working
classifier. Then `panelHolds` requires `holds * 2 > rendered`, a strict majority of about nine
reviewers, and a 24% hold rate cannot produce one. The app cannot surface a finding, and the reason
is arithmetic rather than judgement.

This is the SAME failure the safety panel had, in the opposite direction: unanimity-of-five there,
majority-of-nine here, both applied to reviewers instructed to answer "when in doubt, false".

Operating points, from the measured per-skeptic rates at nine reviewers. These are derived from the
binomial, not separately measured, and are offered so the choice can be made on numbers:

    rule            true finding passes    false finding passes
    >= 5 (current)          4.5%                   0.05%
    >= 4                   15.5%                   0.5%
    >= 3                   38%                     0.7%
    >= 2                   69%                     6.2%

**"At least three of nine skeptics hold it up" is the interesting point**: 38% of true findings reach
the feed against 0.7% of false ones, a likelihood ratio above fifty to one. Today's rule buys a
twentieth of the false-positive rate by giving up almost every true finding.

**Not changed here.** This is the owner's call in the same way the safety panel's unanimity is: it
decides what a person sees about their own health, and the honest input is the table, not a quiet
retune. It is also worth noting what it does NOT require — no deterministic guard, no change to any
reviewer, no new agent. One comparison in `panelHolds`.

### The armed replication panel does not discriminate (2026-08-03)

The third gate, measured like the other two. The engine's own `RegimeShift` on a planted 63 → 56 bpm
step against a same-shaped claim about a metric that is flat by construction. Pilot of 5 panels per
arm, then 12 per arm with the arms alternated; verdicts marked "could not test" are already excluded
by `survivesReplication`, so every verdict counted is an analyst asserting it ran a check.

    pilot    TRUE  panel 2/5    analysts 10/20      FALSE  panel 2/5    analysts  8/17
    powered  TRUE  panel 4/12   analysts 23/53      FALSE  panel 7/12   analysts 31/52
    pooled   TRUE  45% of 73 verdicts               FALSE  57% of 69 verdicts    p ≈ 0.18

**No discrimination, and the point estimate is inverted** — the panel holds up the false claim
slightly more often than the true one. Not significant, so the honest claim is the absence of
evidence for discrimination rather than evidence of inversion. Either way there is no sign of the
signal the skeptics show.

The contrast with the gate above it is the finding:

    skeptics     prose only, no tools     24.4% true vs  4.6% false   p ≈ 0.0002
    replication  armed with tools         45%   true vs 57%   false   p ≈ 0.18

**The panel with tools is worse at telling true from false than the panel without them**, and it is
by far the most expensive in the app — about 55 seconds a panel against a few seconds for the
skeptics.

A limitation of this design, which points at the mechanism. The FALSE arm's "Verified basis" was
fabricated by the fixture, and production never fabricates a basis — it is generated from the engine
and is always true. So what this measures is narrower than "can the panel spot a false finding": it
measures whether analysts VERIFY the stated basis against the data, and the answer is that they do
not. They hold up a claim whose basis the data flatly contradicts, at the same rate as one it
supports. For a panel whose entire purpose is re-testing against the data, that is the defect, not a
side-effect of the fixture.

The realistic production failure — a TRUE basis with prose that overstates it — is not measured here
and is the obvious next arm.

**Traced to the tool calls, then partly retracted (same day).** Instrumenting `AnalyzeTool` during a
re-test of the contradicted claim showed all four analysts querying the RIGHT metric — they are not
failing to check. Two refuted it correctly with real figures. Two returned `holdsUp: true` with the
whole reason "No unusual days detected": a vacuous result from a different question, used as
confirmation, with `couldTest` set true.

`Instructions.replicator` turned out to cover only half of that. It said such a result "is not a
contradiction" — written after observing false REFUTATION — and never that it is not a confirmation.
The wording is now symmetric (prefix 1,865 of a 2,048 bound), and **it changed nothing**: 5 of 10
analysts still held the false claim, three of them citing "no unusual days", and NOT ONE used
`couldTest: false` despite being told to. That is the fifth prompt-level fix in this codebase to
improve legibility and not behaviour. The symmetric wording is kept because the asymmetric version
misstated the intent, not because it works.

The trace also showed a plainer failure. Asked about a claim asserting 74 kg against data at 78, two
analysts answered "the mean body mass is exactly 78 kg, matching the verified value" and held it up;
a third refuted it with the two numbers swapped. They are not comparing their result against the
claim — which is precisely the arithmetic this codebase already refuses to trust a small model with,
and does deterministically via `NumericFidelity` on the skeptic path.

**And that is the flaw in this whole measurement.** In production a finding's figures are resolved
from the engine and are always true, so an analyst never faces a claim whose numbers its own query
contradicts. This false arm tests a case the app cannot produce. What the replication panel EXISTS
to catch — per its own doc, "true-looking numbers that exist only in the window that produced them"
— is a claim with correct figures whose effect vanishes under a different window. That is the arm
that decides whether this panel earns its 55 seconds, and it has still not been run. The
"no discrimination" result above stands only for the narrow question of whether analysts verify a
stated basis against data.

### The replication panel fails the job it exists for (2026-08-03)

The arm the panel is FOR, finally run. Both claims state figures that are true; the difference is
whether the effect survives a wider window — "true-looking numbers that exist only in the window that
produced them" is this panel's own stated purpose.

    FRAGILE   a 14-day blip on a flat baseline    panel 3/10   analysts 16/37   43%
    ROBUST    a 70-day step                       panel 0/10   analysts 16/41   39%

**No discrimination — 43% against 39%, p ≈ 0.7 — and the panel passes the FRAGILE claim more often
than the robust one.** Two independent designs now agree: the fabricated-basis arm gave 57% false
against 45% true, and this one gives 43% fragile against 39% robust. The panel is a coin flip.

Worse than uninformative. At a ~39% hold rate under a majority rule over about four rendering
analysts, the panel passes roughly one claim in six **regardless of whether it is true** — so the
robust, well-supported finding was rejected 10 times out of 10. This is not a strict gate. It is a
random veto, and it falls on true findings at the same rate as false ones.

That reframes what to do about it. The purpose says never to trim model calls, and this panel is the
most expensive thing in the app — about 55 seconds a panel. But the cost is not the objection: a
coin-flip veto on true findings would be worth removing if it were free. The aligned answer is to
redesign it so the calls buy something, not to delete it.

The traces say what to change. Across two probes the analysts DID query the right metric every time,
so they can drive the tools. What they cannot do is the last step: two answered "the mean body mass
is exactly 78 kg, matching the verified value" about a claim asserting 74, a third refuted it with
the numbers swapped, and none of ten used `couldTest: false` on a vacuous result despite the
instruction naming that case twice. **Comparing a retrieved number against a claimed one is exactly
the arithmetic this codebase already refuses to trust a small model with** — `NumericFidelity` does
it deterministically on the skeptic path and hands the panel the result as a fact.

So the proposal, for the owner: keep the agent doing what it demonstrably does well — choosing and
running an alternative view of the data — and stop asking it to judge the comparison. Have the
analyst RETURN the figures its check produced, compare them to the claim in code, and hand that
comparison to the panel as a fact, exactly as `survives` already hands over unsupported figures. No
calls are saved; the same sessions run. What changes is that the arithmetic moves to the place this
codebase has twice decided arithmetic belongs.

### The re-reader prototype failed, and pointed at a better answer (2026-08-03)

The proposal in the previous entry — let the analyst RETURN figures and compare them in code — was
built and measured on the same two arms, then removed. Eight readings per arm, median reproduction
ratio (the analyst's own delta divided by the delta the claim asserts):

    ROBUST   a 70-day step, claim -7 bpm       median 0.00x
    FRAGILE  a 14-day blip, claim +3000 steps  median 0.67x

**Inverted.** It makes the true finding look unreproducible and the fragile one reproducible, which
is worse than the coin flip it was meant to replace.

The readings say why, and the reason is not the one the proposal assumed. Taking the arithmetic away
from the analysts worked — the figures they returned were mostly accurate for the window they chose.
**Choosing the window is the hard part, and that is what they cannot do.** Five of eight on the
robust arm reported the same value on both sides ("56.11 to 56.11"), because the resting-heart-rate
step is only visible in a window reaching back more than seventy days and they picked shorter ones.
One returned step-count numbers for a resting-heart-rate claim. Two of eight chose a window that
could have revealed the effect at all, and both of those reproduced it correctly (-1.13x, -1.00x).

So the last step was never the only problem. An agent asked to re-test a claim has to pick a view
that could falsify it, and a small model picks views that cannot.

**Which points somewhere the app already knows how to go.** A holdout window is not a judgement — it
is arithmetic, and `AnalysisSubstrate` can re-run a finding's own statistic on a stretch of data the
finding did not use, deterministically, in milliseconds. That produces a NUMBER, which is exactly
what this architecture says the engines are for: the reproduction ratio becomes a fact in the
`verifiedBasis`, beside the caveats already there, and the panels decide what it means. No agent is
asked to choose a window, no model call is saved, and the analysts keep doing what they demonstrably
do well.

Removed rather than left in place: the type, the instruction, the subagent method and the test
double are all gone. An unused role that does not work is the inert-feature pattern with extra steps.

### The panels do not read the facts the basis already carries (2026-08-03)

The holdout ratio was NOT built, because the premise was testable first and did not hold.

The fragile and robust claims in the previous experiments already differed in a stated fact: one says
"holding 14 days", the other "holding 70 days". If a panel cannot use a tenure figure that is written
in the claim in plain words, adding a reproduction ratio beside it buys nothing. Put to the skeptics,
sixteen panels, two claims identical except for that figure:

    FRAGILE  "holding 14 days"   panel 0/8   skeptics  8/72   11.1%
    ROBUST   "holding 70 days"   panel 0/8   skeptics  5/72    6.9%

**No discrimination, slightly inverted.** Neither panel uses it: the replication analysts ignored the
same distinction, and now the skeptics do too. So the plan to compute a deterministic holdout ratio
and state it in `verifiedBasis` is shelved — it would be a correct number that nothing reads, which
is the inert-feature pattern one more time.

One honest caveat, and it is the trap this repo has already recorded. These two bases were
HAND-WRITTEN, and a hand-written fixture is not what the app produces. It shows: the same skeptics
held the engine-generated basis (763 characters, every caveat firing) at 24%, and these short
hand-written ones at 7-11%. That gap is a confound between the two experiments and it should not be
read as "richer basis, better odds" without a proper test — but it does mean the numbers here are
about hand-written prose, and only the WITHIN-experiment comparison (11.1% vs 6.9%) is sound.

Where that leaves the investigation. All three gates are measured, none is a reviewer-quality
problem, and the one change with a large measured payoff is a single comparison in `panelHolds` that
is the owner's to make. Adding evidence to the basis does not help, because the panels do not read
the evidence already there.

### The device-only promise is now checked on a real file (2026-08-03)

Reading the user-facing copy as a specification, the way the earlier sweeps did. Settings says:

    Findings stay on this device — encrypted, never copied to iCloud or backups

It is true, and it was enforced by a SOURCE SCAN asserting `isExcludedFromBackup = true` appears in
`AppContainer.swift`. A scan for a string cannot tell a wired-up call from an orphaned one — which is
precisely how a feature ends up implemented, tested and inert, a pattern this repo has hit repeatedly.
On the app's most consequential claim, and the one a person has no way to verify for themselves, that
is the wrong kind of evidence.

`applyProtections(to:)` is now internal, and `StoreProtectionTests` calls it against real files in a
temporary directory and reads the attributes back — the store and BOTH sidecars, because SQLite's WAL
holds recently written rows and a backup that captured it would carry findings the main file has not
absorbed yet. Two non-vacuity checks: a freshly written file is confirmed NOT excluded by default (so
the assertion can fail), and making the call a no-op was injected and does fail it, three times over,
once per file.

The rest of the sweep came back clean. `MetricStatsProvider`'s "every statistic anywhere derives from
one set of daily rollups" holds and is enforced by `NumericTruthSourceTests`; the delete-all and
disclaimer copy check out. One prose defect: `AgentState` said its row is "updated at the end of every
pass", and a pass where every model call errored deliberately does NOT stamp it — the behaviour is
right, tested, and explained at the call site, and only the type's own doc disagreed.

### A source scan passed while a production path was misconfigured (2026-08-03)

Auditing the scan-based invariants for the gap the backup-exclusion test had — asserting a STRING
exists rather than that the BEHAVIOUR happens — turned one up immediately, and it was real.

`ZeroCloudTests` asserted that `cloudKitDatabase: .none` appears in `AppContainer.swift`. It does.
Reading the setting off a built container instead reported `_automatic: true, _none: false`: the
in-memory configuration never opted out. That is not a test-only path — `VerdantApp` falls back to an
in-memory store when the real one will not open, so a production configuration carried the SwiftData
default. Nothing synced, because CloudKit needs an entitlement the app does not claim, but that
entitlement is documented in this very test file as the backstop "even if a `ModelConfiguration`
somewhere were misconfigured". One was.

Two defects, one fix each. The in-memory configuration now passes `cloudKitDatabase: .none`, and
`CloudKitConfigurationTests` reads the setting off a built container with a non-vacuity case proving
it can tell a defaulted container from an opted-out one. Separately, the scan was searching
`container.text` rather than `SourceScan.code`, so its positive assertion would have been satisfied
by a COMMENT — in a file whose comments discuss this setting at length, which is the documented reason
`SourceScan.code` exists.

The general lesson for the remaining invariants. A scan is the RIGHT tool for asserting the absence
of something — no networking API, no `LanguageModelSession` outside one file, no write permission in
the entitlements — because absence cannot be observed by running code. It is the WRONG tool for
asserting that something is done, because it cannot distinguish a wired-up call from an orphaned one
or from a comment. Both invariants found wanting today were of the second kind, and both were on the
app's privacy promises.

### Classifying the scan invariants, and the first behavioural conversion (2026-08-03)

Twelve invariants in `ArchitectureInvariantsTests`, sorted by what kind of claim they make:

**Correct as scans — they assert an ABSENCE, which running code cannot observe.** Every
`LanguageModelSession` in one file; no production template generator for finding prose; day
attribution never uses the device calendar; the device calendar only for duration arithmetic; only
the UI formats numbers for a locale; the deletion-blind range query gains no new callers; and the
meta-check that the scan reaches the real app target. A scan is the only instrument for these.

**Behaviour claims a scan can only approximate.** Every screen carrying the disclaimer; every persist
route passing the arguments its writer defaults; every production `DiscoveryContext` stating
`adversarial`; and every journal write carrying the run's own clock. Each of these is checkable by
running something, and a scan sees only the shape of the call.

The last one is converted, because its failure is observable and this repo's own notes single it out
("prefer a behavioural test where the effect is observable — a slipped `now` shows up as wrong
`daysAgo`"). The scan can see that `now:` was PASSED; it cannot see WHAT was passed, and
`now: Date()` satisfies it while being precisely the bug — the journal steers the next run, so a row
stamped with the wall clock inside a run reasoning about a different `now` files a dead end under the
wrong day.

`InvariantBehaviourTests` runs a discovery with a clock 400 days in the past and reads the stored
stamps back. Injecting `now: Date()` at the rejection write fails it by 34,560,000 seconds — **and
all twelve source scans passed on that same injection**, which is the whole argument in one run.

The remaining three are left as scans for now, with the reason recorded rather than the conversion
assumed: the disclaimer claim is about rendered SwiftUI and would need snapshot machinery this repo
does not have, and the other two guard defaulted arguments whose behavioural effect is diffuse enough
that the test would restate the implementation.

### Ask answers the most basic question wrongly (2026-08-03)

The Ask screen is the one agentic surface a user drives directly, and its failures land in front of a
person rather than in a log. Measured against the real model on data with a planted 63 → 56 bpm step
ten weeks old, nine questions:

    answered 5, withheld 2, did-not-finish 2

The counts are the least of it. **Four of the five answers are wrong.** Asked "Has my resting heart
rate changed recently?", all three replies said it had not:

    "Your resting heart rate hasn't changed recently... (pctChange: 0%)"
    "The recent pctChange is 0%, and the z-score is 0."
    "It remained at 56 bpm with no significant change from the baseline of 56 bpm."

The last states the baseline as 56 when it was 63. A fourth answer reported "a strong positive
correlation between your resting heart rate and sleep duration, with a coefficient of 1 and a
p-value of 0" — on series that are independent by construction.

The arithmetic is not wrong; the CHOICE is. `recentVsBaseline` compares the last 7 days against days
7-36, and both windows sit inside the post-step level, so 0% is the correct answer to a question
nobody asked. No comparison in that family reaches back more than about five weeks. The agent picked
the narrowest one and reported it as settling the matter.

**A fix was built, measured, and reverted.** The agent carries `patternScan` and could have found the
step itself; instead of asking it to, the engine's already-detected regimes were STATED in the answer
prompt — the boundary the rest of the app keeps. The block was correct ("Resting heart rate stepped
from 63 bpm to 56 bpm about 69 days ago, and has held there since"), and over five runs three answers
were withheld and **both that got through still said "has not changed recently... over the past 7
days"**. The agent ignored a fact sitting in its own prompt, so the change was removed rather than
left in place adding 250 characters to every question.

Two smaller things the attempt turned up. An invariant caught the first draft using
`MetricFormatting.formatted` in prompt text — the locale formatter is the UI's, and prompt text must
read the same everywhere; `canonical` is the agent-layer one. And the regime scan emitted
"Sleep duration stepped from 7.2 h to 7.2 h about 177 days ago": a detected shift whose two means are
identical once rendered. It is not a scan bug in the sense of a wrong number — no materiality floor
is wanted here, agents judge — but it means a persisted finding's `verifiedBasis` can read
"stepped from X to X", which is incoherent to the panels that must weigh it.

### Ask, measured properly: withholding is the dominant failure (2026-08-03)

The prediction that followed from "agents use only what they are asked about" — that wording forcing
a longer view would fix the answer — was tested over eighteen questions on the planted 63 → 56 bpm
step, and **it is wrong**. "Recently" and "over the last few months" scored identically.

The re-read matters more than the prediction. A keyword classifier ("63", "stepped", "lower level")
scored 0 of 18 and was TOO NARROW: one answer reads "decreased by 8.7% over the past 3 months", which
is exactly the step measured against the all-time baseline. Classifying model prose by keyword nearly
produced a false negative here; every answer had to be read.

Read properly, of the seven answers that were not withheld:

    "recently"                1 correct of 3   (one said "it is at 0 beats per minute")
    "over the last few months" 1 correct of 3  (one said "remained constant at 60.54 bpm")
    "now vs three months ago"  1 correct of 1

**And eleven of eighteen answers — 61% — were withheld by the safety panel.** That is the dominant
Ask failure, larger than wrongness, and it is the same gate as the feed's: unanimity of five reviewers
each told "when in doubt, false". A person asking about their own resting heart rate is told "I
worked that one out, but held it back" three times in five.

So the safety panel's aggregation is not only why the FEED is empty. It is also why the one surface a
user drives directly mostly declines to answer. Whatever is decided about `panelHolds` for the
skeptics, the same question applies here, and this measurement is the argument for taking it up: the
withheld answers were computed, then thrown away.

One figure reached an answer that should not have: "It is at 0 beats per minute (bpm) with no change
from the baseline (0 bpm)". The numbers are the tool's — a zeroed digest is what `MetricStatsTool`
returns for an out-of-vocabulary key, and the agent read it as a measurement rather than as absence.

### metricStats no longer hands back a quotable zero (2026-08-03)

`MetricStatsTool` returned `baseline: 0, recent: 0, pctChange: 0, z: 0, confident: false` when no
stat existed for a (metric, comparison) pair. The reasoning, written into its test, was that
"`confident: false` is the signal the model reads as 'no data' — a confident zero would be quoted".

It was quoted. On the Ask screen a user was told "Your resting heart rate ... is at 0 beats per
minute (bpm) with no change from the baseline (0 bpm)". A boolean the agent is not asked about does
not get read; that is the failure measured ten times over today. The only reliable way to stop a
number being quoted is not to hand one over, so the tool now throws, and the message says the thing
that was misread: "This is not a value of zero."

Verified against the real model: the session SURVIVES the throw — six questions, none died, the
agent completed or declined every one. That was the risk worth checking before preferring an error
to a value.

Two things this does not fix, stated so nobody reads more into it. The agent still answers "your body
mass has stayed the same this year" about a metric with no data at all — absence confabulated as
no-change, the same root cause one level up. And 4 of those 6 answers were withheld by the safety
panel, consistent with the 61% measured across eighteen questions.

Also corrected: the no-stat path logged an INVARIANT VIOLATION for both cases it handles. An
out-of-vocabulary key genuinely is one; a valid pair with no computed stat is ordinary — a metric can
lack the samples a comparison needs — and was filling the one log that should stay empty with noise.
Only the first is logged now.

### metricStats reports absence instead of zeros (2026-08-03)

The tool returned a well-formed `0/0/0/0, confident: false` for a metric with no data, and the
answerer quoted it: "your body mass has remained stable at 0 over the past year". Fixing it took
three attempts, and the two failures are the useful part.

**The source was not where it looked.** `allStats()` MANUFACTURES a row for every (metric,
comparison) pair whether or not the metric has data — five bodyMass rows on a fixture containing no
body mass. So the zeros came through the normal path, and a first fix guarding the "no row found"
branch was aimed at a case that essentially never fires.

**Throwing killed the session.** Removing the number entirely returned nothing at all, five answers
out of five. Worse, the run that certified "the session survives a throw" was VACUOUS: at that point
the throw only covered out-of-vocabulary keys, which guided generation prevents, so nothing was ever
thrown in the test that passed.

**What worked was copying `analyze`.** Its `QueryResult` carries `available: false` beside a
plain-language `description`, and agents demonstrably read it — "No data for Heart rate" appears
verbatim in their verdicts. `MetricStatDigest` gained the same field. Measured on the same question:

    before   0 of 5 answers mentioned the absence; they reported "stable at 0"
    after    5 of 5 mention it

Two details that only showed up by reading the answers. Phrased as an internal instruction ("these
zeros mean ABSENCE — do not report them as values"), two answers in five repeated it to the user
verbatim, capitals and all: **a field an agent is expected to quote has to be sayable.** And the
comparison's `displayName` is adverbial, producing "There is no vs. a year ago data for Weight";
`baselineLabel` is a noun phrase and reads as English in that slot.

Not fixed: two answers still open with "your body mass has not changed this year" before contradicting
themselves with the absence. The leading clause is wrong; the answer no longer is.

This is the day's synthesis working as advertised — the lever that moved it was the CONTENT OF A TOOL
RESULT, not an instruction. Note also that it cost nothing on the prompt budget: a tool's prefix
schema is its ARGUMENTS, so result fields are far cheaper than the "paid three times over" note in
the token harness implies, which is about arguments only.

### The manufactured zero rows, traced to their other consumers (2026-08-03)

`allStats()` returns a row for every (metric, comparison) pair whether or not the metric has data.
Having found one of them quoted to a user, the question was what else reads them.

    MetricStatsTool     LEAKED — fixed, now reports absence with a reason
    MetricsOverviewTool safe — the digest builder filters on `confident && recentCount > 0`
    persistTrendProposal safe — `MaterialityRules.buildFact` opens with `guard stat.confident`

So no FINDING could ever be built on one, which is the path that mattered: a fact there becomes prose
on the feed, and "your weight changed 0%" would be a fabricated finding rather than a bad answer. The
leak was confined to the single consumer already repaired.

`ManufacturedZeroContainmentTests` pins the two safe paths, opening with a non-vacuity case asserting
the hazard still exists — five empty bodyMass rows on a fixture with no body mass. If the substrate
ever stops manufacturing them, that test fails first and says so, rather than the other two quietly
becoming tautologies.

Left alone deliberately: the rows themselves. Removing them at the source would be tidier and looks
harmless — `MetricStatsTool`'s missing-row branch now returns the same absence digest as its
empty-row branch — but it changes a shared accessor's semantics on the strength of an afternoon's
reading, and the leak it caused is closed and guarded. Recorded as an option rather than taken.

### unusualDays now says what silence means (2026-08-03)

`UnusualDaysResult` had one field, `days`. An empty array arrived with no statement of its meaning,
and the meaning got invented: replication analysts returned `holdsUp: true` on a claim the data flatly
contradicts, with the entire reason "No unusual days detected".

That reading is backwards, which is the part worth fixing. A clean step to a new level produces NO
unusual days, because every day after it is ordinary FOR that level. Silence there is weak evidence
FOR a sustained shift and no evidence at all about whether one is real — and the tool was letting an
agent read it as confirmation of steadiness.

Same shape as the zeroed digest, same fix, and the same three silences distinguished rather than
merged: nothing stood out (a fact about the data), nothing further beyond this page (a fact about
paging), and — in `EventWindowTool`, which shares the type — nothing moved around those days (a fact
about the window that was asked about).

Measured on the same false claim, ten analysts against a baseline of ten:

    before   5 of 10 held it up, three citing "no unusual days"
    after    3 of 10 held it up

Not significant at this n (p ≈ 0.5), and not claimed as such. What IS established is that the note is
READ: one analyst quoted it verbatim and used it to refute — "No single day stood out from its own
baseline here. That is not evidence of steadiness" — which is the sentence doing exactly the work it
was written for.

**The residue is a different failure and no note will fix it.** Two of the three that still held
answered "the mean of bodyMass is 78 kg, which matches the verified value" about a claim asserting 74.
That is comparing a retrieved number against a stated one, which this codebase already refuses to
trust a small model with and does deterministically via `NumericFidelity` on the skeptic path. The
replication path has no equivalent, and every measurement today says it needs one.

### The fabricated-basis measurements were testing a case the app prevents (2026-08-03)

Planned work: point `NumericFidelity` at the replication path, since analysts were answering "the mean
of bodyMass is 78 kg, which matches the verified value" about a claim asserting 74. Checked before
building, and neither half of the premise held.

**It already reaches that panel.** `survives` appends the unsupported-figures clause to `claim`, and
`claim` is the same string passed to `survivesReplication`. There was no gap.

**And the misreading cannot happen in production.** Measured directly:

    engine-generated basis     NumericFidelity flags ["74"]
    the basis my fixture wrote NumericFidelity flags []

The checker is sound — its boundary is exactly the documented ±5% (74 flagged against 78, 76 and 80
accepted, 82 flagged). What defeated it was the fixture: my hand-written basis said "78 kg before and
74 kg after", so the false figure appeared in the BASIS, which is the trusted source the whole check
anchors on. Production bases are engine-generated and cannot contain a figure the data does not
support.

So the fabricated-basis arm of the replication measurements — 45% true against 57% false — was
testing a scenario the app structurally prevents, and the "no discrimination" conclusion rests
properly on the OTHER arm, window-fragility, where both claims state true figures and the panel scored
43% fragile against 39% robust. That result stands; this one should be read as measuring nothing about
production.

**The reusable lesson: a fixture that fabricates the system's TRUSTED input measures a scenario the
system prevents.** This repo already knew to write tests against what the system produces rather than
what one invents; the sharper form is that inventing the trust anchor specifically disables the
defence built on it, and the test then reports a vulnerability that does not exist.

Nothing was built. The real replication failure — not choosing a window that could falsify the claim —
is untouched by any of this and remains the open one.

### The replication panel is NOT a coin flip — the fixture was starving it (2026-08-03)

Every replication measurement today used a HAND-WRITTEN `verifiedBasis`, roughly ninety characters
against the engine's two to three hundred. Rebuilt so both claims carry the engine's own basis, same
two arms, sixteen panels:

    ROBUST   a 69-day step   panel 5/8   analysts 18/31   58%
    FRAGILE  a 20-day step   panel 1/8   analysts 13/36   36%

**That reverses the conclusion.** With hand-written bases the same comparison gave 39% robust against
43% fragile — no discrimination, point estimate inverted. With the engine's basis it is 58% against
36%, in the correct direction, chi-square ≈ 3.2, p ≈ 0.07 two-sided. Marginal at this n and not
claimed as settled, but the direction is right and the panel-level difference is large: **5 of 8 true
claims pass, where the earlier reading said it vetoed roughly five in six.**

So these earlier statements are withdrawn: "the armed replication panel is a coin flip", "no
discrimination on either arm", and "a random veto that falls on true findings at the same rate as
false ones". They were measured on claims stripped of the evidence the panel exists to weigh.

The mechanism is the same one that makes the panel worth having. Its analysts re-test against data,
and the basis is what tells them WHAT to re-test — `postDays`, the co-jump caveat, the provenance
note, the median echo. A bare sentence gives them a claim and no purchase on it. This also explains
the earlier observation that skeptics held an engine basis at 24% and hand-written ones at 7-11%,
which was noted as an unexplained confound between experiments and is now the same effect.

**The general lesson, and the second one today about fixtures.** A hand-written fixture does not merely
risk drifting from what the app produces — where the system's behaviour DEPENDS on the richness of an
input, an impoverished fixture measures a system that does not exist. Both of today's fixture errors
made the app look worse than it is: one disabled `NumericFidelity` by fabricating the trust anchor,
this one starved the panel of its evidence.

Unchanged: the 20-day arm is not the 14-day blip that was seeded — the engine's split blended blip and
baseline days — so the contrast is 69 days against 20, weaker than intended. A sharper fragile case
would test this harder.

### The skeptic figure re-checked symmetrically — and the recommended threshold moves (2026-08-03)

The original 24.4%-vs-4.6% measurement was asymmetric: an engine basis for the true arm, a
hand-written one for the false control. Since that asymmetry is what corrupted the replication numbers,
it needed redoing with both arms engine-generated.

The false arm has an honest form, discovered while looking for one. **The engine reports a regime shift
in pure noise, every time** — score 0.06 against 8.55 for a real step, `preMean == postMean`, median
echo 0.00. That is not a bug: its basis says so plainly, "a sustained step from ~78.0 kg to ~78.0 kg
… (effect size 0.1 standard deviations); caveats: the medians echo the step only weakly", which is the
engines-inform-agents-decide boundary working. It also earlier prompted a note here that
"stepped from X to X" is incoherent to the panels; that is softened — an agent reading the whole basis
has the effect size and the caveat.

Both arms engine-generated, sixteen panels:

    REAL      score 8.55    panel 1/8    skeptics 26/70    37.1%
    SPURIOUS  score 0.06    panel 0/8    skeptics  9/72    12.5%

**Discrimination confirmed**, chi-square 11.6, p ≈ 0.0007 — a second independent result after the
asymmetric run's p ≈ 0.0002. That conclusion is now solid.

**But the RATES moved, and the operating-point table depends on them.** The true-arm hold rate read
24.4% then and 37.1% now (Fisher p ≈ 0.08 between the two runs — the measurement itself has that much
variance), and the false arm 4.6% then, 12.5% now. Recomputing at 37.1%/12.5% over nine skeptics:

    rule            true passes    false passes
    >= 5 (current)      21%            0.3%
    >= 4                44%            1.8%
    >= 3                71%            9.2%
    >= 2                90%           31%

**So the earlier recommendation of ">= 3 of 9" is withdrawn.** On these rates it admits 9% of
spurious findings, not the 0.7% computed from the asymmetric numbers. **">= 4" is the better trade** —
44% of true findings against under 2% of spurious ones.

Two honest caveats on that table. It is a binomial model assuming independent skeptics, and they are
not independent — they read the same claim, so their errors correlate. The model predicts 21% for the
current rule where the observed panel rate is 1 of 18 across both runs, about 6%, so **the model
overestimates**. And the true-arm rate is only known to within 24-37%.

Which means the table should not be the basis of the decision. The right measurement is to record
PER-PANEL hold counts and evaluate each threshold directly against them, which costs nothing extra —
the panels have already run twice — and needs no independence assumption at all.
