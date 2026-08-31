import AppKit
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
    private static let iconValidationCapacity = 128

    private struct RequestKey: Hashable {
        let clipID: UUID
        let extensionID: String
    }

    @ObservationIgnored private let catalog: ExtensionCatalog
    @ObservationIgnored private let host: ExtensionHost
    private var outcomes: [UUID: [String: CardDecorations]] = [:]
    private var inFlight: Set<RequestKey> = []
    @ObservationIgnored private var requestTokens: [RequestKey: UInt64] = [:]
    @ObservationIgnored private var nextRequestToken: UInt64 = 0
    @ObservationIgnored private var iconValidity: [String: Bool] = [:]
    @ObservationIgnored private var keywordIndex: ExtensionKeywordIndex?

    init(catalog: ExtensionCatalog, host: ExtensionHost) {
        self.catalog = catalog
        self.host = host
        catalog.onExtensionInvalidated = { [weak self] extensionID in
            self?.purge(extensionID: extensionID)
        }
    }

    func requestDecorations(for item: ClipItem) {
        let enabledExtensions = catalog.enabledExtensions
        guard !enabledExtensions.isEmpty else { return }

        for installedExtension in enabledExtensions {
            // A type mismatch is cheap to re-check and should not consume a
            // slot in the clip-result cache for work that never ran.
            guard installedExtension.manifest.supports(clipType: item.type.rawValue) else {
                continue
            }
            let key = RequestKey(clipID: item.id, extensionID: installedExtension.id)
            guard outcomes[item.id]?[installedExtension.id] == nil,
                  inFlight.insert(key).inserted else { continue }

            nextRequestToken &+= 1
            let token = nextRequestToken
            requestTokens[key] = token
            host.decorations(
                clipType: item.type.rawValue,
                text: item.text ?? "",
                extension: installedExtension,
                settings: catalog.effectiveSettings(for: installedExtension.id)
            ) { [weak self] decorations in
                self?.finish(key: key, token: token, decorations: decorations)
            }
        }
    }

    func badges(for clipID: UUID) -> [String] {
        weightedDecorations(for: clipID).compactMap(\.badge)
    }

    func subtitle(for clipID: UUID) -> String? {
        let subtitles = weightedDecorations(for: clipID).compactMap(\.subtitle)
        return subtitles.isEmpty ? nil : subtitles.joined(separator: " · ")
    }

    func icon(for clipID: UUID) -> String? {
        for icon in weightedDecorations(for: clipID).compactMap(\.icon) {
            if isValidSystemSymbol(icon) { return icon }
        }
        return nil
    }

    func headerColorHex(for clipID: UUID) -> String? {
        firstValue(for: clipID, at: \.color)
    }

    func titleOverride(for clipID: UUID) -> String? {
        firstValue(for: clipID, at: \.title)
    }

    func labelOverride(for clipID: UUID) -> String? {
        firstValue(for: clipID, at: \.label)
    }

    func suggestedPinboard(for clipID: UUID) -> String? {
        firstValue(for: clipID, at: \.suggestedPinboard)
    }

    func forget(_ clipID: UUID) {
        outcomes.removeValue(forKey: clipID)
        cancelRequests { $0.clipID == clipID }
        keywordIndex?.forget(clipID)
    }

    func forgetAll() {
        outcomes.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        requestTokens.removeAll(keepingCapacity: true)
        keywordIndex?.forgetAll()
    }

    func purge(extensionID: String) {
        for clipID in Array(outcomes.keys) {
            outcomes[clipID]?.removeValue(forKey: extensionID)
            if outcomes[clipID]?.isEmpty == true {
                outcomes.removeValue(forKey: clipID)
            }
        }
        cancelRequests { $0.extensionID == extensionID }
        keywordIndex?.purge(extensionID: extensionID)
    }

    func attachKeywordIndex(_ keywordIndex: ExtensionKeywordIndex) {
        self.keywordIndex = keywordIndex
    }

    var cachedClipCount: Int { outcomes.count }
    var pendingEvaluationCount: Int { inFlight.count }
    var cachedIconValidationCount: Int { iconValidity.count }

    func hasCachedOutcome(for clipID: UUID, extensionID: String) -> Bool {
        outcomes[clipID]?[extensionID] != nil
    }

    private func finish(
        key: RequestKey,
        token: UInt64,
        decorations result: CardDecorations
    ) {
        guard requestTokens[key] == token else { return }
        requestTokens.removeValue(forKey: key)
        inFlight.remove(key)

        if outcomes[key.clipID] == nil, outcomes.count >= Self.capacity {
            // Match ClipTextMetrics: overflow clears the small memoization cache.
            outcomes.removeAll(keepingCapacity: true)
        }
        var clipOutcomes = outcomes[key.clipID] ?? [:]
        // An empty value is still an evaluated result and prevents repeat
        // execution just as the former no-badge marker did.
        clipOutcomes[key.extensionID] = result
        // The captured clip ID prevents a recycled card from receiving stale output.
        outcomes[key.clipID] = clipOutcomes
    }

    private func weightedDecorations(for clipID: UUID) -> [CardDecorations] {
        let clipOutcomes = outcomes[clipID] ?? [:]
        return catalog.enabledExtensions.enumerated()
            .compactMap { entry -> WeightedDecorations? in
                let (catalogIndex, installedExtension) = entry
                guard let decorations = clipOutcomes[installedExtension.id] else { return nil }
                return WeightedDecorations(
                    value: decorations,
                    weight: installedExtension.manifest.weight,
                    catalogIndex: catalogIndex
                )
            }
            .sorted { lhs, rhs in
                lhs.weight == rhs.weight
                    ? lhs.catalogIndex < rhs.catalogIndex
                    : lhs.weight > rhs.weight
            }
            .map(\.value)
    }

    private func firstValue(
        for clipID: UUID,
        at keyPath: KeyPath<CardDecorations, String?>
    ) -> String? {
        weightedDecorations(for: clipID).compactMap { $0[keyPath: keyPath] }.first
    }

    private func isValidSystemSymbol(_ name: String) -> Bool {
        if let cached = iconValidity[name] { return cached }
        if iconValidity.count >= Self.iconValidationCapacity {
            iconValidity.removeAll(keepingCapacity: true)
        }
        let valid = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        ) != nil
        iconValidity[name] = valid
        return valid
    }

    private func cancelRequests(where shouldCancel: (RequestKey) -> Bool) {
        let cancelled = inFlight.filter(shouldCancel)
        for key in cancelled {
            inFlight.remove(key)
            requestTokens.removeValue(forKey: key)
        }
    }

    private struct WeightedDecorations {
        let value: CardDecorations
        let weight: Double
        let catalogIndex: Int
    }
}

enum SuggestedPinboardMatcher {
    static func matchingPinboard(
        named suggestion: String?,
        in pinboards: [Pinboard],
        for item: ClipItem
    ) -> Pinboard? {
        guard let suggestion = normalized(suggestion) else { return nil }
        return pinboards.first { pinboard in
            guard let name = normalized(pinboard.name) else { return false }
            return name.compare(suggestion, options: .caseInsensitive) == .orderedSame
                && !pinboard.items.contains(where: { $0.sameContent(as: item) })
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
