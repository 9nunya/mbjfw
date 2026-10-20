import SwiftUI

struct SDKConsentView: View {
    @Environment(GameLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install Android Runtime")
                .font(.title2.weight(.semibold))
            Text("MBJFW needs a Java runtime, Android Emulator, and an ARM64 Android system image to run this Bedrock APK. Minecraft is installed directly; Google Play and a Google account are not used.")
            Text("This downloads several gigabytes and accepts the Android SDK package licenses for this Mac. Your APK and profile data remain local.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("Read the Android SDK license", destination: URL(string: "https://developer.android.com/studio/terms")!)
                .font(.footnote)
            HStack {
                Spacer()
                Button("Not Now") { library.declineSDKConsent() }
                Button("Accept & Install") { library.acceptSDKConsent() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 460)
    }
}
