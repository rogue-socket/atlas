//
//  GuidedTour.swift
//  Atlas
//

import Foundation

struct TourStop: Identifiable, Codable, Hashable {
    let id: UUID
    let nodeID: UUID
    let narration: String

    init(id: UUID = UUID(), nodeID: UUID, narration: String) {
        self.id = id
        self.nodeID = nodeID
        self.narration = narration
    }
}

struct GuidedTour: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let stops: [TourStop]

    init(id: UUID = UUID(), title: String, stops: [TourStop]) {
        self.id = id
        self.title = title
        self.stops = stops
    }
}
