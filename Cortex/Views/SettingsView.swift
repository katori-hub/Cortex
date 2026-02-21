// SettingsView.swift
// Cortex — Personal Knowledge Agent

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
        }
        .frame(width: 480, height: 300)
    }
}

private struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Text("Cortex settings coming in Phase 2.")
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
