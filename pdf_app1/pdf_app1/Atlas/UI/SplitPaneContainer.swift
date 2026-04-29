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
                let dividerWidth: CGFloat = 6
                let availableWidth = geometry.size.width - dividerWidth
                let leftWidth = availableWidth * splitFraction
                let rightWidth = availableWidth * (1.0 - splitFraction)
                HStack(spacing: 0) {
                    pdfContent()
                        .frame(width: leftWidth)
                        .clipped()

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
                            DragGesture(coordinateSpace: .named("splitContainer"))
                                .onChanged { value in
                                    let newFraction = (value.location.x - dividerWidth / 2) / availableWidth
                                    var t = Transaction()
                                    t.isContinuous = true
                                    t.animation = nil
                                    withTransaction(t) {
                                        splitFraction = min(max(newFraction, 0.25), 0.85)
                                    }
                                }
                        )

                    mapContent()
                        .frame(width: rightWidth)
                        .clipped()
                }
            }
        }
        .coordinateSpace(name: "splitContainer")
    }
}
