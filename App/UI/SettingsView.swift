// App/UI/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        TabView {
            DirectoriesSettingsView(preferences: preferences)
                .tabItem { Label("Directories", systemImage: "folder") }

            AppearanceSettingsView(preferences: preferences)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }

            TerminalsSettingsView(preferences: preferences)
                .tabItem { Label("Terminals", systemImage: "terminal") }
        }
        .frame(width: 560, height: 460)
    }
}
