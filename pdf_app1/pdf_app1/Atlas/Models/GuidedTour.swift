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
    var introduction: String
    var stops: [GuidedTourStop]
    var generatedAt: Date
    var generatedByModel: String?

    init(
        id: UUID = UUID(),
        documentURL: URL,
        introduction: String = "",
        stops: [GuidedTourStop],
        generatedAt: Date = Date(),
        generatedByModel: String? = nil
    ) {
        self.id = id
        self.documentURL = documentURL
        self.introduction = introduction
        self.stops = stops
        self.generatedAt = generatedAt
        self.generatedByModel = generatedByModel
    }

    enum CodingKeys: String, CodingKey {
        case id, documentURL, introduction, stops, generatedAt, generatedByModel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        documentURL = try c.decode(URL.self, forKey: .documentURL)
        introduction = try c.decodeIfPresent(String.self, forKey: .introduction) ?? ""
        stops = try c.decode([GuidedTourStop].self, forKey: .stops)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        generatedByModel = try c.decodeIfPresent(String.self, forKey: .generatedByModel)
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
