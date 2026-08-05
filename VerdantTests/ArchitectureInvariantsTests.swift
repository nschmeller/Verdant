import Foundation
import Testing
@testable import Verdant

/// Invariants that `README.md` and `docs/ARCHITECTURE.md` state as load-bearing, pinned so the
/// prose cannot quietly stop being true. Both documents spent weeks describing a pipeline that had
/// already been deleted and nothing failed — these are the claims worth more than a sentence.
struct ArchitectureInvariantsTests {
    /// **"The Orchestrator owns no `LanguageModelSession`."** This is how the app survives a
    /// 4,096-token window: every session is an ephemeral leaf, created for one job inside a
    /// `Subagents` call and discarded, so no transcript ever accumulates across the fleet. A session
    /// held anywhere longer-lived — on the orchestrator, in a view model, cached for reuse — would
    /// reintroduce exactly the growing transcript the design exists to avoid, and would fail slowly
    /// and confusingly (context overflows deep into a run) rather than loudly.
    ///
    /// Confining construction to one file is the mechanical form of that promise.
    @Test func `every language model session is built in one place`() throws {
        let sources = try SourceScan.swiftSources()
        let builders = sources
            .filter { SourceScan.code($0.text).contains("LanguageModelSession(") }
            .map(\.path)
            .sorted()
        #expect(builders == ["Subagents.swift"], "sessions built outside Subagents: \(builders)")
    }

    /// **"No deterministic findings, and no template fallback."** Every word shown to a user is
    /// model-written and safety-vetted; when the model cannot make something of a candidate the
    /// candidate is dropped, never rendered from a template. `FindingPhrasing` is therefore a
    /// carrier only — the moment it grows a generator, the app can silently start showing prose no
    /// agent wrote and no safety panel saw, which is the failure this promise exists to prevent.
    /// (Tests synthesize a neutral `Phrasing` through a test-target-only helper.)
    /// The check is "cannot manufacture prose", not "has no functions". It was the latter, and that
    /// blocked the clamp `Phrasing` needed: `summary` is the model-written `story`, the last
    /// unbounded model string reaching a prompt, and bounding it takes an initializer. A truncating
    /// init cannot show a user a word no agent wrote — it can only remove words — so banning `func`
    /// outright was stricter than the promise and stricter in the wrong direction.
    ///
    /// What actually distinguishes a generator is that it RETURNS a `Phrasing`, and that it carries
    /// the prose to put in one. Both are checked; a literal long enough to be a sentence fails even
    /// if it is returned some other way.
    @Test func `finding prose has no production template generator`() throws {
        let sources = try SourceScan.swiftSources()
        let phrasing = try #require(sources.first { $0.path == "FindingPhrasing.swift" })
        let body = SourceScan.code(phrasing.text)
        #expect(!body.contains("-> Phrasing"), "FindingPhrasing gained a generator")
        // No string literal long enough to be prose. Comments are already stripped, so the doc
        // comments explaining all this are not scanned.
        let literals = body.components(separatedBy: "\"")
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map(\.element)
        for literal in literals where literal.count > 24 {
            Issue.record("FindingPhrasing carries prose: “\(literal)”")
        }
        // It is still the type the writer persists, so this isn't passing on an empty file.
        #expect(body.contains("struct Phrasing"))
    }

