import SwiftUI

struct NodeSizing {
    let baseWidth: CGFloat
    let baseHeight: CGFloat
    let summaryBaseHeight: CGFloat
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let borderWidth: CGFloat
    let colorStripWidth: CGFloat
    let dotSize: CGFloat
    let bgOpacity: Double

    /// Maps a `NodeLevel` to its visual sizing tier. Document and Chapter
    /// share the largest tier (they're the dominant nodes when their tab
    /// is selected); Concept is medium; Entity is smallest.
    static func forNodeLevel(_ level: NodeLevel, hasSummary: Bool = false) -> NodeSizing {
        switch level {
        case .document, .chapter: return forLevel(0, hasSummary: hasSummary)
        case .concept:            return forLevel(1, hasSummary: hasSummary)
        case .entity:             return forLevel(2, hasSummary: hasSummary)
        }
    }

    static func forLevel(_ level: Int, hasSummary: Bool = false) -> NodeSizing {
        let clamped = max(0, min(level, 2))
        switch clamped {
        case 0:
            return NodeSizing(
                baseWidth: 200,
                baseHeight: hasSummary ? 60 : 42,
                summaryBaseHeight: 60,
                fontSize: 12,
                fontWeight: .bold,
                borderWidth: 1.5,
                colorStripWidth: 4,
                dotSize: 10,
                bgOpacity: 0.95
            )
        case 1:
            return NodeSizing(
                baseWidth: 160,
                baseHeight: hasSummary ? 50 : 36,
                summaryBaseHeight: 50,
                fontSize: 11,
                fontWeight: .semibold,
                borderWidth: 1.2,
                colorStripWidth: 3,
                dotSize: 7,
                bgOpacity: 0.90
            )
        default:
            return NodeSizing(
                baseWidth: 130,
                baseHeight: hasSummary ? 42 : 30,
                summaryBaseHeight: 42,
                fontSize: 10,
                fontWeight: .regular,
                borderWidth: 1,
                colorStripWidth: 2.5,
                dotSize: 5,
                bgOpacity: 0.85
            )
        }
    }
}
