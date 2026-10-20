import Foundation

enum GameLaunchStage: String, CaseIterable, Identifiable {
    case javaRuntime
    case commandLineTools
    case sdkLicenses
    case emulatorTools
    case systemImage
    case device
    case startingAndroid
    case bootingAndroid
    case provisioningDevice
    case installingGame
    case launchingGame
    case display

    var id: Self { self }

    var title: String {
        switch self {
        case .javaRuntime: "Installing the Java runtime"
        case .commandLineTools: "Installing Android command-line tools"
        case .sdkLicenses: "Accepting Android SDK licenses"
        case .emulatorTools: "Downloading the Android emulator"
        case .systemImage: "Downloading the Android system image"
        case .device: "Creating your game device"
        case .startingAndroid: "Starting Android"
        case .bootingAndroid: "Booting Android"
        case .provisioningDevice: "Preparing the game device"
        case .installingGame: "Installing the game"
        case .launchingGame: "Launching Bedrock"
        case .display: "Connecting the display"
        }
    }

    var isSetupStage: Bool {
        switch self {
        case .javaRuntime, .commandLineTools, .sdkLicenses, .emulatorTools, .systemImage, .device: true
        case .startingAndroid, .bootingAndroid, .provisioningDevice, .installingGame, .launchingGame, .display: false
        }
    }
}

enum GameLaunchStepState: Equatable {
    case pending
    case active
    case finished
    case failed(String)
}

struct GameLaunchStep: Identifiable, Equatable {
    let stage: GameLaunchStage
    var state: GameLaunchStepState
    var detail: String?
    var progress: Double?

    var id: GameLaunchStage { stage }
}
