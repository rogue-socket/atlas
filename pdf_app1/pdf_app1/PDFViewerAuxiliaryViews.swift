//
//  PDFViewerAuxiliaryViews.swift
//  PDFViewer
//
//  Small auxiliary views used by PDFViewerView.
//

import AppKit
import PDFKit
import SwiftUI

struct TextAnnotationDialog: View {
    @Binding var content: String
    @Binding var isPresented: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add Text Annotation")
                .font(.headline)

            TextField("Enter text", text: $content, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .frame(width: 300)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    onSave()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(content.isEmpty)
            }
        }
        .padding()
        .frame(width: 350, height: 200)
    }
}

struct PDFThumbnailViewRepresentable: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnailView = PDFThumbnailView()
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 90, height: 120)
        thumbnailView.backgroundColor = NSColor.controlBackgroundColor
        return thumbnailView
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== pdfView {
            nsView.pdfView = pdfView
        }
    }
}
