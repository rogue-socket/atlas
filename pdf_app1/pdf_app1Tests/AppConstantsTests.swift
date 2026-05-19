import XCTest
@testable import pdf_app1

/// Pins constants that are widely referenced across the app surface.
/// A change to one of these probably affects user-facing behavior and
/// deserves a deliberate update; the assertions here force the change.
final class AppConstantsTests: XCTestCase {

    // MARK: - AppConstants

    func test_appConstants_recentFilesLimit() {
        XCTAssertEqual(AppConstants.maxRecentFiles, 20)
    }

    func test_appConstants_annotationDefaults_arePositive() {
        XCTAssertGreaterThan(AppConstants.textAnnotationWidth, 0)
        XCTAssertGreaterThan(AppConstants.textAnnotationHeight, 0)
        XCTAssertGreaterThan(AppConstants.minimumHighlightSize, 0)
        XCTAssertGreaterThan(AppConstants.annotationAlpha, 0)
        XCTAssertLessThanOrEqual(AppConstants.annotationAlpha, 1)
        XCTAssertGreaterThan(AppConstants.annotationFontSize, 0)
    }

    func test_appConstants_uiDimensions_arePositive() {
        XCTAssertGreaterThan(AppConstants.notificationDuration, 0)
        XCTAssertGreaterThan(AppConstants.notificationWidth, 0)
        XCTAssertGreaterThan(AppConstants.maxVisibleNotifications, 0)
        XCTAssertGreaterThan(AppConstants.sidebarMinWidth, 0)
        XCTAssertGreaterThanOrEqual(AppConstants.sidebarIdealWidth, AppConstants.sidebarMinWidth)
        XCTAssertGreaterThan(AppConstants.minWindowWidth, 0)
        XCTAssertGreaterThan(AppConstants.minWindowHeight, 0)
    }

    func test_appConstants_zoomMultiplierGreaterThanOne() {
        XCTAssertGreaterThan(AppConstants.zoomMultiplier, 1.0)
    }

    func test_appConstants_mapDefaults() {
        XCTAssertGreaterThan(AppConstants.mapNodeWidth, 0)
        XCTAssertGreaterThan(AppConstants.mapNodeHeight, 0)
        XCTAssertGreaterThanOrEqual(AppConstants.mapNodeCornerRadius, 0)
        XCTAssertGreaterThan(AppConstants.mapAnimationDuration, 0)
        XCTAssertGreaterThan(AppConstants.sourcePulseDuration, 0)
        XCTAssertGreaterThan(AppConstants.defaultSplitFraction, 0)
        XCTAssertLessThan(AppConstants.defaultSplitFraction, 1)
        XCTAssertGreaterThan(AppConstants.mapDensityThreshold, 0)
        XCTAssertGreaterThan(AppConstants.layoutMaxIterations, 0)
        XCTAssertGreaterThanOrEqual(AppConstants.barnesHutThreshold, 1)
        XCTAssertGreaterThan(AppConstants.barnesHutTheta, 0)
    }

    // MARK: - UserDefaults keys are stable

    func test_userDefaults_keys_areStable() {
        XCTAssertEqual(AppConstants.recentFilesBookmarksKey, "RecentPDFFilesBookmarks")
        XCTAssertEqual(AppConstants.windowStateKey, "WindowStatePreference")
        XCTAssertEqual(AppConstants.openSessionBookmarksKey, "OpenSessionBookmarks")
        XCTAssertEqual(AppConstants.aiBackendTypeKey, "atlas.ai.backendType")
        XCTAssertEqual(AppConstants.aiModelKey, "atlas.ai.model")
        XCTAssertEqual(AppConstants.ollamaBaseURLKey, "atlas.ollama.baseURL")
    }

    // MARK: - Notification.Name

    func test_notificationNames_areStable() {
        XCTAssertEqual(Notification.Name.openNewDocument.rawValue, "OpenNewDocument")
        XCTAssertEqual(Notification.Name.openDocumentInNewWindow.rawValue, "OpenDocumentInNewWindow")
        XCTAssertEqual(Notification.Name.navigateToPage.rawValue, "NavigateToPage")
        XCTAssertEqual(Notification.Name.closeCurrentTab.rawValue, "CloseCurrentTab")
        XCTAssertEqual(Notification.Name.closeOtherTabs.rawValue, "CloseOtherTabs")
        XCTAssertEqual(Notification.Name.setPaneMode.rawValue, "SetPaneMode")
    }

    // MARK: - AnnotationMode equality

    func test_annotationMode_equality() {
        XCTAssertEqual(AnnotationMode.highlightText, .highlightText)
        XCTAssertNotEqual(AnnotationMode.text, .stickyNote)
    }

    // MARK: - SidebarPanel hashability

    func test_sidebarPanel_isHashable() {
        let set: Set<SidebarPanel> = [.thumbnails, .outline, .annotations, .projectCorrelations]
        XCTAssertEqual(set.count, 4)
    }

    // MARK: - ReadingMode raw values

    func test_readingMode_rawValuesAreStable() {
        XCTAssertEqual(ReadingMode.normal.rawValue, "normal")
        XCTAssertEqual(ReadingMode.sepia.rawValue,  "sepia")
        XCTAssertEqual(ReadingMode.dark.rawValue,   "dark")
    }

    // MARK: - ExtractionMode

    func test_extractionMode_displayNameAndDescription() {
        XCTAssertEqual(ExtractionMode.fast.displayName, "Fast")
        XCTAssertEqual(ExtractionMode.deep.displayName, "Deep")
        XCTAssertFalse(ExtractionMode.fast.description.isEmpty)
        XCTAssertFalse(ExtractionMode.deep.description.isEmpty)
        XCTAssertTrue(ExtractionMode.fast.isAvailable)
        XCTAssertTrue(ExtractionMode.deep.isAvailable)
    }
}
