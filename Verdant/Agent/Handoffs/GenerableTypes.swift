import FoundationModels

// Machine-checkable handoffs between ephemeral subagents. Every cross-session value is one
// of these `@Generable` structs — there is no long-lived transcript. Closed `.anyOf`
// vocabularies mean the model can only ever name metrics/comparisons the deterministic
// verifier can recompute.
//
// These types are `nonisolated` because the model runs off the main actor; the Orchestrator
// (MainActor) and the subagents (off-main) both construct and read them.

/// The slim, model-facing view of a `MetricStat`, returned by `MetricStatsTool`. Carries the
/// already-computed numbers so the model never sees raw samples and never does arithmetic.
@Generable nonisolated struct MetricStatDigest: Equatable {
    @Guide(description: "Metric key")
    let metric: String
    @Guide(description: "Comparison key")
    let comparison: String
    /// "already computed; never recompute it" was on both of the next two, and the tool's own
    /// description already says it once for the whole result ("The numbers are already calculated —
    /// use them as given; never compute your own"). Saying it three times cost about ten tokens of a
    /// shared schema whose spare capacity is eleven — and those tokens bought `z` below, which the
    /// agent had no way to obtain at all.
    @Guide(description: "Baseline mean")
    let baseline: Double
    @Guide(description: "Recent mean")
    let recent: Double
    @Guide(description: "Percent change from baseline to recent")
    let pctChange: Double
    /// The move in standard deviations of the baseline's own spread.
    ///
    /// Withheld until now, on the reasoning that buckets and percentages were enough. They are not:
    /// a percentage cannot say whether a move is large FOR THIS METRIC. A 3% rise in resting heart
    /// rate is a real signal and a 3% rise in step count is a rounding error, and `pctChange` reads
    /// identically for both. This is the only figure here that compares across metrics — it is what
    /// the digest is ranked by upstream, and what `confident` is silently a judgement about.
    @Guide(description: "Move in standard deviations of baseline (2 is notable)")
    let z: Double
    @Guide(description: "Number of days this comparison is based on")
    let dayCount: Int
    @Guide(description: "Whether there is enough data to trust this comparison")
    let confident: Bool
    /// Empty when the figures are real. Non-empty when they are NOT figures at all — the same job
    /// `QueryResult.description` does for `analyze`, which agents demonstrably read back verbatim
    /// ("No data for Heart rate"), where a bare `confident: false` was quoted straight past.
    @Guide(description: "Empty normally; when set, the numbers are absent rather than measured")
    let note: String
}

nonisolated extension MetricStat {
    /// The slim digest handed to the model: the computed figures, never the raw samples or the
    /// per-side counts.
    var digest: MetricStatDigest {
        MetricStatDigest(
            metric: metric.rawValue,
            comparison: comparison.rawValue,
            baseline: baseline,
            recent: recent,
            pctChange: pctChange,
            z: z,
            dayCount: n,
            confident: confident,
            note: ""
        )
    }
}

