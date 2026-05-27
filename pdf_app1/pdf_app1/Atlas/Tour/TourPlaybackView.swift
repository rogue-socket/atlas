//
//  TourPlaybackView.swift
//  Atlas
//

import SwiftUI

struct TourPlaybackView: View {
    @Bindable var player: TourPlayer
    var onDismiss: () -> Void
    var nodeLabel: (UUID) -> String
    @State private var showSkipMenu = false

    var body: some View {
        if let stop = player.currentStop, let tour = player.tour {
            let position = player.currentIndex + 1
            let total = tour.stops.count
            let currentNodeLabel = nodeLabel(stop.nodeID)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "graduationcap.fill")
                        .foregroundColor(.accentColor)
                    Text("Guided Tour")
                        .font(.headline)
                    Text("Read-only")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(position) / \(total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close the guided tour card and keep the map position")
                }

                Text("Centered on: \(currentNodeLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(stop.narration)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: { player.previous() }) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!player.canGoPrevious)
                    .help("Go to the previous guided tour stop")

                    Button(action: { player.next() }) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!player.canGoNext)
                    .help("Go to the next guided tour stop")

                    Button(action: { showSkipMenu.toggle() }) {
                        Image(systemName: "list.bullet")
                    }
                    .help("Open valid guided tour stops")
                    .popover(isPresented: $showSkipMenu, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(tour.stops.enumerated()), id: \.element.id) { index, stop in
                                Button(action: {
                                    player.skip(to: index)
                                    showSkipMenu = false
                                }) {
                                    HStack {
                                        Text("\(index + 1).")
                                            .foregroundColor(.secondary)
                                            .frame(width: 24, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(nodeLabel(stop.nodeID))
                                                .font(.body)
                                                .lineLimit(1)
                                            Text(stop.narration)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: 280, alignment: .leading)
                                        if index == player.currentIndex {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    Spacer()

                    if !player.canGoNext {
                        Button("Replay") { player.replay() }
                            .help("Replay the guided tour from the first stop")
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .frame(maxWidth: 360)
            .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
            .shadow(radius: 8)
        }
    }
}
