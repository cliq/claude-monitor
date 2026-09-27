// iOS/BridgeBrowser.swift
import Foundation
import Network

/// Lists the Macs advertising the usage bridge over Bonjour. Only runs while
/// the picker is on screen — a saved Bonjour endpoint connects by name
/// without browsing.
@MainActor
final class BridgeBrowser: ObservableObject {
    @Published private(set) var serviceNames: [String] = []

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: BridgeEndpoint.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = Set(results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }).sorted()
            Task { @MainActor in self?.serviceNames = names }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
