//
//  EmbeddingMath.swift
//  Atlas
//
//  Pure vector math for ETR pairwise candidate generation.
//  No dependencies on backends or graph types — fully unit-testable.
//

import Foundation

enum EmbeddingMath {
    /// Cosine similarity in [-1, 1]. Returns 0 when either vector has zero
    /// magnitude (degenerate input — treat as "no signal"). Traps on dimension
    /// mismatch (a programmer error: comparing across embedding models).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count,
                     "cosineSimilarity: dimension mismatch (\(a.count) vs \(b.count))")
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na  += a[i] * a[i]
            nb  += b[i] * b[i]
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
