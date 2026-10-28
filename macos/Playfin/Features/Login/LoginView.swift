import SwiftUI

/// Onboarding and sign-in screen:
/// 1. Automatic discovery of servers on the local network (UDP 7359) or URL entry.
/// 2. Prior validation of the server (reachable, Jellyfin, version >= 10.9).
/// 3. Authentication with credentials (password) or Quick Connect (code to approve).
/// 4. Suggestion to add a secondary address (remote or local) after signing in.
struct LoginView: View {
    @Environment(AppModel.self) private var model

    enum AuthMode: String, CaseIterable, Identifiable {
        case credentials = "Password"
        case quickConnect = "Quick Connect"
        var id: String { rawValue }
    }

    // Step 1: Choosing the server
    @State private var serverUrl = AppModel.defaultServer
    @State private var discoveredServers: [DiscoveredServer] = []
    @State private var isScanning = false
    @State private var isValidatingServer = false
    @State private var validatedServer: ServerPublicInfo?
    @State private var serverValidationError: String?

    // Step 2: Authentication
    @State private var authMode: AuthMode = .credentials
    @State private var username = ""
    @State private var password = ""
    @State private var isLoggingIn = false

    // Quick Connect
    @State private var quickConnectClient: JellyfinClient?
    @State private var quickConnectState: QuickConnectState?
    @State private var isInitiatingQuickConnect = false
    @State private var isPollingQuickConnect = false

