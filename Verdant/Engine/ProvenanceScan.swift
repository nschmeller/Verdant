import Foundation

/// One metric's recording history: which sources produced each day.
nonisolated struct SourceHistory: Equatable {
    let metric: MetricKey
    /// `Calendar.civil.startOfDay` → that day's `SourceSignature.joined` form. Days whose
    /// provenance is unknown carry `""`.
    let signatures: [Date: String]
}

/// A day on which a metric started being recorded by a different set of sources.
nonisolated struct SourceChange: Equatable {
    let metric: MetricKey
    /// The first day recorded the new way.
    let day: Date
    let before: [String]
    let after: [String]
    /// Consecutive known days immediately before `day` on the old signature, and from `day` onward
    /// on the new one. These are what let an agent tell a settled hardware change (hundreds of days
    /// either side) from a watch left on the charger overnight (one).
    let daysBefore: Int
    let daysAfter: Int

    /// How well-established the change is: the smaller of the two runs. A transition with a year on
    /// one side and a day on the other is a blip whichever side is short.
    var establishedDays: Int {
        min(daysBefore, daysAfter)
    }
}

/// Finds the days a metric changed hands.
///
/// This is the evidence that separates two indistinguishable stories. A new Apple Watch shifts
/// resting heart rate by a few bpm; a new scale reads consistently heavy; replacing a phone changes
/// which device counts steps. Every one of those is a real, sustained, statistically solid level
/// shift — `RegimeShiftScan` fires on them correctly — and every one is about equipment, not the
/// person. Without provenance an investigating agent has no way to even ask, so it writes the only
/// story available: that the user's body changed.
///
/// Deliberately NOT a filter. This scan takes no view on whether any finding should be suppressed;
/// it reports transitions and how long each regime ran, and the agents decide what that means. A
/// device swap that coincides with a genuine change is a real possibility, and a hard rule would
/// silently discard it — which is exactly the deterministic judgment this app puts in the model's
/// hands instead.
nonisolated enum ProvenanceScan {
    static func scan(_ histories: [SourceHistory]) -> [SourceChange] {
        histories.flatMap(changes(in:))
    }

    /// The most recent change to `metric` that falls INSIDE a claim's own comparison window, phrased
    /// for that claim's basis line — or `nil` if the metric never changed hands within it.
    ///
    /// The window is the bound, and it is deliberately not a constant of this file's choosing: it is
    /// the span the claim itself compares over. A record that stands for 90 days is a comparison
    /// against the last 90 days, so a device swap 200 days ago predates everything being compared
    /// and is genuinely irrelevant rather than merely judged unimportant — while one 30 days ago
    /// means the record and the field it beat were measured by different equipment. Same for a
    /// volatility shift and its recent window. Within the window the note states the distance and
    /// says nothing about what it means; that judgment stays with the agent.
    ///
    /// Bounding it this way is also what keeps the note affordable. An unconditional "the source
    /// changed 1,100 days ago" on every row would spend the token budget the whole delivery design
    /// was shaped around, to tell the agent nothing.
    static func noteForClaim(
        metric: MetricKey,
        window: String,
        since: Date,
        now: Date,
        changes: [SourceChange]
    ) -> String? {
        let calendar = Calendar.civil
        let anchor = calendar.startOfDay(for: now)
        let latest = changes
            .filter { $0.metric == metric && $0.day >= since }
            .max { $0.day < $1.day }
        guard let latest else { return nil }
        let ago = calendar.dateComponents([.day], from: latest.day, to: anchor).day ?? 0
        return "what RECORDS this metric changed (\(SourceSignature.describe(latest.before)) → "
            + "\(SourceSignature.describe(latest.after))) \(ago) day\(ago == 1 ? "" : "s") ago, "
            + "inside \(window) — a new device reading differently would look exactly like this"
    }

    /// Transitions within one metric, oldest first.
    static func changes(in history: SourceHistory) -> [SourceChange] {
        // Only days whose provenance is actually known. A stretch ingested before this data was
        // recorded carries "", and treating unknown as a distinct signature would manufacture two
        // spurious changes at the edges of every such stretch — on nothing but our own upgrade.
        let known = history.signatures
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
        guard known.count > 1 else { return [] }

        var out: [SourceChange] = []
        var runStart = 0
        for index in 1..<known.count where known[index].value != known[index - 1].value {
            out.append(SourceChange(
                metric: history.metric,
                day: known[index].key,
                before: SourceSignature.split(known[index - 1].value),
                after: SourceSignature.split(known[index].value),
                daysBefore: index - runStart,
                daysAfter: runLength(from: index, in: known)
            ))
            runStart = index
        }
        return out
    }

    /// How many consecutive known days from `index` share its signature.
    private static func runLength(from index: Int, in known: [(key: Date, value: String)]) -> Int {
        var end = index + 1
        while end < known.count, known[end].value == known[index].value {
            end += 1
        }
        return end - index
    }
}
