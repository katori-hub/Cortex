// GeminiService.swift
// Cortex — Personal Knowledge Agent
//
// Direct REST client for Gemini 2.0 Flash.
// Extracts structured content from captured items.
// No SDK dependency — just URLSession + JSON.

import Foundation
import os.log

// MARK: - ExtractionResult

struct ExtractionResult: Sendable {
    let summary: String?
    let keyInsights: [String]
    let topics: [String]
    let contentQuality: Double?
}

// MARK: - GeminiService

actor GeminiService {

    static let shared = GeminiService()

    private let logger = Logger(subsystem: "io.bdcllc.cortex", category: "GeminiService")
    private let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    func extract(title: String?, url: String, rawText: String?) async throws -> ExtractionResult {
        let apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            throw GeminiError.noAPIKey
        }

        let prompt = buildPrompt(title: title, url: url, rawText: rawText)
        let responseText = try await call(prompt: prompt, apiKey: apiKey)
        return parse(responseText)
    }

    // MARK: - REST Call

    private func call(prompt: String, apiKey: String) async throws -> String {
        guard var urlComponents = URLComponents(string: endpoint) else {
            throw GeminiError.invalidEndpoint
        }
        urlComponents.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = urlComponents.url else {
            throw GeminiError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 1024
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 429:
            throw GeminiError.rateLimited
        case 401, 403:
            throw GeminiError.authenticationFailed
        default:
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            logger.error("[Gemini] HTTP \(httpResponse.statusCode): \(body)")
            throw GeminiError.httpError(statusCode: httpResponse.statusCode)
        }

        // Parse Gemini response JSON
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String
        else {
            throw GeminiError.malformedResponse
        }

        return text
    }

    // MARK: - Prompt

    private func buildPrompt(title: String?, url: String, rawText: String?) -> String {
        let content = rawText ?? title ?? url
        return """
        Analyze this web content and return ONLY valid JSON (no markdown fencing, no explanation).

        URL: \(url)
        Title: \(title ?? "(none)")
        Content: \(String(content.prefix(4000)))

        Return this exact JSON structure:
        {
          "summary": "2-3 sentence summary of the content",
          "key_insights": ["insight 1", "insight 2", "insight 3"],
          "topics": ["topic1", "topic2", "topic3"],
          "content_quality": 0.0 to 1.0
        }

        Rules:
        - summary: concise, factual, no fluff
        - key_insights: 2-5 specific takeaways, not generic
        - topics: 2-5 lowercase single-word or hyphenated tags
        - content_quality: 0.0 = spam/empty, 1.0 = exceptional original content
        """
    }

    // MARK: - Parse

    private func parse(_ text: String) -> ExtractionResult {
        // Strip markdown code fences if Gemini includes them despite instructions
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            logger.warning("[Gemini] Failed to parse response as JSON")
            return ExtractionResult(summary: nil, keyInsights: [], topics: [], contentQuality: nil)
        }

        return ExtractionResult(
            summary: json["summary"] as? String,
            keyInsights: json["key_insights"] as? [String] ?? [],
            topics: json["topics"] as? [String] ?? [],
            contentQuality: json["content_quality"] as? Double
        )
    }
}

// MARK: - Errors

enum GeminiError: LocalizedError {
    case noAPIKey
    case invalidEndpoint
    case invalidResponse
    case rateLimited
    case authenticationFailed
    case httpError(statusCode: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:              return "No Gemini API key configured. Add one in Settings."
        case .invalidEndpoint:       return "Invalid Gemini API endpoint."
        case .invalidResponse:       return "Invalid response from Gemini API."
        case .rateLimited:           return "Gemini API rate limit reached. Will retry later."
        case .authenticationFailed:  return "Gemini API key is invalid or expired."
        case .httpError(let code):   return "Gemini API returned HTTP \(code)."
        case .malformedResponse:     return "Could not parse Gemini API response."
        }
    }
}
