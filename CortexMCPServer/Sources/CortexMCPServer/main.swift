// main.swift — CortexMCP Server
// Cortex — Personal Knowledge Agent
//
// Standalone MCP server over stdio. No SPM dependencies — uses system SQLite3.
// Build: swift build (from CortexMCPServer/)
// Configure in Claude Desktop's mcpServers config pointing to the compiled binary.
//
// Env: CORTEX_DB_PATH — override the SQLite path (default: ~/Library/Application Support/Cortex/cortex.sqlite)

import Foundation
import SQLite3

// MARK: - DB Path

let dbPath: String = {
    if let custom = ProcessInfo.processInfo.environment["CORTEX_DB_PATH"] { return custom }
    let home = ProcessInfo.processInfo.environment["HOME"] ?? "~"
    return "\(home)/Library/Application Support/Cortex/cortex.sqlite"
}()

var db: OpaquePointer?
sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)

// MARK: - SQLite Helper

func sqlRows(_ sql: String, bind: [String] = []) -> [[String: Any]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    for (i, s) in bind.enumerated() {
        sqlite3_bind_text(stmt, Int32(i + 1), (s as NSString).utf8String, -1, nil)
    }
    var rows: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [String: Any] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            let col = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_TEXT:    row[col] = String(cString: sqlite3_column_text(stmt, i))
            case SQLITE_INTEGER: row[col] = sqlite3_column_int64(stmt, i)
            case SQLITE_FLOAT:   row[col] = sqlite3_column_double(stmt, i)
            default: break
            }
        }
        rows.append(row)
    }
    return rows
}

// MARK: - Tool Schemas

let tools: [[String: Any]] = [
    [
        "name": "list_recent",
        "description": "List recently captured items from the Cortex knowledge base.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "limit": ["type": "integer", "description": "Number of items to return (default 10, max 50)"]
            ]
        ]
    ],
    [
        "name": "search_items",
        "description": "Search Cortex items by keyword across title, summary, and topics.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "query": ["type": "string", "description": "Search keyword or phrase"]
            ],
            "required": ["query"]
        ]
    ],
    [
        "name": "capture_url",
        "description": "Capture a URL into the Cortex knowledge base. Requires the Cortex app to be running.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "url":   ["type": "string", "description": "URL to capture (must start with http/https)"],
                "title": ["type": "string", "description": "Optional title override"]
            ],
            "required": ["url"]
        ]
    ],
    [
        "name": "get_tasks",
        "description": "Get tasks from Cortex. Returns proposed and active tasks by default.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "status": ["type": "string", "description": "Filter by status: proposed, active, completed, dismissed. Omit for all pending."]
            ]
        ]
    ],
    [
        "name": "list_projects",
        "description": "List all user-created projects in Cortex.",
        "inputSchema": [
            "type": "object",
            "properties": [:]
        ]
    ]
]

// MARK: - Tool Handlers

func handleListRecent(args: [String: Any]) -> String {
    let limit = min((args["limit"] as? Int) ?? 10, 50)
    let rows = sqlRows("SELECT title, url, summary, status, captured_at FROM items ORDER BY captured_at DESC LIMIT \(limit)")
    guard !rows.isEmpty else { return "No items captured yet." }
    return rows.map { row in
        let title    = row["title"]    as? String ?? "(untitled)"
        let url      = row["url"]      as? String ?? ""
        let summary  = row["summary"]  as? String ?? ""
        let status   = row["status"]   as? String ?? ""
        let captured = row["captured_at"] as? String ?? ""
        var out = "• \(title)\n  URL: \(url)\n  Status: \(status) | Captured: \(captured)"
        if !summary.isEmpty { out += "\n  \(String(summary.prefix(200)))" }
        return out
    }.joined(separator: "\n\n")
}

