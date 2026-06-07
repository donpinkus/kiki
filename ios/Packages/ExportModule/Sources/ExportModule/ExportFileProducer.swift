import Foundation

/// Turns an ``Exportable`` into a temp file with a sensible, human-readable
/// filename — the share sheet and "Save to Files" surface this name verbatim,
/// so we go through a real file URL rather than handing raw bytes to the sheet.
public struct ExportFileProducer {
    public init() {}

    /// Encode `item` as `format` and write it to `directory` as
    /// `<sanitized baseName>.<ext>`, returning the file URL. Overwrites any
    /// existing file of the same name (callers reuse a stable base like "Kiki",
    /// so the temp dir self-cleans).
    public func makeFile(
        from item: Exportable,
        format: ExportFormat,
        baseName: String,
        in directory: URL
    ) throws -> URL {
        let data = try item.encode(as: format)
        let url = directory.appendingPathComponent(Self.fileName(baseName: baseName, format: format))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `<sanitized base>.<ext>`. Strips path separators / control characters and
    /// any extension already on the base name; falls back to "Kiki" if empty.
    static func fileName(baseName: String, format: ExportFormat) -> String {
        let sanitized = sanitize(baseName)
        let base = sanitized.isEmpty ? "Kiki" : sanitized
        return "\(base).\(format.fileExtension)"
    }

    static func sanitize(_ raw: String) -> String {
        // Drop any extension the caller already baked in so we don't double it.
        var name = (raw as NSString).deletingPathExtension
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        name = name.components(separatedBy: illegal).joined()
        name = name.trimmingCharacters(in: .whitespaces)
        return String(name.prefix(120))
    }
}
