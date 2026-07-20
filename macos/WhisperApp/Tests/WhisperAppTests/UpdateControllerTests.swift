import Testing
@testable import WhisperApp

@MainActor
private final class FakeUpdateChecker: ApplicationUpdateChecking {
    var canCheckForUpdates = true
    private(set) var checkCount = 0
    func checkForUpdates() { checkCount += 1 }
}

@MainActor
struct UpdateControllerTests {
    @Test
    func invalidReleaseConfigurationDisablesChecksWithoutCallingFramework() {
        let checker = FakeUpdateChecker()
        let controller = UpdateController(
            checker: checker,
            configuration: .invalid("Signed HTTPS appcast is not configured")
        )

        controller.checkForUpdates()

        #expect(!controller.canCheckForUpdates)
        #expect(checker.checkCount == 0)
        #expect(controller.statusMessage.contains("not configured"))
    }

    @Test
    func validReleaseConfigurationDelegatesUserInitiatedCheck() {
        let checker = FakeUpdateChecker()
        let controller = UpdateController(checker: checker, configuration: .valid)

        controller.checkForUpdates()

        #expect(checker.checkCount == 1)
        #expect(controller.statusMessage == "Checking for updates…")
    }
}
