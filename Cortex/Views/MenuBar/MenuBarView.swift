// MenuBarView.swift
// Cortex — Personal Knowledge Agent
//
// The primary persistent UI — lives in the menu bar popover.
// 380px wide, compact, keyboard-driven.

import SwiftUI

struct MenuBarView: View {
    let onOpen: () -> Void
    init(onOpen: @escaping () -> Void = {}) { self.onOpen = onOpen }

    @EnvironmentObject private var captureService: CaptureService
    @State private var captureText: String = ""
    @State private var captureError: String? = nil
    @State private var isCapturing: Bool = false
    @FocusState private var captureFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            quickCapture
            Divider()
            recentList
            Divider()
            footer
        }
        .frame(width: 380)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: "#7B2FBE"), Color(hex: "#E91E8C")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text("Cortex")
                .font(.headline)
            Spacer()
            Button("Open") {
                onOpen()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Quick Capture

    private var quickCapture: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                TextField("Paste URL to save…", text: $captureText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($captureFieldFocused)
                    .onSubmit { submitCapture() }

                if isCapturing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 18, height: 18)
                } else {
                    Button(action: submitCapture) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(captureText.isEmpty
                                ? AnyShapeStyle(Color.secondary)
                                : AnyShapeStyle(LinearGradient(
                                    colors: [Color(hex: "#7B2FBE"), Color(hex: "#E91E8C")],
                                    startPoint: .leading, endPoint: .trailing)))
                    }
                    .buttonStyle(.plain)
                    .disabled(captureText.isEmpty)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            if let error = captureError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.15), value: captureError)
    }

    // MARK: - Recent List

    @ViewBuilder
    private var recentList: some View {
        if captureService.recentItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text("No items yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Capture links from Safari or paste a URL above")
                    .font(.caption)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(captureService.recentItems) { item in
                        MenuBarItemRow(item: item)
                        if item.id != captureService.recentItems.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text("\(captureService.totalCount) items")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func submitCapture() {
        let urlString = captureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty else { return }

        // Basic URL validation
        guard let _ = URL(string: urlString), urlString.hasPrefix("http") else {
            captureError = "Enter a valid URL starting with http:// or https://"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { captureError = nil }
            return
        }

        captureError = nil
        isCapturing = true
        let text = captureText
        captureText = ""

        Task {
            await captureService.capture(url: text, title: nil, source: .menuBar)
            isCapturing = false
        }
    }
}

// MARK: - MenuBarItemRow

private struct MenuBarItemRow: View {

    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            platformIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 6) {
                    StatusDot(status: item.status)
                    Text(item.status.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(item.capturedAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open URL") {
                if let url = URL(string: item.url) {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
        }
    }

    private var platformIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
                .frame(width: 28, height: 28)
            Image(systemName: item.resolvedSourcePlatform.systemImage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}


