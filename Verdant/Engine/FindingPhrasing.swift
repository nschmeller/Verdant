import Foundation

/// The carrier for a finding's display prose — a short `summary` and a tappable `oneTapTitle`. The
/// writer persists it and the summary is embedded for semantic dedup. In production it is filled
/// **only** with safety-vetted, LLM-crafted prose; there is no deterministic template fallback, so
/// no template *generator* lives here. (Tests synthesize a neutral `Phrasing` via a test-only helper.)
nonisolated enum FindingPhrasing {
    nonisolated struct Phrasing: Equatable {
        /// Roughly 150 tokens — five times the two or three sentences the investigator is asked for,
        /// so no prose a model writes in good faith is touched, and matches the 600 the retest
        /// planner already clamps its view of the claim to.
        static let maxSummaryLength = 600

        let summary: String
        let oneTapTitle: String

        /// Clamped here, for exactly the reason `InvestigationFocus` clamps `title` here rather than
        /// at the point of use: it covers every construction site at once and any future one free.
        ///
        /// `summary` is the model-written `story`. This doc used to call it "the last unbounded
        /// model string reaching a prompt", and `oneTapTitle` was sitting one line above it,
        /// unclamped, going into the safety panel as "title\nsummary" — found by reading the
        /// absolute as a specification and checking what it did NOT enumerate. The rephraser can now
        /// write a title too, so both sides of this struct are model output. `persistProposed` builds the
        /// vetting claim as summary + verified basis
        /// and hands it to the skeptic panel, the replication analysts AND the safety panel — three
        /// sessions, so a runaway is paid for three times over. `story` carries a `@Guide` asking for
        /// "two or three sentences", and a guide constrains GENERATION, not what reaches the
        /// function; the same reasoning that made `title` a bug here.
        ///
        /// The failure is not a wrong answer. It is a session killed mid-vetting by a 4,096-token
        /// window, which surfaces as a panel that rendered no verdict — indistinguishable from a
        /// rate limit, and on the replication path (prefix 1,848) there is least room to absorb it.
        ///
        /// Cut on whitespace so a truncated summary ends on a word. It is user-visible prose as well
        /// as prompt text, and this is the one clamp in the app whose output someone reads.
        /// Three times the "3-6 words" the guide asks for, which is the same slack `maxSummaryLength`
        /// gives the summary: no title written in good faith is touched, and a runaway is bounded.
        static let maxTitleLength = 120

        init(summary: String, oneTapTitle: String) {
            self.summary = PromptText.clamped(summary, to: Self.maxSummaryLength)
            self.oneTapTitle = PromptText.clamped(oneTapTitle, to: Self.maxTitleLength)
        }
    }
}
