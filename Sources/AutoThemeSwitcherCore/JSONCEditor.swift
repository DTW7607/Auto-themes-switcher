import Foundation

/// Errors emitted by the lossless JSON-with-comments editor.
public enum JSONCEditorError: Error, Equatable, Sendable {
    case invalidUTF8
    case syntax(message: String, byteOffset: Int)
    case rootMustBeObject
    case duplicateKey(path: String, key: String)
    case typeMismatch(path: String, expected: String)
    case conflict(String)
}

extension JSONCEditorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "JSONC 文件不是有效的 UTF-8。"
        case let .syntax(message, offset):
            return "JSONC 语法错误（字节偏移 \(offset)）：\(message)"
        case .rootMustBeObject:
            return "VS Code settings.json 的根值必须是对象。"
        case let .duplicateKey(path, key):
            return "\(path) 中存在重复键 \(key)，为避免覆盖配置已停止。"
        case let .typeMismatch(path, expected):
            return "\(path) 的类型不正确，应为 \(expected)。"
        case let .conflict(message):
            return message
        }
    }
}

struct JSONCMember: Sendable {
    let key: String
    let keyRange: Range<Int>
    let value: JSONCNode
    var commaRange: Range<Int>?
}

struct JSONCArrayElement: Sendable {
    let value: JSONCNode
    var commaRange: Range<Int>?
}

struct JSONCNode: Sendable {
    indirect enum Kind: Sendable {
        case object([JSONCMember])
        case array([JSONCArrayElement])
        case string(String)
        case number
        case bool(Bool)
        case null
    }

    let range: Range<Int>
    let kind: Kind
}

private struct JSONCToken {
    enum Kind {
        case leftBrace, rightBrace, leftBracket, rightBracket, colon, comma
        case string(String), number, bool(Bool), null, eof
    }

    let kind: Kind
    let range: Range<Int>
}

private struct JSONCLexer {
    let bytes: [UInt8]
    var index: Int

    init(bytes: [UInt8]) {
        self.bytes = bytes
        self.index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    }

    mutating func next() throws -> JSONCToken {
        try skipTrivia()
        guard index < bytes.count else {
            return JSONCToken(kind: .eof, range: index..<index)
        }

        let start = index
        switch bytes[index] {
        case 0x7B: index += 1; return token(.leftBrace, start)
        case 0x7D: index += 1; return token(.rightBrace, start)
        case 0x5B: index += 1; return token(.leftBracket, start)
        case 0x5D: index += 1; return token(.rightBracket, start)
        case 0x3A: index += 1; return token(.colon, start)
        case 0x2C: index += 1; return token(.comma, start)
        case 0x22:
            return try readString()
        case 0x2D, 0x30...0x39:
            return try readNumber()
        case 0x74:
            return try readLiteral("true", kind: .bool(true))
        case 0x66:
            return try readLiteral("false", kind: .bool(false))
        case 0x6E:
            return try readLiteral("null", kind: .null)
        default:
            throw syntax("无法识别的字符", at: start)
        }
    }

    private func token(_ kind: JSONCToken.Kind, _ start: Int) -> JSONCToken {
        JSONCToken(kind: kind, range: start..<index)
    }