/// Adversarial-verification output: a skeptic's verdict on whether a proposed finding survives
/// scrutiny. Several independent skeptics vote; a finding is kept only if it survives a majority.
/// The reason comes FIRST so the small model commits to its reasoning before the verdict — and so
/// the panel's thinking is narrated and steered on instead of discarded as a bare boolean.
@Generable nonisolated struct Verdict {
    @Guide(description: """
    One terse sentence: the single strongest consideration behind your verdict — the flaw that \
    kills it, or what convinced you it survives.
    """)
    let why: String
    /// Whether the check could be RUN at all — distinct from whether it passed.
    ///
    /// A replication analyst that cannot obtain the data has refuted nothing, but the instruction it
    /// works under says "when in doubt, false", so it returned `holdsUp: false` and the tally counted
    /// that as evidence against the finding. Observed against the real model: asked to re-test a
    /// resting-heart-rate step, an analyst queried a metric with no data, answered "No data for Heart
    /// rate.", and the panel scored 0 of 5 on a claim whose own basis stated the numbers.
    ///
    /// The panel already excludes verdicts that never rendered, on exactly this reasoning — no
    /// evidence is not evidence against. This puts "rendered, but could not test" in the same class.
    ///
    /// Widened once the panel started completing re-tests at all, because a SECOND way to learn
    /// nothing then became visible. Observed the first run the analysts could reach the data: asked
    /// to re-test a 30-day resting-heart-rate drop, an analyst compared weekday against weekend
    /// averages, found no significant difference, and returned "the claim fails because the
    /// difference between the weekday and weekend averages is not statistically significant." A
    /// uniform drop is perfectly consistent with that, so the check bore on nothing — yet it refuted
    /// the finding and became the headline a person would have read.
    ///
    /// So the question is not "did your check run" but "did it test THIS claim". Both ways of coming
    /// back empty-handed belong in the same class: no evidence, counted neither way.
    ///
    /// The same hole then appeared in the OPPOSITE direction, and the instruction had only ever
    /// closed one side of it. Tracing the analysts' actual tool calls on a claim the data flatly
    /// contradicts (body mass flat at 78 kg, claim asserts a step to 74), all four queried the right
    /// metric; two refuted it correctly with real figures, and two returned `holdsUp: true` with the
    /// entire reason "No unusual days detected" — a vacuous result from a different question, used as
    /// CONFIRMATION, with `couldTest` set true. `Instructions.replicator` had said such a result "is
    /// not a contradiction" and never that it is not a confirmation, because it was written after
    /// observing false refutation. That asymmetry is the likeliest source of the panel's measured
    /// inability to tell a true claim from a false one.
    @Guide(description: """
    True if your check actually tested this claim. False when it did not — the data was not there \
    (no samples, no such metric), or your check ran but its result bears on something else. Not a \
    judgement on the finding: use holdsUp for that.
    """)
    let couldTest: Bool
    @Guide(description: """
    True only if this finding genuinely holds up — not trivial, not an obvious restatement, not a \
    likely coincidence or artifact, and actually worth a thoughtful person's attention. When in \
    doubt, false.
    """)
    let holdsUp: Bool
}

/// Safety-panel output: one reviewer's verdict on whether a piece of model-written prose is safe to
/// show. Safety is now an AGENT decision — a fan-out of perspective-diverse reviewers, any of whom can
/// veto — rather than a deterministic blocklist. The panel fails CLOSED: prose is shown only if the
/// panel actively confirms it is safe.
@Generable nonisolated struct SafetyVerdict {
    /// The reason, FIRST — the same ordering `Verdict` uses and for the same documented reason: the
    /// small model commits to its reasoning before its verdict, and the panel's thinking is narrated
    /// rather than discarded as a bare boolean.
    ///
    /// This was the one verdict type in the app without it, on the app's most consequential gate.
    /// Safety runs before the skeptics and the replication analysts, needs UNANIMITY among five, and
    /// fails closed — so one reviewer ends a finding, and the other two panels never convene.
    ///
    /// Measured against the real model on a deliberately benign claim ("Your resting heart rate
    /// stepped down about a month ago and has stayed there — it now sits around 54 bpm, against
    /// roughly 63 bpm before" — no diagnosis, no condition, no advice): four reviewers cleared it,
    /// the fifth flagged it, and the finding died. All the feed could report was the LENS that
    /// fired, because a lens is a question and the answer was a single bit. Whether that reviewer
    /// had found something real or had simply agreed with a leading question was unknowable.
    @Guide(description: """
    One terse sentence: the specific thing in this text that concerns you, or why it is fine. Name \
    the words, not the category.
    """)
    let why: String
    @Guide(description: """
    True only if the text is safe to show a wellness-app user for the specific concern posed — it makes \
    no diagnosis, names no disease/condition as the user's, gives no medical advice, and is not \
    alarmist. When in doubt, false.
    """)
    let isSafe: Bool
}

