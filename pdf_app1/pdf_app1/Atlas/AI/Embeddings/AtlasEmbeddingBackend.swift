//
//  AtlasEmbeddingBackend.swift
//  Atlas
//
//  Protocol for embedding-vector providers used by ETR (Extract-Then-Resolve).
//  Separate from `AtlasModel` because (a) Claude has no embedding API and ETR
//  must work even when the LLM backend is Claude, and (b) the embedding model
//  is selected independently in Settings — see PRD §"Locked-in prep items".
//

import Foundation

protocol AtlasEmbeddingBackend: Sendable {
    /// Human-readable name for Settings UI.
    var displayName: String { get }

    /// Vendor-specific identifier (e.g. "gemini-embedding-2-preview").
    var modelIdentifier: String { get }

    /// Output dimensionality. Used for sanity-checks against stored embeddings
    /// (a model change invalidates the cache; comparing vectors of different
    /// dimensions is a programmer error and traps).
    var vectorDimension: Int { get }

    /// True when the backend has the credentials / configuration needed to
    /// make calls. UI surfaces "ETR unavailable" when no backend reports true.
    var isAvailable: Bool { get }

    /// Embed `texts` in order. Returns a parallel `[[Float]]` where
    /// `result[i]` is the embedding of `texts[i]`. Implementations may batch
    /// internally; callers should pass everything they want embedded at once
    /// (typically ~250 nodes per project) and let the implementation chunk.
    ///
    /// Throws on transport, decoding, or per-vector-dimension mismatch.
    func embed(_ texts: [String]) async throws -> [[Float]]
}
