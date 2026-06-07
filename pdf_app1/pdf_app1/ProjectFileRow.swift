//
//  ProjectFileRow.swift
//  PDFViewer
//
//  Row for a project file in the sidebar file list.
//

import AppKit
import SwiftUI

struct ProjectFileRow: View {
    let file: URL
    let projectsManager: ProjectsManager
    let projectID: UUID
    let processingState: ProcessingState
    let canAnalyze: Bool
    let onSelect: (URL) -> Void
    let onRemove: (URL) -> Void
    let onAnalyze: (URL) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 14))
                .foregroundColor(.blue)
                .frame(width: 16)

            Button(action: { onSelect(file) }) {
                HStack {
                    Text(file.lastPathComponent)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                }
            }
            .buttonStyle(.borderless)

            processingBadge

            if canAnalyze && processingState == .unprocessed {
                Button(action: { onAnalyze(file) }) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Analyze this document")
            }

            Button(action: { onRemove(file) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.clear)
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private var processingBadge: some View {
        Group {
            switch processingState {
            case .unprocessed:
                EmptyView()
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
