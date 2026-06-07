//
//  DocumentComparisonView.swift
//  PDFViewer
//
//  Side-by-side PDF comparison views.
//

import AppKit
import SwiftUI

struct DocumentComparisonView: View {
    let leftDocument: PDFDocumentItem?
    let rightDocument: PDFDocumentItem?
    let splitView: ComparisonSplitView
    let onSplitViewChange: (ComparisonSplitView) -> Void

    var body: some View {
        Group {
            if let left = leftDocument, let right = rightDocument {
                HStack(spacing: 1) {
                    switch splitView {
                    case .sideBySide:
                        HStack(spacing: 1) {
                            DocumentPanel(document: left, title: "Left Document")
                            Divider()
                            DocumentPanel(document: right, title: "Right Document")
                        }
                    case .vertical:
                        VStack(spacing: 1) {
                            DocumentPanel(document: left, title: "Top Document")
                            Divider()
                            DocumentPanel(document: right, title: "Bottom Document")
                        }
                    case .horizontal:
                        HStack(spacing: 1) {
                            DocumentPanel(document: left, title: "Document 1")
                            Divider()
                            DocumentPanel(document: right, title: "Document 2")
                        }
                    }
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select two documents to compare")
                        .foregroundColor(.secondary)
                        .font(.headline)
                    Text("Drag documents to the left and right panels")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct DocumentPanel: View {
    let document: PDFDocumentItem
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text(document.title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // PDF View
            PDFViewerView(
                pdfDocument: document.document,
                pdfURL: document.url,
                annotationMode: .constant(.none),
                highlightColor: .constant(.yellow),
                notificationManager: NotificationManager(),
                toolbarBridge: PDFToolbarBridge()
            )
        }
    }
}
