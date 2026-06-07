/// The kind of media an ``Exportable`` represents.
///
/// This is the seam that lets video sharing slot in alongside image sharing
/// without reworking the pipeline: the share UI asks the current result for its
/// `MediaKind` and offers the matching set of ``ExportFormat``s.
public enum MediaKind: Sendable, Hashable {
    case image
    case video
}
