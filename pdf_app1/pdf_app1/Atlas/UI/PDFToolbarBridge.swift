import SwiftUI
import PDFKit

@Observable
final class PDFToolbarBridge {
    var currentPageIndex: Int = 0
    var pageCount: Int = 0
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var canUndo: Bool = false
    var canRedo: Bool = false
    var sidebarPanel: SidebarPanel? = nil
    var isFullscreen: Bool = false
    var isSaving: Bool = false
    var bookmarks: [Int] = []
    var currentPageBookmarked: Bool = false
    var hasURL: Bool = false

    var onGoBack: () -> Void = {}
    var onGoForward: () -> Void = {}
    var onGoToFirstPage: () -> Void = {}
    var onGoToLastPage: () -> Void = {}
    var onGoToPage: (Int) -> Void = { _ in }
    var onZoomIn: () -> Void = {}
    var onZoomOut: () -> Void = {}
    var onFitToPage: () -> Void = {}
    var onSetDisplayMode: (PDFDisplayMode) -> Void = { _ in }
    var onRotateCW: () -> Void = {}
    var onRotateCCW: () -> Void = {}
    var onSetReadingMode: (ReadingMode) -> Void = { _ in }
    var onToggleSearch: () -> Void = {}
    var onTogglePanel: (SidebarPanel) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var onToggleFullscreen: () -> Void = {}
    var onToggleBookmark: () -> Void = {}
    var onClearBookmarks: () -> Void = {}
    var onSave: () -> Void = {}
    var onSaveAs: () -> Void = {}
    var onPrint: () -> Void = {}
}
