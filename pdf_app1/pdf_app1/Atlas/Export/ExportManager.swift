//
//  ExportManager.swift
//  Atlas
//
//  Export knowledge graph to Markdown (Obsidian vault format), plain Markdown, JSON
//

import Foundation
import UniformTypeIdentifiers

class ExportManager {

    enum ExportFormat {
        case obsidian
        case markdown
        case json

        var fileExtension: String {
            switch self {
            case .obsidian, .markdown: return "md"
            case .json: return "json"
            }
        }

        var contentType: UTType {
            switch self {
            case .obsidian, .markdown: return .plainText
            case .json: return .json
            }
        }
    }

    // MARK: - Export

    func export(graph: KnowledgeGraph, format: ExportFormat, projectName: String = "Atlas Export") -> String {
        switch format {
        case .obsidian:
            return exportObsidian(graph: graph, projectName: projectName)
        case .markdown:
            return exportMarkdown(graph: graph, projectName: projectName)
        case .json:
            return exportJSON(graph: graph)
        }
    }

    /// Export as a single Markdown file
    func exportToFile(graph: KnowledgeGraph, format: ExportFormat, projectName: String = "Atlas Export") -> URL? {
        let content = export(graph: graph, format: format, projectName: projectName)

        let fileName: String
        switch format {
        case .obsidian, .markdown, .json:
            fileName = "\(projectName).\(format.fileExtension)"
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            print("ExportManager: Failed to write export: \(error)")
            return nil
        }
    }

    // MARK: - Obsidian Format (with wikilinks)

    private func exportObsidian(graph: KnowledgeGraph, projectName: String) -> String {
        var lines: [String] = []
        lines.append("# \(projectName)")
        lines.append("")

        // Group nodes by type
        let grouped = Dictionary(grouping: graph.allNodes, by: { $0.type })

        for (type, nodes) in grouped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            lines.append("## \(type.displayName)s")
            lines.append("")

            for node in nodes.sorted(by: { $0.label < $1.label }) {
                lines.append("### \(node.label)")

                if let summary = node.summary {
                    lines.append(summary)
                }

                // Connections as wikilinks
                let edges = graph.edges(for: node.id)
                if !edges.isEmpty {
                    lines.append("")
                    lines.append("**Connections:**")
                    for edge in edges {
                        let otherID = edge.sourceNodeID == node.id ? edge.targetNodeID : edge.sourceNodeID
                        if let otherNode = graph.node(for: otherID) {
                            lines.append("- \(edge.type.displayName): [[\(otherNode.label)]]")
                        }
                    }
                }

                // Source references
                if !node.sourceAnchors.isEmpty {
                    lines.append("")
                    lines.append("**Sources:**")
                    for anchor in node.sourceAnchors {
                        lines.append("- \(anchor.documentURL.lastPathComponent), page \(anchor.pageIndex + 1)")
                    }
                }

                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Plain Markdown

    private func exportMarkdown(graph: KnowledgeGraph, projectName: String) -> String {
        var lines: [String] = []
        lines.append("# \(projectName) — Knowledge Map")
        lines.append("")
        lines.append("**\(graph.nodeCount) concepts, \(graph.edgeCount) connections**")
        lines.append("")

        for node in graph.allNodes.sorted(by: { $0.label < $1.label }) {
            lines.append("## \(node.label)")
            lines.append("*Type: \(node.type.displayName) | Confidence: \(Int(node.confidence * 100))%*")

            if let summary = node.summary {
                lines.append("")
                lines.append(summary)
            }

            let edges = graph.edges(for: node.id)
            if !edges.isEmpty {
                lines.append("")
                for edge in edges {
                    let otherID = edge.sourceNodeID == node.id ? edge.targetNodeID : edge.sourceNodeID
                    if let otherNode = graph.node(for: otherID) {
                        lines.append("- **\(edge.type.displayName)** \(otherNode.label)")
                    }
                }
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON

    private func exportJSON(graph: KnowledgeGraph) -> String {
        do {
            let data = try graph.encode()
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{\"error\": \"\(error.localizedDescription)\"}"
        }
    }
}
