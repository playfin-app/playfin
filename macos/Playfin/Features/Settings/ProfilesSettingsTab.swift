import SwiftUI

/// Settings > Profiles: one block per server with its addresses (add, edit, order, test, forced address)
/// and its users (open, primary, sign out).
struct ProfilesSettingsTab: View {
    @Environment(AppModel.self) private var model

    private var servers: [(id: String, profiles: [ServerProfile])] {
        var order: [String] = []
        for profile in model.profiles where !order.contains(profile.serverId) { order.append(profile.serverId) }
        return order.map { id in (id, model.profiles.filter { $0.serverId == id }) }
    }

    var body: some View {
        Form {
            if model.profiles.isEmpty {
                Section {
                    Text("No saved server.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(servers, id: \.id) { server in
                ServerSection(serverId: server.id, profiles: server.profiles)
            }
            Section {
                Button {
                    model.beginAddServer()
                } label: {
                    Label("Add another server…", systemImage: "plus.circle")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshProfiles()
            // Open session but no profile (old version, lost file): we recreate it.
            if model.profiles.isEmpty, let session = model.client?.sessionInfo() {
                model.recreateProfile(for: session, existing: [])
            }
        }
        .task { await model.refreshProfileStatuses() }
    }
}

private struct ServerSection: View {
    @Environment(AppModel.self) private var model
    let serverId: String
    let profiles: [ServerProfile]

    @State private var testResults: [String: AddressTestResult] = [:]
    @State private var editing: Int?
    @State private var editLabel = ""
    @State private var editURL = ""
    @State private var newLabel = "Remote"
    @State private var newURL = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var confirmSignOut: ServerProfile?

    private var addresses: [ServerAddress] { profiles.first?.addresses ?? [] }
    private var forced: String? { profiles.first?.forcedAddress }
    private var serverName: String { profiles.first?.serverName ?? "Server" }

    var body: some View {
        Section {
            ForEach(Array(addresses.enumerated()), id: \.offset) { index, address in
                addressRow(index: index, address: address)
                if editing == index { editor(index: index) }
            }
            if forced != nil {
                Button("Go back to automatic address selection") { model.setForcedAddress(nil, forServer: serverId) }
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                Text(serverName).font(.headline)
                StatusDot(status: profiles.first.flatMap { model.profileStatuses[$0.id] })
                Spacer()
                if let label = model.activeAddressLabel, profiles.contains(where: { $0.id == model.activeProfileKey }) {
                    Text("Active address: \(label)").font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("The app tries the addresses in this order and keeps the first one that answers with the right server. "
                 + "Add your outside address (e.g. https://jellyfin.example.com) to watch away from home.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Add an address to \(serverName)") {
            HStack {
                Picker("", selection: $newLabel) {
                    Text("Remote").tag("Remote"); Text("Home").tag("Home"); Text("Office").tag("Office")
                }
                .labelsHidden()
                .frame(width: 110)
                // In a Form, a field's title shows as a label: only the prompt is used.
                TextField("Address", text: $newURL, prompt: Text("https://jellyfin.example.com or 192.0.2.10:8096"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(isAdding ? "Checking…" : "Check and add", action: add)
                    .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
            }
            if addressSendsTokenUnencrypted(url: newURL), !newURL.isEmpty {
                Label("Remote address over http: the token would travel in clear text. Prefer https.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.Colors.warning)
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(Theme.Colors.error) }
        }

        Section("Users of \(serverName)") {
            ForEach(profiles) { profile in userRow(profile) }
            if let first = profiles.first {
                Button {
                    model.beginAddUser(toServerOf: first)
                } label: {
                    Label("Add a user…", systemImage: "person.badge.plus")
                }
            }
        }
        .confirmationDialog(
            "Sign out \(confirmSignOut?.userName ?? "")?",
            isPresented: Binding(get: { confirmSignOut != nil }, set: { if !$0 { confirmSignOut = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                if let profile = confirmSignOut { model.signOut(profile) }
                confirmSignOut = nil
            }
        } message: {
            Text("This profile's token is deleted and its cache cleared. Downloads stay on disk.")
        }
    }

    private func add() {
        let url = newURL
        isAdding = true
        errorMessage = nil
        Task {
            defer { isAdding = false }
            do {
                try await model.addAddress(forServer: serverId, label: newLabel, url: url)
                newURL = ""
            } catch {
                errorMessage = model.message(for: error)
            }
        }
    }

    private func userRow(_ profile: ServerProfile) -> some View {
        HStack(spacing: 10) {
            ProfileAvatar(
                profile: profile,
                imageURL: profile.id == model.activeProfileKey ? model.activeAvatarURL : nil,
                size: 26
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.userName)
                HStack(spacing: 6) {
                    if profile.isPrimary { Text("Primary profile (opened at launch)") }
                    if profile.id == model.activeProfileKey { Text("Open").foregroundStyle(Theme.Colors.reachable) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if profile.id != model.activeProfileKey {
                Button("Open") { model.switchProfile(profile) }
            }
            Menu {
                if !profile.isPrimary {
                    Button("Set as primary") { model.setPrimary(profile) }
                }
                Button("Sign out…", role: .destructive) { confirmSignOut = profile }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for \(profile.userName)")
        }
    }

    @ViewBuilder
    private func addressRow(index: Int, address: ServerAddress) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(address.label).bold()
                    if address.isLocal { badge("local network") }
                    if forced == address.url { badge("forced", color: Theme.Colors.warning) }
                }
                Text(address.url).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if !address.isLocal, addressSendsTokenUnencrypted(url: address.url) {
                    Label("Unencrypted connection: the token travels in clear text over the Internet.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.Colors.warning)
                }
                if let result = testResults[address.url] {
                    Text(text(for: result)).font(.caption).foregroundStyle(color(for: result))
                }
            }
            Spacer()
            Button("Test") {
                Task { testResults[address.url] = await model.testAddress(address, serverId: serverId) }
            }
            ControlGroup {
                Button { model.moveAddress(forServer: serverId, from: index, to: index - 1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .accessibilityLabel("Move up")
                Button { model.moveAddress(forServer: serverId, from: index, to: index + 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == addresses.count - 1)
                    .accessibilityLabel("Move down")
            }
            .fixedSize()
            Menu {
                Button("Edit…") {
                    editing = editing == index ? nil : index
                    editLabel = address.label
                    editURL = address.url
                    errorMessage = nil
                }
                Button(forced == address.url ? "Stop forcing" : "Always use this address") {
                    model.setForcedAddress(forced == address.url ? nil : address.url, forServer: serverId)
                }
                Divider()
                Button("Delete", role: .destructive) { model.removeAddress(forServer: serverId, at: index) }
                    .disabled(addresses.count < 2)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for address \(address.label)")
        }
    }

    private func editor(index: Int) -> some View {
        HStack {
            TextField("Label", text: $editLabel, prompt: Text("Label")).labelsHidden().frame(width: 110)
            TextField("Address", text: $editURL, prompt: Text("https://…")).labelsHidden()
            Button("Save") {
                Task {
                    do {
                        try await model.editAddress(forServer: serverId, at: index, label: editLabel, url: editURL)
                        editing = nil
                        errorMessage = nil
                    } catch {
                        errorMessage = model.message(for: error)
                    }
                }
            }
            Button("Cancel") { editing = nil }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func badge(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.Colors.surface))
    }

    private func text(for result: AddressTestResult) -> String {
        switch result {
        case .ok(let ms): return "✓ Answers in \(ms) ms"
        case .wrongServer: return "Answers, but it is another server"
        case .unreachable: return "Unreachable from this network"
        }
    }

    private func color(for result: AddressTestResult) -> Color {
        if case .ok = result { return Theme.Colors.reachable }
        return Theme.Colors.error
    }
}
