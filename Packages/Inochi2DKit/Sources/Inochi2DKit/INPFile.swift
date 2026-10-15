// INP/INX container reader, following Inochi2D 0.8 (inochi2d.fmt).
// Copyright © 2020, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

public enum INPError: Error, LocalizedError {
    case notAPuppet
    case truncated
    case badJSON(String)

    public var errorDescription: String? {
        switch self {
        case .notAPuppet: return "This file isn't an Inochi2D puppet (.inp or .inx)."
        case .truncated: return "The puppet file is incomplete or damaged."
        case let .badJSON(s): return "The puppet data couldn't be read: \(s)"
        }
    }
}

/// One texture slot from the file. Pixels stay encoded until a renderer asks for them.
public struct TextureBlob: Sendable {
    public enum Encoding: UInt8, Sendable {
        case png = 0, tga = 1, bc7 = 2
    }

    public var encoding: Encoding?
    public var data: Data

    public var isEmpty: Bool { data.isEmpty }
}

/// The raw contents of an `.inp`/`.inx` file.
public struct INPFile {
    public static let magic = Array("TRNSRTS\0".utf8)
    static let textureSection = Array("TEX_SECT".utf8)
    static let extSection = Array("EXT_SECT".utf8)

    public var json: [String: Any]
    public var textures: [TextureBlob]
    public var extensions: [String: Data]

    public init(data: Data) throws {
        var r = ByteReader(data)
        guard try r.bytes(8) == INPFile.magic else { throw INPError.notAPuppet }
        let jsonLength = Int(try r.u32())
        let jsonData = try r.data(jsonLength)
        do {
            guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                throw INPError.badJSON("top level is not an object")
            }
            json = obj
        } catch let e as INPError {
            throw e
        } catch {
            throw INPError.badJSON(error.localizedDescription)
        }

        guard try r.bytes(8) == INPFile.textureSection else { throw INPError.truncated }
        let count = Int(try r.u32())
        var tex: [TextureBlob] = []
        tex.reserveCapacity(count)
        for _ in 0..<count {
            let length = Int(try r.u32())
            let type = try r.u8()
            tex.append(TextureBlob(encoding: .init(rawValue: type), data: try r.data(length)))
        }
        textures = tex

        var ext: [String: Data] = [:]
        if r.remaining >= 8, (try? r.peek(8)) == INPFile.extSection {
            _ = try r.bytes(8)
            let sections = Int(try r.u32())
            for _ in 0..<sections {
                let nameLength = Int(try r.u32())
                let name = String(decoding: try r.bytes(nameLength), as: UTF8.self)
                let payloadLength = Int(try r.u32())
                ext[name] = try r.data(payloadLength)
            }
        }
        extensions = ext
    }
}

struct ByteReader {
    let data: Data
    var pos = 0

    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - pos }

    mutating func u8() throws -> UInt8 {
        guard pos < data.count else { throw INPError.truncated }
        defer { pos += 1 }
        return data[data.startIndex + pos]
    }

    /// Big-endian (the format uses network byte order).
    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        [UInt8](try data(n))
    }

    func peek(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos + n <= data.count else { throw INPError.truncated }
        let s = data.startIndex + pos
        return [UInt8](data[s..<(s + n)])
    }

    mutating func data(_ n: Int) throws -> Data {
        guard n >= 0, pos + n <= data.count else { throw INPError.truncated }
        let s = data.startIndex + pos
        pos += n
        return data.subdata(in: s..<(s + n))
    }
}

// MARK: - JSON helpers

extension Dictionary where Key == String, Value == Any {
    func float(_ key: String) -> Float? { (self[key] as? NSNumber)?.floatValue }
    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }
    func uint32(_ key: String) -> UInt32? {
        guard let n = self[key] as? NSNumber else { return nil }
        let d = n.doubleValue
        return d >= 0 && d <= Double(UInt32.max) ? UInt32(d) : nil
    }
    func string(_ key: String) -> String? { self[key] as? String }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }

    func vec2(_ key: String) -> Vec2? {
        guard let a = self[key] as? [NSNumber], a.count >= 2 else { return nil }
        return Vec2(a[0].floatValue, a[1].floatValue)
    }

    func vec3(_ key: String) -> Vec3? {
        guard let a = self[key] as? [NSNumber], a.count >= 3 else { return nil }
        return Vec3(a[0].floatValue, a[1].floatValue, a[2].floatValue)
    }

    func floats(_ key: String) -> [Float]? {
        (self[key] as? [NSNumber])?.map(\.floatValue)
    }
}
