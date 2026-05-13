//
//  PDFOutlinePanel.swift
//  PDFViewer
//
//  Sidebar panel rendering the PDF's table of contents as an expandable tree.
//

import SwiftUI
import PDFKit

// MARK: - PDF Outline Panel (Table of Contents)
struct PDFOutlinePanel: View {
    let pdfDocument: PDFDocument
    let pdfView: PDFView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Table of Contents")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if let root = pdfDocument.outlineRoot, root.numberOfChildren > 0 {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<root.numberOfChildren, id: \.self) { i in
                            if let child = root.child(at: i) {
                                OutlineItemView(outline: child, pdfView: pdfView, depth: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            } else {
                VStack {
                    Spacer()
                    Text("No table of contents")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct OutlineItemView: View {
    let outline: PDFOutline
    let pdfView: PDFView
    let depth: Int
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if outline.numberOfChildren > 0 {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Spacer().frame(width: 14)
                }

                Button(action: {
                    if let destination = outline.destination {
                        pdfView.go(to: destination)
                    }
                }) {
                    Text(outline.label ?? "Untitled")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 16)
            .padding(.vertical, 4)

            if isExpanded {
                ForEach(0..<outline.numberOfChildren, id: \.self) { i in
                    if let child = outline.child(at: i) {
                        OutlineItemView(outline: child, pdfView: pdfView, depth: depth + 1)
                    }
                }
            }
        }
    }
}
