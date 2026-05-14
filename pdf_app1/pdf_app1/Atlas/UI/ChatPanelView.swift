//
//  ChatPanelView.swift
//  Atlas
//
//  Chat panel for asking questions about extracted concepts with source citations
//

import SwiftUI

struct ChatPanelView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            inputBar
        }
        .frame(minWidth: 250)
        .background(.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.secondary)
            Text("Chat")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
                    ForEach(viewModel.messages) { message in
                        ChatBubbleView(message: message) { citation in
                            guard let pageIndex = citation.pageIndex else { return }
                            let anchor = viewModel.resolveCitationAnchor(citation)
                            NotificationCenter.default.post(
                                name: .navigateToPage,
                                object: pageIndex,
                                userInfo: anchor.map { ["boundingBox": $0.boundingBox] }
                            )
                        }
                        .id(message.id)
                    }
                    if viewModel.isLoading {
                        loadingIndicator
                    }
                }
                .padding(12)
            }
            .onChange(of: viewModel.messages.count) {
                if let lastID = viewModel.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)
            Text("Ask about concepts in this document")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var loadingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .onSubmit {
                    sendMessage()
                }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(inputText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isLoading)
        }
        .padding(12)
    }

    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, !viewModel.isLoading else { return }
        inputText = ""
        Task {
            await viewModel.send(question)
        }
    }
}

// MARK: - Chat Bubble

private struct ChatBubbleView: View {
    let message: ChatMessage
    var onCitationTap: ((AnswerWithCitations.Citation) -> Void)?

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .padding(10)
                .background(backgroundColor)
                .cornerRadius(12)
                .foregroundStyle(message.role == .error ? .red : .primary)

            if !message.citations.isEmpty {
                citationRow
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var backgroundColor: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.15)
        case .assistant: return Color(.controlBackgroundColor)
        case .error: return .red.opacity(0.1)
        }
    }

    private var citationRow: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(message.citations.enumerated()), id: \.offset) { index, citation in
                Button {
                    navigateToCitation(citation)
                } label: {
                    Text(citationLabel(citation, index: index))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help(citation.text)
            }
        }
    }

    private func citationLabel(_ citation: AnswerWithCitations.Citation, index: Int) -> String {
        if let page = citation.pageIndex {
            return "[p.\(page + 1)]"
        }
        return "[Source \(index + 1)]"
    }

    private func navigateToCitation(_ citation: AnswerWithCitations.Citation) {
        onCitationTap?(citation)
    }
}

// MARK: - Flow Layout (for citation chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let position = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }
        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
