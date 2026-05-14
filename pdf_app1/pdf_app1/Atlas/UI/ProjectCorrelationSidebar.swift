//
//  ProjectCorrelationSidebar.swift
//  Atlas
//
//  Enhanced project sidebar showing correlation status across PDFs
//

import SwiftUI

struct ProjectCorrelationSidebar: View {
    let project: Project
    var projectGraph: KnowledgeGraph
    let correlationStats: [DocumentPairID: CorrelationStats]
    let documentProcessingState: [URL: ProcessingState]
    var onSelectDocument: (URL) -> Void
    var onAnalyzeAll: () -> Void
    var onViewUnifiedMap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Project Correlations")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    // Document list with extraction progress
                    ForEach(project.files) { file in
                        DocumentCorrelationRow(
                            file: file,
                            conceptCount: conceptCount(for: file),
                            processingState: processingState(for: file),
                            sharedConcepts: sharedConceptSummary(for: file),
                            onSelect: {
                                if let url = resolveURL(for: file) {
                                    onSelectDocument(url)
                                }
                            }
                        )
                    }

                    // Cross-document correlations summary
                    if !correlationStats.isEmpty {
                        Section {
                            ForEach(Array(correlationStats.keys.sorted(by: {
                                correlationStats[$0]?.sharedConceptCount ?? 0 > correlationStats[$1]?.sharedConceptCount ?? 0
                            })), id: \.self) { pairID in
                                if let stats = correlationStats[pairID] {
                                    CorrelationPairRow(
                                        urlA: pairID.urlA,
                                        urlB: pairID.urlB,
                                        stats: stats
                                    )
                                }
                            }
                        } header: {
                            Text("Cross-Document Connections")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Actions
            HStack(spacing: 8) {
                Button(action: onAnalyzeAll) {
                    Label("Analyze All", systemImage: "brain")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onViewUnifiedMap) {
                    Label("Unified Map", systemImage: "map")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(8)
        }
    }

    // MARK: - Helpers

    private func conceptCount(for file: ProjectFile) -> Int {
        guard let url = resolveURL(for: file) else { return 0 }
        return projectGraph.nodes(forDocument: url).count
    }

    private func processingState(for file: ProjectFile) -> ProcessingState {
        guard let url = resolveURL(for: file) else { return .unprocessed }
        return documentProcessingState[url] ?? .unprocessed
    }

    private func sharedConceptSummary(for file: ProjectFile) -> [(String, Int)] {
        guard let url = resolveURL(for: file) else { return [] }
        var summary: [(String, Int)] = []

        for (pairID, stats) in correlationStats {
            if pairID.urlA == url {
                summary.append((pairID.urlB.lastPathComponent, stats.sharedConceptCount))
            } else if pairID.urlB == url {
                summary.append((pairID.urlA.lastPathComponent, stats.sharedConceptCount))
            }
        }

        return summary.sorted { $0.1 > $1.1 }
    }

    private func resolveURL(for file: ProjectFile) -> URL? {
        var isStale = false
        return try? URL(resolvingBookmarkData: file.bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}

// MARK: - Document Row

struct DocumentCorrelationRow: View {
    let file: ProjectFile
    let conceptCount: Int
    let processingState: ProcessingState
    let sharedConcepts: [(String, Int)]
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.blue)

                    Text(file.displayName)
                        .font(.callout)
                        .lineLimit(1)

                    Spacer()

                    // Processing state badge
                    processingBadge

                    // Concept count badge
                    if conceptCount > 0 {
                        Text("\(conceptCount)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                            .foregroundColor(.blue)
                    }
                }

                // Shared concepts
                if !sharedConcepts.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(sharedConcepts.prefix(3), id: \.0) { name, count in
                            Text("\(count) shared with \(name)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
    }

    private var processingBadge: some View {
        Group {
            switch processingState {
            case .unprocessed:
                Image(systemName: "circle")
                    .foregroundColor(.gray)
                    .font(.caption2)
            case .processing:
                ProgressView()
                    .controlSize(.mini)
            case .partial:
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundColor(.orange)
                    .font(.caption2)
            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption2)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption2)
            }
        }
    }
}

// MARK: - Correlation Pair Row

struct CorrelationPairRow: View {
    let urlA: URL
    let urlB: URL
    let stats: CorrelationStats

    var body: some View {
        HStack(spacing: 8) {
            Text(urlA.deletingPathExtension().lastPathComponent)
                .font(.caption)
                .lineLimit(1)

            Image(systemName: "link")
                .foregroundColor(.orange)
                .font(.caption2)

            Text(urlB.deletingPathExtension().lastPathComponent)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Text("\(stats.sharedConceptCount) shared")
                .font(.caption2)
                .foregroundColor(.orange)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.orange.opacity(0.05))
        )
    }
}
