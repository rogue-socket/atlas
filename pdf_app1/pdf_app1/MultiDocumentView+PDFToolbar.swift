//
//  MultiDocumentView+PDFToolbar.swift
//  PDFViewer
//
//  PDF toolbar controls hosted in the multi-document sidebar.
//

import PDFKit
import SwiftUI

extension MultiDocumentView {
    var pdfAnnotationIcon: String {
        switch annotationMode {
        case .none: return "hand.point.up.left"
        case .select: return "arrow.up.and.down.and.arrow.left.and.right"
        case .highlightText: return "highlighter"
        case .highlightArea: return "rectangle.dashed"
        case .text: return "text.bubble"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .stickyNote: return "note.text"
        case .ink: return "pencil.tip"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.right"
        }
    }

    var pdfAnnotationUsesColor: Bool {
        switch annotationMode {
        case .none, .select, .text, .stickyNote: return false
        default: return true
        }
    }

    @ViewBuilder
    var pdfToolbar: some View {
        let bridge = toolbarBridge
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button(action: { bridge.onGoBack() }) { Image(systemName: "chevron.left") }
                    .disabled(!bridge.canGoBack)
                    .help("Previous Page (⌘←)")
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button(action: { bridge.onGoForward() }) { Image(systemName: "chevron.right") }
                    .disabled(!bridge.canGoForward)
                    .help("Next Page (⌘→)")
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Text("\(bridge.currentPageIndex + 1)/\(max(bridge.pageCount, 1))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
                Button(action: { bridge.onZoomOut() }) { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out")
                Button(action: { bridge.onZoomIn() }) { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In")
                Button(action: { bridge.onFitToPage() }) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help("Fit to Page")
            }

            HStack(spacing: 4) {
                Menu {
                    Section("Display Mode") {
                        Button("Single Page") { bridge.onSetDisplayMode(.singlePage) }
                        Button("Continuous") { bridge.onSetDisplayMode(.singlePageContinuous) }
                        Button("Two Pages") { bridge.onSetDisplayMode(.twoUp) }
                        Button("Two Pages Continuous") { bridge.onSetDisplayMode(.twoUpContinuous) }
                    }
                    Section("Rotation") {
                        Button("Rotate Left") { bridge.onRotateCCW() }
                        Button("Rotate Right") { bridge.onRotateCW() }
                    }
                    Section("Reading Mode") {
                        Button("Normal") { bridge.onSetReadingMode(.normal) }
                        Button("Sepia") { bridge.onSetReadingMode(.sepia) }
                        Button("Dark") { bridge.onSetReadingMode(.dark) }
                    }
                } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Display & Reading")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                Button(action: { bridge.onToggleSearch() }) { Image(systemName: "magnifyingglass") }
                    .help("Search (⌘F)")
                    .keyboardShortcut("f", modifiers: .command)
                Menu {
                    Section("Markup") {
                        Button("None") { annotationMode = .none }
                        Button("Move / Resize") { annotationMode = .select }
                        Button("Highlight") { annotationMode = .highlightText }
                        Button("Underline") { annotationMode = .underline }
                        Button("Strikethrough") { annotationMode = .strikethrough }
                        Button("Area Highlight") { annotationMode = .highlightArea }
                    }
                    Section("Shapes") {
                        Button("Rectangle") { annotationMode = .rectangle }
                        Button("Circle") { annotationMode = .circle }
                        Button("Line") { annotationMode = .line }
                        Button("Arrow") { annotationMode = .arrow }
                    }
                    Section("Other") {
                        Button("Text") { annotationMode = .text }
                        Button("Sticky Note") { annotationMode = .stickyNote }
                        Button("Ink") { annotationMode = .ink }
                    }
                } label: { Image(systemName: pdfAnnotationIcon) }
                    .help("Annotation")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                if pdfAnnotationUsesColor {
                    ColorPicker("", selection: $highlightColor).labelsHidden()
                }
                Spacer(minLength: 0)
                Button(action: { bridge.onUndo() }) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!bridge.canUndo)
                    .help("Undo (⌘Z)")
                    .keyboardShortcut("z", modifiers: .command)
                Button(action: { bridge.onRedo() }) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!bridge.canRedo)
                    .help("Redo (⌘⇧Z)")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            HStack(spacing: 4) {
                Button(action: { bridge.onTogglePanel(.thumbnails) }) { Image(systemName: "square.grid.2x2") }
                    .help("Thumbnails")
                Button(action: { bridge.onTogglePanel(.outline) }) { Image(systemName: "list.bullet") }
                    .help("Table of Contents")
                Button(action: { bridge.onTogglePanel(.annotations) }) { Image(systemName: "note.text") }
                    .help("Annotations")
                Spacer(minLength: 0)
                Button(action: { bridge.onToggleFullscreen() }) {
                    Image(systemName: bridge.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help("Fullscreen (⌘⌃F)")
                .keyboardShortcut("f", modifiers: [.command, .control])
                Menu {
                    Button(bridge.currentPageBookmarked ? "Remove Bookmark" : "Add Bookmark") {
                        bridge.onToggleBookmark()
                    }.disabled(bridge.pageCount == 0)
                    if !bridge.bookmarks.isEmpty {
                        Divider()
                        ForEach(bridge.bookmarks, id: \.self) { idx in
                            Button("Page \(idx + 1)") { bridge.onGoToPage(idx) }
                        }
                        Divider()
                        Button("Clear Bookmarks") { bridge.onClearBookmarks() }
                    }
                } label: { Image(systemName: bridge.currentPageBookmarked ? "bookmark.fill" : "bookmark") }
                    .help("Bookmarks")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                if bridge.hasURL {
                    Button(action: { bridge.onSave() }) {
                        if bridge.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .disabled(bridge.isSaving)
                    .help("Save (⌘S)")
                    .keyboardShortcut("s", modifiers: .command)
                    Menu {
                        Button("Save As...") { bridge.onSaveAs() }
                            .keyboardShortcut("s", modifiers: [.command, .shift])
                        Button("Print...") { bridge.onPrint() }
                            .keyboardShortcut("p", modifiers: .command)
                    } label: { Image(systemName: "ellipsis") }
                        .help("More")
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
