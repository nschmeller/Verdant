import SwiftUI

private struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

/// Foreground Q&A. There is no Router — that chain was removed in the agent inversion. Each question
/// runs two fresh sessions: a gather pass that MEASURES with the tool surface, then an answerer that
/// starts on a clean window already holding those readings.
///
/// A hard-clamped TAIL of the transcript is replayed into both — the last two completed exchanges,
/// 220 characters a side (`ConversationTurn`). Nothing was replayed at all until 2026-08-02, which
/// kept the 4k window at arm's length and meant this screen rendered a conversation while the model
/// answered a series of unrelated questions: "How have my steps been?" followed by "Why?" sent the
/// agent the bare word "Why?". The clamp keeps the window protection — the replay is bounded and
/// cannot grow with the conversation — while giving a follow-up its referent.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var messages: [ChatMessage] = []
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                inputBar
            }
            .navigationTitle("Ask")
            .safeAreaInset(edge: .bottom) { DisclaimerBar() }
        }
        // A question staged from elsewhere (a finding's "Ask about this") sends itself on arrival —
        // both when the tab appears with one already staged and when it's staged while visible.
        .onAppear { consumePendingQuestion() }
        .onChange(of: model.pendingQuestion) { _, _ in consumePendingQuestion() }
    }

    private func consumePendingQuestion() {
        guard let staged = model.pendingQuestion, !sending else { return }
        model.pendingQuestion = nil
        input = staged
        send()
    }

    @ViewBuilder
    private var transcript: some View {
        if messages.isEmpty {
            ContentUnavailableView {
                Label("Ask anything about your health data", systemImage: "text.bubble")
            } description: {
                // The examples steer what people ask, so they should point at questions the data can
                // actually answer well. A sleep→next-day prompt used to lead here — the single worst
                // choice while sleep is bucketed by a fixed UTC day, which puts the boundary at some
                // local hour that varies by time zone — so one night may land wholly on the wake
                // day, wholly on the sleep-onset day, or be split (see `CivilCalendar` and the
                // corrected caveat in `Instructions.investigationLenses`). Restore it once settled.
                Text(
                    "e.g. \u{201C}What moves together with my resting heart rate?\u{201D} or "
                        + "\u{201C}Has my walking pace drifted over the past two years?\u{201D} — an "
                        + "agent digs through your real numbers to answer."
                )
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { bubble($0) }
                    if sending { thinkingRow }
                }
                .padding(.vertical)
            }
        }
    }

    /// What the agent is doing RIGHT NOW, not a bare spinner: an answer costs two model passes and a
    /// five-reviewer safety panel, and the app's whole promise is that you can watch it reason. The
    /// text is the reporter's real activity line — the same feed the research program narrates into
    /// — so it never claims a step that isn't happening.
    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(model.askProgress?.activity ?? "Thinking…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .animation(.smooth, value: model.askProgress?.activity)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.text)
                .foregroundStyle(isUser ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isUser ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.brandSoft),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about your health data…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            .accessibilityLabel("Send") // icon-only control — VoiceOver would otherwise read the symbol name
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// The exchanges that have both a question and an answer. The in-flight question is deliberately
    /// excluded — it is passed as the question, and repeating it as context would have the agent
    /// answer it twice over.
    private var completedTurns: [ConversationTurn] {
        var turns: [ConversationTurn] = []
        var asked: String?
        for message in messages {
            switch message.role {
            case .user:
                asked = message.text
            case .assistant:
                if let asked { turns.append(ConversationTurn(question: asked, answer: message.text)) }
                asked = nil
            }
        }
        return turns
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !sending else { return }
        input = ""
        // Captured BEFORE the new question joins the transcript.
        let history = completedTurns
        messages.append(ChatMessage(role: .user, text: question))
        sending = true
        Task {
            let answer = await model.ask(question, history: history)
            messages.append(ChatMessage(role: .assistant, text: answer))
            sending = false
        }
    }
}
