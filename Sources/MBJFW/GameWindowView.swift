import SwiftUI

struct GameWindowView: View {
    let accountID: UUID

    @Environment(GameLibrary.self) private var library
    @Environment(\.dismissWindow) private var dismissWindow

    private var runtime: AndroidRuntimeManager {
        library.runtime(for: accountID)
    }

    var body: some View {
        Group {
            if runtime.isGameRunning {
                ContentUnavailableView("Minecraft Is Running", systemImage: "gamecontroller", description: Text("The game is open in its native window."))
            } else {
                LaunchProgressView(
                    steps: runtime.steps,
                    pipelineError: runtime.pipelineError,
                    retry: runtime.retry
                )
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .navigationTitle("Minecraft")
        .onChange(of: runtime.isGameRunning) { _, running in
            if running {
                dismissWindow(id: "game", value: accountID)
                runtime.focusGameWindow()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if runtime.isGameRunning {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { runtime.stopGame() }
                        .help("Stop Minecraft and Android")
                } else if runtime.isInstalling || runtime.isLaunching {
                    Button("Cancel") { runtime.cancelPreparation() }
                }
            }
        }
    }
}

private struct LaunchProgressView: View {
    let steps: [GameLaunchStep]
    let pipelineError: String?
    let retry: () -> Void

    private var activeStep: GameLaunchStep? { steps.first { $0.state == .active } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(pipelineError == nil ? "Getting Minecraft Ready" : "Minecraft Could Not Start")
                .font(.title2.weight(.semibold))
            Text(pipelineError ?? activeStep?.detail ?? "Preparing the Android runtime.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(steps) { step in
                launchStep(step)
            }
            .listStyle(.inset)

            if pipelineError != nil {
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder
    private func launchStep(_ step: GameLaunchStep) -> some View {
        let active = step.state == .active
        let failed: Bool = { if case .failed = step.state { true } else { false } }()
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch step.state {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                case .active:
                    ProgressView().controlSize(.small)
                case .finished:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.stage.title)
                    .fontWeight(active || failed ? .semibold : .regular)
                if active || failed, let detail = step.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if active, let progress = step.progress {
                    ProgressView(value: progress)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
