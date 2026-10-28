import SwiftUI

struct SecondaryAddressSheet: View {
    @Environment(AppModel.self) private var model
    @State private var secondaryAddressUrl = ""
    @State private var secondaryAddressLabel = "Remote"
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a connection address")
                        .font(.headline)
                    Text("Smooth access on the go and at home")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(
                "You are signed in. If your server also has a remote address (HTTPS) " +
                "or a local address (local IP), you can save it right now.\n\n" +
                "Playfin will automatically probe your addresses to use the ultra-fast local network " +
                "at home and remote access when you are away."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                TextField("https://jellyfin.example.com or 192.0.2.10:8096", text: $secondaryAddressUrl)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Label:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $secondaryAddressLabel) {
                        Text("Remote").tag("Remote")
                        Text("Home").tag("Home")
                        Text("Office").tag("Office")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.error)
                }
            }

            HStack {
                Button("Later") {
                    model.dismissSecondaryAddressPrompt()
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    Task { await saveSecondaryAddress() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save the address")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(secondaryAddressUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 480)
    }

    private func saveSecondaryAddress() async {
        let clean = secondaryAddressUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await model.addSecondaryAddress(url: clean, label: secondaryAddressLabel)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
