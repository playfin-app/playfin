import SwiftUI
import AppKit

/// Settings window (⌘,). The core validates and saves the settings; each change applies right away
/// (the player cache and decoding at the next playback).
struct SettingsView: View {
    var body: some View {
        TabView {
            ProfilesSettingsTab()
                .tabItem { Label("Profiles", systemImage: "person.2") }
            PlaybackSettingsTab()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            PlayerCacheSettingsTab()
                .tabItem { Label("Player cache", systemImage: "memorychip") }
            DownloadsSettingsTab()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            StorageSettingsTab()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 720, height: 620)
    }
}

private let languageChoices: [(code: String, name: String)] = [
    ("", "System language"), ("fr", "French"), ("en", "English"), ("es", "Spanish"), ("de", "German"),
    ("it", "Italian"), ("pt", "Portuguese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ("ar", "Arabic"), ("ru", "Russian"), ("tr", "Turkish")
]

// MARK: - Playback

struct PlaybackSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Preferred languages") {
                Picker("Audio", selection: $settings.values.audioLanguage) {
                    ForEach(languageChoices, id: \.code) { Text($0.name).tag($0.code) }
                }
                Picker("Subtitles", selection: $settings.values.subtitleLanguage) {
                    ForEach(languageChoices, id: \.code) { Text($0.name).tag($0.code) }
                }
            }
            Section("Navigation") {
                Picker("Skip back by", selection: $settings.values.skipBackSeconds) {
                    ForEach([5, 10, 15, 30, 60] as [UInt32], id: \.self) { Text("\($0) s").tag($0) }
                }
                Picker("Skip forward by", selection: $settings.values.skipForwardSeconds) {
                    ForEach([5, 10, 15, 30, 60] as [UInt32], id: \.self) { Text("\($0) s").tag($0) }
                }
                Toggle("Automatically play the next episode", isOn: $settings.values.autoPlayNext)
            }
            Section("Video") {
                Toggle("Hardware decoding (recommended)", isOn: $settings.values.hardwareDecoding)
                Text("Applies at the next playback.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Subtitle style") {
                Picker("Size", selection: $settings.values.subtitleSize) {
                    Text("Extra small").tag("xsmall"); Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large")
                }
                Picker("Colour", selection: $settings.values.subtitleColor) {
                    Text("White").tag("white"); Text("Yellow").tag("yellow"); Text("Green").tag("green")
                }
                Picker("Background", selection: $settings.values.subtitleBackground) {
                    Text("None").tag("none"); Text("Translucent").tag("translucent"); Text("Black").tag("black")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Player cache

struct PlayerCacheSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var customError: String?
    @State private var showsAdvanced = false

    private let presets: [(id: String, name: String)] = [
        ("low", "Low"), ("normal", "Normal"), ("high", "High"), ("custom", "Custom")
    ]

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Preset", selection: $settings.values.cachePreset) {
                    ForEach(presets, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Maximum memory") {
                    Text("≈ \(settingsCacheMemoryMib(settings: settings.values)) MiB of RAM")
                        .monospacedDigit()
                }
            } header: {
                Text("Playback cache")
            } footer: {
                Text("More cache = fewer interruptions on a slow connection, but more memory used. "
                     + "Applies at the next playback.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.values.cachePreset == "custom" {
                Section("Custom setting") {
                    CacheSlider(
                        title: "Memory ahead", value: $settings.values.customCacheMaxMib,
                        range: 16...4096, step: 16, unit: "MiB"
                    )
                    CacheSlider(
                        title: "Memory behind (quick rewind)", value: $settings.values.customCacheBackMib,
                        range: 8...2048, step: 8, unit: "MiB"
                    )
                    CacheSlider(
                        title: "Time kept ahead", value: $settings.values.customCacheSecs,
                        range: 10...3600, step: 10, unit: "s"
                    )
                    DisclosureGroup("Advanced mpv options", isExpanded: $showsAdvanced) {
                        Text("One option per line (name=value). Only cache, decoding and picture options are accepted.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $settings.values.customMpvOptions)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 90)
                            .onChange(of: settings.values.customMpvOptions) { _, text in validate(text) }
                            .onAppear { validate(settings.values.customMpvOptions) }
                        if let customError {
                            Text(customError).font(.caption).foregroundStyle(Theme.Colors.error)
                        }
                    }
                }
            }

            Section("Location") {
                Toggle("Keep the cache on disk rather than in memory", isOn: $settings.values.cacheOnDisk)
            }
        }
        .formStyle(.grouped)
    }

    private func validate(_ text: String) {
        do {
            _ = try validateCustomMpvOptions(text: text)
            customError = nil
        } catch {
            customError = model.message(for: error)
        }
    }
}

/// Slider for an integer value (MiB, seconds) with its displayed value.
private struct CacheSlider: View {
    let title: String
    @Binding var value: UInt32
    let range: ClosedRange<Double>
    let step: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(formatted).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { Double(value) }, set: { value = UInt32(($0 / step).rounded() * step) }),
                in: range
            )
        }
    }

    private var formatted: String {
        if unit == "s", value >= 60 {
            let minutes = value / 60, seconds = value % 60
            return seconds == 0 ? "\(minutes) min" : "\(minutes) min \(seconds) s"
        }
        if unit == "MiB", value >= 1024 {
            return String(format: "%.1f GiB", Double(value) / 1024)
        }
        return "\(value) \(unit)"
    }
}

