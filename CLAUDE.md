# Cortex — Agent Context

## Project
Native macOS personal knowledge agent. Swift/SwiftUI, macOS 26.2+, local-first.
Bundle ID: io.bdcllc.cortex

## Targets
- Cortex (main app)
- CortexSafariExtension (io.bdcllc.cortex.safari)
- CortexShareExtension (io.bdcllc.cortex.share)

## Hard Rules
- ALL database writes go through CaptureService in the main app only
- NEVER write to SQLite from an extension process
- Events table is append-only — NEVER update or delete event rows
- Use GRDB for ALL database access — no raw SQLite calls ever
- IPC between extensions and main app: DistributedNotificationCenter only
- Notification name: "io.bdcllc.cortex.capture"
- App Group: group.io.bdcllc.cortex

## Architecture
CaptureService.swift is the single intake point for all captured items.
It listens for the capture notification and writes Item + CortexEvent to GRDB.
After capture, TitleFetcher runs inline (no LLM), then ExtractionQueue picks up
for Gemini Flash extraction + NLEmbedding vector generation + connection discovery.

## Phase Status
- Phase 1 complete — capture pipeline, Safari/Share extensions, full UI (delete, star, priority, Add URL, Enter-to-open, sidebar filtering)
- Phase 2 complete — Gemini Flash extraction (REST), NLEmbedding vectors, semantic search, batch ExtractionQueue
- Phase 3 complete — Connections (auto-linking by embedding similarity), Projects (user-created groups)
- Phase 4 next — Tasks, Synthesis (2–6 AM window), MCP integration

# currentDate
Today's date is 2026-02-22.

---

## Session Handoff — 2026-02-22
**Thread:** Cortex Architecture 5.0 → next: 6.0

### State
Phase 3 fully complete and building clean. Phase 3A (Connections) and Phase 3B (Projects) both implemented end-to-end. A local commit was initiated at session end — verify it landed and push to GitHub at the start of the next session before any new work.

**Phase 3A — Connections:** v4 DB migration → `ItemConnection` model → `ConnectionDiscoveryService` actor → wired into `ExtractionQueue` after embed step → "Connected" sidebar filter → "Show Related Items" context menu (populates existing search results UI).

**Phase 3B — Projects:** v5 DB migration → `Project` + `ProjectItem` models → Projects sidebar section with "+" create button → project creation sheet → "Add to Project" context submenu → "Remove from Project" (shown only when viewing a project filter) → project item list via JOIN query.

**Build:** Clean. Swift 6 strict concurrency issues were hit and resolved in `ConnectionDiscoveryService` (see Key Context).

### Standing Preferences (Permanent)
- **Every prompt labeled with WHERE**: `[ANTIGRAVITY]` / `[XCODE]` / `[MANUAL]`
- **[PROMPT N] format**: AntiGravity echoes label at start of response
- **Terminator line**: "Do NOT make any other changes. Only modify the specified lines/files." on every prompt
- **Workflow**: Cowork writes prompts → User feeds to AntiGravity → AntiGravity edits files → Xcode Cmd+R
- Cowork does NOT write code directly. AntiGravity does.
- **Direct folder access**: Cowork reads live project files directly — no diagnostic prompts needed
- **Git**: AntiGravity commits via Source Control sidebar (not terminal)

### Key Decisions (This Session)

- **Connection threshold: 0.7** — Tighter than search's 0.3. Only genuinely similar items get linked. Brute-force cosine similarity over all embeddings (same pattern as search). Fine for hundreds of items.

- **Dedup in Swift, not SQL** — No UNIQUE constraint on `connections` table. Swift loads existing pairs before insert, skips known pairs. `try/catch` around each insert handles any race conditions gracefully.

- **No payload on connection events** — `CortexEvent` calls for `connectionFound` and `connectionDismissed` omit `payload:`. Removing `[String: Any]` was required to fix Swift 6 concurrency errors (see Key Context). The connection record itself holds all the data.

- **Item status NOT changed when added to project** — The `ItemStatus` pipeline (pending → indexed → enriched) is orthogonal to organizational/UI concepts. Adding to a project does not mutate `item.status`. Querying uses JOIN on `project_items`.

- **No event logging for add/remove from project** — Kept simple. `project_items` table is the source of truth. Event logging for project membership deferred to Phase 4 if needed.

- **`ProjectItem` uses `PersistableRecord` not `MutablePersistableRecord`** — Composite primary key `(project_id, item_id)`, no auto-increment rowID to capture via `didInsert`.

