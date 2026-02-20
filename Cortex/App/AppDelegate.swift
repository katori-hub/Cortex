// AppDelegate.swift
// Cortex — Personal Knowledge Agent
//
// Manages the menu bar status item, popover, and app lifecycle.
// The menu bar icon is Cortex's persistent presence; the full window
// is shown on demand.

import AppKit
import SwiftUI
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Shared capture service — injected into SwiftUI environment
    let captureService = CaptureService.shared

    private let logger = Logger(subsystem: "io.bdcllc.cortex", category: "AppDelegate")

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?     // Dismiss popover on outside click

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Set up database
        do {
            try DatabaseManager.shared.setup()
            let dbPath = (try? DatabaseManager.databaseFileURL().path) ?? "(unknown)"
            logger.info("Database ready at \(dbPath)")
        } catch {
            logger.error("Database setup failed: \(error)")
            // Fatal — surface error and quit gracefully
            showDatabaseError(error)
            return
        }

        // 2. Start listening for extension captures
        captureService.startListening()

        // 3. Set up menu bar
        setupMenuBar()

        // 4. Hide dock icon — Cortex lives in the menu bar
        NSApp.setActivationPolicy(.accessory)

        logger.info("Cortex launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running when main window is closed — we live in the menu bar
        return false
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }

        // Use SF Symbol; replace with custom Cortex icon asset in production
        let image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Cortex")
        image?.isTemplate = true   // Adapts to light/dark menu bar
        button.image = image
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self

        // Popover
        let popoverContent = MenuBarView(onOpen: { [weak self] in
            self?.showMainWindow()
        })
            .environmentObject(captureService)

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 380, height: 480)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: popoverContent)
        self.popover = pop

        // Dismiss when clicking outside
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            if let popover, popover.isShown {
                closePopover()
            } else {
                openPopover()
            }
        }
    }

    private func openPopover() {
        guard let button = statusItem?.button, let popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Cortex", action: #selector(showMainWindow), keyEquivalent: "1")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cortex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil  // Reset so left-click opens popover next time
    }

    // MARK: - Main Window

    @objc func showMainWindow() {
        closePopover()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if !window.isKind(of: NSPanel.self) {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    // MARK: - Quick Actions

    func captureClipboardURL() {
        guard let string = NSPasteboard.general.string(forType: .string),
              let _ = URL(string: string),
              string.hasPrefix("http")
        else { return }

        Task {
            await captureService.capture(url: string, title: nil, source: .menuBar)
        }
    }

    // MARK: - Error Handling

    private func showDatabaseError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Cortex could not start"
        alert.informativeText = "Database initialization failed: \(error.localizedDescription)\n\nCortex will quit."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