/// Investigator output: one single-metric finding the agent uncovered by driving the tools itself.
/// The agent names the metric/comparison from the closed vocabulary (so the orchestrator can resolve
/// the authoritative numbers from source), and supplies the prose + its own worth judgment. This is
/// the handoff of the inverted architecture: the agent investigates via tools and proposes findings,
/// rather than a logical workflow feeding it one pre-chosen candidate.
@Generable nonisolated struct ProposedFinding: Equatable {
    @Guide(description: """
    What kind of finding this is: a single-metric trend/anomaly (vs. a comparison window), a volatility \
    shift, a record milestone, a sustained regimeShift, or a two-metric correlation.
    """, .anyOf(InsightKind.investigatorFacingRawValues))
    let kind: String
    /// No .anyOf: the full 72-key vocabulary would ride in the guided-generation schema at the END
    /// of the transcript — the window's fullest moment (it blew the 4096 budget on device). The
    /// model reads valid keys from every tool result it explored, and the registry resolve at
    /// persist time drops any unresolvable key — the anti-hallucination boundary is the registry.
    @Guide(description: """
    The metric this finding is about (exact metric key as used by the tools); for a correlation, \
    the first of the two.
    """)
    let metric: String
    /// No .anyOf here: with the full registry the duplicated vocabulary would bloat the context
    /// window, and the registry resolve at persist time already drops any unresolvable key — the
    /// anti-hallucination boundary is the registry, not this guide.
    @Guide(description: """
    For a correlation ONLY, the second metric involved (exact metric key as used by the tools); for \
    every other kind, repeat the same metric.
    """)
    let secondaryMetric: String
    @Guide(
        description: "For a trend/anomaly, the comparison window; ignored for the other kinds",
        .anyOf(ComparisonKey.allRawValues)
    )
    let comparison: String
    @Guide(description: """
    A specific, evocative 3-6 word headline that names the actual pattern, not the metric. Avoid bland \
    labels like "Heart Rate Trend".
    """)
    let title: String
    @Guide(description: """
    Two or three sentences: state the change plainly, offer one careful non-obvious interpretation of \
    what it might reflect, and note why it is worth attention. Use ONLY numbers you read from the \
    tools; invent nothing. Factual and calm. No diagnosis, no medical advice, no alarm.
    """)
    let story: String
    @Guide(description: """
    How deep and non-obvious this is — 0 = visible at a glance in the Apple Health app, 100 = a \
    fascinating connection or shift the user could never have seen themselves. Judge novelty and \
    depth, not size or how alarming it sounds.
    """, .range(0...100))
    let worth: Int
}

/// The investigator's full result: the few findings worth telling that it uncovered this pass. It may
/// propose zero — a thin list of real, non-obvious findings beats a padded one.
@Generable nonisolated struct InvestigationResult {
    @Guide(
        description: "The few TRULY DEEP, non-obvious findings uncovered — nothing the Health app would "
            + "already show; propose zero rather than pad",
        .count(0...EnhancementPolicy.maxCandidates)
    )
    let findings: [ProposedFinding]
}

/// One scout lead: a testable hypothesis handed from the surveying scout to the investigator
/// fleet. Consumed as PROMPT TEXT (a lead lens), never persisted — so the metric fields resolve
/// softly, and there is deliberately no metric `.anyOf` (same schema-size reasoning as
/// `ProposedFinding.metric`).
@Generable nonisolated struct ProposedLead: Equatable {
    @Guide(description: """
    One terse, testable hypothesis — what might be true in the data and how an investigator could \
    check it. A single sentence.
    """)
    let hypothesis: String
    @Guide(description: "The main metric key involved (as used by the tools)")
    let metric: String
    @Guide(description: "A second metric key if the lead links two; otherwise repeat the first")
    let secondaryMetric: String
}

/// The scout's full result: the few UNTESTED places worth an investigator's time this pass. Zero
/// is a fine answer — a sharp lead beats a padded list.
@Generable nonisolated struct ScoutReport {
    @Guide(
        description: "The few most promising untested leads — propose zero rather than pad",
        .count(0...DeepAnalysisPolicy.maxLeadsPerScout)
    )
    let leads: [ProposedLead]
}

/// The research director's plan for ONE deep-run pass. The STRATEGY decision is the agent's —
/// dry streaks, feed contents, and the run ledger are facts it reads, not rules that decide.
@Generable nonisolated struct PassPlan {
    @Guide(description: """
    The next pass's strategy: breadth = sweep broad thematic ground for new findings; drill = dig \
    deeper into the strongest findings already on the feed; frontier = push into unexplored \
    corners — rare metrics, the oldest windows, the gaps.
    """, .anyOf(Orchestrator.PassStrategy.allRawValues))
    let strategy: String
    @Guide(description: """
    One sentence directing the fleet: the single most promising direction for this pass given \
    what has been found, rejected, and left unexplored. Specific — name metrics or windows.
    """)
    let directive: String
    @Guide(description: """
    Angles of your OWN to add to this pass's fleet — each one sentence telling a specialist \
    investigator what to hunt, naming metrics or windows. These are EXTRA investigators, not \
    replacements, so add only angles the standard sweep would miss. None is a fine answer.
    """, .count(0...3))
    let extraLenses: [String]
}

/// Challenges written FOR one specific finding, added to the skeptic panel's fixed six. The fixed
/// lenses are the failure modes every finding shares (trivial? coincidence? artifact? too small?
/// reversed? outliers?); these are the ones only this claim has. Additive — a finding never faces
/// fewer challenges because the challenger was terse.
@Generable nonisolated struct ChallengeSet {
    @Guide(description: """
    Specific ways THIS finding in particular could be wrong — each one a single sharp question a \
    skeptic should put to it, naming what makes this claim vulnerable. Skip anything a generic \
    reviewer would already ask. None is a fine answer.
    """, .count(0...3))
    let challenges: [String]
}

