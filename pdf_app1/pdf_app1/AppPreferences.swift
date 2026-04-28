import SwiftUI
import PDFKit

struct PreferencesView: View {
    @Environment(AIServiceManager.self) private var aiServiceManager

    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            DisplayPreferencesView()
                .tabItem {
                    Label("Display", systemImage: "eye")
                }

            AISettingsView(serviceManager: aiServiceManager)
                .tabItem {
                    Label("AI", systemImage: "brain")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralPreferencesView: View {
    @AppStorage("defaultZoomLevel") private var defaultZoomLevel: Double = 100
    @AppStorage("autoSaveEnabled") private var autoSaveEnabled: Bool = true
    @AppStorage("autoSaveInterval") private var autoSaveInterval: Double = 1.0

    var body: some View {
        Form {
            Section("Zoom") {
                HStack {
                    Text("Default Zoom Level")
                    Spacer()
                    TextField("", value: $defaultZoomLevel, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Text("%")
                }
            }

            Section("Auto-Save") {
                Toggle("Enable Auto-Save", isOn: $autoSaveEnabled)

                if autoSaveEnabled {
                    HStack {
                        Text("Save Interval")
                        Spacer()
                        Picker("", selection: $autoSaveInterval) {
                            Text("0.5s").tag(0.5)
                            Text("1s").tag(1.0)
                            Text("2s").tag(2.0)
                            Text("5s").tag(5.0)
                        }
                        .frame(width: 100)
                    }
                }
            }

            Section("Keyboard Shortcuts") {
                VStack(alignment: .leading, spacing: 4) {
                    shortcutRow("Open File", "T")
                    shortcutRow("Close Tab", "W")
                    shortcutRow("Save", "S")
                    shortcutRow("Save As", "S")
                    shortcutRow("Print", "P")
                    shortcutRow("Search", "F")
                    shortcutRow("Undo", "Z")
                    shortcutRow("Fullscreen", "F")
                    shortcutRow("Comparison", "D")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func shortcutRow(_ action: String, _ key: String) -> some View {
        HStack {
            Text(action)
                .font(.system(size: 12))
            Spacer()
            Text("\(key)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

struct DisplayPreferencesView: View {
    @AppStorage("defaultDisplayMode") private var defaultDisplayMode: String = "singlePageContinuous"
    @AppStorage("defaultReadingMode") private var defaultReadingMode: String = "normal"

    var body: some View {
        Form {
            Section("Display Mode") {
                Picker("Default Display Mode", selection: $defaultDisplayMode) {
                    Text("Single Page").tag("singlePage")
                    Text("Continuous").tag("singlePageContinuous")
                    Text("Two Pages").tag("twoUp")
                    Text("Two Pages Continuous").tag("twoUpContinuous")
                }
            }

            Section("Reading Mode") {
                Picker("Default Reading Mode", selection: $defaultReadingMode) {
                    Text("Normal").tag("normal")
                    Text("Sepia").tag("sepia")
                    Text("Dark").tag("dark")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
