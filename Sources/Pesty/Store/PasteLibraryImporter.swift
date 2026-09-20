import AppKit
import Foundation
import SQLite3

struct PasteImportSummary {
    let history: Int
    let pinboards: Int
    let images: Int
}

@MainActor
enum PasteLibraryImporter {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.wiheads.paste-setapp/db.sqlite")

    static func importLibrary(from url: URL) throws -> PasteImportSummary {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw ImportError.unreadable }
        defer { sqlite3_close(database) }

        let rows = try readItems(database)
        var history: [ClipItem] = []
        var boards: [String: [ClipItem]] = [:]
        var boardColors: [String: String] = [:]
        var imageCount = 0
        for row in rows {
            guard let item = decode(row, imageCount: &imageCount) else { continue }
            if row.listName == "Clipboard History" || row.listType == 1 || row.listName == nil {
                history.append(item)
            } else if let name = row.listName {
                boards[name, default: []].append(item)
                boardColors[name] = "#5B8DEF"
            }
        }
        let pinboards = boards.enumerated().map { index, entry in
            Pinboard(name: entry.key, colorHex: boardColors[entry.key] ?? "#5B8DEF",
                     items: entry.value, sortIndex: index)
        }
        ClipboardStore.shared.mergeImportedLibrary(history: history, pinboards: pinboards)
        return PasteImportSummary(history: history.count, pinboards: pinboards.count, images: imageCount)
    }

    private struct Row {
        let type: Int
        let title: String?
        let timestamp: Date
        let listName: String?
        let listType: Int?
        let sourceID: String?
        let sourceName: String?
        let preview: Data?
    }

    private static func readItems(_ db: OpaquePointer) throws -> [Row] {
        let sql = """
        SELECT i.ZRAWTYPE, i.ZTITLE, i.ZCREATEDAT, l.ZNAME, l.ZRAWTYPE,
               a.ZBUNDLEIDENTIFIER, a.ZNAME, i.ZRAWPREVIEW
        FROM ZITEMENTITY i
        LEFT JOIN ZLISTENTITY l ON l.Z_PK = i.ZLIST
        LEFT JOIN ZAPPLICATIONENTITY a ON a.Z_PK = i.ZSOURCEAPPLICATION
        ORDER BY i.ZCREATEDAT ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ImportError.unreadable }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            rows.append(Row(type: Int(sqlite3_column_int(statement, 0)),
                            title: string(statement, 1), timestamp: timestamp,
                            listName: string(statement, 3),
                            listType: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 4)),
                            sourceID: string(statement, 5), sourceName: string(statement, 6),
                            preview: blob(statement, 7)))
        }
        return rows
    }

    private static func decode(_ row: Row, imageCount: inout Int) -> ClipItem? {
        guard let preview = row.preview else {
            if row.type == 5 { return ClipItem(type: .text, text: row.title, sourceBundleID: row.sourceID, sourceAppName: row.sourceName, createdAt: row.timestamp) }
            return nil
        }
        let values: [String: Any]
        if let json = try? JSONSerialization.jsonObject(with: preview) as? [String: Any] {
            values = json
        } else if let plist = try? PropertyListSerialization.propertyList(from: preview, options: [], format: nil) {
            values = plist as? [String: Any] ?? [:]
        } else {
            values = [:]
        }
        let type = (values["type"] as? String)?.lowercased()
        let date = row.timestamp
        if row.type == 4 || type == "link" {
            guard let url = values["url"] as? String else { return nil }
            return ClipItem(type: .link, text: url, sourceBundleID: row.sourceID,
                            sourceAppName: row.sourceName, customTitle: values["urlName"] as? String, createdAt: date)
        }
        if row.type == 2 || type == "color" {
            let code = values["colorCode"] as? String ?? row.title
            return ClipItem(type: .color, colorHex: code, sourceBundleID: row.sourceID,
                            sourceAppName: row.sourceName, createdAt: date)
        }
        if row.type == 1 || type == "image", let data = values["imageData"] as? Data,
           let name = ClipboardStore.shared.storeImageData(data) {
            imageCount += 1
            return ClipItem(type: .image, imageFileName: name, sourceBundleID: row.sourceID,
                            sourceAppName: row.sourceName, createdAt: date)
        }
        if row.type == 3 || type == "file" {
            let paths = (values["files"] as? [String]) ?? (values["filePaths"] as? [String]) ?? []
            return ClipItem(type: .file, text: paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "),
                            fileURLs: paths.map { URL(fileURLWithPath: $0).absoluteString },
                            sourceBundleID: row.sourceID, sourceAppName: row.sourceName, createdAt: date)
        }
        if let text = values["text"] as? String {
            return ClipItem(type: row.type == 5 && values["rtfData"] != nil ? .richText : .text,
                            text: text, sourceBundleID: row.sourceID, sourceAppName: row.sourceName,
                            customTitle: row.title, createdAt: date)
        }
        if let parts = values["text"] as? [Any], let text = parts.first as? String {
            return ClipItem(type: .richText, text: text, sourceBundleID: row.sourceID,
                            sourceAppName: row.sourceName, customTitle: row.title, createdAt: date)
        }
        return nil
    }

    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "The Paste library could not be read." }
    }
}
