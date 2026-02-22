// SettingsView.swift
// Cortex — Personal Knowledge Agent
//
// Settings dialog. Accessed via right-click on menu bar icon → Settings…

import SwiftUI

struct SettingsView: View {

    @AppStorage("geminiAPIKey") private var geminiAPIKey: String = ""
    @State private var keyVisible: Bool = false

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
        }
        .frame(width: 450, height: 200)
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
}
