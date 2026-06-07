//
//  GuidedTour.swift
//  Atlas
//
//  Persisted guided learning tour for a concept map.
//

import Foundation

struct GuidedTour: Codable, Equatable {
    let id: UUID
    let documentURL: URL
    var stops: [GuidedTourStop]
    var generatedAt: Date
    var generatedByModel: String?

    init(
        id: UUID = UUID(),
        documentURL: URL,
        stops: [GuidedTourStop],
        generatedAt: Date = Date(),
        generatedByModel: String? = nil
    ) {
        self.id = id
        self.documentURL = documentURL
        self.stops = stops
        self.generatedAt = generatedAt
        self.generatedByModel = generatedByModel
    }
}

struct GuidedTourStop: Identifiable, Codable, Equatable {
    let id: UUID
    let nodeID: UUID
    var title: String
    var narration: String

    init(
        id: UUID = UUID(),
        nodeID: UUID,
        title: String,
        narration: String
    ) {
        self.id = id
        self.nodeID = nodeID
        self.title = title
        self.narration = narration
    }
}
