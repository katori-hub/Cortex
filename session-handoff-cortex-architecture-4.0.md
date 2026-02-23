# Session Handoff — Cortex Architecture 4.0
**Date:** 2026-02-22
**Thread:** Cortex Architecture 4.0 → next: 5.0
**GitHub:** `https://github.com/katori-hub/Cortex.git` (private, username: katori-hub)

---

## State

Phase 1 and Phase 2 both complete, tested, and pushed to GitHub (`origin/main`).

**Phase 1 (complete):** Capture pipeline via Safari extension, Share sheet, and manual Add URL (⌘N). Full UI: sidebar filtering (All Items, Unread, Starred, Platform), item list with swipe-to-delete, hover trash icon, keyboard Delete with confirmation alert, star toggle overlay, right-click Set Priority submenu (high/normal/low), Enter key opens URL in browser and marks as read. Menu bar accessory with popover. Settings via right-click → Settings…

**Phase 2 (complete):** Gemini Flash extraction via direct REST, NLEmbedding 512-dim sentence vectors, semantic search bar in toolbar. ExtractionQueue batch processor runs on app launch (5s delay) and after each capture. Tested end-to-end: Paul Graham essay captured → TitleFetcher scraped → Gemini extracted summary/insights/topics/quality → NLEmbedding generated vector → search query "essays about doing great work" returned correct item ranked #1.

**Two commits on main:**
1. `461fa9f` — Phase 1 polish
2. Phase 2 commit — Gemini + embeddings + search

---

## Decisions Made

### This Session

1. **Xcode 16 folder-based project (verified)**
   - `objectVersion = 77`, `fileSystemSynchronizedGroups` in pbxproj
   - All `.swift` files under target directories are automatically compiled
   - Empty `PBXSourcesBuildPhase` arrays are NORMAL — do NOT manually add files
   - Previous session's diagnosis of "TitleFetcher not in Xcode target" was **wrong**
   - Implication: never waste time on target membership — just put files in the right directory

2. **Gemini Flash via direct REST (URLSession) — not Google AI Swift SDK**
   - Endpoint: `generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent`
   - API key as query parameter
   - Why: zero extra SPM dependencies, simple extraction use case, URLSession already used everywhere
   - Alternatives rejected: Google AI Swift SDK (adds dependency, SDK is young, transitive deps)

3. **NLEmbedding — not Core ML MiniLM**
   - `NaturalLanguage.NLEmbedding.sentenceEmbedding(for: .english)`, 512-dim vectors
   - Zero model files, zero dependencies, ships with macOS
   - Why: Core ML conversion failed — torch 2.10.0 incompatible with coremltools (max tested: 2.7.0)
   - Error: `TypeError: only 0-dimensional arrays can be converted to Python scalars` + `libcoremlpython` not found
   - Could retry with `pip install torch==2.7.0` if NLEmbedding quality proves insufficient
   - Long-term: Core ML MiniLM still intended (ANE-accelerated, better benchmarks)

4. **Settings window as manual NSWindow**
   - SwiftUI `Settings { }` scene doesn't work with `.accessory` activation policy
   - Fixed by removing Settings scene from CortexApp, creating NSWindow + NSHostingController in AppDelegate
   - Backlog: needs explicit Save/Done button UX for API key field

5. **Search threshold at 0.3**
   - Returns all 3 items with current small corpus (everything scores > 0.3)
   - Will need tuning or dynamic threshold as item count grows

### Carried From Prior Sessions

6. **Core ML (not ONNX Runtime)** for MiniLM when we revisit — native, ANE-accelerated, no extra SPM dep
7. **macOS 26.2 (Tahoe)** — real deployment target, not a bug
8. **GRDB 7.10.0** — no raw SQLite ever, events append-only
9. **DistributedNotificationCenter IPC** — notification: `"io.bdcllc.cortex.capture"`
10. **App Group**: `group.io.bdcllc.cortex`
11. **Two-tier extraction**: TitleFetcher (inline, no LLM) → Gemini Flash (batch)
12. **Settings access**: right-click menu bar icon → Settings… (not Cmd+,)
13. **GitHub**: `https://github.com/katori-hub/Cortex.git` (private, katori-hub)

---

## Next Steps

1. **Phase 3: Connections** — auto-link related items based on embedding similarity. New `connections` table, connection discovery job that runs after embedding. UI to show/dismiss connections.
2. **Phase 3: Projects** — user-created groups of items. New `projects` and `project_items` tables. UI for creating/managing projects.
3. **Tune search threshold** — dynamic threshold or result limiting as corpus grows
4. **Settings UX** — Save/Done button for API key field
5. **Phase 4: Tasks** — from architecture spec
6. **Phase 4: Synthesis** — 2-6 AM synthesis window
7. **Phase 5: MCP integration**

---

## Key Context

### Pipeline Flow
```
Capture (Safari/Share/Manual)
  → CaptureService writes Item + CortexEvent to GRDB
  → TitleFetcher (async, inline HTML scrape, no LLM)
  → Item status: pending → indexed
  → ExtractionQueue picks up .indexed items
  → Gemini Flash extracts summary, key_insights, topics, content_quality
  → NLEmbedding generates 512-dim vector
  → Writes to item_embeddings table (BLOB)
  → Item status: indexed → enriched
  → Events logged: item_extracted, item_embedded
```

