//
//  SplitPaneContainer.swift
//  Atlas
//
//  Two-pane container: PDF viewer (left) + Knowledge map (right)
//  Supports Cmd+1 (PDF only), Cmd+2 (Map only), Cmd+3 (Split)
//

import SwiftUI

struct SplitPaneContainer<PDFContent: View, MapContent: View>: View {
    @Binding var paneMode: PaneMode
    let pdfContent: () -> PDFContent
    let mapContent: () -> MapContent

    @State private var splitFraction: CGFloat = 0.6

    var body: some View {
        GeometryReader { geometry in
            switch paneMode {
            case .pdfOnly:
                pdfContent()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .mapOnly:
                mapContent()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .split:
                let leftWidth = geometry.size.width * splitFraction
                let rightWidth = geometry.size.width * (1.0 - splitFraction) - 6
                HStack(spacing: 0) {
                    pdfContent()
                        .frame(width: max(leftWidth, 200))

                    // Draggable divider
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .padding(.horizontal, 2.5)
                        .contentShape(Rectangle().size(width: 10, height: geometry.size.height))
                        .onHover { hovering in
                            if hovering {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let newFraction = value.location.x / geometry.size.width
                                    var t = Transaction()
                                    t.isContinuous = true
                                    t.animation = nil
                                    withTransaction(t) {
                                        splitFraction = min(max(newFraction, 0.25), 0.85)
                                    }
                                }
                        )

                    mapContent()
                        .frame(width: max(rightWidth, 200))
                }
            }
        }
    }
}
