//
//  PDFViewerApp.swift
//  PDFViewer
//
//  Created on macOS
//

import SwiftUI
import AppKit

@main
struct PDFViewerApp: App {
    @StateObject private var recentFilesManager: RecentFilesManager
    @StateObject private var projectsManager = ProjectsManager()
    @StateObject private var documentManager: DocumentManager
    @State private var knowledgeGraph = KnowledgeGraph()
    @State private var aiServiceManager = AIServiceManager()

    init() {
        let recent = RecentFilesManager()
        _recentFilesManager = StateObject(wrappedValue: recent)
        _documentManager = StateObject(wrappedValue: DocumentManager(recentFilesManager: recent))
    }

    var body: some Scene {
        WindowGroup {
            MultiDocumentView()
                .environmentObject(recentFilesManager)
                .environmentObject(projectsManager)
                .environmentObject(documentManager)
                .environment(knowledgeGraph)
                .environment(aiServiceManager)
                .frame(minWidth: AppConstants.minWindowWidth, minHeight: AppConstants.minWindowHeight)
                .onAppear {
                    documentManager.restoreOpenSession()
                    configureWindow()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    documentManager.saveOpenSession()
                    GraphStore.shared.flushPendingSave()
                }
        }
        .defaultSize(width: NSScreen.main?.frame.width ?? AppConstants.minWindowWidth,
                    height: NSScreen.main?.frame.height ?? AppConstants.minWindowHeight)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    NotificationCenter.default.post(name: NSNotification.Name("OpenNewDocument"), object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])
                
                Button("Close Tab") {
                    NotificationCenter.default.post(name: NSNotification.Name("CloseCurrentTab"), object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command])
                
                Divider()
                
                Button("Enter Comparison Mode") {
                    documentManager.startComparison(
                        left: documentManager.documents.first,
                        right: documentManager.documents.dropFirst().first
                    )
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            CommandMenu("View") {
                Button("PDF Only") {
                    NotificationCenter.default.post(name: NSNotification.Name("SetPaneMode"), object: PaneMode.pdfOnly)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("Map Only") {
                    NotificationCenter.default.post(name: NSNotification.Name("SetPaneMode"), object: PaneMode.mapOnly)
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Split View") {
                    NotificationCenter.default.post(name: NSNotification.Name("SetPaneMode"), object: PaneMode.split)
                }
                .keyboardShortcut("3", modifiers: [.command])
            }
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            PreferencesView()
                .environment(aiServiceManager)
        }
    }
    
    /// Configure window to open maximized/fullscreen by default
    private func configureWindow() {
        DispatchQueue.main.async {
            if let window = NSApplication.shared.windows.first {
                // Set window to fill screen (maximized)
                if let screen = NSScreen.main {
                    window.setFrame(screen.visibleFrame, display: true)
                }
                
                // Center window if smaller than screen
                window.center()
                
                // Make window resizable with content extending into title bar
                window.styleMask.insert(.resizable)
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden

                let shouldStartFullscreen = UserDefaults.standard.bool(forKey: AppConstants.windowStateKey)
                if shouldStartFullscreen {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        window.toggleFullScreen(nil)
                    }
                }
            }
        }
    }
}

