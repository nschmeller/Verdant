import Foundation
import SwiftData
import Testing
@testable import Verdant

/// The connection map's two sentences: the VoiceOver description and the hub caption.
///
/// The accessibility string is the one that matters most. For a sighted user the Canvas is the
/// finding and the caption is a summary; for a VoiceOver user the sentence IS the map — there is no
/// picture to contradict it. Dropping an edge, or calling a negative coefficient "move together", is
/// a wrong statement about someone's health data with nothing to check it against, in a string no
/// test ever reads.
/// How the Trends screen orders the connections it shows.
///
/// The ordering lives in `TrendsView` (a SwiftUI view, so it is pinned here as the pure comparison it
/// is). It used to be `abs(coefficient)` — the loudest link first — while the feed, curation and the
/// audit docket all rank by `quality`, which blends the agent's judgment of worth with the
/// statistical trust term. Two screens showing the same findings in different orders, and the one
/// that ignored the agents was the one built on a raw statistic.
///
/// `SalienceSourceTests` states the principle for single-metric findings: a magnitude measures
/// BIGNESS, which usually means obviousness, and leading with it promotes exactly the loud,
/// predictable changes this app exists to filter out.
struct TrendsOrderingTests {
    private func log(quality: Int, coefficient: Double) -> CorrelationLog {
        CorrelationLog(
            createdAt: Date(),
            metricA: MetricKey.stepCount.rawValue,
            metricB: MetricKey.restingHeartRate.rawValue,
            lag: 0,
            pairKey: "restingHeartRate|stepCount",
            coefficient: coefficient,
            sampleCount: 90,
            pValue: 0.01,
            summary: "s",
            oneTapTitle: "t",
            quality: quality,
            jobRunID: UUID()
        )
    }

    /// The judged-better link leads, even when the other one is statistically louder.
    @Test func `a higher-quality connection outranks a louder one`() {
        let subtle = log(quality: 90, coefficient: 0.31)
        let loud = log(quality: 40, coefficient: 0.82)
        let ordered = TrendsView.ordered([loud, subtle])
        #expect(ordered.first?.quality == 90, "the loudest link led instead of the best-judged one")
    }

    /// Magnitude still breaks ties, so equally-judged links order sensibly rather than arbitrarily.
    @Test func `equal quality falls back to magnitude`() {
        let weak = log(quality: 70, coefficient: 0.20)
        let strong = log(quality: 70, coefficient: -0.75)
        let ordered = TrendsView.ordered([weak, strong])
        #expect(ordered.first?.coefficient == -0.75, "a strong inverse link was buried by a weak one")
    }

    /// And the original bug the magnitude sort fixed stays fixed: sign must not decide order.
    @Test func `a strong inverse link is not buried by a weak positive one`() {
        let inverse = log(quality: 50, coefficient: -0.80)
        let positive = log(quality: 50, coefficient: 0.10)
        #expect(TrendsView.ordered([positive, inverse]).first?.coefficient == -0.80)
    }
}

struct ConnectionMapTests {
    private func log(_ a: MetricKey, _ b: MetricKey, r: Double) -> CorrelationLog {
        CorrelationLog(
            createdAt: Date(),
            metricA: a.rawValue,
            metricB: b.rawValue,
            lag: 0,
            pairKey: [a.rawValue, b.rawValue].sorted().joined(separator: "|"),
            coefficient: r,
            sampleCount: 40,
            pValue: 0.01,
            summary: "s",
            oneTapTitle: "t",
            quality: 70,
            jobRunID: UUID()
        )
    }

