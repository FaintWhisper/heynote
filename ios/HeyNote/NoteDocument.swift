import Foundation

enum NoteError: LocalizedError {
    case invalidFormat(String)
    case permission
    case noFolder
    case invalidPath
    case changedOnDisk
    case cloudConflict
    case alreadyExists
    case tooLarge
    case coordination

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let reason): return "Cannot open this buffer: \(reason)"
        case .permission: return "Folder access has expired. Choose the HeyNote folder again."
        case .noFolder: return "Choose your HeyNote folder in iCloud Drive first."
        case .invalidPath: return "This file path is not inside the selected folder."
        case .changedOnDisk: return "This buffer changed in iCloud Drive. Your edits are kept on this device."
        case .cloudConflict: return "iCloud has unresolved versions of this file. Save your edits as a new buffer, then resolve the original in Files."
        case .alreadyExists: return "A buffer with that filename already exists. Choose a different name."
        case .tooLarge: return "This buffer exceeds the 64 MB editing limit."
        case .coordination: return "iCloud Drive did not grant access to this file. Download it in Files and try again."
        }
    }
}

struct NoteBlock: Identifiable {
    var id = UUID()
    var delimiter: String
    var token: String
    var text: String

    var language: String {
        token.hasSuffix("-a") ? String(token.dropLast(2)) : token
    }

    var preview: String {
        let short = String(text.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
        return short.isEmpty ? "Empty block" : short
    }

    mutating func setLanguage(_ value: String) {
        if delimiter.isEmpty {
            delimiter = NoteDocument.delimiter(language: value)
        } else if let range = delimiter.range(of: "∞∞∞" + token) {
            delimiter.replaceSubrange(range, with: "∞∞∞" + value)
        }
        token = value
    }
}

struct NoteDocument {
    // Keep delimiter strings intact: they contain creation times and may contain
    // metadata added by a newer desktop version.
    private static let separators = try! NSRegularExpression(
        pattern: #"(?:\r?\n|\A)∞∞∞([a-zA-Z0-9_+\-]+)(?:;[^\r\n]*)?\r?\n"#
    )
    private(set) var metadata: [String: Any]?
    private var header: String
    var blocks: [NoteBlock]

    var title: String? { metadata?["name"] as? String }

    init(data: Data) throws {
        guard data.count <= 64 * 1024 * 1024 else { throw NoteError.tooLarge }
        guard let source = String(data: data, encoding: .utf8) else {
            throw NoteError.invalidFormat("the file is not UTF-8 text.")
        }
        let ns = source as NSString
        let matches = Self.separators.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first else {
            // Legacy plain-text buffers have no metadata or block separators.
            if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\"formatVersion\"") {
                throw NoteError.invalidFormat("the HeyNote block headers are missing.")
            }
            header = ""
            metadata = nil
            blocks = [NoteBlock(delimiter: "", token: "text", text: source)]
            return
        }
        header = ns.substring(to: first.range.location)
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if trimmed.isEmpty {
            metadata = nil
        } else {
            guard let json = trimmed.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                throw NoteError.invalidFormat("invalid JSON metadata before the first block.")
            }
            if let version = object["formatVersion"] {
                guard let string = version as? String,
                      let major = Int(string.split(separator: ".").first ?? ""), major <= 2 else {
                    throw NoteError.invalidFormat("this format version is not supported.")
                }
            }
            metadata = object
        }
        blocks = matches.enumerated().map { index, match in
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            return NoteBlock(delimiter: ns.substring(with: match.range),
                             token: ns.substring(with: match.range(at: 1)),
                             text: ns.substring(with: NSRange(location: start, length: end - start)))
        }
    }

    init(name: String) {
        metadata = ["formatVersion": "2.0.0", "name": name]
        header = ""
        blocks = [NoteBlock(delimiter: Self.delimiter(language: "text"), token: "text", text: "")]
    }

    static func delimiter(language: String) -> String {
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\n∞∞∞\(language);created=\(date.string(from: Date()))\n"
    }

    mutating func addBlock(language: String = "text") -> UUID {
        if blocks.first?.delimiter.isEmpty == true {
            blocks[0].delimiter = Self.delimiter(language: blocks[0].token)
        }
        let block = NoteBlock(delimiter: Self.delimiter(language: language), token: language, text: "")
        blocks.append(block)
        return block.id
    }

    mutating func rename(_ name: String) {
        if metadata == nil { metadata = ["formatVersion": "2.0.0"] }
        metadata?["name"] = name
    }

    mutating func preserveBlockIDs(from previous: NoteDocument) {
        var available: [String: [UUID]] = [:]
        for block in previous.blocks { available[block.delimiter, default: []].append(block.id) }
        for index in blocks.indices {
            let key = blocks[index].delimiter
            if let id = available[key]?.first {
                blocks[index].id = id
                available[key]?.removeFirst()
            }
        }
    }

    func data(forSaving: Bool) throws -> Data {
        var prefix = header
        if forSaving {
            for block in blocks {
                let candidate = "\n" + block.text
                if Self.separators.firstMatch(in: candidate, range: NSRange(location: 0, length: (candidate as NSString).length)) != nil {
                    throw NoteError.invalidFormat("a block contains a reserved ∞∞∞ header. Use Add Block to create blocks.")
                }
            }
            if var object = metadata {
                // Desktop positions use UTF-16 offsets and become stale after mobile edits.
                object.removeValue(forKey: "cursors")
                object.removeValue(forKey: "foldedRanges")
                let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
                prefix = String(decoding: encoded, as: UTF8.self)
            }
        }
        // A newly-created document has metadata but no serialized header yet.
        if prefix.isEmpty, let object = metadata {
            prefix = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
        return Data((prefix + blocks.map { $0.delimiter + $0.text }.joined()).utf8)
    }
}
