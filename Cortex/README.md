# Cortex — Phase 1 Build Guide

Architecture: v1.2 (locked). Local-first, subscription-first, no API key needed for Phase 1.

---

## Prerequisites

- Xcode 16+
- macOS 14+ target device
- Apple Developer account (for extension signing + App Groups)

---

## Step 1: Create the Xcode Project

1. Open Xcode → **Create New Project**
2. Choose **macOS → App**
3. Settings:
   - Product Name: `Cortex`
   - Bundle ID: `io.bdcllc.cortex`
   - Language: Swift
   - Interface: SwiftUI
   - Uncheck "Include Tests" (add later)
4. Save to a location of your choice (separate from this `AI Learning/` folder)
5. Delete the default `ContentView.swift` and `CortexApp.swift` — you'll replace them with the files here

---

## Step 2: Add Safari Web Extension Target

1. **File → New → Target**
2. Choose **Safari Web Extension**
3. Settings:
   - Product Name: `CortexSafariExtension`
   - Bundle ID: `io.bdcllc.cortex.safari`
4. When Xcode asks "Activate scheme?", click **Activate**
5. Delete the template JS/HTML files Xcode created in the extension's `Resources/` folder
6. Copy in the files from `SafariExtension/Resources/`:
   - `manifest.json`
   - `content.js`
   - `background.js`
   - `popup.html`
   - `popup.js`
7. Replace the template `SafariWebExtensionHandler.swift` with `SafariExtension/SafariWebExtensionHandler.swift`

---

## Step 3: Add Share Extension Target

1. **File → New → Target**
2. Choose **Share Extension**
3. Settings:
   - Product Name: `CortexShareExtension`
   - Bundle ID: `io.bdcllc.cortex.share`
4. Replace the template `ShareViewController.swift` with `ShareExtension/ShareViewController.swift`
5. Update the Share Extension's `Info.plist`:
   - Set `NSExtensionActivationRule` to:
     ```xml
     <key>NSExtensionActivationRule</key>
     <dict>
       <key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
       <integer>1</integer>
     </dict>
     ```

---

## Step 4: Add Source Files to Main App Target

Copy all files from `App/`, `Database/`, `Models/`, and `Views/` into your Xcode project, making sure they are added to the **Cortex** target (the main app).

File → Add Files to "Cortex" → select the folders → check "Add to targets: Cortex".

---

## Step 5: Add Swift Package Dependencies

**File → Add Package Dependencies…**

Add these packages:

| Package | URL | Version |
|---------|-----|---------|
| GRDB.swift | `https://github.com/groue/GRDB.swift` | `from: "6.29.3"` |
| SwiftSoup | `https://github.com/scinfu/SwiftSoup` | `from: "2.7.0"` |

Add **GRDB** to targets: `Cortex`, `CortexSafariExtension`, `CortexShareExtension`
Add **SwiftSoup** to target: `Cortex` only (extraction is in the main app)

---

## Step 6: Configure App Groups

App Groups allow the extensions to communicate with the main app via DistributedNotificationCenter.

For each target (Cortex, CortexSafariExtension, CortexShareExtension):
1. Select target → **Signing & Capabilities** → **+ Capability** → **App Groups**
2. Add group: `group.io.bdcllc.cortex`

This entitlement is required for DistributedNotificationCenter to deliver across process boundaries in the sandbox.

---

## Step 7: Configure Entitlements

Main app `Cortex.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.io.bdcllc.cortex</string>
    </array>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
</plist>
```

Safari Extension `CortexSafariExtension.entitlements`:
```xml
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.io.bdcllc.cortex</string>
    </array>
</dict>
```

---

## Step 8: Enable Safari Extension in Safari

1. Build and run the Cortex app (`Cmd+R`)
2. Open **Safari → Preferences → Extensions**
3. Enable **Cortex**
4. Grant permissions: "Allow on All Websites" (needed for content.js on Twitter/Reddit)

---

## Step 9: Verify Phase 1 Ship Criteria

The v0.1 ship gate: **capture a link from Safari or Share Sheet and see it in the app**.

Test checklist:
- [ ] Menu bar icon appears in macOS menu bar
- [ ] Click icon → popover opens with quick capture field
- [ ] Paste a URL in popover → item appears in list
- [ ] Safari Extension button visible in toolbar
- [ ] Click extension on any webpage → item captured
- [ ] Click extension on twitter.com → platform badge shows "Twitter/X"
- [ ] Click extension on reddit.com → platform badge shows "Reddit"
- [ ] Share a URL from any app → confirmation UI → item saved
- [ ] Open Cortex full window → items visible with status, timestamp, platform

---

## Architecture Notes

### Communication Flow

```
Safari Extension (JS)
  └─ background.js
       └─ browser.runtime.sendNativeMessage()
            └─ SafariWebExtensionHandler.swift (extension process)
                 └─ DistributedNotificationCenter
                      └─ CaptureService.swift (main app process)
                           └─ DatabaseManager → SQLite

Share Extension
  └─ ShareViewController.swift (extension process)
       └─ DistributedNotificationCenter
            └─ CaptureService.swift (main app)
```

### Database Location

Shared App Group container: `~/Library/Group Containers/group.io.bdcllc.cortex/cortex.sqlite`

Falls back to `~/Library/Application Support/Cortex/cortex.sqlite` if App Groups not configured (development only).

### Core ML Decision (locked v1.2)

Local embeddings (Phase 2) use **Core ML** — not ONNX Runtime.

Rationale: Native macOS framework, ANE acceleration on Apple Silicon, no SPM dependency, `.mlpackage` bundles cleanly into Xcode.

Conversion (run once before Phase 2):
```bash
pip install coremltools transformers torch
python Scripts/convert_minilm_to_coreml.py
```

Output: `MiniLM-L6-v2.mlpackage` → add to Xcode project → add to Cortex target only.

---

## File Map

```
Cortex/
├── README.md                          ← this file
├── App/
│   ├── CortexApp.swift                → main app entry, @main
│   ├── AppDelegate.swift              → menu bar, NSStatusItem, popover
│   └── CaptureService.swift           → notification bridge + SQLite writes
├── Database/
│   └── DatabaseManager.swift         → GRDB setup, migrations
├── Models/
│   ├── Item.swift                     → items table + GRDB conformance
│   ├── Event.swift                    → events table (truth layer)
│   └── Tag.swift                      → tags + item_tags tables
├── Views/
│   ├── MenuBar/
│   │   └── MenuBarView.swift          → popover UI + quick capture
│   └── MainWindow/
│       └── MainWindowView.swift       → full window: list + sidebar
├── SafariExtension/
│   ├── SafariWebExtensionHandler.swift → NSExtensionRequestHandling
│   └── Resources/
│       ├── manifest.json
│       ├── content.js                 → Twitter/Reddit DOM scraping
│       ├── background.js              → capture orchestration + queue
│       ├── popup.html
│       └── popup.js
└── ShareExtension/
    └── ShareViewController.swift      → macOS Share Sheet handler
```

---

## Next: Phase 2

- Gemini Flash integration (summarization + insight extraction)
- Core ML MiniLM embeddings + sqlite-vss
- Full-text + semantic search
- Item detail view (summary, key insights, topics)
- Global hotkey Cmd+Shift+K (Spotlight-style search)
