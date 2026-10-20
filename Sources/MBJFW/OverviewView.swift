import SwiftUI
import UniformTypeIdentifiers

struct OverviewView: View {
    @Environment(GameLibrary.self) private var library
    @Binding var tab: LauncherTab
    @State private var choosingAPK = false

    private var primaryActionTitle: String {
        if library.selectedBuild != nil { return "Play" }
        return library.runtime.isReady ? "Choose APK…" : "Set Up Android"
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(library.selectedBuild?.displayName ?? "Play Minecraft Bedrock")
                        .font(.title2.weight(.semibold))
                    Text(library.selectedBuild == nil
                         ? "Import a Bedrock APK to get started. Your game and worlds stay on this Mac."
                         : "Launch the selected build in your Android device.")
                        .foregroundStyle(.secondary)
                    Button(primaryActionTitle, systemImage: library.selectedBuild == nil ? "plus" : "play.fill") {
                        if library.selectedBuild != nil {
                            library.launch()
                        } else if !library.runtime.isReady {
                            library.runtime.requestInstall()
                        } else {
                            choosingAPK = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.isWorking)
                    .padding(.top, 4)
                }
                .padding(.vertical, 8)
            }

            Section("Library") {
                LabeledContent("Builds", value: "\(library.builds.count)")
                if let selected = library.selectedBuild {
                    LabeledContent("Selected", value: selected.displayName)
                } else {
                    LabeledContent("Selected", value: "None")
                }
                HStack {
                    Spacer()
                    Button("View Library", systemImage: "arrow.right") { tab = .library }
                        .buttonStyle(.bordered)
                }
            }

            if !library.builds.isEmpty {
                Section("Recent builds") {
                    ForEach(library.builds.prefix(5)) { build in
                        BuildRow(build: build, selected: build.id == library.selectedBuildID)
                            .contentShape(Rectangle())
                            .onTapGesture { library.selectBuild(build.id) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .toolbar {
            ToolbarItem {
                Button("Import APK…", systemImage: "plus") { choosingAPK = true }
                    .disabled(library.isWorking)
            }
        }
        .fileImporter(isPresented: $choosingAPK, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            library.importAPK(url)
        }
    }
}

struct BuildRow: View {
    let build: GameBuild
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Label(build.displayName, systemImage: "shippingbox")
                .labelStyle(.titleAndIcon)
            Spacer()
            Text(build.importedAt.formatted(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Selected")
            }
        }
        .contentShape(Rectangle())
    }
}
