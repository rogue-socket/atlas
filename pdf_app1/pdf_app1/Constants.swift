//
//  Constants.swift
//  PDFViewer
//
//  Application-wide constants and configuration
//

import Foundation
import SwiftUI

enum AnnotationMode: Equatable {
    case none
    case select
    case highlightText
    case highlightArea
    case text
    case underline
    case strikethrough
    case stickyNote
    case ink
    case rectangle
    case circle
    case line
    case arrow
}

enum SidebarPanel: Hashable {
    case thumbnails
    case outline
    case annotations
    case projectCorrelations
}

enum ReadingMode: String {
    case normal
    case sepia
    case dark
}

/// Application-wide constants
struct AppConstants {
    // MARK: - Recent Files
    /// Maximum number of recent files to store
    static let maxRecentFiles: Int = 20
    
    // MARK: - Annotations
    /// Default text annotation width
    static let textAnnotationWidth: CGFloat = 200
    /// Default text annotation height
    static let textAnnotationHeight: CGFloat = 40
    /// Minimum highlight size (width or height) to be considered valid
    static let minimumHighlightSize: CGFloat = 5
    /// Default annotation alpha/opacity
    static let annotationAlpha: CGFloat = 0.3
    /// Default annotation font size
    static let annotationFontSize: CGFloat = 12
    /// Vertical offset for text annotations (from click point)
    static let textAnnotationVerticalOffset: CGFloat = 20
    
    // MARK: - UI
    /// Default notification duration in seconds
    static let notificationDuration: Double = 3.0
    /// Notification width (fixed, not full screen)
    static let notificationWidth: CGFloat = 350
    /// Maximum number of visible toast notifications
    static let maxVisibleNotifications: Int = 3
    /// Sidebar minimum width
    static let sidebarMinWidth: CGFloat = 250
    /// Sidebar ideal width
    static let sidebarIdealWidth: CGFloat = 300
    /// Minimum window width
    static let minWindowWidth: CGFloat = 800
    /// Minimum window height
    static let minWindowHeight: CGFloat = 600
    
    // MARK: - Zoom
    /// Zoom in/out multiplier
    static let zoomMultiplier: CGFloat = 1.2

    // MARK: - Knowledge Map
    /// Default node width
    static let mapNodeWidth: CGFloat = 140
    /// Default node height
    static let mapNodeHeight: CGFloat = 40
    /// Node corner radius
    static let mapNodeCornerRadius: CGFloat = 8
    /// Maximum animation duration in seconds
    static let mapAnimationDuration: Double = 0.4
    /// Source pulse animation duration in seconds
    static let sourcePulseDuration: Double = 0.8
    /// Default split pane fraction (PDF side)
    static let defaultSplitFraction: CGFloat = 0.6
    /// Maximum nodes before forcing chapter-level zoom
    static let mapDensityThreshold: Int = 200
    /// Force-directed layout iteration limit
    static let layoutMaxIterations: Int = 500
    /// Node count below which the exact O(n²) repulsion loop is used; at or above, switch to Barnes-Hut
    static let barnesHutThreshold: Int = 100
    /// Barnes-Hut accuracy parameter. Lower = closer to exact (slower), higher = more approximate (faster)
    static let barnesHutTheta: Double = 0.7

    // MARK: - UserDefaults Keys
    /// UserDefaults key for recent files bookmarks
    static let recentFilesBookmarksKey = "RecentPDFFilesBookmarks"
    /// UserDefaults key for window state preference
    static let windowStateKey = "WindowStatePreference"
    /// UserDefaults key for open session tab bookmarks
    static let openSessionBookmarksKey = "OpenSessionBookmarks"
    /// UserDefaults key for selected AI backend type
    static let aiBackendTypeKey = "atlas.ai.backendType"
    /// UserDefaults key for selected AI model identifier
    static let aiModelKey = "atlas.ai.model"
    /// UserDefaults key for Ollama base URL override
    static let ollamaBaseURLKey = "atlas.ollama.baseURL"
    /// UserDefaults key for the ETR embedding backend type (nil = ETR disabled)
    static let aiEmbeddingBackendTypeKey = "atlas.ai.embedding.backendType"
    /// UserDefaults key for the ETR embedding model identifier
    static let aiEmbeddingModelKey = "atlas.ai.embedding.model"
}

// MARK: - Notification Names

extension Notification.Name {
    static let openNewDocument = Notification.Name("OpenNewDocument")
    static let openDocumentInNewWindow = Notification.Name("OpenDocumentInNewWindow")
    static let navigateToPage = Notification.Name("NavigateToPage")
    static let closeCurrentTab = Notification.Name("CloseCurrentTab")
    static let closeOtherTabs = Notification.Name("CloseOtherTabs")
    static let setPaneMode = Notification.Name("SetPaneMode")
}
