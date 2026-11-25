import Foundation

/// Deterministic test-only adapter. Never invokes platform networking APIs.
public struct SimulatedNetworkAdapter: Sendable {
    public private(set) var configuration: OwnedNetworkConfiguration
    public private(set) var writes = 0

    public init(configuration: OwnedNetworkConfiguration) { self.configuration = configuration }

    public mutating func compareAndSwap(expected: OwnedNetworkConfiguration,
                                         desired: [String: String]) -> OwnedNetworkConfiguration? {
        guard configuration == expected, configuration.revision < UInt64.max,
              Set(desired.keys) == Set(expected.settings.keys) else { return nil }
        configuration = OwnedNetworkConfiguration(revision: configuration.revision + 1, settings: desired)
        writes += 1
        return configuration
    }

    public mutating func externalEdit(settings: [String: String]) {
        guard configuration.revision < UInt64.max else { return }
        configuration = OwnedNetworkConfiguration(revision: configuration.revision + 1, settings: settings)
    }
}