    var body: some View {
        VStack(spacing: 24) {
            // Playfin header
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Welcome to Playfin")
                    .font(.title2.bold())
                Text("A light, fast native client for Jellyfin")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)

            if let serverInfo = validatedServer {
                // Step 2: Authentication on the validated server
                authenticationView(server: serverInfo)
            } else {
                // Step 1: Discovery and validation of the server
                serverSelectionView
            }
        }
        .padding(32)
        .frame(width: 480)
        .overlay(alignment: .topLeading) {
            // Adding a server or a user: one can go back to the open profile without changing anything.
            if model.isAddingProfile {
                Button("Cancel") { model.cancelAddProfile() }
                    .keyboardShortcut(.cancelAction)
                    .padding(12)
            }
        }
        .task {
            // New user of an already known server: skip the server choice.
            if let prefill = model.loginPrefillServer, validatedServer == nil {
                serverUrl = prefill
                validateAndProceed()
            }
            await scanServers()
        }
    }

    // MARK: - Step 1: Selecting & validating the server

    private var serverSelectionView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Automatically discovered servers
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Servers on your network")
                        .font(.headline)
                    Spacer()
                    if isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await scanServers() }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.tint)
                    }
                }

                if discoveredServers.isEmpty {
                    Text(isScanning ? "Looking for local servers…" : "No server detected automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(discoveredServers, id: \.address) { discovered in
                            Button {
                                selectDiscoveredServer(discovered)
                            } label: {
                                HStack {
                                    Image(systemName: "server.rack")
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(discovered.name)
                                            .font(.subheadline.bold())
                                        Text(discovered.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()

            // Manual address entry
            VStack(alignment: .leading, spacing: 8) {
                Text("Or enter your server's address")
                    .font(.headline)

                HStack {
                    TextField("https://jellyfin.example.com:8096", text: $serverUrl)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { validateAndProceed() }

                    Button {
                        validateAndProceed()
                    } label: {
                        Text("Check")
                            .opacity(isValidatingServer ? 0 : 1)
                            .overlay { if isValidatingServer { ProgressView().controlSize(.small) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidatingServer)
                }

                if let error = serverValidationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.error)
                } else {
                    // The disabled "Check" button explains nothing by itself: what to type.
                    Text("The address you use to open Jellyfin in a browser, e.g. http://jellyfin.local:8096")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Step 2: Authentication

    private func authenticationView(server: ServerPublicInfo) -> some View {
        VStack(spacing: 20) {
            // Card of the validated server
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.reachable)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.serverName)
                        .font(.headline)
                    Text("Jellyfin \(server.version) · \(serverUrl)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Changer") {
                    withAnimation {
                        validatedServer = nil
                        quickConnectState = nil
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tint)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            // Method picker: Password or Quick Connect
            Picker("Sign-in method", selection: $authMode) {
                ForEach(AuthMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if authMode == .credentials {
                // Classic username / password form
                VStack(spacing: 12) {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { performPasswordLogin() }

                    if let error = model.loginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.error)
                    }

                    Button {
                        performPasswordLogin()
                    } label: {
                        Text("Sign in")
                            .frame(maxWidth: .infinity)
                            .opacity(isLoggingIn ? 0 : 1)
                            .overlay { if isLoggingIn { ProgressView().controlSize(.small) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isLoggingIn || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                // Flow Quick Connect
                quickConnectView
            }
        }
    }

    // MARK: - Vue Quick Connect

    private var quickConnectView: some View {
        VStack(spacing: 16) {
            if let state = quickConnectState {
                VStack(spacing: 10) {
                    Text("Authorisation code:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(state.code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 24)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))

                    Text("Open the Jellyfin web app, go to **Settings > Quick Connect** and authorise this code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)

                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for approval on your other device…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    Button("Cancel") {
                        quickConnectState = nil
                        isPollingQuickConnect = false
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                }
                .task {
                    await startQuickConnectPolling()
                }
            } else {
                VStack(spacing: 12) {
                    Text("Sign in without typing your password by approving a code from another Jellyfin client.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let error = model.loginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.Colors.error)
                    }

                    Button {
                        Task { await startQuickConnect() }
                    } label: {
                        Label("Generate a Quick Connect code", systemImage: "qrcode")
                            .frame(maxWidth: .infinity)
                            .opacity(isInitiatingQuickConnect ? 0 : 1)
                            .overlay { if isInitiatingQuickConnect { ProgressView().controlSize(.small) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isInitiatingQuickConnect)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Secondary address sheet

    // MARK: - Actions

    private func scanServers() async {
        isScanning = true
        defer { isScanning = false }
        discoveredServers = await model.scanLocalServers(timeoutMs: 1500)
    }

    private func selectDiscoveredServer(_ discovered: DiscoveredServer) {
        serverUrl = discovered.address
        validateAndProceed()
    }

    private func validateAndProceed() {
        let clean = AppModel.normalizeURL(serverUrl)
        guard !clean.isEmpty else { return }
        serverUrl = clean
        serverValidationError = nil
        isValidatingServer = true

        Task {
            defer { isValidatingServer = false }
            do {
                let info = try await model.validateServerURL(clean)
                validatedServer = info
                AppModel.rememberServer(clean)
            } catch {
                serverValidationError = "Server unreachable or not supported: \(model.message(for: error))"
            }
        }
    }

    private func performPasswordLogin() {
        let cleanUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty else { return }
        isLoggingIn = true

        Task {
            defer { isLoggingIn = false }
            let success = await model.login(server: serverUrl, username: cleanUser, password: password)
            if success {
                // Sign-in succeeded, AppModel switches to .library and ContentView presents the sheet if needed
            }
        }
    }

    private func startQuickConnect() async {
        isInitiatingQuickConnect = true
        defer { isInitiatingQuickConnect = false }
        do {
            let (client, state) = try await model.initiateQuickConnect(server: serverUrl)
            self.quickConnectClient = client
            self.quickConnectState = state
        } catch {
            model.loginError = "Quick Connect is unavailable on this server: \(model.message(for: error))"
        }
    }

    private func startQuickConnectPolling() async {
        guard let client = quickConnectClient, let state = quickConnectState else { return }
        isPollingQuickConnect = true
        defer { isPollingQuickConnect = false }

        let outcome = await model.runQuickConnectPolling(client: client, secret: state.secret)
        // Code expired or refused: back to the start screen to ask for a new one.
        if outcome == .timedOut || outcome == .failed {
            quickConnectState = nil
            quickConnectClient = nil
        }
    }
}