    private mutating func skipTrivia() throws {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case 0x2F where index + 1 < bytes.count && bytes[index + 1] == 0x2F:
                index += 2
                while index < bytes.count && bytes[index] != 0x0A && bytes[index] != 0x0D { index += 1 }
            case 0x2F where index + 1 < bytes.count && bytes[index + 1] == 0x2A:
                let start = index
                index += 2
                var closed = false
                while index + 1 < bytes.count {
                    if bytes[index] == 0x2A && bytes[index + 1] == 0x2F {
                        index += 2
                        closed = true
                        break
                    }
                    index += 1
                }
                if !closed { throw syntax("块注释未闭合", at: start) }
            default:
                return
            }
        }
    }

    private mutating func readString() throws -> JSONCToken {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let data = Data(bytes[start..<index])
                do {
                    let value = try JSONDecoder().decode(String.self, from: data)
                    return JSONCToken(kind: .string(value), range: start..<index)
                } catch {
                    throw syntax("字符串转义或 Unicode 无效", at: start)
                }
            }
            if byte < 0x20 { throw syntax("字符串包含未转义的控制字符", at: index) }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { throw syntax("字符串转义未完成", at: start) }
                if bytes[index] == 0x75 {
                    guard index + 4 < bytes.count else { throw syntax("Unicode 转义未完成", at: index) }
                    for position in (index + 1)...(index + 4) where !Self.isHex(bytes[position]) {
                        throw syntax("Unicode 转义无效", at: position)
                    }
                    index += 5
                    continue
                }
                guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(bytes[index]) else {
                    throw syntax("字符串转义无效", at: index)
                }
            }
            index += 1
        }
        throw syntax("字符串未闭合", at: start)
    }

    private mutating func readNumber() throws -> JSONCToken {
        let start = index
        if bytes[index] == 0x2D { index += 1 }
        guard index < bytes.count else { throw syntax("数字不完整", at: start) }
        if bytes[index] == 0x30 {
            index += 1
            if index < bytes.count && Self.isDigit(bytes[index]) { throw syntax("数字不能有前导零", at: index) }
        } else {
            guard (0x31...0x39).contains(bytes[index]) else { throw syntax("数字无效", at: index) }
            while index < bytes.count && Self.isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count && bytes[index] == 0x2E {
            index += 1
            guard index < bytes.count && Self.isDigit(bytes[index]) else { throw syntax("小数部分不完整", at: index) }
            while index < bytes.count && Self.isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) { index += 1 }
            guard index < bytes.count && Self.isDigit(bytes[index]) else { throw syntax("指数部分不完整", at: index) }
            while index < bytes.count && Self.isDigit(bytes[index]) { index += 1 }
        }
        return JSONCToken(kind: .number, range: start..<index)
    }

    private mutating func readLiteral(_ literal: String, kind: JSONCToken.Kind) throws -> JSONCToken {
        let start = index
        let expected = Array(literal.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw syntax("字面量无效", at: start)
        }
        index += expected.count
        return JSONCToken(kind: kind, range: start..<index)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    private func syntax(_ message: String, at offset: Int) -> JSONCEditorError {
        .syntax(message: message, byteOffset: offset)
    }
}

private struct JSONCParser {
    var lexer: JSONCLexer
    var current: JSONCToken

    init(bytes: [UInt8]) throws {
        var lexer = JSONCLexer(bytes: bytes)
        let first = try lexer.next()
        self.lexer = lexer
        self.current = first
    }

    mutating func document() throws -> JSONCNode {
        let node = try value()
        guard case .eof = current.kind else { throw syntax("根值之后还有多余内容") }
        return node
    }

    private mutating func value() throws -> JSONCNode {
        switch current.kind {
        case .leftBrace: return try object()
        case .leftBracket: return try array()
        case let .string(value):
            let range = current.range; try advance(); return JSONCNode(range: range, kind: .string(value))
        case .number:
            let range = current.range; try advance(); return JSONCNode(range: range, kind: .number)
        case let .bool(value):
            let range = current.range; try advance(); return JSONCNode(range: range, kind: .bool(value))
        case .null:
            let range = current.range; try advance(); return JSONCNode(range: range, kind: .null)
        default:
            throw syntax("此处应为 JSON 值")
        }
    }

    private mutating func object() throws -> JSONCNode {
        let start = current.range.lowerBound
        try advance()
        var members: [JSONCMember] = []
        if case .rightBrace = current.kind {
            let end = current.range.upperBound; try advance()
            return JSONCNode(range: start..<end, kind: .object(members))
        }
        while true {
            guard case let .string(key) = current.kind else { throw syntax("对象键必须是字符串") }
            let keyRange = current.range
            try advance()
            guard case .colon = current.kind else { throw syntax("对象键后缺少冒号") }
            try advance()
            let memberValue = try value()
            var member = JSONCMember(key: key, keyRange: keyRange, value: memberValue, commaRange: nil)
            if case .comma = current.kind {
                member.commaRange = current.range
                try advance()
                members.append(member)
                if case .rightBrace = current.kind { break }
            } else {
                members.append(member)
                guard case .rightBrace = current.kind else { throw syntax("对象成员之间缺少逗号") }
                break
            }
        }
        let end = current.range.upperBound
        try advance()
        return JSONCNode(range: start..<end, kind: .object(members))
    }