    /// A pair can legitimately appear TWICE in the persisted findings: when the novelty judge rules a
    /// candidate a meaningful update on a standing finding, `persistProposed` sets
    /// `noveltyLookback = 0` so both rows survive "until the curator weighs both". The map counted
    /// both.
    ///
    /// Three things went wrong at once, and the third is the one this file's own doc calls the
    /// failure it exists to prevent. Degree was inflated for both metrics, so `hubCaption` could name
    /// the wrong "most connected signal". The line was drawn twice. And `accessibilityDescription` —
    /// the ONLY channel by which a VoiceOver user receives this map — spoke the connection twice,
    /// with the standing coefficient and the updated one contradicting each other.
    @Test func `a pair persisted twice is one edge, not two`() {
        let map = ConnectionMap(correlations: [
            log(.stepCount, .restingHeartRate, r: 0.61), // the update, ranked first by quality
            log(.restingHeartRate, .stepCount, r: 0.44) // the standing finding, reversed order
        ])
        let graph = map.graph
        #expect(graph.edges.count == 1, "the same pair was drawn \(graph.edges.count) times")
        #expect(graph.nodes.count == 2)
        // Degree is per pair, not per row — otherwise the hub caption ranks on how often a finding
        // was re-proposed rather than on how connected the metric is.
        #expect(graph.nodes.allSatisfy { $0.degree == 1 }, "degree counted the duplicate row")
        // The better-scored row wins, since the caller sorts by quality.
        #expect(graph.edges.first?.r == 0.61)
        // And it is spoken once.
        let spoken = map.accessibilityDescription(graph)
        let mentions = spoken.components(separatedBy: MetricKey.stepCount.displayName).count - 1
        #expect(mentions == 1, Comment(rawValue: "spoken \(mentions) times: \(spoken)"))
    }

    /// Non-vacuity: distinct pairs are still distinct edges, so the de-duplication is by PAIR and not
    /// something coarser that would collapse the whole map to one line.
    @Test func `distinct pairs remain distinct edges`() {
        let graph = ConnectionMap(correlations: [
            log(.stepCount, .restingHeartRate, r: 0.61),
            log(.stepCount, .sleepDurationHours, r: 0.35)
        ]).graph
        #expect(graph.edges.count == 2)
        #expect(graph.nodes.count == 3)
        #expect(graph.nodes.first { $0.metric == .stepCount }?.degree == 2, "the hub lost a connection")
    }

    @Test func `every surfaced link is spoken, with its direction`() {
        let map = ConnectionMap(correlations: [
            log(.stepCount, .restingHeartRate, r: 0.7),
            log(.stepCount, .sleepDurationHours, r: -0.6)
        ])
        let spoken = map.accessibilityDescription(map.graph)

        // Both metrics of both links are named — an edge silently dropped is the failure here.
        for metric in [MetricKey.stepCount, .restingHeartRate, .sleepDurationHours] {
            #expect(spoken.contains(metric.displayName), "\(metric.displayName) is not spoken")
        }
        // And the SIGNS are not swapped.
        #expect(spoken.contains("move together"))
        #expect(spoken.contains("move oppositely"))
        #expect(spoken.contains("Connection map of 3 metrics"))
    }

    /// A negative link must never be described as moving together. This is the single most damaging
    /// thing this string can get wrong.
    @Test func `a negative link is never described as moving together`() {
        let map = ConnectionMap(correlations: [log(.stepCount, .restingHeartRate, r: -0.8)])
        let spoken = map.accessibilityDescription(map.graph)
        #expect(spoken.contains("move oppositely"))
        #expect(!spoken.contains("move together"))
    }

    @Test func `an empty map says so rather than describing nothing`() {
        let map = ConnectionMap(correlations: [])
        #expect(map.accessibilityDescription(map.graph) == "Connection map (no connections yet)")
        #expect(map.hubCaption(map.graph) == nil)
    }

    /// The hub caption names the most-connected metric and splits its links by direction.
    @Test func `the hub is the most connected metric, split by direction`() throws {
        let map = ConnectionMap(correlations: [
            log(.stepCount, .restingHeartRate, r: 0.7),
            log(.stepCount, .sleepDurationHours, r: 0.5),
            log(.stepCount, .bodyMass, r: -0.4)
        ])
        let caption = try #require(map.hubCaption(map.graph))
        #expect(caption.contains(MetricKey.stepCount.displayName), "wrong hub: \(caption)")
        #expect(caption.contains("2 others"), "same-direction count wrong: \(caption)")
        #expect(caption.contains("1 other"), "opposite-direction count wrong: \(caption)")
    }

    /// One link is not a web — a "centre" of two nodes would overstate the picture.
    @Test func `a single link has no hub`() {
        let map = ConnectionMap(correlations: [log(.stepCount, .restingHeartRate, r: 0.7)])
        #expect(map.hubCaption(map.graph) == nil)
    }
}