    /// **"Informational and wellness only — not medical advice, diagnosis, or treatment."** The
    /// app's regulatory posture, and the one line that must accompany anything a user could read as
    /// a health judgment. Every screen that shows a finding, a trend, or an agent's answer carries
    /// `DisclaimerBar`; a new screen — or a refactor of an existing one — could drop it in silence,
    /// and nothing else would notice.
    ///
    /// `SettingsView` is deliberately absent from this list: it shows configuration and diagnostics
    /// (permissions, tracked metrics, the compute meter), never an interpretation of the user's
    /// health. If it ever grows one, it belongs here.
    @Test func `every screen that interprets health data carries the disclaimer`() throws {
        let sources = try SourceScan.swiftSources()
        // DERIVED, not listed. The screens are whatever `RootView` puts in its TabView plus whatever
        // a NavigationLink pushes — so a new tab or a new pushed destination is in scope the moment
        // it is written, and has to be either given the disclaimer or exempted here on purpose.
        var screens: Set<String> = []
        let root = try #require(sources.first { $0.path == "RootView.swift" })
        for match in SourceScan.code(root.text).components(separatedBy: "\n") {
            let trimmed = match.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("View()"), let name = trimmed.split(separator: "(").first {
                screens.insert(String(name))
            }
        }
        for source in sources {
            let code = SourceScan.code(source.text)
            var searched = code[...]
            while let hit = searched.range(of: "NavigationLink {") {
                let body = searched[hit.upperBound...].prefix(200)
                for line in body.components(separatedBy: "\n").prefix(3) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard let name = trimmed.split(separator: "(").first, name.hasSuffix("View")
                    else { continue }
                    screens.insert(String(name))
                }
                searched = searched[hit.upperBound...]
            }
        }
        // Positive control: the derivation found the screens it must have, or the sweep below is
        // asserting nothing about a set it failed to build.
        for known in [
            "InsightFeedView",
            "TrendsView",
            "ChatView",
            "FindingDetailView"
        ] {
            #expect(screens.contains(known), "the screen derivation missed \(known)")
        }

