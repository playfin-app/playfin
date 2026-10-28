import SwiftUI

/// List of keyboard shortcuts (Help ▸ Keyboard Shortcuts menu, ⇧⌘/).
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(title: String, items: [(keys: String, action: String)])] = [
        ("Navigation", [
            ("⌘1", "Home"), ("⌘2", "Library"), ("⌘3", "Downloads"), ("⌘F", "Search"), ("⇧⌘A", "Add a server address"),
            ("⌃⌘1 to ⌃⌘9", "Switch profile"), ("⌘,", "Settings"), ("Space", "Play the selected item"),
            ("Esc", "Back")
        ]),
        ("Player", [
            ("Space", "Play / pause"), ("← / →", "Skip back / forward (length set in Settings)"),
            ("↑ / ↓", "Volume"), ("M", "Mute"), ("C", "Subtitles on / off"), ("[ / ]", "Slower / faster"),
            ("P / N", "Previous / next episode"), ("F", "Full screen"), ("Esc", "Close the player")
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard shortcuts").font(.title2.bold())
            ForEach(sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title).font(.headline).foregroundStyle(.secondary)
                    ForEach(section.items, id: \.keys) { item in
                        HStack {
                            Text(item.keys)
                                .font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.surface))
                                .frame(minWidth: 130, alignment: .leading)
                            Text(item.action)
                            Spacer()
                        }
                    }
                }
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(28)
        .frame(width: 520)
    }
}
