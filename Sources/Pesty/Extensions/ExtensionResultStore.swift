import Foundation
import Observation

@Observable
@MainActor
final class ExtensionResultStore {
    static let shared = ExtensionResultStore(
        catalog: ExtensionCatalog.shared,
        host: ExtensionCatalog.sharedHost
    )

    private static let capacity = 512

    private enum Outcome {
        case badge(String)
        case noBadge
    }

    private struct RequestKey: Hashable {
        let clipID: UUID
        let extensionID: String
    }

    @ObservationIgnored private let catalog: ExtensionCatalog
    @ObservationIgnored private let host: ExtensionHost
    private var outcomes: [UUID: [String: Outcome]] = [:]
    private var inFlight: Set<RequestKey> = []
    @ObservationIgnored private var requestTokens: [RequestKey: UInt64] = [:]
    @ObservationIgnored private var nextRequestToken: UInt64 = 0

    init(catalog: ExtensionCatalog, host: ExtensionHost) {
        self.catalog = catalog
        self.host = host
        catalog.onExtensionInvalidated = { [weak self] extensionID in
            self?.purge(extensionID: extensionID)
        }
    }

    func requestBadges(for item: ClipItem) {
        let enabledExtensions = catalog.enabledExtensions
        guard !enabledExtensions.isEmpty else { return }

        for installedExtension in enabledExtensions {
            let key = RequestKey(clipID: item.id, extensionID: installedExtension.id)
            guard outcomes[item.id]?[installedExtension.id] == nil,
                  inFlight.insert(key).inserted else { continue }

            nextRequestToken &+= 1
            let token = nextRequestToken
            requestTokens[key] = token
            host.badge(
                clipType: item.type.rawValue,
                text: item.text ?? "",
                extension: installedExtension
            ) { [weak self] badge in
                self?.finish(key: key, token: token, badge: badge)
            }
        }
    }

    func badges(for clipID: UUID) -> [String] {
        catalog.enabledExtensions.compactMap { installedExtension in
            guard case .badge(let badge) = outcomes[clipID]?[installedExtension.id] else {
                return nil
            }
            return badge
        }
    }

    func forget(_ clipID: UUID) {
        outcomes.removeValue(forKey: clipID)
        cancelRequests { $0.clipID == clipID }
    }

    func forgetAll() {
        outcomes.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        requestTokens.removeAll(keepingCapacity: true)
    }

    func purge(extensionID: String) {
        for clipID in Array(outcomes.keys) {
            outcomes[clipID]?.removeValue(forKey: extensionID)
            if outcomes[clipID]?.isEmpty == true {
                outcomes.removeValue(forKey: clipID)
            }
        }
        cancelRequests { $0.extensionID == extensionID }
    }

    var cachedClipCount: Int { outcomes.count }
    var pendingEvaluationCount: Int { inFlight.count }

    func hasCachedOutcome(for clipID: UUID, extensionID: String) -> Bool {
        outcomes[clipID]?[extensionID] != nil
    }

    private func finish(key: RequestKey, token: UInt64, badge: String?) {
        guard requestTokens[key] == token else { return }
        requestTokens.removeValue(forKey: key)
        inFlight.remove(key)

        if outcomes[key.clipID] == nil, outcomes.count >= Self.capacity {
            // Match ClipTextMetrics: overflow clears the small memoization cache.
            outcomes.removeAll(keepingCapacity: true)
        }
        var clipOutcomes = outcomes[key.clipID] ?? [:]
        clipOutcomes[key.extensionID] = badge.map(Outcome.badge) ?? .noBadge
        // The captured clip ID prevents a recycled card from receiving stale output.
        outcomes[key.clipID] = clipOutcomes
    }

    private func cancelRequests(where shouldCancel: (RequestKey) -> Bool) {
        let cancelled = inFlight.filter(shouldCancel)
        for key in cancelled {
            inFlight.remove(key)
            requestTokens.removeValue(forKey: key)
        }
    }
}
