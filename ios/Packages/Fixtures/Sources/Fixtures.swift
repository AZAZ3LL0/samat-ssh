import Foundation

/// Seed data from the repository's `fixtures/` directory, bundled as a resource.
///
/// The same files feed the agent's `--fake` mode and are validated against the
/// contract by `make validate-fixtures`, so the app never decodes seed data the
/// agent could not have sent.
public enum Fixtures {
    public enum Failure: Error, Equatable {
        case missing(String)
    }

    /// The contents of a fixture, addressed relative to `fixtures/`, e.g. `host_metrics/01.json`.
    public static func data(_ path: String) throws(Failure) -> Data {
        guard let data = try? Data(contentsOf: root.appending(path: path)) else {
            throw .missing(path)
        }
        return data
    }

    /// Paths of the fixtures in a directory, sorted by name so replay order is stable.
    public static func paths(in directory: String) throws(Failure) -> [String] {
        let names = try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: directory).path)
        guard let names, !names.isEmpty else {
            throw .missing(directory)
        }
        return names.sorted().map { "\(directory)/\($0)" }
    }

    private static var root: URL {
        Bundle.module.bundleURL.appending(path: "fixtures")
    }
}
