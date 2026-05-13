//
//  AnnotationListPanel.swift
//  PDFViewer
//
//  Sidebar panel listing every annotation in the open PDF, with row actions
//  (navigate, delete).
//

import SwiftUI
import PDFKit

// MARK: - Annotation List Panel
struct AnnotationListPanel: View {
    let pdfDocument: PDFDocument
    let pdfView: PDFView
    let undoRedoManager: UndoRedoManager
    let onAnnotationsChanged: () -> Void
    @State private var annotations: [(pageIndex: Int, annotation: PDFAnnotation)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Annotations")
                    .font(.headline)
                Spacer()
                Button(action: refreshAnnotations) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if annotations.isEmpty {
                VStack {
                    Spacer()
                    Text("No annotations")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(annotations.enumerated()), id: \.offset) { idx, item in
                            AnnotationRowView(
                                pageIndex: item.pageIndex,
                                annotation: item.annotation,
                                onNavigate: {
                                    if let page = pdfDocument.page(at: item.pageIndex) {
                                        pdfView.go(to: item.annotation.bounds, on: page)
                                    }
                                },
                                onDelete: {
                                    if let page = pdfDocument.page(at: item.pageIndex) {
                                        page.removeAnnotation(item.annotation)
                                        undoRedoManager.addOperation(.remove(annotation: item.annotation, page: page))
                                        onAnnotationsChanged()
                                        refreshAnnotations()
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .onAppear { refreshAnnotations() }
    }

    private func refreshAnnotations() {
        var result: [(pageIndex: Int, annotation: PDFAnnotation)] = []
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            for annotation in page.annotations {
                // Skip built-in widget annotations
                if annotation.type == "Widget" { continue }
                result.append((pageIndex: i, annotation: annotation))
            }
        }
        annotations = result
    }
}

struct AnnotationRowView: View {
    let pageIndex: Int
    let annotation: PDFAnnotation
    let onNavigate: () -> Void
    let onDelete: () -> Void

    private var typeIcon: String {
        switch annotation.type {
        case "Highlight": return "highlighter"
        case "Underline": return "underline"
        case "StrikeOut": return "strikethrough"
        case "FreeText": return "text.bubble"
        case "Text": return "note.text"
        case "Ink": return "pencil.tip"
        case "Square": return "rectangle"
        case "Circle": return "circle"
        case "Line": return "line.diagonal"
        default: return "pencil"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: typeIcon)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(pageIndex + 1) — \(annotation.type ?? "Annotation")")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if let contents = annotation.contents, !contents.isEmpty {
                    Text(contents)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { onNavigate() }
    }
}
