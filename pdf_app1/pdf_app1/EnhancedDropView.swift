//
//  EnhancedDropView.swift
//  PDFViewer
//
//  Drop zone for PDF files. Single `.onDrop(of:isTargeted:perform:)`
//  modifier — SwiftUI manages drag-enter / drag-exit / drop-complete
//  state via the `$isDropTargeted` binding, including the cancelled-drag
//  case that the previous DropDelegate + duplicate-onDrop setup mishandled.
//

import SwiftUI
import UniformTypeIdentifiers

struct EnhancedDropView<Content: View>: View {
    let content: Content
    let onFilesDropped: ([URL]) -> Void
    let maxFiles: Int
    @State private var isDropTargeted = false

    init(maxFiles: Int = 10, onFilesDropped: @escaping ([URL]) -> Void, @ViewBuilder content: () -> Content) {
        self.maxFiles = maxFiles
        self.onFilesDropped = onFilesDropped
        self.content = content()
    }

    var body: some View {
        content
            .background(
                dropOverlay
                    .opacity(isDropTargeted ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleProviders(providers)
                return true
            }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.1)

            VStack(spacing: 16) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text("Drop PDF Files Here")
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
            )
            .padding(40)
        }
    }

    private func handleProviders(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }

                if let fileURL = url, fileURL.pathExtension.lowercased() == "pdf" {
                    urls.append(fileURL)
                }
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            onFilesDropped(Array(urls.prefix(maxFiles)))
        }
    }
}

extension View {
    func enhancedDropZone(maxFiles: Int = 10, onFilesDropped: @escaping ([URL]) -> Void) -> some View {
        EnhancedDropView(maxFiles: maxFiles, onFilesDropped: onFilesDropped) {
            self
        }
    }
}