func handleSearchItems(args: [String: Any]) -> String {
    guard let query = args["query"] as? String else { return "Missing required argument: query" }
    let pattern = "%\(query)%"
    let rows = sqlRows(
        "SELECT title, url, summary, status FROM items WHERE title LIKE ? OR summary LIKE ? OR topics_json LIKE ? ORDER BY captured_at DESC LIMIT 20",
        bind: [pattern, pattern, pattern]
    )
    guard !rows.isEmpty else { return "No items found matching '\(query)'." }
    return rows.map { row in
        let title   = row["title"]   as? String ?? "(untitled)"
        let url     = row["url"]     as? String ?? ""
        let summary = row["summary"] as? String ?? ""
        var out = "• \(title)\n  URL: \(url)"
        if !summary.isEmpty { out += "\n  \(String(summary.prefix(200)))" }
        return out
    }.joined(separator: "\n\n")
}

func handleCaptureURL(args: [String: Any]) -> String {
    guard let url = args["url"] as? String else { return "Missing required argument: url" }
    guard url.hasPrefix("http") else { return "URL must start with http or https." }
    var userInfo: [AnyHashable: Any] = ["url": url, "source": "mcp_call"]
    if let title = args["title"] as? String { userInfo["title"] = title }
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("io.bdcllc.cortex.capture"),
        object: nil,
        userInfo: userInfo,
        deliverImmediately: true
    )
    return "Capture sent to Cortex: \(url)\nNote: Cortex app must be running to process this capture."
}

func handleGetTasks(args: [String: Any]) -> String {
    let rows: [[String: Any]]
    if let status = args["status"] as? String {
        rows = sqlRows("SELECT title, status, created_at FROM tasks WHERE status = ? ORDER BY created_at DESC", bind: [status])
    } else {
        rows = sqlRows("SELECT title, status, created_at FROM tasks WHERE status IN ('proposed','active') ORDER BY created_at DESC")
    }
    guard !rows.isEmpty else { return "No tasks found." }
    return rows.map { row in
        let title  = row["title"]  as? String ?? "(untitled)"
        let status = row["status"] as? String ?? ""
        return "• [\(status.uppercased())] \(title)"
    }.joined(separator: "\n")
}

func handleListProjects(args: [String: Any]) -> String {
    let rows = sqlRows("SELECT id, name, created_at FROM projects ORDER BY name ASC")
    guard !rows.isEmpty else { return "No projects found." }
    return rows.map { row in
        let name = row["name"] as? String ?? "(unnamed)"
        let id   = row["id"]   as? Int64  ?? 0
        return "• \(name) (id: \(id))"
    }.joined(separator: "\n")
}

// MARK: - MCP JSON-RPC

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let str  = String(data: data, encoding: .utf8) else { return }
    print(str)
    fflush(stdout)
}

func respond(id: Any, result: Any) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func handleRequest(_ raw: [String: Any]) {
    let method = raw["method"] as? String ?? ""
    guard let id = raw["id"] else { return }  // notifications have no id — no response needed

    switch method {

    case "initialize":
        respond(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "CortexMCP", "version": "1.0.0"]
        ])

    case "tools/list":
        respond(id: id, result: ["tools": tools])

    case "tools/call":
        guard let params = raw["params"] as? [String: Any],
              let name   = params["name"] as? String else {
            respond(id: id, result: ["content": [["type": "text", "text": "Invalid tools/call request."]]])
            return
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        let text: String
        switch name {
        case "list_recent":   text = handleListRecent(args: args)
        case "search_items":  text = handleSearchItems(args: args)
        case "capture_url":   text = handleCaptureURL(args: args)
        case "get_tasks":     text = handleGetTasks(args: args)
        case "list_projects": text = handleListProjects(args: args)
        default:              text = "Unknown tool: \(name)"
        }
        respond(id: id, result: ["content": [["type": "text", "text": text]]])

    default:
        respond(id: id, result: [:])
    }
}

// MARK: - Main Loop

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
          let data    = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }
    handleRequest(request)
}

sqlite3_close(db)
