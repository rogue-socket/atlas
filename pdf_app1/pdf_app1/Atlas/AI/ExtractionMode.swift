import Foundation

enum ExtractionMode: String, CaseIterable {
    case fast
    case deep

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .deep: "Deep"
        }
    }

    var description: String {
        switch self {
        case .fast: "Quick single-pass extraction"
        case .deep: "Thorough 3-pass extraction"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .fast: true
        case .deep: false
        }
    }
}
