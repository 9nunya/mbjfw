import SwiftUI

enum LauncherTab: String, CaseIterable, Identifiable, Hashable {
    case overview = "Overview"
    case accounts = "Accounts"
    case library = "Library"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "house"
        case .accounts: "person.crop.circle"
        case .library: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }
}
