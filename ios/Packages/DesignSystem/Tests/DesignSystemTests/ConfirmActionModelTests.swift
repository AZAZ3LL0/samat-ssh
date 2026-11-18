import LocalAuthentication
import Testing

@testable import DesignSystem

/// Records each prompt and answers with a fixed result.
private actor StubAuthenticator: OwnerAuthenticator {
    let error: (any Error)?
    private(set) var prompts: [String] = []

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func authenticate(reason: String) async throws {
        prompts.append(reason)
        if let error { throw error }
    }
}

@MainActor private final class Counter {
    var value = 0
}

@MainActor @Suite struct ConfirmActionModelTests {
    private func model(
        biometrics: Bool,
        authenticator: StubAuthenticator,
        counter: Counter
    ) -> ConfirmActionModel {
        ConfirmActionModel(reason: "Restart web", requiresBiometrics: biometrics, authenticator: authenticator) {
            counter.value += 1
        }
    }

    @Test func runsActionOnceAfterOwnerIsConfirmed() async {
        let authenticator = StubAuthenticator()
        let counter = Counter()
        let model = model(biometrics: true, authenticator: authenticator, counter: counter)
        await model.confirm()
        await model.confirm()
        #expect(await authenticator.prompts == ["Restart web"])
        #expect(counter.value == 1)
        #expect(model.phase == .done)
    }

    @Test(arguments: [LAError.Code.authenticationFailed, .biometryLockout, .passcodeNotSet, .notInteractive])
    func neverRunsActionWhenAuthenticationFails(code: LAError.Code) async {
        let counter = Counter()
        let model = model(biometrics: true, authenticator: StubAuthenticator(error: LAError(code)), counter: counter)
        await model.confirm()
        #expect(counter.value == 0)
        guard case .failed(let text) = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
        #expect(!text.isEmpty)
    }

    @Test func returnsToIdleWhenUserCancels() async {
        let counter = Counter()
        let model = model(
            biometrics: true, authenticator: StubAuthenticator(error: LAError(.userCancel)), counter: counter)
        await model.confirm()
        #expect(counter.value == 0)
        #expect(model.phase == .idle)
    }

    @Test func skipsPromptWhenBiometricsAreNotRequired() async {
        let authenticator = StubAuthenticator(error: LAError(.authenticationFailed))
        let counter = Counter()
        let model = model(biometrics: false, authenticator: authenticator, counter: counter)
        await model.confirm()
        #expect(await authenticator.prompts.isEmpty)
        #expect(counter.value == 1)
    }
}
