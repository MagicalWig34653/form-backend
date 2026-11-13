import NIOCore

public struct MySQLPacket {
    public var payload: ByteBuffer
    
    public init(payload: ByteBuffer) {
        self.payload = payload
    }
    
    public init() {
        self.payload = ByteBufferAllocator().buffer(capacity: 0)
    }
    
    public var isError: Bool {
        self.headerFlag == 0xFF
    }
    
    public var isOK: Bool {
        self.headerFlag == 0x00
    }
    
    public var isEOF: Bool {
        self.headerFlag == 0xFE
    }
    
    var headerFlag: UInt8? {
        self.payload.getInteger(at: self.payload.readerIndex)
    }
}

extension MySQLPacket: CustomStringConvertible {
    public var description: String {
        // LOCAL PATCH (form-backend S2-04): upstream printed the first 16 payload bytes, which contain the
        // cleartext DB password in the caching_sha2_password full-authentication packet. Length and flags only.
        return "<\(self.payload.readableBytes) payload bytes redacted> (err: \(self.isError), ok: \(self.isOK), eof: \(self.isEOF))"
    }
}

public protocol MySQLPacketDecodable {
    static func decode(from packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> Self
}

public protocol MySQLPacketEncodable {
    func encode(to packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws
}

extension MySQLPacket {
    public mutating func decode<T: MySQLPacketDecodable>(_: T.Type, capabilities: MySQLProtocol.CapabilityFlags) throws -> T {
        try T.decode(from: &self, capabilities: capabilities)
    }
    
    public static func encode<T: MySQLPacketEncodable>(_ value: T, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLPacket {
        var packet = MySQLPacket()
        try value.encode(to: &packet, capabilities: capabilities)
        return packet
    }
}