### Database Schema (3 migrations)
- **v1**: items (18 columns), tags, item_tags, events (append-only)
- **v2**: added `priority` column to items (default: "normal")
- **v3**: added `item_embeddings` table (item_id FK, vector_blob BLOB, model_version, created_at; unique index on item_id)

### Embedding Storage
- `[Float]` arrays serialized to `Data` via `withUnsafeBufferPointer`
- Stored as BLOB in `item_embeddings.vector_blob`
- Deserialized via `bindMemory(to: Float.self)`
- All vectors L2-normalized → dot product = cosine similarity

### Search Implementation
- Brute-force: load all vectors, score each against query vector
- Filter: similarity > 0.3 threshold
- Return: top 20 sorted by score descending
- Scalability: fine for hundreds; needs FAISS/Annoy for thousands

### ExtractionQueue Rate Limiting
- 4-second delay between items (15 RPM Gemini Flash free tier)
- On HTTP 429: pause 60 seconds
- On no API key: stop entirely
- Runs on app launch (5s delay) and after each capture

### GeminiService Prompt
- Instructs Gemini to return raw JSON (no markdown fencing)
- Caps content at 4000 characters
- Requests: summary (2-3 sentences), key_insights (2-5), topics (2-5 tags), content_quality (0.0-1.0)
- Parser strips ```json fences defensively

### Approach Tried and Failed
- **Core ML MiniLM conversion**: Python script with coremltools + transformers + torch
- torch 2.10.0 untested with coremltools (max: 2.7.0)
- Errors: `TypeError: only 0-dimensional arrays can be converted to Python scalars`, `libcoremlpython` module not found
- Fix: pin `torch==2.7.0` and retry. Not attempted — NLEmbedding was sufficient.

### False Alarm from Session 3.0
- "TitleFetcher.swift not added to Xcode target" was wrong
- Folder-based project auto-includes all .swift files
- "All Items not clickable" was already fixed (`.tag()` reorder)
- "Delete button gone" was already wired (swipe + hover + keyboard)

---

## Workspace Structure

```
Cortex/
├── CLAUDE.md                              ← Agent context + handoff history ← START HERE
├── session-handoff-cortex-architecture-4.0.md ← THIS FILE
├── Cortex.xcodeproj/                      ← Xcode 16 folder-based (objectVersion 77)
├── Cortex/                                ← Main app target
│   ├── App/
│   │   ├── AppDelegate.swift              ← Menu bar, popover, Settings window, ExtractionQueue launch
│   │   └── CaptureService.swift           ← Single intake, IPC listener, triggers TitleFetcher + ExtractionQueue
│   ├── Database/
│   │   └── DatabaseManager.swift          ← GRDB setup, migrations v1-v3, App Group path
│   ├── Models/
│   │   ├── Event.swift                    ← CortexEvent, CortexEventType (22 types), CortexEventSource
│   │   ├── Item.swift                     ← Item, ItemStatus (8 states), SourcePlatform (5), ItemPriority (3)
│   │   └── Tag.swift                      ← Tag model (exists, not yet used in UI)
│   ├── Services/
│   │   ├── TitleFetcher.swift             ← Phase 1: inline HTML scrape (actor, URLSession, regex parsing)
│   │   ├── GeminiService.swift            ← Phase 2: REST client, Gemini 2.0 Flash (actor, 7 error types)
│   │   ├── EmbeddingService.swift         ← Phase 2: NLEmbedding 512-dim vectors (actor, cosine sim)
│   │   └── ExtractionQueue.swift          ← Phase 2: batch processor, rate-limited (actor)
│   ├── Views/
│   │   ├── MainWindow/
│   │   │   ├── MainWindowView.swift       ← Full UI + MainWindowViewModel (load, delete, star, priority, addURL, openAndMarkRead, search)
│   │   │   └── SharedViewComponents.swift ← StatusDot, platform icons, status colors, Color(hex:)
│   │   ├── MenuBar/
│   │   │   └── MenuBarView.swift          ← Menu bar popover
│   │   └── SettingsView.swift             ← TabView: Gemini API key + About
│   ├── ContentView.swift                  ← Unused (MainWindowView is root)
│   ├── CortexApp.swift                    ← @main, WindowGroup only
│   └── Assets.xcassets/
├── CortexSafariExtension/
│   ├── SafariWebExtensionHandler.swift
│   └── Resources/ (manifest.json, background.js, content.js, popup.html, popup.js)
├── CortexShareExtension/
│   ├── ShareViewController.swift
│   └── Info.plist
└── README.md
```

---

## Standing Preferences (Permanent — carry to all future sessions)

- **Every prompt labeled with WHERE**: `[ANTIGRAVITY]` / `[XCODE]` / `[MANUAL]`
- **[PROMPT N] format**: AntiGravity echoes label at start of response
- **Terminator line**: "Do NOT make any other changes. Only modify the specified lines/files." on every prompt
- **Workflow**: Cowork writes prompts → User feeds to AntiGravity → AntiGravity edits files → Xcode Cmd+R
- Cowork does NOT write code directly. AntiGravity does.
- **Direct folder access**: Cowork reads live project files — no diagnostic prompts
- Git operations via AntiGravity's Source Control sidebar (not terminal)
