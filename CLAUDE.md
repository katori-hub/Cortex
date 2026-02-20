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

## Phase Status
Phase 1 complete (capture pipeline working).
Phase 2 next: Gemini Flash extraction, Core ML MiniLM embeddings, vector search.
