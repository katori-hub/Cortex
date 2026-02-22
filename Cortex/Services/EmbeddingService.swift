// EmbeddingService.swift
// Cortex — Personal Knowledge Agent
//
// Generates sentence embeddings using Apple's built-in NLEmbedding.
// No model files, no dependencies — ships with macOS.
// Produces 512-dim vectors for cosine similarity search.

import Foundation
import NaturalLanguage
import os.log

actor EmbeddingService {

    static let shared = EmbeddingService()

    private let logger = Logger(subsystem: "io.bdcllc.cortex", category: "EmbeddingService")
    private let embedding: NLEmbedding?

    private init() {
        embedding = NLEmbedding.sentenceEmbedding(for: .english)
        if embedding == nil {
            Logger(subsystem: "io.bdcllc.cortex", category: "EmbeddingService")
                .error("Failed to load NLEmbedding for English")
        }
    }

    /// Returns a unit-normalized embedding vector, or nil if embedding fails.
    func embed(text: String) -> [Float]? {
        guard let embedding else {
            logger.error("NLEmbedding not available")
            return nil
        }

        // NLEmbedding.vector returns [Double] — convert to [Float] for storage efficiency
        guard let vector = embedding.vector(for: text) else {
            logger.warning("Failed to embed text: \(String(text.prefix(80)))")
            return nil
        }

        // L2 normalize to unit vector for cosine similarity
        let floats = vector.map { Float($0) }
        return normalize(floats)
    }

    /// Embed and return as Data (for BLOB storage in GRDB)
    func embedAsData(text: String) -> Data? {
        guard let vector = embed(text: text) else { return nil }
        return vector.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Cosine similarity between two vectors (both must be unit-normalized)
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return dot  // Already unit vectors, so dot product = cosine similarity
    }

    /// Decode a BLOB back to a float vector
    func vectorFromData(_ data: Data) -> [Float] {
        data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    // MARK: - Internal

    private func normalize(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for v in vector { sumSquares += v * v }
        let magnitude = sqrt(sumSquares)
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }
}
