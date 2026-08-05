import SwiftUI

/// A constellation of the cross-source correlations the app has SURFACED: each metric taking part
/// in one is a node on a ring, and each surfaced link an edge — green when the two signals move
/// together, blue when they move oppositely, weighted by strength.
///
/// Precisely: an edge is an active `CorrelationLog`, meaning a pair an investigator proposed, the
/// safety, skeptic and replication panels all cleared, and the curator kept. It is deliberately NOT
/// "every significant association" — the engine judges far more pairs than reach the feed, and
/// since the FDR significance floor stopped being a drop-gate a surfaced link need not be
/// statistically significant at all; that is a judgment the agents now make with the evidence in
/// front of them. So this maps what the app decided was worth telling, not the full correlation
/// structure of the data.
struct ConnectionMap: View {
    let correlations: [CorrelationLog]

    struct Node: Identifiable {
        let metric: MetricKey
        let index: Int
        let degree: Int
        var id: String {
            metric.rawValue
        }
    }

    struct Edge {
        let a: Int
        let b: Int
        let r: Double
    }

    /// Internal so the two captions below can be checked against it. See
    /// `accessibilityDescription` for why that matters more here than in most views.
    var graph: (nodes: [Node], edges: [Edge]) {
        var indexOf: [MetricKey: Int] = [:]
        var degree: [MetricKey: Int] = [:]
        var order: [MetricKey] = []
        var edges: [Edge] = []
        // ONE edge per unordered metric pair, and the first wins — `correlations` arrives sorted by
        // quality (`TrendsView.ordered`), so the first is the best-scored account of that pair.
        //
        // Two rows for one pair is a deliberate state, not corruption: when the novelty judge rules a
        // candidate a meaningful update on a standing finding, `persistProposed` sets
        // `noveltyLookback = 0` so both persist "until the curator weighs both". Counted twice here,
        // that pair inflated the DEGREE of both its metrics — so `hubCaption` could name the wrong
        // "most connected signal" — drew the line twice, and listed the connection twice in
        // `accessibilityDescription`, with the old and updated coefficients contradicting each other.
        // That last one is the failure this file's own doc says matters most: for a VoiceOver user
        // the sentence IS the picture, and it was describing an edge that does not exist.
        var pairSeen: Set<String> = []
        for correlation in correlations {
            guard let a = correlation.metricAKey, let b = correlation.metricBKey, a != b else { continue }
            let pair = [a.rawValue, b.rawValue].sorted().joined(separator: "|")
            guard pairSeen.insert(pair).inserted else { continue }
            for metric in [a, b] where indexOf[metric] == nil {
                indexOf[metric] = order.count
                order.append(metric)
            }
            degree[a, default: 0] += 1
            degree[b, default: 0] += 1
            if let ia = indexOf[a], let ib = indexOf[b] {
                edges.append(Edge(a: ia, b: ib, r: correlation.coefficient))
            }
        }
        let nodes = order.enumerated().map { Node(metric: $1, index: $0, degree: degree[$1] ?? 1) }
        return (nodes, edges)
    }

    /// A spoken equivalent of the constellation for VoiceOver: every connection in words, with its
    /// sign and strength — the information the Canvas conveys only through color and line weight.
    ///
    /// Internal because this is the ONLY channel by which a VoiceOver user receives the map. A
    /// sighted user who is told the wrong thing can look at the picture; here the sentence IS the
    /// picture. Dropping an edge, or rendering a negative coefficient as "move together", is then a
    /// wrong statement about someone's health data with nothing to contradict it — and it is exactly
    /// the kind of string no test looks at.
    func accessibilityDescription(_ model: (nodes: [Node], edges: [Edge])) -> String {
        guard !model.edges.isEmpty else { return "Connection map (no connections yet)" }
        let connections = model.edges.map { edge -> String in
            let nameA = model.nodes[edge.a].metric.displayName
            let nameB = model.nodes[edge.b].metric.displayName
            let relation = edge.r >= 0 ? "move together" : "move oppositely"
            let strength = CorrelationStrength.word(absoluteCoefficient: abs(edge.r))
            return "\(nameA) and \(nameB) \(relation), \(strength)"
        }
        return "Connection map of \(model.nodes.count) metrics. "
            + connections.joined(separator: ". ") + "."
    }

