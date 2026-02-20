// ShareViewController.swift
// Cortex Share Extension
//
// Accepts URLs shared from any app (Safari, Mail, Messages, etc.)
// Shows a minimal confirmation UI, then posts to CaptureService via
// DistributedNotificationCenter.
//
// In Xcode: set this as NSExtensionPrincipalClass in the Share Extension's
// Info.plist. NSExtensionActivationRule should include NSExtensionActivationSupportsWebURLWithMaxCount.

import AppKit
import SwiftUI
import os.log

final class ShareViewController: NSViewController {

    private let logger = Logger(subsystem: "io.bdcllc.cortex.share", category: "ShareViewController")
    private static let captureNotificationName = NSNotification.Name("io.bdcllc.cortex.capture")

    // MARK: - View Loading

    override func loadView() {
        // Start with a minimal frame — we'll size it after content loads
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 130))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        extractURLFromInput()
    }

    // MARK: - Input Processing

    private func extractURLFromInput() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else {
            cancel(with: ShareExtensionError.noContent)
            return
        }

        let attachments = extensionItem.attachments ?? []

        // Try URL type first, then fall back to plain text (some apps share URLs as strings)
        let urlTypeIdentifiers = ["public.url", "public.plain-text"]

        for typeId in urlTypeIdentifiers {
            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(typeId) {
                    attachment.loadItem(forTypeIdentifier: typeId) { [weak self] item, error in
                        guard let self else { return }

                        if let error {
                            self.logger.error("Failed to load attachment: \(error)")
                            DispatchQueue.main.async { self.cancel(with: error) }
                            return
                        }

                        let url: URL?
                        switch item {
                        case let u as URL:    url = u
                        case let s as String: url = URL(string: s)
                        default:              url = nil
                        }

                        guard let resolvedURL = url, resolvedURL.scheme?.hasPrefix("http") == true else {
                            DispatchQueue.main.async {
                                self.cancel(with: ShareExtensionError.invalidURL)
                            }
                            return
                        }

                        let title = extensionItem.attributedTitle?.string
                            ?? extensionItem.attributedContentText?.string

                        DispatchQueue.main.async {
                            self.presentConfirmation(url: resolvedURL, title: title)
                        }
                    }
                    return
                }
            }
        }

        cancel(with: ShareExtensionError.noURL)
    }

    // MARK: - Confirmation UI

    private func presentConfirmation(url: URL, title: String?) {
        let hostingView = NSHostingView(
            rootView: ShareConfirmationView(
                url: url.absoluteString,
                title: title,
                onSave: { [weak self] in self?.save(url: url, title: title) },
                onCancel: { [weak self] in self?.cancel(with: ShareExtensionError.cancelled) }
            )
        )

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Save / Cancel

    private func save(url: URL, title: String?) {
        logger.info("Share: saving \(url.absoluteString)")

        var notifInfo: [String: Any] = [
            "url":    url.absoluteString,
            "source": "share_sheet",
        ]
        if let title { notifInfo["title"] = title }

        DistributedNotificationCenter.default().postNotificationName(
            Self.captureNotificationName,
            object: nil,
            userInfo: notifInfo,
            deliverImmediately: true
        )

        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel(with error: Error? = nil) {
        if let error {
            extensionContext?.cancelRequest(withError: error)
        } else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}

// MARK: - ShareConfirmationView

private struct ShareConfirmationView: View {

    let url: String
    let title: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(
                            colors: [Color(hex: "#7B2FBE"), Color(hex: "#E91E8C")],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.white)
                        .font(.system(size: 14))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Save to Cortex")
                        .font(.headline)
                    Text(title ?? URL(string: url)?.host ?? url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            Text(url)
                .font(.caption2)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#7B2FBE"))
            }
        }
        .padding(16)
    }
}

// MARK: - Errors

enum ShareExtensionError: LocalizedError {
    case noContent, noURL, invalidURL, cancelled

    var errorDescription: String? {
        switch self {
        case .noContent:  return "No content found to share"
        case .noURL:      return "No URL found in shared content"
        case .invalidURL: return "Shared content is not a valid URL"
        case .cancelled:  return "Share cancelled"
        }
    }
}

// MARK: - Extensions (Share Extension-specific)

extension Color {
    /// Initialize from a hex string like "#7B2FBE"
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

