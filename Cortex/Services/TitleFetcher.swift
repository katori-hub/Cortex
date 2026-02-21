// TitleFetcher.swift
// Cortex — Personal Knowledge Agent
//
// Lightweight inline title/description extractor.
// Runs at capture time — no LLM, no API cost.
// Phase 2 (Gemini Flash) will upgrade items to full extraction.

import Foundation
import os.log

struct TitleFetchResult {
    let title: String?
    let description: String?
}

actor TitleFetcher {

    static let shared = TitleFetcher()
    private let logger = Logger(subsystem: "io.bdcllc.cortex", category: "TitleFetcher")
    private init() {}

    func fetch(urlString: String) async -> TitleFetchResult {
        guard let url = URL(string: urlString) else {
            return TitleFetchResult(title: nil, description: nil)
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            return parse(html: html)
        } catch {
            logger.warning("[TitleFetcher] Fetch failed for \(urlString): \(error.localizedDescription)")
            return TitleFetchResult(title: nil, description: nil)
        }
    }

    // MARK: - Parsing

    private func parse(html: String) -> TitleFetchResult {
        let title = extractBetweenTags(open: "<title", close: "</title>", in: html)
        let description = extractMeta(name: "description", in: html)
            ?? extractMeta(property: "og:description", in: html)
        return TitleFetchResult(
            title: title.flatMap { clean($0) },
            description: description.flatMap { clean($0) }
        )
    }

    private func extractBetweenTags(open: String, close: String, in html: String) -> String? {
        let lower = html.lowercased()
        guard let start = lower.range(of: open),
              let closeTag = lower.range(of: ">", range: start.upperBound..<lower.endIndex),
              let end = lower.range(of: close, range: closeTag.upperBound..<lower.endIndex)
        else { return nil }
        return String(html[closeTag.upperBound..<end.lowerBound])
    }

    private func extractMeta(name: String, in html: String) -> String? {
        extractMetaContent(matching: "name=[\"']\(name)[\"']", in: html)
    }

    private func extractMeta(property: String, in html: String) -> String? {
        extractMetaContent(matching: "property=[\"']\(property)[\"']", in: html)
    }

    private func extractMetaContent(matching attribute: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<meta[^>]+\(attribute)[^>]+content=[\"']([^\"']+)[\"'][^>]*>",
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let captureRange = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[captureRange])
    }

    private func clean(_ text: String) -> String? {
        let decoded = text
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let result = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}
