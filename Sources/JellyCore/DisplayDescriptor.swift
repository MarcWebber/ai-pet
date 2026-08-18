public struct DisplayDescriptor: Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
    public let isPrimary: Bool

    public init(
        id: UInt32,
        name: String,
        width: Int,
        height: Int,
        isPrimary: Bool
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.isPrimary = isPrimary
    }
}
