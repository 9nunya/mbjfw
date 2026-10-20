import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(GameLibrary.self) private var library
    @State private var choosingAPK = false

    private var selection: Binding<String?> {
        Binding(
            get: { library.selectedBuildID },
            set: { if let id = $0 { library.selectBuild(id) } }
        )
    }

    var body: some View {
        List(selection: selection) {
            ForEach(library.builds) { build in
                BuildRow(build: build, selected: build.id == library.selectedBuildID)
                    .tag(build.id)
                    .contextMenu {
                        Button("Remove from Library", role: .destructive) { library.remove(build) }
                    }
            }
        }
        .overlay {
            if library.builds.isEmpty {
                ContentUnavailableView {
                    Label("No Builds", systemImage: "shippingbox")
                } description: {
                    Text("Import a Bedrock APK stored on this Mac.")
                } actions: {
                    Button("Import APK…") { choosingAPK = true }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Import APK…", systemImage: "plus") { choosingAPK = true }
                    .disabled(library.isWorking)
            }
            ToolbarItem {
                Button("Play", systemImage: "play.fill") { library.launch() }
                    .disabled(library.selectedBuild == nil || library.isWorking)
            }
        }
        .fileImporter(isPresented: $choosingAPK, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            library.importAPK(url)
        }
    }
}