// MARK: - Downloads

struct DownloadsSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Stepper(value: $settings.values.downloadConnections, in: 1...16) {
                    LabeledContent("Connections per file", value: "\(settings.values.downloadConnections)")
                }
                Stepper(value: $settings.values.downloadConcurrent, in: 1...5) {
                    LabeledContent("Simultaneous downloads", value: "\(settings.values.downloadConcurrent)")
                }
                Stepper(value: $settings.values.downloadRetries, in: 0...20) {
                    LabeledContent("Attempts before failing", value: "\(settings.values.downloadRetries)")
                }
            } header: {
                Text("Speed")
            } footer: {
                Text("On the local network, one connection is often enough. Several connections mainly help remotely.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Speed limit") {
                Toggle("Limit the speed", isOn: Binding(
                    get: { settings.values.downloadBandwidthKbps > 0 },
                    set: { settings.values.downloadBandwidthKbps = $0 ? 5120 : 0 }
                ))
                if settings.values.downloadBandwidthKbps > 0 {
                    let mbps = Double(settings.values.downloadBandwidthKbps) * 8 / 1024
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Maximum speed")
                            Spacer()
                            Text(String(format: "%.0f Mbit/s", mbps)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.values.downloadBandwidthKbps) },
                                set: { settings.values.downloadBandwidthKbps = UInt32(($0 / 128).rounded() * 128) }
                            ),
                            in: 128...51200
                        )
                    }
                }
            }

            Section("Files") {
                LabeledContent("Folder") {
                    HStack {
                        Text(folderPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                        if !settings.values.downloadFolder.isEmpty {
                            Button("Default") { settings.values.downloadFolder = "" }
                        }
                    }
                }
                Picker("Subtitles to download", selection: $settings.values.downloadSubtitles) {
                    Text("Preferred languages").tag("preferred")
                    Text("All").tag("all")
                    Text("None").tag("none")
                }
                Toggle("Delete a download once watched", isOn: $settings.values.deleteAfterWatched)
                LabeledContent("Space used") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.downloads.usedBytes), countStyle: .file))
                }
            }

            if !model.downloads.canDownload {
                Section {
                    Label("The server administrator does not allow downloads for this account.",
                          systemImage: "lock.fill")
                        .foregroundStyle(Theme.Colors.warning)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var folderPath: String {
        let values = model.settings.values
        return values.downloadFolder.isEmpty ? DownloadsModel.defaultRoot().path : values.downloadFolder
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.values.downloadFolder = url.path
        }
    }
}

// MARK: - Stockage

struct StorageSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var imageCacheBytes: Int64 = 0
    @State private var confirmation: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Images") {
                Picker("Image cache limit", selection: $settings.values.imageCacheLimitMb) {
                    ForEach([500, 1024, 2048, 5120, 10240] as [UInt32], id: \.self) { mb in
                        Text(mb >= 1024 ? "\(mb / 1024) GB" : "\(mb) MB").tag(mb)
                    }
                }
                LabeledContent("Used", value: ByteCountFormatter.string(fromByteCount: imageCacheBytes, countStyle: .file))
                Button("Clear the image cache") {
                    ImageCache.shared.clearDiskCache()
                    refresh()
                    confirmation = "Image cache cleared."
                }
            }
            Section("Downloads") {
                LabeledContent("Space used") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.downloads.usedBytes), countStyle: .file))
                }
                Button("Show downloads") {
                    model.selectedSection = .downloads
                    NSApp.keyWindow?.close()
                }
            }
            Section("Metadata") {
                Text("Movie lists, libraries and home kept so they show without waiting for the server. Downloads are never touched.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear the metadata cache") {
                    model.clearMetadataCache()
                    confirmation = "Metadata cache cleared. It will be rebuilt at the next connection to the server."
                }
                .disabled(model.client == nil)
            }
            if let confirmation {
                Text(confirmation).font(.caption).foregroundStyle(Theme.Colors.reachable)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: settings.values.imageCacheLimitMb) { _, mb in
            ImageCache.shared.applyDiskLimit(megabytes: Int(mb))
        }
    }

    private func refresh() {
        imageCacheBytes = ImageCache.shared.diskCacheSize()
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var exportMessage: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Log") {
                Picker("Level of detail", selection: $settings.values.logLevel) {
                    Text("Errors").tag("error"); Text("Warnings").tag("warning")
                    Text("Information").tag("info"); Text("Debug").tag("debug")
                }
                Text("Applies to the player at the next playback. The \"Debug\" level writes more detail: "
                    + "only enable it for a diagnosis.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Button("Export the diagnostics…") { export() }
                Text("App, system and server versions, and recent logs. No token or password is included.")
                    .font(.caption).foregroundStyle(.secondary)
                if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(Theme.Colors.reachable) }
            }
        }
        .formStyle(.grouped)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Playfin-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.diagnosticsReport().write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "Diagnostics saved."
        } catch {
            exportMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}