- **"Show Related Items" reuses search results UI** — `loadRelatedItems(for:)` populates `searchResults` and sets `searchText = "Related: [title]"`. The existing search results list branch handles display. X button clears it identically to clearing a search.

- **Sidebar filter clears search state** — Added `searchText = ""; searchResults = []` to `onChange(of: selectedFilter)` handler. Prevents stale search/related results showing when switching filters.

### Key Context

**Swift 6 Concurrency Issues — Hit and Resolved in ConnectionDiscoveryService:**

Three errors, all in the write loop inside `discoverConnections`:

1. "Mutation of captured var 'connection'" + "Reference to captured var 'connection'" — `var connection = ItemConnection(...)` declared outside the `db.write` closure, then mutated inside via `insert` (calls `didInsert` → sets `id`). **Fix:** Move `ItemConnection` creation inside the closure as a local `var conn`.

2. "Call to main actor-isolated initializer in a synchronous nonisolated context" — `CortexEvent.init(payload: [String: Any]?)` inside a synchronous `db.write` closure. `Any` is not `Sendable`. **Fix:** Remove `payload:` from both `CortexEvent` calls in this file.

**Rule:** Inside `DatabaseQueue.write { db in ... }` (synchronous, nonisolated): (a) create all mutable GRDB records locally inside the closure, never capturing external `var` structs; (b) don't pass `[String: Any]` to `CortexEvent.init`. This constraint applies to `ConnectionDiscoveryService` only — `MainWindowViewModel` calls are `@MainActor` async and are fine with payload.

**P5 Regression Pattern — AntiGravity partial execution:** Prompt 5 specified two deliverables (v5 migration + `Project.swift`). AntiGravity did the migration but silently skipped the file. Symptom: 5 cascading errors ("Cannot find type 'Project' in scope", "SidebarFilter does not conform to Hashable/Equatable"). When a prompt specifies multiple files, always verify all were created/modified before building.

**Database Schema — 5 Migrations:**
- v1: items (18 cols), tags, item_tags, events (append-only)
- v2: `priority` column on items (default: "normal")
- v3: `item_embeddings` (item_id FK, vector_blob BLOB, model_version, created_at; unique index on item_id)
- v4: `connections` (id, item_id_a, item_id_b, similarity_score DOUBLE, dismissed BOOL default false, discovered_at; indexes on item_id_a and item_id_b)
- v5: `projects` (id autoincrement, name TEXT, created_at) + `project_items` (project_id FK CASCADE, item_id FK CASCADE, added_at; composite PK; index on item_id)

**Idempotency keys:**
- `"connection_found_{min(itemIdA,itemIdB)}_{max(itemIdA,itemIdB)}"` — direction-independent
- `"connection_dismissed_{connectionId}"`
- project events: auto-generated by CortexEvent init

### Next Steps
1. **Push Phase 3 to GitHub** — verify local commit exists, then push `origin/main`
2. **Search threshold tuning** — `performSearch()` in `MainWindowView` hardcodes `0.3`. With small corpus returns everything. Options: raise to `0.5`, cap at top 5, or make dynamic (items within 0.1 of top score). Single-file change.
3. **Settings UX** — `SettingsView.swift` Gemini API key `SecureField` has no explicit Save/Done button. Add one.
4. **Phase 4: Tasks** — new `tasks` table, task proposal UI, accept/dismiss workflow
5. **Phase 4: Synthesis** — 2–6 AM synthesis window background job
6. **Phase 5: MCP integration**

### Key Files

