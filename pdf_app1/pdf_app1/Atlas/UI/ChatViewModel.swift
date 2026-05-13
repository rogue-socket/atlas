//
//  ChatViewModel.swift
//  Atlas
//
//  Manages chat state: message history, context building, and AI interaction
//

import Foundation
import Observation
import PDFKit

// MARK: - Chat Message

enum ChatRole: Equatable {
    case user
    case assistant
    case error
}

struct ChatMessage: Identifiable {
    let id: UUID
    let role: ChatRole
    let content: String
    let citations: [AnswerWithCitations.Citation]

    init(id: UUID = UUID(), role: ChatRole, content: String, citations: [AnswerWithCitations.Citation] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.citations = citations
    }
}

// MARK: - Chat View Model

@Observable
@MainActor
class ChatViewModel {
    var messages: [ChatMessage] = []
    var isLoading: Bool = false

    private let backend: any AtlasModel
    private let graph: KnowledgeGraph
    private let documentURL: URL?
    private var pageTexts: [(pageIndex: Int, text: String)] = []

    init(backend: any AtlasModel, graph: KnowledgeGraph, documentURL: URL?) {
        self.backend = backend
        self.graph = graph
        self.documentURL = documentURL
    }

    func send(_ question: String) async {
        let userMessage = ChatMessage(role: .user, content: question)
        messages.append(userMessage)

        isLoading = true
        defer { isLoading = false }

        do {
            let context = buildContext()
            let result = try await backend.answerQuestion(question, context: context)
            let assistantMessage = ChatMessage(
                role: .assistant,
                content: result.answer,
                citations: result.citations
            )
            messages.append(assistantMessage)
        } catch {
            let errorMessage = ChatMessage(role: .error, content: error.localizedDescription)
            messages.append(errorMessage)
        }
    }

    func setPageText(_ pages: [(pageIndex: Int, text: String)]) {
        self.pageTexts = pages
    }

    func resolveCitationAnchor(_ citation: AnswerWithCitations.Citation) -> SourceAnchor? {
        guard let pageIndex = citation.pageIndex else { return nil }
        let candidates = graph.allNodes.flatMap { $0.sourceAnchors }
            .filter { $0.pageIndex == pageIndex }
        let citationText = citation.text.lowercased()
        return candidates.first { anchor in
            anchor.textSnippet.lowercased().contains(citationText)
                || citationText.contains(anchor.textSnippet.lowercased())
        } ?? candidates.first
    }

    func buildContext() -> String {
        var sections: [String] = []

        let nodes = graph.allNodes
        if !nodes.isEmpty {
            var graphLines: [String] = ["## Knowledge Graph"]
            for node in nodes.sorted(by: { $0.label < $1.label }) {
                var line = "- \(node.label) (\(node.type.displayName))"
                if let summary = node.summary {
                    line += ": \(summary)"
                }
                graphLines.append(line)
            }

            let edges = graph.allEdges
            if !edges.isEmpty {
                graphLines.append("")
                graphLines.append("### Relationships")
                for edge in edges {
                    if let source = graph.node(for: edge.sourceNodeID),
                       let target = graph.node(for: edge.targetNodeID) {
                        graphLines.append("- \(source.label) → \(edge.type.displayName) → \(target.label)")
                    }
                }
            }
            sections.append(graphLines.joined(separator: "\n"))
        }

        if !pageTexts.isEmpty {
            var pageLines: [String] = ["## Source Text"]
            for page in pageTexts {
                pageLines.append("--- Page \(page.pageIndex + 1) ---")
                pageLines.append(page.text)
            }
            sections.append(pageLines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }
}