/// Re-tests written FOR one specific claim, added to the armed replication panel's fixed three.
/// Where `ChallengeSet` asks how a claim could be wrong in PRINCIPLE, these say what to COMPUTE:
/// the analyst that receives one drives `analyze`/`unusualDays` to run it. Additive, like every
/// other panel extension.
@Generable nonisolated struct RetestPlan {
    @Guide(description: """
    Re-tests only THIS claim needs — each one a concrete check an analyst can run with analyze or \
    unusualDays (a specific window, lag, day-filter, or median-vs-mean swap), and what result would \
    contradict the claim. Skip anything a generic re-test already covers. None is a fine answer.
    """, .count(0...2))
    let retests: [String]
}

/// The exploring investigator's field notes — what it actually MEASURED in its first session,
/// handed to a second session that tests and commits. The 4,096-token window is what forces the
/// investigator's four-tool-call budget; splitting exploration from commitment buys a second clean
/// window instead of loosening that budget, so a lens gets roughly twice the tool round-trips
/// without either session ever running out of room. Terse by construction: these ride in the
/// follow-up session's prompt.
@Generable nonisolated struct ExplorationNotes {
    @Guide(description: """
    What you MEASURED, one terse line each, with the numbers the tools returned and the exact \
    metric keys. No conclusions and no findings — just the readings.
    """, .count(0...5))
    let notes: [String]
}

/// The curator's decision: which findings keep their feed slots. Curation is an AGENT decision —
/// the roster's quality scores, ages, and overlap/duplicate notes are deterministic FACTS it
/// weighs; every roster number left out is retired.
@Generable nonisolated struct CurationDecision {
    @Guide(description: """
    The numbers of the findings to KEEP on the feed — the deepest, most distinct set. Every \
    number not listed is retired. Never keep two findings telling the same story or leaning on \
    the same metric unless both are exceptional.
    """, .count(0...EnhancementPolicy.maxActiveFindings))
    let keep: [Int]

    @Guide(description: """
    Of the numbers you kept, the few that are genuinely STANDOUT — the ones worth reading first. \
    Leave empty if nothing rises above the rest; never promote something merely because it scored \
    well.
    """, .count(0...Orchestrator.maxHighlights))
    let highlight: [Int]
}

/// The novelty judge's verdict: is a candidate a meaningful UPDATE over the standing finding it
/// collides with, or a re-tread? Freshness is an AGENT decision — the deterministic lookback
/// window only selects which standing finding to compare against.
@Generable nonisolated struct NoveltyVerdict {
    @Guide(description: """
    True ONLY if the candidate says something meaningfully NEW versus the standing finding — the \
    pattern strengthened, reversed, extended to a longer span, or changed character. False if it \
    re-tells the same story in new words. When in doubt, false.
    """)
    let meaningfulUpdate: Bool
}

/// Q&A Answerer output.
@Generable nonisolated struct Answer {
    @Guide(description: """
    Answer the question directly and specifically using only the numbers provided — cite the actual \
    figure rather than gesturing at it, and bring in the longer time view when it sharpens the \
    answer. Calm, factual, concise. State plainly if the data can't answer it. No diagnosis, no \
    medical advice, no filler.
    """)
    let text: String
}

/// A safety-refused finding, rewritten by an agent that was shown the panel's objection.
///
/// The numbers are NOT here. They are resolved from source after safety, so a rewrite cannot invent
/// a figure, and `NumericFidelity` still checks the rewritten prose against the verified values
/// downstream. What this agent may change is how the finding is SAID — which is what the panel
/// objected to in every measured case.
@Generable nonisolated struct Rephrasing: Equatable {
    /// The change, FIRST — the same ordering `Verdict` and `SafetyVerdict` use, and for the same
    /// reason: the small model commits to what it is doing before doing it, and the sentence is
    /// worth reading when the rewrite fails the panel a second time.
    @Guide(description: """
    In one sentence, what you removed or reworded to answer the objection.
    """)
    let changed: String
    @Guide(description: """
    The rewritten title: 3-6 plain words naming what moved. No cause, no judgement, no alarm.
    """)
    let oneTapTitle: String
    @Guide(description: """
    The rewritten finding in two or three plain sentences. State only what the data shows and over \
    what period. Keep every number exactly as it was.
    """)
    let summary: String
}