        // `SettingsView` shows configuration and diagnostics — permissions, tracked metrics, the
        // compute meter — and never an interpretation of the user's health. It is exempt BY NAME so
        // that exempting a screen is a visible act, and if it ever grows an interpretation the line
        // to delete is right here.
        let exempt: Set = ["SettingsView"]
        for name in screens.subtracting(exempt).sorted() {
            // Located by DECLARATION, not by filename. `ConnectionMapView` would live in
            // `ConnectionMap.swift`, and assuming the two match made a genuine failure report "the
            // file is missing" rather than "the screen has no disclaimer" — and would have skipped
            // the check silently had the lookup been optional rather than required.
            let screen = try #require(
                sources.first { SourceScan.code($0.text).contains("struct \(name): View") },
                "no file declares the screen \(name)"
            )
            #expect(
                SourceScan.code(screen.text).contains("DisclaimerBar()"),
                "\(name) is a screen and does not show the wellness disclaimer"
            )
        }
    }

    /// The sweep must actually read the app. A silent miss would make every check above vacuous, so
    /// this asserts the scanner found the tree and a file it knows must be in it.
    /// Day attribution must ALWAYS go through `Calendar.civil`, which is pinned to UTC.
    ///
    /// This is the app's most load-bearing data invariant and the least visible one. `startOfDay` on
    /// a LOCAL calendar returns an instant that moves when the user travels, so the same physical day
    /// re-keys to a second `MetricRollup` row and every statistic downstream double-counts it — a
    /// wrong number behind every finding, with nothing failing. It is invisible in this suite too:
    /// CI runs in UTC, where local and civil agree exactly, so no ordinary test can catch it. A
    /// source scan can.
    ///
    /// `Calendar.current` itself is legitimate for the wall-clock freshness cutoffs (novelty,
    /// tombstones) that compare timestamps without attributing a day, which is why the rule targets
    /// day ATTRIBUTION specifically rather than banning the calendar outright. Constructing a
    /// `Calendar` anywhere but `CivilCalendar` is banned as well: a fresh one carries the device's
    /// time zone, which is the same bug wearing different clothes.
    @Test func `day attribution never uses the device calendar`() throws {
        var offenders: [String] = []
        for file in try SourceScan.swiftSources() {
            let code = SourceScan.code(file.text)
            for line in code.split(separator: "\n") {
                // `startOfDay` is the operation that re-keys a day, but it is not the only one that
                // attributes. `component(.month, from:)` reads the month a moment falls in and
                // `isDateInWeekend` reads which day of the week it is — both in the DEVICE zone, so
                // both slip a boundary west of UTC exactly as `startOfDay` does. Neither is used
                // today; they are named because the rule is "no attribution on the device calendar",
                // and a rule that lists only the one operation that has already gone wrong invites
                // the next one in. (`dateComponents(from:to:)` is deliberately absent: with two
                // dates it measures a DIFFERENCE, which is what the freshness cutoffs legitimately
                // do.)
                let localAttribution = [
                    "Calendar.current.startOfDay",
                    "Calendar.autoupdatingCurrent.startOfDay",
                    "Calendar.current.component(",
                    "Calendar.autoupdatingCurrent.component(",
                    "Calendar.current.isDateInWeekend",
                    "Calendar.autoupdatingCurrent.isDateInWeekend"
                ]
                if let hit = localAttribution.first(where: { line.contains($0) }) {
                    offenders
                        .append(
                            "\(file.path): local \(hit) — \(line.trimmingCharacters(in: .whitespaces))"
                        )
                }
                // `Date.formatted(date:...)` renders in the DEVICE time zone, so a UTC-keyed day
                // slips to the previous date west of UTC — and in the device locale, whose digits
                // `NumericFidelity` then scrapes as "verified" numbers. Agent-facing code uses
                // `Calendar.civilDayLabel`; the UI may of course show the user their own format.
                if line.contains(".formatted(date:"), !file.path.hasPrefix("Charts"),
                   file.path != "Components.swift", file.path != "FindingDetailView.swift"
                {
                    offenders
                        .append(
                            "\(file.path): device-formatted date — \(line.trimmingCharacters(in: .whitespaces))"
                        )
                }
                if line.contains("Calendar(identifier:"), file.path != "CivilCalendar.swift" {
                    offenders
                        .append(
                            "\(file.path): built its own Calendar — \(line.trimmingCharacters(in: .whitespaces))"
                        )
                }
            }
        }
        let report = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty, "day attribution outside Calendar.civil:\n\(report)")
    }

    /// And the civil calendar really is UTC — the property every day key depends on. Asserted rather
    /// than assumed, because the whole scan above is pointless if this ever changes.
    @Test func `the civil calendar is pinned to UTC`() {
        #expect(Calendar.civil.timeZone.secondsFromGMT() == 0)
        #expect(Calendar.civil.identifier == .gregorian)
    }

    /// The complement to the ban above, and the reason it is needed: that check names SIX specific
    /// operations, and a rule expressed as a list of forbidden calls only refuses what someone
    /// thought of. `Calendar.current.ordinality(of: .day, in: .year, for:)` attributes a moment to a
    /// day-of-year and is not on it — `SeasonalityScan` uses exactly that call, correctly, on
    /// `Calendar.civil`, and nothing would have stopped it being written against the device calendar
    /// instead. So do `dateInterval(of:for:)` and `isDate(_:inSameDayAs:)`.
    ///
    /// Inverted: `Calendar.current` may be used for DURATION arithmetic and nothing else. Two members
    /// are permitted — `date(byAdding:)` for the freshness cutoffs and `dateComponents(from:to:)` for
    /// an elapsed-day count — and every other member of `Calendar` attributes, whether or not anyone
    /// has named it. That is the rule the sibling test's own doc states in prose ("no attribution on
    /// the device calendar"); this is it as a check.
    @Test func `the device calendar is used only for duration arithmetic`() throws {
        let permitted: Set = ["date", "dateComponents"]
        var offenders: [String] = []
        for file in try SourceScan.swiftSources() {
            let code = SourceScan.code(file.text)
            for base in ["Calendar.current.", "Calendar.autoupdatingCurrent."] {
                var searched = code[...]
                while let hit = searched.range(of: base) {
                    let member = searched[hit.upperBound...].prefix { $0.isLetter || $0.isNumber }
                    if !permitted.contains(String(member)) {
                        offenders.append("\(file.path): \(base)\(member)")
                    }
                    searched = searched[hit.upperBound...]
                }
            }
        }
        #expect(
            offenders.isEmpty,
            Comment(rawValue: """
            the device calendar is attributing, not measuring: \(offenders.joined(separator: ", ")). \
            Use `Calendar.civil` for anything that decides WHICH day a moment belongs to.
            """)
        )
        // Positive control: the permitted uses really are there, so an empty offender list means the
        // scan ran rather than that it matched nothing.
        let all = try SourceScan.swiftSources().map { SourceScan.code($0.text) }
        #expect(
            all.contains { $0.contains("Calendar.current.date(byAdding:") },
            "the scan found no legitimate Calendar.current use — it is reading nothing"
        )
    }

    /// Locale-aware number formatting belongs on the SCREEN and nowhere else.
    ///
    /// `MetricFormatting.formatted`/`number` group thousands through a `NumberFormatter` that
    /// follows `Locale.current`. In an agent-facing string that is a defect, not a nicety: a German
    /// device turns 8400 into "8.400", which the model reads as 8.4 and `NumericFidelity` reparses
    /// POSIX-style into the same wrong value; a French one produces a narrow no-break space that
    /// splits the token in two. Agent-facing code uses `canonical`/`canonicalNumber`, which never
    /// group and always use a POSIX point.
    ///
    /// Like the UTC calendar rule, this cannot be caught by running the suite — CI is en_US, where
    /// the grouped form is exactly what everything downstream assumes. A source scan can.
    @Test func `only the UI formats numbers for a locale`() throws {
        let offenders = try SourceScan.swiftSources()
            .filter { file in
                let code = SourceScan.code(file.text)
                return code.contains("MetricFormatting.formatted")
                    || code.contains("MetricFormatting.number(")
            }
            .map(\.path)
            // Allowed because they are the screen. By NAME rather than by directory only because
            // `swiftSources` hands back `lastPathComponent` — a third tuple element for the
            // directory would trip the `large_tuple` limit, and a named struct would touch every
            // scanning suite. The cost of that shortcut is this list: forgetting to add a new UI
            // file here fails the build, which is the safe direction for a rule about what reaches
            // the model.
            .filter { !["Charts.swift", "Components.swift", "FindingCardLine.swift"].contains($0) }
        #expect(
            offenders.isEmpty,
            "locale-aware formatting outside the UI (use canonical): \(offenders.joined(separator: ", "))"
        )
    }

    /// Every persist route must pass the arguments its writer defaults.
    ///
    /// "Every finding records its own provenance — which lens proposed it, what each panel tallied,
    /// and a panelist's own words" is a promise the detail screen keeps to the user, and it is how a
    /// finding can be audited at all. The `append*IfNovel` writers take `provenance` with a DEFAULT
    /// of `""`, so omitting it is silent: no compiler error, no test failure, just a finding that
    /// quietly cannot say where it came from. The default exists so the many tests that construct
    /// findings directly need not care — which is reasonable, and is exactly what makes a scan the
    /// right enforcement here rather than removing it.
    ///
    /// Only ONE behavioural test reads provenance, and it exercises the trend route. There are six.
    /// The same reasoning covers `embedding`, `within` and `now`, which are defaulted for the same
    /// convenience and lose something different when dropped.
    @Test func `every persist route passes the arguments its writer defaults`() throws {
        let sources = try SourceScan.swiftSources()
        let persist = try #require(sources.first { $0.path == "Orchestrator+Persist.swift" })
        let text = SourceScan.code(persist.text)

        var offenders: [String] = []
        var searched = text[...]
        var callSites = 0
        while let hit = searched.range(of: "IfNovel(") {
            callSites += 1
            // The call spans several lines; look as far as its closing `)` at statement indentation.
            let tail = searched[hit.upperBound...]
            let call = SourceScan.callBody(in: searched, from: hit.upperBound)
            // All four, not just provenance. Each is defaulted on the writer, so each is silent when
            // omitted, and each loses something different: `embedding` makes a finding invisible to
            // semantic search and to novelty-by-similarity; `within` swaps the run's novelty
            // lookback for a hardcoded 14 days; `now` swaps the run's anchor for the wall clock,
            // which is how a pass and its own persisted rows come to disagree about what day it is.
            for required in ["provenance:", "embedding:", "within:", "now:"] {
                guard !call.contains(required) else { continue }
                let name = searched[..<hit.lowerBound].suffix(24)
                offenders.append("…\(name)IfNovel( — no \(required)")
            }
            searched = tail
        }
        #expect(callSites >= 6, "found only \(callSites) persist routes — the scan missed some")
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }

    /// The run's anchor must reach every journal write.
    ///
    /// `recordJournal` defaults `now` to the wall clock. An agent pass carries its own `ctx.now` —
    /// injected in tests, and in production the instant the pass began rather than the instant a
    /// particular write happens to land. Omitting it is silent and the damage is subtle: journal
    /// entries drift out of step with the run that produced them, so `journalSteering`'s "within the
    /// last N days" window can include or exclude an entry the run itself would place differently.
    /// Four call sites today, one of them added in this session; all four pass it.
    @Test func `every journal write carries the run's own clock`() throws {
        var offenders: [String] = []
        var callSites = 0
        for file in try SourceScan.swiftSources() {
            for call in SourceScan.callSites(of: "recordJournal", in: SourceScan.code(file.text)) {
                callSites += 1
                if !call.contains("now:") {
                    offenders.append("\(file.path): recordJournal without now:")
                }
            }
        }
        #expect(callSites >= 4, "found only \(callSites) journal writes — the scan missed some")
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }

    /// Every production `DiscoveryContext` must state `adversarial` explicitly.
    ///
    /// This is the highest-stakes default in the codebase. `adversarial` gates BOTH verification
    /// panels — `survivesScrutiny` and `survivesReplication` each open with
    /// `guard ctx.adversarial else { return .notConvened }` — and it defaults to `false`. The flag
    /// exists so tests can isolate the rest of the pipeline; no production path turns it off. But the
    /// default points the wrong way for safety: a new context that simply forgets it would surface
    /// findings to the user that no skeptic and no replication analyst ever saw, and nothing would
    /// fail, because "not convened" is a legitimate state the panels report calmly.
    ///
    /// Defaulting it to `true` would fail safe, but would silently switch on panels in every test
    /// that relies on the current default — a large, quiet behaviour change. Requiring the argument
    /// at the two production call sites gets the same protection without touching test semantics.
    @Test func `every production discovery context states whether it is adversarial`() throws {
        var offenders: [String] = []
        var callSites = 0
        for file in try SourceScan.swiftSources() {
            var searched = SourceScan.code(file.text)[...]
            while let hit = searched.range(of: "DiscoveryContext(") {
                callSites += 1
                let tail = searched[hit.upperBound...]
                let call = SourceScan.callBody(in: searched, from: hit.upperBound)
                if !call.contains("adversarial:") {
                    offenders.append("\(file.path): DiscoveryContext without adversarial:")
                }
                searched = tail
            }
        }
        #expect(callSites >= 2, "found only \(callSites) contexts — the scan missed some")
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }

    /// The deletion-blind range query may only serve spans where no stale rollup can pre-exist.
    ///
    /// `dailyValuesRange` fetches a whole date range in ONE HealthKit query — the thing that makes
    /// multi-year backfill affordable — but it is deletion-blind: "empty day → no row" cannot REMOVE
    /// a stale rollup the way the per-day path's `DayDeletion` does. Its own doc states the
    /// invariant: only the first ingest (no rollups yet) and history deepening (strictly older than
    /// any rollup) may use it, and the deletion-triggered window recompute must stay per-day.
    ///
    /// Breaking it is tempting, because the range query is much faster than the per-day loop the
    /// recompute uses. The consequence is not a crash: a sample the user DELETES from Apple Health
    /// leaves its rollup behind, and Verdant keeps analysing and reporting data the user removed.
    ///
    /// Enforced as a tripwire rather than behaviourally: `Ingestor` holds a concrete `HealthStore`,
    /// so there is no seam to fake HealthKit deletions through without putting it behind a protocol.
    /// A third call site fails here and sends the reader to the invariant.
    @Test func `the deletion-blind range query gains no new callers`() throws {
        var sites: [String] = []
        var perDayPathPresent = false
        for file in try SourceScan.swiftSources() {
            let code = SourceScan.code(file.text)
            for _ in SourceScan.callSites(of: "dailyValuesRange", in: code) {
                sites.append(file.path)
            }
            if code.contains("dailyValues(for:") || code.contains("dailyValues(") {
                perDayPathPresent = perDayPathPresent || file.path == "Ingestor.swift"
            }
        }
        #expect(
            sites.sorted() == ["Ingestor.swift", "Ingestor.swift"],
            """
            `dailyValuesRange` call sites changed (\(sites.sorted())). It is DELETION-BLIND: it may \
            only serve the first ingest and history deepening, never the deletion-triggered \
            recompute, or a sample deleted from Apple Health keeps its rollup and goes on being \
            analysed. See the invariant on `dailyValuesRange`.
            """
        )
        #expect(perDayPathPresent, "the per-day path vanished from Ingestor — what recomputes now?")
    }

    @Test func `the source scan reaches the real app target`() throws {
        let sources = try SourceScan.swiftSources()
        #expect(sources.contains { $0.path == "Orchestrator.swift" })
        #expect(sources.contains { $0.path == "Subagents.swift" })
    }
}