    private mutating func array() throws -> JSONCNode {
        let start = current.range.lowerBound
        try advance()
        var elements: [JSONCArrayElement] = []
        if case .rightBracket = current.kind {
            let end = current.range.upperBound; try advance()
            return JSONCNode(range: start..<end, kind: .array(elements))
        }
        while true {
            let node = try value()
            var element = JSONCArrayElement(value: node, commaRange: nil)
            if case .comma = current.kind {
                element.commaRange = current.range
                try advance()
                elements.append(element)
                if case .rightBracket = current.kind { break }
            } else {
                elements.append(element)
                guard case .rightBracket = current.kind else { throw syntax("数组元素之间缺少逗号") }
                break
            }
        }
        let end = current.range.upperBound
        try advance()
        return JSONCNode(range: start..<end, kind: .array(elements))
    }

    private mutating func advance() throws { current = try lexer.next() }
    private func syntax(_ message: String) -> JSONCEditorError {
        .syntax(message: message, byteOffset: current.range.lowerBound)
    }
}

/// A byte-preserving JSONC editor. It parses comments and trailing commas, then
/// changes only the byte ranges belonging to explicitly requested settings.
public struct JSONCEditor: Sendable {
    private var bytes: [UInt8]
    private var root: JSONCNode

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        let contentStart = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        guard String(bytes: bytes[contentStart...], encoding: .utf8) != nil else { throw JSONCEditorError.invalidUTF8 }
        var parser = try JSONCParser(bytes: bytes)
        let root = try parser.document()
        guard case .object = root.kind else { throw JSONCEditorError.rootMustBeObject }
        self.bytes = bytes
        self.root = root
    }

    public init(_ source: String) throws { try self.init(data: Data(source.utf8)) }

    public var data: Data { Data(bytes) }
    public var source: String { String(decoding: bytes, as: UTF8.self) }
    public var hasUTF8BOM: Bool { bytes.starts(with: [0xEF, 0xBB, 0xBF]) }
    public var lineEnding: String { bytes.containsSequence([0x0D, 0x0A]) ? "\r\n" : "\n" }

    public func rootString(forKey key: String) throws -> String? {
        guard let member = try uniqueRootMember(key) else { return nil }
        guard case let .string(value) = member.value.kind else {
            throw JSONCEditorError.typeMismatch(path: key, expected: "字符串")
        }
        return value
    }

    public func rootBoolean(forKey key: String) throws -> Bool? {
        guard let member = try uniqueRootMember(key) else { return nil }
        guard case let .bool(value) = member.value.kind else {
            throw JSONCEditorError.typeMismatch(path: key, expected: "布尔值")
        }
        return value
    }

    public func rootStringArray(forKey key: String) throws -> [String]? {
        guard let member = try uniqueRootMember(key) else { return nil }
        guard case let .array(elements) = member.value.kind else {
            throw JSONCEditorError.typeMismatch(path: key, expected: "字符串数组")
        }
        return try elements.map { element in
            guard case let .string(value) = element.value.kind else {
                throw JSONCEditorError.typeMismatch(path: key, expected: "字符串数组")
            }
            return value
        }
    }

    public mutating func setRootString(_ value: String, forKey key: String) throws {
        try setRootRawValue(Self.quoted(value), forKey: key)
    }

    public mutating func setRootBoolean(_ value: Bool, forKey key: String) throws {
        try setRootRawValue(value ? "true" : "false", forKey: key)
    }

    public mutating func appendUniqueString(_ value: String, toRootArray key: String) throws {
        guard let member = try uniqueRootMember(key) else {
            try setRootRawValue("[\(Self.quoted(value))]", forKey: key)
            return
        }
        guard case let .array(elements) = member.value.kind else {
            throw JSONCEditorError.typeMismatch(path: key, expected: "字符串数组")
        }
        let strings = try elements.map { element -> String in
            guard case let .string(string) = element.value.kind else {
                throw JSONCEditorError.typeMismatch(path: key, expected: "字符串数组")
            }
            return string
        }
        guard !strings.contains(value) else { return }
        let close = member.value.range.upperBound - 1
        if let last = elements.last {
            let multiline = bytes[member.value.range].contains(0x0A) || bytes[member.value.range].contains(0x0D)
            let insertionPosition = multiline ? closingIndentStart(before: close) : close
            let insertion: String
            if multiline {
                let itemIndent = indentation(at: elements.first?.value.range.lowerBound ?? member.keyRange.lowerBound)
                let fallback = indentation(at: member.keyRange.lowerBound) + indentUnit(for: root)
                insertion = (itemIndent.isEmpty ? fallback : itemIndent) + Self.quoted(value) + lineEnding
            } else {
                insertion = " " + Self.quoted(value)
            }
            var edits = [ByteEdit(range: insertionPosition..<insertionPosition, replacement: Array(insertion.utf8))]
            if last.commaRange == nil {
                edits.append(ByteEdit(range: last.value.range.upperBound..<last.value.range.upperBound, replacement: [0x2C]))
            }
            try apply(edits)
        } else {
            if bytes[member.value.range].contains(0x0A) || bytes[member.value.range].contains(0x0D) {
                let position = closingIndentStart(before: close)
                let itemIndent = indentation(at: member.keyRange.lowerBound) + indentUnit(for: root)
                try apply([ByteEdit(range: position..<position, replacement: Array((itemIndent + Self.quoted(value) + lineEnding).utf8))])
            } else {
                try apply([ByteEdit(range: close..<close, replacement: Array(Self.quoted(value).utf8))])
            }
        }
    }

    public mutating func removeString(_ value: String, fromRootArray key: String) throws {
        while true {
            guard let member = try uniqueRootMember(key) else { return }
            guard case let .array(elements) = member.value.kind else {
                throw JSONCEditorError.typeMismatch(path: key, expected: "字符串数组")
            }
            let values = try elements.map { element -> String in
                guard case let .string(string) = element.value.kind else {
                    throw JSONCEditorError.typeMismatch(path: key, expected: "字符串数组")
                }
                return string
            }
            guard let index = values.firstIndex(of: value) else { return }
            let element = elements[index]
            var edits: [ByteEdit] = []
            if let comma = element.commaRange {
                edits.append(ByteEdit(range: element.value.range.lowerBound..<comma.upperBound, replacement: []))
            } else {
                edits.append(ByteEdit(range: element.value.range, replacement: []))
                if index > 0, let previousComma = elements[index - 1].commaRange {
                    edits.append(ByteEdit(range: previousComma, replacement: []))
                }
            }
            try apply(edits)
        }
    }

    /// Installs the two theme-qualified color blocks. Existing flat members are
    /// wrapped byte-for-byte (with one indentation level added) in Dark Modern.
    /// Existing incomplete theme blocks are treated as a conflict.
    @discardableResult
    public mutating func installVSCodeThemeColorBlocks(
        lightColors: [(String, String)],
        acceptExistingManagedBlocks: Bool = false
    ) throws -> Bool {
        let setting = "workbench.colorCustomizations"
        if let member = try uniqueRootMember(setting) {
            guard case let .object(members) = member.value.kind else {
                throw JSONCEditorError.typeMismatch(path: setting, expected: "对象")
            }
            try rejectDuplicateKeys(members, path: setting)
            let dark = members.filter { $0.key == "[Dark Modern]" }
            let light = members.filter { $0.key == "[Light Modern]" }
            let themed = members.filter { Self.isThemeSelector($0.key) }
            let flat = members.filter { !Self.isThemeSelector($0.key) }
            if dark.count == 1, light.count == 1, flat.isEmpty {
                guard acceptExistingManagedBlocks else {
                    throw JSONCEditorError.conflict("workbench.colorCustomizations 已存在 Dark Modern/Light Modern 主题块，但没有本 App 的 ownership manifest；未修改文件。")
                }
                return false
            }
            if !themed.isEmpty {
                throw JSONCEditorError.conflict("workbench.colorCustomizations 已包含主题限定块，无法确认归属；未修改文件。")
            }

            let baseIndent = indentation(at: member.keyRange.lowerBound)
            let unit = indentUnit(for: root)
            let childIndent = baseIndent + unit
            let inner = Array(bytes[(member.value.range.lowerBound + 1)..<(member.value.range.upperBound - 1)])
            let shiftedInner = indentAfterNewlines(inner, by: Array(unit.utf8))
            var replacement = "{" + lineEnding + childIndent + Self.quoted("[Dark Modern]") + ": {"
            replacement += String(decoding: shiftedInner, as: UTF8.self)
            replacement += "}," + lineEnding + childIndent + Self.quoted("[Light Modern]") + ": "
            replacement += renderObject(lightColors, baseIndent: childIndent, unit: unit)
            replacement += lineEnding + baseIndent + "}"
            try apply([ByteEdit(range: member.value.range, replacement: Array(replacement.utf8))])
            return true
        }

        let memberIndent = childIndent(for: root)
        let unit = indentUnit(for: root)
        var object = "{" + lineEnding + memberIndent + unit + Self.quoted("[Dark Modern]") + ": {},"
        object += lineEnding + memberIndent + unit + Self.quoted("[Light Modern]") + ": "
        object += renderObject(lightColors, baseIndent: memberIndent + unit, unit: unit)
        object += lineEnding + memberIndent + "}"
        try setRootRawValue(object, forKey: setting)
        return true
    }

    public func hasInstalledVSCodeThemeColorBlocks() throws -> Bool {
        guard let member = try uniqueRootMember("workbench.colorCustomizations") else { return false }
        guard case let .object(members) = member.value.kind else {
            throw JSONCEditorError.typeMismatch(path: "workbench.colorCustomizations", expected: "对象")
        }
        try rejectDuplicateKeys(members, path: "workbench.colorCustomizations")
        return members.contains { $0.key == "[Dark Modern]" } && members.contains { $0.key == "[Light Modern]" }
    }

    public func hasAnyVSCodeThemeColorBlock() throws -> Bool {
        guard let member = try uniqueRootMember("workbench.colorCustomizations") else { return false }
        guard case let .object(members) = member.value.kind else {
            throw JSONCEditorError.typeMismatch(path: "workbench.colorCustomizations", expected: "对象")
        }
        try rejectDuplicateKeys(members, path: "workbench.colorCustomizations")
        return members.contains { Self.isThemeSelector($0.key) }
    }

    func rawRootValue(forKey key: String) throws -> Data? {
        guard let member = try uniqueRootMember(key) else { return nil }
        return Data(bytes[member.value.range])
    }

    mutating func setRootRawData(_ value: Data, forKey key: String) throws {
        try setRootRawValue(String(decoding: value, as: UTF8.self), forKey: key)
    }

    mutating func removeRootValue(forKey key: String) throws {
        guard let member = try uniqueRootMember(key) else { return }
        guard case let .object(members) = root.kind,
              let index = members.firstIndex(where: { $0.keyRange == member.keyRange }) else { return }
        var edits: [ByteEdit] = []
        if let comma = member.commaRange {
            edits.append(ByteEdit(range: member.keyRange.lowerBound..<comma.upperBound, replacement: []))
        } else {
            edits.append(ByteEdit(range: member.keyRange.lowerBound..<member.value.range.upperBound, replacement: []))
            if index > 0, let previousComma = members[index - 1].commaRange {
                edits.append(ByteEdit(range: previousComma, replacement: []))
            }
        }
        try apply(edits)
    }

    private mutating func setRootRawValue(_ rawValue: String, forKey key: String) throws {
        _ = try JSONCEditor("{\"value\":\(rawValue)}")
        if let member = try uniqueRootMember(key) {
            let existing = String(decoding: bytes[member.value.range], as: UTF8.self)
            guard existing != rawValue else { return }
            try apply([ByteEdit(range: member.value.range, replacement: Array(rawValue.utf8))])
            return
        }
        guard case let .object(members) = root.kind else { throw JSONCEditorError.rootMustBeObject }
        let close = root.range.upperBound - 1
        let memberIndent = childIndent(for: root)
        let baseIndent = indentation(at: close)
        var edits: [ByteEdit] = []
        if let last = members.last, last.commaRange == nil {
            edits.append(ByteEdit(range: last.value.range.upperBound..<last.value.range.upperBound, replacement: [0x2C]))
        }
        let insertion: String
        if isMultiline(object: root) {
            let position = closingIndentStart(before: close)
            insertion = memberIndent + Self.quoted(key) + ": " + rawValue + lineEnding
            edits.append(ByteEdit(range: position..<position, replacement: Array(insertion.utf8)))
        } else if members.isEmpty {
            insertion = Self.quoted(key) + ": " + rawValue
            edits.append(ByteEdit(range: close..<close, replacement: Array(insertion.utf8)))
        } else {
            insertion = " " + Self.quoted(key) + ": " + rawValue + " "
            edits.append(ByteEdit(range: close..<close, replacement: Array(insertion.utf8)))
        }
        _ = baseIndent
        try apply(edits)
    }

    private func uniqueRootMember(_ key: String) throws -> JSONCMember? {
        guard case let .object(members) = root.kind else { throw JSONCEditorError.rootMustBeObject }
        let matches = members.filter { $0.key == key }
        if matches.count > 1 { throw JSONCEditorError.duplicateKey(path: "$", key: key) }
        return matches.first
    }

    private func rejectDuplicateKeys(_ members: [JSONCMember], path: String) throws {
        var seen: Set<String> = []
        for member in members {
            if !seen.insert(member.key).inserted {
                throw JSONCEditorError.duplicateKey(path: path, key: member.key)
            }
        }
    }

    private struct ByteEdit {
        let range: Range<Int>
        var replacement: [UInt8]
    }

    private mutating func apply(_ edits: [ByteEdit]) throws {
        let sorted = edits.sorted { $0.range.lowerBound > $1.range.lowerBound }
        var previousLowerBound = bytes.count + 1
        var candidate = bytes
        for edit in sorted {
            guard edit.range.lowerBound >= 0, edit.range.upperBound <= candidate.count,
                  edit.range.upperBound <= previousLowerBound else {
                throw JSONCEditorError.conflict("内部 JSONC 编辑范围重叠。")
            }
            candidate.replaceSubrange(edit.range, with: edit.replacement)
            previousLowerBound = edit.range.lowerBound
        }
        var parser = try JSONCParser(bytes: candidate)
        let parsed = try parser.document()
        guard case .object = parsed.kind else { throw JSONCEditorError.rootMustBeObject }
        bytes = candidate
        root = parsed
    }

    private func renderObject(_ pairs: [(String, String)], baseIndent: String, unit: String) -> String {
        guard !pairs.isEmpty else { return "{}" }
        let body = pairs.enumerated().map { index, pair in
            baseIndent + unit + Self.quoted(pair.0) + ": " + Self.quoted(pair.1) + (index + 1 == pairs.count ? "" : ",")
        }.joined(separator: lineEnding)
        return "{" + lineEnding + body + lineEnding + baseIndent + "}"
    }

    private func indentation(at offset: Int) -> String {
        var lineStart = offset
        while lineStart > 0 && bytes[lineStart - 1] != 0x0A && bytes[lineStart - 1] != 0x0D { lineStart -= 1 }
        var end = lineStart
        while end < offset && (bytes[end] == 0x20 || bytes[end] == 0x09) { end += 1 }
        return String(decoding: bytes[lineStart..<end], as: UTF8.self)
    }

    private func indentUnit(for object: JSONCNode) -> String {
        guard case let .object(members) = object.kind, let first = members.first else { return "    " }
        let base = indentation(at: object.range.upperBound - 1)
        let child = indentation(at: first.keyRange.lowerBound)
        if child.hasPrefix(base), child.count > base.count { return String(child.dropFirst(base.count)) }
        return child.isEmpty ? "    " : child
    }

    private func childIndent(for object: JSONCNode) -> String {
        guard case let .object(members) = object.kind else { return "    " }
        if let first = members.first { return indentation(at: first.keyRange.lowerBound) }
        return indentation(at: object.range.upperBound - 1) + indentUnit(for: object)
    }

    private func isMultiline(object: JSONCNode) -> Bool {
        bytes[object.range].contains(0x0A) || bytes[object.range].contains(0x0D)
    }

    private func closingIndentStart(before close: Int) -> Int {
        var start = close
        while start > 0 && (bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09) { start -= 1 }
        return start
    }

    private func indentAfterNewlines(_ input: [UInt8], by indentation: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(input.count + indentation.count * 4)
        for byte in input {
            result.append(byte)
            if byte == 0x0A { result.append(contentsOf: indentation) }
        }
        return result
    }

    private static func isThemeSelector(_ key: String) -> Bool { key.hasPrefix("[") && key.hasSuffix("]") }

    private static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x08: result += "\\b"
            case 0x0C: result += "\\f"
            case 0x0A: result += "\\n"
            case 0x0D: result += "\\r"
            case 0x09: result += "\\t"
            case 0x00...0x1F: result += String(format: "\\u%04X", scalar.value)
            default: result.append(contentsOf: String(scalar))
            }
        }
        result += "\""
        return result
    }
}

private extension Array where Element == UInt8 {
    func containsSequence(_ sequence: [UInt8]) -> Bool {
        guard !sequence.isEmpty, count >= sequence.count else { return false }
        for start in 0...(count - sequence.count) where Array(self[start..<(start + sequence.count)]) == sequence { return true }
        return false
    }
}
