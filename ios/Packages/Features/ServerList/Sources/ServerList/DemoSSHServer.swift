import AgentKit
import Foundation

/// The server "Install over SSH" reaches in demo mode: Ubuntu on x86_64, root, password `demo`.
/// Its agent is the fake one `FakeAgentPairing` pairs with at any address.
public enum DemoSSHServer {
    public static let password = "demo"

    public static func connector() -> FakeSSHConnector {
        let pairJSON = """
            {"host":"demo.local","port":7443,"fp":"\(FakeAgentPairing.fingerprint)",\
            "code":"\(FakeAgentClient.pairingCode)","expiresAt":"2026-01-01T00:10:00.000Z","url":"pulse://pair"}
            """
        return FakeSSHConnector(password: password) { command in
            let stdout: String? =
                switch command {
                case "uname -m": "x86_64\n"
                case "cat /etc/os-release": "PRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\nID=ubuntu\nVERSION_ID=\"24.04\"\n"
                case "id -u": "0\n"
                case _ where command.contains("pulse-agent pair --json"): pairJSON + "\n"
                case _ where command.contains("base64 -d"): "pulse-agent 0.1.0 is running.\n"
                case _ where command.contains("authorized_keys"): ""
                default: nil
                }
            return stdout.map { SSHOutput(status: 0, stdout: $0, stderr: "") }
        }
    }
}
