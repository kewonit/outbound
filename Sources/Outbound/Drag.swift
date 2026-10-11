import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let outboundItem = UTType(exportedAs: "app.outbound.item")
}

/// A prompt or category being dragged inside the panel. Prompts carry their text,
/// so they can also be dropped into other apps.
struct DragItem: Codable, Transferable {
    enum Kind: String, Codable {
        case prompt, category
    }

    var kind: Kind
    var id: UUID
    var text: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .outboundItem)
        ProxyRepresentation(exporting: \.text)
    }
}

extension [DragItem] {
    func ids(_ kind: DragItem.Kind) -> [UUID] {
        filter { $0.kind == kind }.map(\.id)
    }
}