/// The invariants above are SOURCE SCANS, and a scan is the right tool for asserting an ABSENCE — no
/// networking API, no `LanguageModelSession` outside one file, no device calendar in day attribution.
/// It is the wrong tool for asserting that something is DONE, because it cannot tell a wired-up call
/// from an orphaned one, nor a correct argument from a plausible-looking wrong one. Two privacy
/// invariants failed that way on 2026-08-03: one asserted `isExcludedFromBackup = true` appears in a
/// file, and one passed while a production configuration carried the SwiftData CloudKit default.
///
/// This suite is the behavioural half for the claims that admit one.
struct InvariantBehaviourTests {
    /// `every journal write carries the run's own clock` can only see that `now:` was PASSED. A call
    /// site passing `now: Date()` satisfies it and is exactly the bug — the journal is what steers
    /// the next run, and a row stamped with the wall clock inside a run reasoning about a different
    /// `now` puts a dead end in the wrong day's window.
    @Test func `journal rows are stamped with the run's clock, not the wall clock`() async throws {
        let container = try TestSupport.inMemoryContainer()
        let writer = StoreWriter(modelContainer: container)
        // Far enough back that a wall-clock stamp cannot be mistaken for it.
        let runClock = Date().addingTimeInterval(-400 * 86400)
        try await TestSupport.seed(writer, metric: .stepCount, value: 9000, daysAgo: 1...60, now: runClock)
        var fake = FakeSubagents()
        fake.proposals = [ProposedFinding(
            kind: InsightKind.trend.rawValue, metric: MetricKey.stepCount.rawValue,
            secondaryMetric: MetricKey.stepCount.rawValue,
            comparison: ComparisonKey.recentVsBaseline.rawValue,
            title: "Steps Up", story: "Your steps rose.", worth: 80
        )]
        // Refused, so the run writes a rejection to the journal — the write under test.
        fake.safetyIsSafe = false
        _ = await Orchestrator(
            provider: MetricStatsProvider(modelContainer: container), writer: writer,
            embeddings: Embeddings(), subagents: fake, capability: { .available }
        ).runDiscovery(now: runClock)

        let stamps = try await writer.journalStampsForTest()
        // Non-vacuity: the run must actually have written something, or this asserts over nothing.
        #expect(!stamps.isEmpty, "no journal rows were written — the fixture does not exercise the write")
        for stamp in stamps {
            #expect(
                abs(stamp.timeIntervalSince(runClock)) < 60,
                Comment(rawValue: "a journal row is stamped \(stamp) but the run's clock was \(runClock)"
                    + " — it took the wall clock, which the source scan cannot see")
            )
        }
    }
}