    /// The most-connected metric, described by how its links split between moving-with and
    /// moving-against it — a read on which signal sits at the center of the user's web.
    func hubCaption(_ model: (nodes: [Node], edges: [Edge])) -> String? {
        guard let hub = model.nodes.max(by: { $0.degree < $1.degree }), hub.degree >= 2 else { return nil }
        let incident = model.edges.filter { $0.a == hub.index || $0.b == hub.index }
        let same = incident.count(where: { $0.r >= 0 })
        let opposite = incident.count - same
        func others(_ count: Int) -> String {
            "\(count) other\(count == 1 ? "" : "s")"
        }
        var parts: [String] = []
        if same > 0 { parts.append("rising and falling with \(others(same))") }
        if opposite > 0 { parts.append("pulling against \(others(opposite))") }
        return "\(hub.metric.displayName) sits at the center of your map — \(parts.joined(separator: ", "))."
    }

    var body: some View {
        let model = graph
        VStack(spacing: 12) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: side / 2)
                let radius = side / 2 - 54
                ZStack {
                    Canvas { context, _ in
                        drawEdges(model, in: &context, center: center, radius: radius)
                        drawNodes(model, in: &context, center: center, radius: radius)
                    }
                    ForEach(model.nodes) { node in
                        Text(node.metric.displayName)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(.secondary)
                            .frame(width: 78)
                            .position(labelPoint(
                                node.index,
                                count: model.nodes.count,
                                center: center,
                                radius: radius
                            ))
                    }
                }
            }
            .frame(height: 280)
            // The graph is drawn in a Canvas, which emits nothing to the accessibility tree — so
            // collapse the map into one element that SPEAKS the connections (which metrics, the sign,
            // the strength), built from the same model the Canvas draws. Without this a VoiceOver user
            // hears a pile of disconnected metric names and a legend describing colors they can't see.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription(model))

            if let caption = hubCaption(model) {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            legend
        }
    }

    // MARK: Drawing

    private func drawEdges(
        _ model: (nodes: [Node], edges: [Edge]),
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat
    ) {
        for edge in model.edges {
            let start = nodePoint(edge.a, count: model.nodes.count, center: center, radius: radius)
            let end = nodePoint(edge.b, count: model.nodes.count, center: center, radius: radius)
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            let strength = min(abs(edge.r), 1)
            let color = edge.r >= 0 ? Theme.brand : Direction.down.tint
            context.stroke(
                path,
                with: .color(color.opacity(0.22 + 0.5 * strength)),
                lineWidth: 1 + strength * 4
            )
        }
    }

    private func drawNodes(
        _ model: (nodes: [Node], edges: [Edge]),
        in context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat
    ) {
        for node in model.nodes {
            let point = nodePoint(node.index, count: model.nodes.count, center: center, radius: radius)
            let dotRadius = 6 + CGFloat(min(node.degree, 4)) * 2.5
            let rect = CGRect(
                x: point.x - dotRadius, y: point.y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )
            context.fill(
                Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                with: .color(Theme.brand.opacity(0.18))
            )
            context.fill(Path(ellipseIn: rect), with: .color(Theme.brand))
        }
    }

    // MARK: Geometry

    private func angle(_ index: Int, count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return -.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(count)
    }

    private func nodePoint(_ index: Int, count: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let theta = angle(index, count: count)
        return CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
    }

    private func labelPoint(_ index: Int, count: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let theta = angle(index, count: count)
        return CGPoint(x: center.x + (radius + 26) * cos(theta), y: center.y + (radius + 26) * sin(theta))
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(color: Theme.brand, text: "Move together")
            legendItem(color: Direction.down.tint, text: "Move oppositely")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 16, height: 3)
            Text(text)
        }
    }
}
