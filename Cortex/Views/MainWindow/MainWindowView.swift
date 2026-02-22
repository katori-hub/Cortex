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

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            itemList
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
            Task { await viewModel.load(filter: selectedFilter) }
        }
        .onChange(of: selectedFilter) { oldValue, newValue in
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
                    if score > 0.3 {
                        scored.append((id: row.itemId, score: score))
                    }
                }
                scored.sort { $0.score > $1.score }

                let topIds = scored.prefix(20).map { $0.id }
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
        }
        .listStyle(.sidebar)
        .navigationTitle("Cortex")
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

// MARK: - SidebarFilter

enum SidebarFilter: Hashable, Identifiable, CaseIterable {
    case all
    case unread
    case starred
    case platform(SourcePlatform)

    static var allCases: [SidebarFilter] = [.all, .unread, .starred]

    var id: String {
        switch self {
        case .all:           return "all"
        case .unread:        return "unread"
        case .starred:       return "starred"
        case .platform(let p): return "platform_\(p.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .all:           return "All Items"
        case .unread:        return "Unread"
        case .starred:       return "Starred"
        case .platform(let p): return p.rawValue.capitalized
        }
    }

    var icon: String {
        switch self {
        case .all:           return "tray.full"
        case .unread:        return "circle"
        case .starred:       return "star"
        case .platform(let p): return p.systemImage
        }
    }
}

// MARK: - MainWindowViewModel

@MainActor
final class MainWindowViewModel: ObservableObject {
    @Published var filteredItems: [Item] = []
    @Published var totalCount: Int = 0
    @Published var isLoading: Bool = false
    private var currentFilter: SidebarFilter = .all

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
                case .platform(let p):
                    return try Item
                        .filter(Item.Columns.sourcePlatform == p.rawValue)
                        .order(Item.Columns.capturedAt.desc)
                        .fetchAll(db)
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
}


