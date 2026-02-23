// SettingsView.swift
// Cortex — Personal Knowledge Agent
//
// Settings dialog. Accessed via right-click on menu bar icon → Settings…

import SwiftUI

struct SettingsView: View {

    @AppStorage("geminiAPIKey") private var geminiAPIKey: String = ""
    @State private var keyVisible: Bool = false
    @State private var saved: Bool = false
    @State private var lastRun: CortexSynthesisRun? = nil
    @State private var isSynthesizing: Bool = false

    var body: some View {
        TabView {
            geminiTab
                .tabItem {
                    Label("Gemini", systemImage: "sparkle")
                }
            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
            synthesisTab
                .tabItem {
                    Label("Synthesis", systemImage: "wand.and.stars")
                }
        }
        .frame(width: 450, height: 220)
    }

    private var geminiTab: some View {
        Form {
            HStack {
                if keyVisible {
                    TextField("API Key", text: $geminiAPIKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField("API Key", text: $geminiAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                Button(keyVisible ? "Hide" : "Show") {
                    keyVisible.toggle()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
            }
            Text("Get a key at aistudio.google.com/apikey")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Spacer()
                Button(saved ? "Saved ✓" : "Save") {
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        saved = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(geminiAPIKey.isEmpty)
            }
        }

        .formStyle(.grouped)
        .padding()
    }

    private var aboutTab: some View {
        Form {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            LabeledContent("Database", value: (try? DatabaseManager.databaseFileURL().path) ?? "—")
        }
        .formStyle(.grouped)
        .padding()
    }

    private var synthesisTab: some View {
        Form {
            LabeledContent("Last Run") {
                if let run = lastRun {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(run.startedAt.formatted(.relative(presentation: .named)))
                        Text(run.status.capitalized)
                            .font(.caption)
                            .foregroundColor(run.status == "completed" ? .green : .secondary)
                    }
                } else {
                    Text("Never")
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Spacer()
                Button(isSynthesizing ? "Running…" : "Run Now") {
                    isSynthesizing = true
                    Task {
                        await SynthesisService.shared.runSynthesis()
                        if let db = DatabaseManager.shared.dbQueue {
                            lastRun = try? await db.read { db in
                                try CortexSynthesisRun.latest.fetchOne(db)
                            }
                        }
                        isSynthesizing = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSynthesizing)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            Task {
                if let db = DatabaseManager.shared.dbQueue {
                    lastRun = try? await db.read { db in
                        try CortexSynthesisRun.latest.fetchOne(db)
                    }
                }
            }
        }
    }
}
