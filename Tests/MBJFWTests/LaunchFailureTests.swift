import XCTest
@testable import MBJFW

final class LaunchFailureTests: XCTestCase {
    func test_androidCommandFailure_whenAPKInstallIsRejected_reportsTheReason() {
        let error = AndroidCommandError(
            command: "adb",
            status: 1,
            output: "Failure [INSTALL_FAILED_NO_MATCHING_ABIS]"
        )

        let message = error.errorDescription ?? ""

        XCTAssertTrue(message.contains("exit 1"))
        XCTAssertTrue(message.contains("INSTALL_FAILED_NO_MATCHING_ABIS"))
    }
}
