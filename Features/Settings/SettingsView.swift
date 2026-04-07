import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("AI Provider") {
                TextField("Provider", text: $settings.aiProviderName)
            }
            Section("Shortcut") {
                TextField("Hotkey", text: $settings.shortcutDisplay)
                Text("MVP defaults to Cmd + Shift + Space to avoid replacing Spotlight in development.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Auto-run safe actions", isOn: $settings.autoRunSafeActions)
                Toggle("Show recent commands", isOn: $settings.showRecentCommands)
            }
            Section("Search scope") {
                Toggle("Desktop", isOn: $settings.searchDesktop)
                Toggle("Documents", isOn: $settings.searchDocuments)
                Toggle("Downloads", isOn: $settings.searchDownloads)
            }
            Section("Permissions") {
                Text("Accessibility: required for global shortcuts and automation.")
                Text("Calendar, Mail, Notes: integration stubs in MVP.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
