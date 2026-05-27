//
//  TourPlayer.swift
//  Atlas
//

import Foundation
import Observation

@Observable
class TourPlayer {
    private(set) var tour: GuidedTour?
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying: Bool = false

    var currentStop: TourStop? {
        guard let tour, isPlaying, tour.stops.indices.contains(currentIndex) else { return nil }
        return tour.stops[currentIndex]
    }

    func load(_ tour: GuidedTour) {
        self.tour = tour
        currentIndex = 0
        isPlaying = false
    }

    func start() {
        guard tour != nil else { return }
        currentIndex = 0
        isPlaying = true
    }

    var canGoNext: Bool {
        guard let tour else { return false }
        return currentIndex < tour.stops.count - 1
    }

    func next() {
        guard canGoNext else { return }
        currentIndex += 1
    }

    var canGoPrevious: Bool {
        currentIndex > 0
    }

    func previous() {
        guard canGoPrevious else { return }
        currentIndex -= 1
    }

    func skip(to index: Int) {
        guard let tour, tour.stops.indices.contains(index) else { return }
        currentIndex = index
    }

    func replay() {
        guard tour != nil else { return }
        currentIndex = 0
        isPlaying = true
    }

    func dismiss() {
        isPlaying = false
    }
}
