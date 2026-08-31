import Foundation
import XCTest
@testable import Pesty

final class ExtensionAuthoringExamplesTests: XCTestCase {
    func testEveryCookbookExampleValidatesAndUsesAUniqueID() throws {
        let examples = try javascriptExamples()
        XCTAssertGreaterThanOrEqual(
            examples.count,
            15,
            "The cookbook fence scanner found too few complete examples"
        )

        let host = ExtensionHost()
        var ids: Set<String> = []
        for (index, source) in examples.enumerated() {
            switch host.validate(source: source) {
            case .success(let manifest):
                XCTAssertTrue(
                    ids.insert(manifest.id).inserted,
                    "Duplicate cookbook extension id: \(manifest.id)"
                )
            case .failure(let error):
                XCTFail(
                    "Cookbook JavaScript fence \(index + 1) failed validation: "
                        + error.userDescription
                )
            }
        }
    }

    func testWordCountBadgeExampleBehavior() throws {
        let host = ExtensionHost()
        let installedExtension = try installedExample(
            id: "com.example.word-count",
            host: host
        )

        XCTAssertEqual(
            host.badgeSync(
                clipType: "text",
                text: "one two three",
                extension: installedExtension
            ),
            .success("3 words")
        )
    }

    func testTrackingParameterTransformExampleBehavior() throws {
        let host = ExtensionHost()
        let installedExtension = try installedExample(
            id: "com.example.utm-strip",
            host: host
        )

        XCTAssertEqual(
            host.transformSync(
                clipType: "link",
                text: "https://example.com/article?utm_source=newsletter&id=42"
                    + "&utm_medium=email#part",
                extension: installedExtension
            ),
            .success("https://example.com/article?id=42#part")
        )
    }

    func testEmailCategoryExampleBehavior() throws {
        let host = ExtensionHost()
        let installedExtension = try installedExample(
            id: "com.example.email-category",
            host: host
        )

        let decorations = try host.decorationsSync(
            clipType: "text",
            text: "Contact Ada at ada@example.com for details.",
            extension: installedExtension
        ).get()
        XCTAssertEqual(decorations.label, "Email")
        XCTAssertEqual(decorations.icon, "envelope.fill")
    }

    func testURLHostKeywordExampleBehavior() throws {
        let host = ExtensionHost()
        let installedExtension = try installedExample(
            id: "com.example.url-host-keyword",
            host: host
        )

        XCTAssertEqual(
            host.keywordsSync(
                clipType: "link",
                text: "https://Docs.Example.com:443/guide/start?q=swift",
                extension: installedExtension
            ),
            .success(["docs.example.com"])
        )
    }

    private func installedExample(
        id: String,
        host: ExtensionHost
    ) throws -> InstalledExtension {
        let examples = try javascriptExamples()
        let source = try XCTUnwrap(
            examples.first { source in
                guard case .success(let manifest) = host.validate(source: source) else {
                    return false
                }
                return manifest.id == id
            },
            "Missing cookbook example \(id)"
        )
        let manifest = try host.validate(source: source).get()
        return InstalledExtension(
            manifest: manifest,
            source: source,
            enabled: true,
            isBundled: false,
            installedAt: .now
        )
    }

    private func javascriptExamples() throws -> [String] {
        let document = try String(contentsOf: cookbookURL, encoding: .utf8)
        var examples: [String] = []
        var currentLines: [String] = []
        var insideJavaScriptFence = false

        for line in document.components(separatedBy: .newlines) {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if !insideJavaScriptFence, marker == "```javascript" {
                insideJavaScriptFence = true
                currentLines.removeAll(keepingCapacity: true)
            } else if insideJavaScriptFence, marker == "```" {
                let source = currentLines.joined(separator: "\n")
                if source.contains("pesty.register") {
                    examples.append(source)
                }
                insideJavaScriptFence = false
            } else if insideJavaScriptFence {
                currentLines.append(line)
            }
        }

        guard !insideJavaScriptFence else {
            throw CookbookReadError.unclosedJavaScriptFence
        }
        return examples
    }

    private var cookbookURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EXTENSION-AUTHORING.md")
    }
}

private enum CookbookReadError: Error {
    case unclosedJavaScriptFence
}
