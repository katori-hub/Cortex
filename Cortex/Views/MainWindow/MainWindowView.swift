// MainWindowView.swift
// Cortex — Personal Knowledge Agent
//
// Full application window. Phase 1: simple list view with sidebar.
// No intelligence yet — just shows captured items with status.

import SwiftUI
import GRDB
import Combine

struct MainWindowView: View {

    @EnvironmentObject private var captureService: CaptureService
    @StateObject private var viewModel = MainWindowViewModel()
    @State private var selectedItem: Item? = nil
    @State private var selectedFilter: SidebarFilter = .all
    @State private var itemPendingDelete: Item? = nil
    @State private var showDeleteConfirmation: Bool = false
    @State private var hoveredItem: Item? = nil
    @State private var showAddURL: Bool = false
    @State private var newURL: String = ""
    @State private var searchText: String = ""
    @State private var searchResults: [Item] = []
    @State private var isSearching: Bool = false
    @State private var showCreateProject: Bool = false
    @State private var newProjectName: String = ""
    @State private var showAddTask: Bool = false
    @State private var newTaskTitle: String = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if case .tasks = selectedFilter {
                taskList
            } else {
                itemList
            }
        }
        .navigationTitle("Cortex")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { Task { await viewModel.refresh() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showAddURL = true }) {
                    Image(systemName: "plus")
                }
                .help("Add URL (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Text("\(viewModel.filteredItems.count) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Semantic search…", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                        .onSubmit { performSearch() }
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
        }
        .onAppear {
            Task {
                await viewModel.load(filter: selectedFilter)
                await viewModel.loadProjects()
                await viewModel.loadTasks()
            }
        }
        .onChange(of: selectedFilter) { oldValue, newValue in
            searchText = ""
            searchResults = []
            Task { await viewModel.load(filter: newValue) }
        }
        .onChange(of: captureService.totalCount) {
            // Refresh when new items arrive via extension
            Task { await viewModel.load(filter: selectedFilter) }
        }
        .alert("Delete this item?", isPresented: $showDeleteConfirmation, presenting: itemPendingDelete) { item in
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteItem(item)
                    if selectedItem == item { selectedItem = nil }
                }
            }
            Button("Cancel", role: .cancel) { itemPendingDelete = nil }
        } message: { _ in
            Text("This cannot be undone.")
        }
        .sheet(isPresented: $showAddURL, onDismiss: { newURL = "" }) {
            VStack(spacing: 16) {
                Text("Add URL")
                    .font(.headline)
                TextField("https://", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
                    .onSubmit { submitURL() }
                HStack {
                    Button("Cancel") { showAddURL = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Add") { submitURL() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        Task {
            defer { isSearching = false }

            guard let queryVector = await EmbeddingService.shared.embed(text: query),
                  let db = DatabaseManager.shared.dbQueue
            else {
                searchResults = []
                return
            }

            do {
                let rows = try await db.read { db -> [(itemId: Int64, vector: Data)] in
                    let rows = try Row.fetchAll(db, sql: "SELECT item_id, vector_blob FROM item_embeddings")
                    return rows.map { (itemId: $0["item_id"] as Int64, vector: $0["vector_blob"] as Data) }
                }

                var scored: [(id: Int64, score: Float)] = []
                for row in rows {
                    let itemVector = await EmbeddingService.shared.vectorFromData(row.vector)
                    let score = await EmbeddingService.shared.cosineSimilarity(queryVector, itemVector)
                    if score > 0.5 {
                        scored.append((id: row.itemId, score: score))
                    }
                }
                scored.sort { $0.score > $1.score }

                let topIds = scored.prefix(10).map { $0.id }
                guard !topIds.isEmpty else {
                    searchResults = []
                    return
                }

                let items = try await db.read { db -> [Item] in
                    try Item.filter(keys: topIds).fetchAll(db)
                }

                let itemDict = Dictionary(uniqueKeysWithValues: items.compactMap { item in
                    item.id.map { ($0, item) }
                })
                searchResults = topIds.compactMap { itemDict[$0] }
            } catch {
                print("[Cortex] Search failed: \(error)")
                searchResults = []
            }
        }
    }

    private func submitURL() {
        let trimmed = newURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        showAddURL = false
        newURL = ""
        Task { await viewModel.addURL(trimmed) }
    }

    private func loadRelatedItems(for item: Item) {
        guard let itemId = item.id else { return }
        isSearching = true
        searchText = "Related: \(item.displayTitle)"
        Task {
            defer { isSearching = false }
            guard let db = DatabaseManager.shared.dbQueue else {
                searchResults = []
                return
            }
            do {
                let connections = try await db.read { db in
                    try ItemConnection.active(for: itemId).fetchAll(db)
                }
                let relatedIds = connections.map { $0.itemIdA == itemId ? $0.itemIdB : $0.itemIdA }
                guard !relatedIds.isEmpty else {
                    searchResults = []
                    return
                }
                let items = try await db.read { db in
                    try Item.filter(keys: relatedIds).fetchAll(db)
                }
                let itemMap = Dictionary(
                    uniqueKeysWithValues: items.compactMap { item -> (Int64, Item)? in
                        guard let id = item.id else { return nil }
                        return (id, item)
                    }
                )
                searchResults = relatedIds.compactMap { itemMap[$0] }
            } catch {
                print("[Cortex] loadRelatedItems failed: \(error)")
                searchResults = []
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedFilter) {
            Section("Library") {
                ForEach(SidebarFilter.allCases) { filter in
                    sidebarRow(for: filter)
                }
            }

            Section("Platforms") {
                ForEach(SourcePlatform.allCases, id: \.rawValue) { platform in
                    platformRow(for: platform)
                }
            }

            Section {
                ForEach(viewModel.projects) { project in
                    projectRow(for: project)
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button(action: { showCreateProject = true }) {
                        Image(systemName: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("New Project")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Cortex")
        .sheet(isPresented: $showCreateProject, onDismiss: { newProjectName = "" }) {
            VStack(spacing: 16) {
                Text("New Project")
                    .font(.headline)
                TextField("Project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { submitProject() }
                HStack {
                    Button("Cancel") { showCreateProject = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") { submitProject() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
    }

    private func projectRow(for project: Project) -> some View {
        Label(project.name, systemImage: "folder")
            .tag(SidebarFilter.project(project))
    }

    private func submitProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        showCreateProject = false
        newProjectName = ""
        Task { await viewModel.createProject(name: name) }
    }
    
    @ViewBuilder
    private func sidebarRow(for filter: SidebarFilter) -> some View {
        if filter == .all {
            Label(filter.title, systemImage: filter.icon)
                .badge(viewModel.totalCount)
                .tag(filter)
        } else {
            Label(filter.title, systemImage: filter.icon)
                .tag(filter)
        }
    }
    
    private func platformRow(for platform: SourcePlatform) -> some View {
        Label(platform.rawValue.capitalized, systemImage: platform.systemImage)
            .tag(SidebarFilter.platform(platform))
    }

    // MARK: - Item List

    @ViewBuilder
    private var itemList: some View {
        if !searchResults.isEmpty {
            List(searchResults, selection: $selectedItem) { item in
                ItemRow(item: item)
                    .tag(item)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 6) {
                            Button {
                                Task { await viewModel.toggleStar(item) }
                            } label: {
                                Image(systemName: item.starred ? "star.fill" : "star")
                                    .font(.system(size: 11))
                                    .foregroundColor(item.starred ? .yellow : .secondary.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.trailing, 12)
                    }
            }
            .onKeyPress(.return) {
                if let item = selectedItem {
                    Task { await viewModel.openAndMarkRead(item) }
                    return .handled
                }
                return .ignored
            }
            .listStyle(.inset)
        } else if viewModel.isLoading {
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredItems.isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "tray",
                description: Text(emptyDescription)
            )
        } else {
            List(viewModel.filteredItems, selection: $selectedItem) { item in
                ItemRow(item: item)
                    .tag(item)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            itemPendingDelete = item
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 6) {
                            Button {
                                Task { await viewModel.toggleStar(item) }
                            } label: {
                                Image(systemName: item.starred ? "star.fill" : "star")
                                    .font(.system(size: 11))
                                    .foregroundColor(item.starred ? .yellow : .secondary.opacity(0.4))
                            }
                            .buttonStyle(.plain)

                            if hoveredItem?.id == item.id {
                                Button {
                                    itemPendingDelete = item
                                    showDeleteConfirmation = true
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.trailing, 12)
                    }
                    .onHover { isHovered in
                        hoveredItem = isHovered ? item : nil
                    }
                    .contextMenu {
                        Button("Show Related Items") {
                            loadRelatedItems(for: item)
                        }
                        Divider()
                        if case .project(let currentProject) = selectedFilter {
                            Button("Remove from \(currentProject.name)") {
                                Task { await viewModel.removeFromProject(currentProject, item: item) }
                            }
                            Divider()
                        }
                        if !viewModel.projects.isEmpty {
                            Menu("Add to Project") {
                                ForEach(viewModel.projects) { project in
                                    Button(project.name) {
                                        Task { await viewModel.addToProject(project, item: item) }
                                    }
                                }
                            }
                            Divider()
                        }
                        Menu("Set Priority") {
                            ForEach(ItemPriority.allCases, id: \.self) { priority in
                                Button {
                                    Task { await viewModel.setPriority(priority, for: item) }
                                } label: {
                                    Label(
                                        priority.label + (item.priority == priority ? " ✓" : ""),
                                        systemImage: priority.systemImage
                                    )
                                }
                            }
                        }
                    }
            }
            .onDeleteCommand {
                if let item = selectedItem {
                    itemPendingDelete = item
                    showDeleteConfirmation = true
                }
            }
            .onKeyPress(.return) {
                if let item = selectedItem {
                    Task { await viewModel.openAndMarkRead(item) }
                    return .handled
                }
                return .ignored
            }
            .listStyle(.inset)
        }
    }

    private var emptyTitle: String {
        selectedFilter == .all ? "No items yet" : "No \(selectedFilter.title.lowercased())"
    }

    private var emptyDescription: String {
        selectedFilter == .all
            ? "Capture links from Safari using the Cortex extension, or paste a URL in the menu bar."
            : "Items matching this filter will appear here."
    }

    // MARK: - Task List

    @ViewBuilder
    private var taskList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tasks")
                    .font(.headline)
                Spacer()
                Button("Add Task") { showAddTask = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if viewModel.tasks.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No tasks")
                        .font(.headline)
                    Text("Add a task manually, or accept AI-proposed tasks.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List(viewModel.tasks) { task in
                    TaskRow(
                        task: task,
                        onAccept:   { Task { await viewModel.acceptTask(task) } },
                        onDismiss:  { Task { await viewModel.dismissTask(task) } },
                        onComplete: { Task { await viewModel.completeTask(task) } }
                    )
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showAddTask, onDismiss: { newTaskTitle = "" }) {
            VStack(spacing: 16) {
                Text("New Task")
                    .font(.headline)
                TextField("Task title", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { submitTask() }
                HStack {
                    Button("Cancel") { showAddTask = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Add") { submitTask() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
    }

    private func submitTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        showAddTask = false
        newTaskTitle = ""
        Task { await viewModel.addTask(title: title) }
    }

// MARK: - ItemRow

private struct ItemRow: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            platformBadge
            content
            Spacer()
            meta
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open in Browser") {
                if let url = URL(string: item.url) { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
        }
    }

    private var platformBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
                .frame(width: 34, height: 34)
            Image(systemName: item.resolvedSourcePlatform.systemImage)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayTitle)
                .font(.headline)
                .lineLimit(2)

            Text(item.url)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                StatusPill(status: item.status)

                if let platform = item.sourcePlatform, platform != "web" {
                    Pill(text: platform, color: .purple)
                }
            }
        }
    }

    private var meta: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(item.capturedAt.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
    }
}

// MARK: - Status Pill

private struct StatusPill: View {
    let status: ItemStatus

    var body: some View {
        HStack(spacing: 4) {
            StatusDot(status: status)
            Text(status.rawValue)
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.1))
        .cornerRadius(4)
    }
}

private struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.1))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

// MARK: - TaskRow

private struct TaskRow: View {
    let task: CortexTask
    let onAccept:   () -> Void
    let onDismiss:  () -> Void
    let onComplete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.body)
                    .strikethrough(task.status == .completed)
                    .foregroundColor(task.status == .completed ? .secondary : .primary)
                if task.status == .proposed {
                    Text("Proposed")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }
            }
            Spacer()
            if task.status == .proposed {
                Button("Accept") { onAccept() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.secondary)
            } else if task.status == .active {
                Button { onComplete() } label: {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
                .help("Mark complete")
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.vertical, 4)
        .opacity(task.status == .completed || task.status == .dismissed ? 0.5 : 1.0)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .proposed:
            Image(systemName: "clock.badge.questionmark").foregroundColor(.orange)
        case .active:
            Image(systemName: "circle").foregroundColor(.blue)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .dismissed:
            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
        }
    }
}

// MARK: - SidebarFilter

enum SidebarFilter: Hashable, Identifiable, CaseIterable {
    case all
    case unread
    case starred
    case connected
    case tasks
    case platform(SourcePlatform)
    case project(Project)

    static var allCases: [SidebarFilter] = [.all, .unread, .starred, .connected, .tasks]

    var id: String {
        switch self {
        case .all:             return "all"
        case .unread:          return "unread"
        case .starred:         return "starred"
        case .connected:       return "connected"
        case .tasks:           return "tasks"
        case .platform(let p): return "platform_\(p.rawValue)"
        case .project(let p):  return "project_\(p.id.map(String.init) ?? "new")"
        }
    }

    var title: String {
        switch self {
        case .all:             return "All Items"
        case .unread:          return "Unread"
        case .starred:         return "Starred"
        case .connected:       return "Connected"
        case .tasks:           return "Tasks"
        case .platform(let p): return p.rawValue.capitalized
        case .project(let p):  return p.name
        }
    }

    var icon: String {
        switch self {
        case .all:             return "tray.full"
        case .unread:          return "circle"
        case .starred:         return "star"
        case .connected:       return "link"
        case .tasks:           return "checkmark.circle"
        case .platform(let p): return p.systemImage
        case .project:         return "folder"
        }
    }
}

// MARK: - MainWindowViewModel

@MainActor
final class MainWindowViewModel: ObservableObject {
    @Published var filteredItems: [Item] = []
    @Published var totalCount: Int = 0
    @Published var isLoading: Bool = false
    @Published var projects: [Project] = []
    @Published var tasks: [CortexTask] = []
    private var currentFilter: SidebarFilter = .all

    func loadProjects() async {
        guard let db = DatabaseManager.shared.dbQueue else { return }
        do {
            projects = try await db.read { db in
                try Project.allByName.fetchAll(db)
            }
        } catch {
            print("[Cortex] loadProjects failed: \(error)")
        }
    }

    func createProject(name: String) async {
        guard let db = DatabaseManager.shared.dbQueue else { return }
        var project = Project(name: name)
        do {
            try await db.write { db in
                try project.insert(db)
                var event = CortexEvent(
                    eventType: .projectCreated,
                    entityType: "project",
                    entityId: project.id,
                    payload: ["name": project.name],
                    source: .user
                )
                try event.insert(db, onConflict: .ignore)
            }
            await loadProjects()
        } catch {
            print("[Cortex] createProject failed: \(error)")
        }
    }

    func addToProject(_ project: Project, item: Item) async {
        guard let projectId = project.id,
              let itemId = item.id,
              let db = DatabaseManager.shared.dbQueue else { return }
        let projectItem = ProjectItem(projectId: projectId, itemId: itemId)
        do {
            try await db.write { db in
                try projectItem.insert(db)
            }
        } catch {
            // Composite PK — silently ignore if item already in project
            print("[Cortex] addToProject skipped (already exists): \(error)")
        }
    }

    func removeFromProject(_ project: Project, item: Item) async {
        guard let projectId = project.id,
              let itemId = item.id,
              let db = DatabaseManager.shared.dbQueue else { return }
        do {
            try await db.write { db in
                try db.execute(
                    sql: "DELETE FROM project_items WHERE project_id = ? AND item_id = ?",
                    arguments: [projectId, itemId]
                )
            }
            await load(filter: currentFilter)
        } catch {
            print("[Cortex] removeFromProject failed: \(error)")
        }
    }

    func load(filter: SidebarFilter) async {
        currentFilter = filter
        guard let db = DatabaseManager.shared.dbQueue else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            async let items = db.read { db -> [Item] in
                switch filter {
                case .all:
                    return try Item.allByDate.fetchAll(db)
                case .unread:
                    return try Item.unread.fetchAll(db)
                case .starred:
                    return try Item.starred.fetchAll(db)
                case .connected:
                    return try Item.fetchAll(
                        db,
                        sql: """
                            SELECT DISTINCT items.* FROM items
                            INNER JOIN connections
                                ON (connections.item_id_a = items.id OR connections.item_id_b = items.id)
                            WHERE connections.dismissed = 0
                            ORDER BY items.captured_at DESC
                            """
                    )
                case .platform(let p):
                    return try Item
                        .filter(Item.Columns.sourcePlatform == p.rawValue)
                        .order(Item.Columns.capturedAt.desc)
                        .fetchAll(db)
                case .project(let p):
                    guard let projectId = p.id else { return [] }
                    return try Item.fetchAll(
                        db,
                        sql: """
                            SELECT items.* FROM items
                            INNER JOIN project_items ON project_items.item_id = items.id
                            WHERE project_items.project_id = ?
                            ORDER BY project_items.added_at DESC
                            """,
                        arguments: [projectId]
                    )
                case .tasks:
                    // Tasks view doesn't show items, return empty
                    return []
                }
            }
            async let count = db.read { try Item.fetchCount($0) }

            let (fetched, total) = try await (items, count)
            filteredItems = fetched
            totalCount = total
        } catch {
            print("MainWindowViewModel load error: \(error)")
        }
    }

    func refresh() async {
        // Re-run whatever filter is active — caller passes current filter
        // This no-arg version just refreshes totalCount
        guard let db = DatabaseManager.shared.dbQueue else { return }
        do {
            totalCount = try await db.read { try Item.fetchCount($0) }
        } catch { }
    }

    func deleteItem(_ item: Item) async {
        guard let db = DatabaseManager.shared.dbQueue else { return }
        do {
            try await db.write { db in
                _ = try item.delete(db)
            }
            filteredItems.removeAll { $0.id == item.id }
            totalCount = max(0, totalCount - 1)
        } catch {
            print("MainWindowViewModel deleteItem error: \(error)")
        }
    }

    func toggleStar(_ item: Item) async {
        var updated = item
        updated.starred = !item.starred
        do {
            try await DatabaseManager.shared.dbQueue.write { [updated] db in
                try updated.update(db)
            }
            if let index = filteredItems.firstIndex(where: { $0.id == item.id }) {
                filteredItems[index] = updated
            }
        } catch {
            print("[Cortex] toggleStar failed: \(error)")
        }
    }

    func setPriority(_ priority: ItemPriority, for item: Item) async {
        var updated = item
        updated.priority = priority
        do {
            try await DatabaseManager.shared.dbQueue.write { [updated] db in
                try updated.update(db)
            }
            if let index = filteredItems.firstIndex(where: { $0.id == item.id }) {
                filteredItems[index] = updated
            }
        } catch {
            print("[Cortex] setPriority failed: \(error)")
        }
    }

    func addURL(_ urlString: String) async {
        guard URL(string: urlString) != nil else { return }
        var item = Item(url: urlString)
        do {
            try await DatabaseManager.shared.dbQueue.write { [item] db in
                var mutableItem = item
                try mutableItem.insert(db)
            }
            await load(filter: currentFilter)
        } catch {
            print("[Cortex] addURL failed: \(error)")
        }
    }

    func openAndMarkRead(_ item: Item) async {
        if let url = URL(string: item.url) {
            NSWorkspace.shared.open(url)
        }
        guard !item.readByUser else { return }
        var updated = item
        updated.readByUser = true
        do {
            try await DatabaseManager.shared.dbQueue.write { [updated] db in
                try updated.update(db)
            }
            if let index = filteredItems.firstIndex(where: { $0.id == item.id }) {
                filteredItems[index] = updated
            }
        } catch {
            print("[Cortex] openAndMarkRead failed: \(error)")
        }
    }

    // MARK: - Tasks

    func loadTasks() async {
        guard let db = DatabaseManager.shared.dbQueue else { return }
        do {
            tasks = try await db.read { db in
                try CortexTask.pending.fetchAll(db)
            }
        } catch {
            print("[Cortex] loadTasks error: \(error)")
        }
    }

    func addTask(title: String) async {
        guard let db = DatabaseManager.shared.dbQueue else { return }
        do {
            try await db.write { db in
                var task = CortexTask(title: title, status: .active)
                try task.insert(db)
                var event = CortexEvent(
                    eventType: .taskAccepted,
                    entityType: "task",
                    entityId: task.id,
                    source: .user,
                    idempotencyKey: "task_created_\(UUID().uuidString)"
                )
                try event.insert(db, onConflict: .ignore)
            }
            await loadTasks()
        } catch {
            print("[Cortex] addTask error: \(error)")
        }
    }

    func acceptTask(_ task: CortexTask) async {
        guard let taskId = task.id else { return }
        await updateTaskStatus(task, to: .active, eventType: .taskAccepted,
                               key: "task_accepted_\(taskId)")
    }

    func dismissTask(_ task: CortexTask) async {
        guard let taskId = task.id else { return }
        await updateTaskStatus(task, to: .dismissed, eventType: .taskDismissed,
                               key: "task_dismissed_\(taskId)")
    }

    func completeTask(_ task: CortexTask) async {
        guard let taskId = task.id else { return }
        await updateTaskStatus(task, to: .completed, eventType: .taskCompleted,
                               key: "task_completed_\(taskId)")
    }

    private func updateTaskStatus(_ task: CortexTask, to newStatus: TaskStatus,
                                  eventType: CortexEventType, key: String) async {
        guard let db = DatabaseManager.shared.dbQueue, let taskId = task.id else { return }
        do {
            try await db.write { [task, newStatus, key, eventType] db in
                var updated = task
                updated.status = newStatus
                updated.updatedAt = Date()
                try updated.update(db)
                var event = CortexEvent(
                    eventType: eventType,
                    entityType: "task",
                    entityId: taskId,
                    source: .user,
                    idempotencyKey: key
                )
                try event.insert(db, onConflict: .ignore)
            }
            tasks.removeAll { $0.id == taskId }
        } catch {
            print("[Cortex] updateTaskStatus error: \(error)")
        }
    }
}

}