```
Cortex/
├── CLAUDE.md                              ← THIS FILE ← START HERE
├── session-handoff-cortex-architecture-4.0.md ← prior session reference
├── Cortex.xcodeproj/                      ← Xcode 16 folder-based (objectVersion 77)
├── Cortex/
│   ├── App/
│   │   ├── AppDelegate.swift              ← Menu bar, popover, Settings window, ExtractionQueue launch
│   │   └── CaptureService.swift           ← Single intake, IPC listener, TitleFetcher + ExtractionQueue trigger
│   ├── Database/
│   │   └── DatabaseManager.swift          ← GRDB setup, migrations v1–v5, App Group path
│   ├── Models/
│   │   ├── Connection.swift               ← ItemConnection GRDB record; active(for:) query ← NEW Phase 3
│   │   ├── Event.swift                    ← CortexEvent, CortexEventType (22 types), CortexEventSource
│   │   ├── Item.swift                     ← Item, ItemStatus (8 states), SourcePlatform, ItemPriority
│   │   ├── Project.swift                  ← Project + ProjectItem GRDB records ← NEW Phase 3
│   │   └── Tag.swift                      ← Tag model (not yet used in UI)
│   ├── Services/
│   │   ├── ConnectionDiscoveryService.swift ← Phase 3A: actor, threshold 0.7, discoverConnections + dismissConnection ← NEW
│   │   ├── EmbeddingService.swift         ← Phase 2: NLEmbedding 512-dim, cosine similarity
│   │   ├── ExtractionQueue.swift          ← Phase 2+3: batch processor; Step 4 triggers ConnectionDiscovery
│   │   ├── GeminiService.swift            ← Phase 2: Gemini 2.0 Flash REST
│   │   └── TitleFetcher.swift             ← Phase 1: inline HTML scrape
│   ├── Views/
│   │   ├── MainWindow/
│   │   │   ├── MainWindowView.swift       ← Full UI + ViewModel; Phase 3 adds Connected/Project filters, all context menus
│   │   │   └── SharedViewComponents.swift ← StatusDot, platform icons, status colors, Color(hex:)
│   │   ├── MenuBar/
│   │   │   └── MenuBarView.swift          ← Menu bar popover
│   │   └── SettingsView.swift             ← TabView: Gemini API key + About (needs Save/Done button)
│   ├── ContentView.swift                  ← Unused
│   └── CortexApp.swift                    ← @main, WindowGroup only
├── CortexSafariExtension/                 ← Safari web extension
└── CortexShareExtension/                  ← Share sheet extension
```

### Files Changed This Session

| File | Change | Why |
|------|--------|-----|
| `Database/DatabaseManager.swift` | v4 migration: connections table + indexes | Phase 3A schema |
| `Database/DatabaseManager.swift` | v5 migration: projects + project_items tables | Phase 3B schema |
| `Models/Connection.swift` | **Created** | ItemConnection GRDB record |
| `Models/Project.swift` | **Created** | Project + ProjectItem GRDB records |
| `Services/ConnectionDiscoveryService.swift` | **Created** | Embedding similarity discovery actor |
| `Services/ConnectionDiscoveryService.swift` | Swift 6 fix: move struct init inside closure, remove payload | Resolved Sendable/mutation errors |
| `Services/ExtractionQueue.swift` | Added Step 4: trigger ConnectionDiscoveryService after embed | Wire Phase 3A into pipeline |
| `Views/MainWindow/MainWindowView.swift` | SidebarFilter.connected + .project(Project) cases | Phase 3 filters |
| `Views/MainWindow/MainWindowView.swift` | loadRelatedItems(for:), Projects sidebar, create sheet, Add/Remove to Project, context menus | Full Phase 3 UI |
| `Views/MainWindow/MainWindowView.swift` | Clear search state on filter change | Bug fix |

---

## Prior Sessions (Compressed)

**Cortex Architecture 4.0 (2026-02-22):** Phase 2 built and pushed. Gemini Flash extraction via direct REST (URLSession, no SDK). NLEmbedding 512-dim vectors (Core ML MiniLM deferred — coremltools incompatible with torch 2.10.0, fix: pin torch==2.7.0 if quality insufficient). Settings window as manual NSWindow (SwiftUI Settings scene broken with .accessory policy). Semantic search bar working end-to-end. DB at 3 migrations. Full handoff: `session-handoff-cortex-architecture-4.0.md`.

**Cortex Architecture 3.0 (2026-02-21):** Phase 1 polish complete. TitleFetcher written. Delete, star, Add URL, priority, Enter-to-open, Settings all working. TitleFetcher target membership was false alarm — folder-based project auto-includes all files. Pushed to GitHub (commit 461fa9f).

**Cortex Architecture 2.0 (2026-02-20):** Phase 1 built and running. All three targets compile. Seed files written and dragged into Xcode.

**Cortex Architecture 1.0 (2026-02-20):** Architecture designed, locked at v1.2. Seven agents, Events append-only, 2–6 AM synthesis window. Full spec: `AI Learning/Cortex_Architecture_v1.md`.

**Nexus Framework Build 2.0 (2026-02-19):** Separate BDC consulting product. T1 palette: `#0A0A0A` bg / `#7B2FBE` purple / `#E91E8C` pink. Do NOT use teal or amber.
