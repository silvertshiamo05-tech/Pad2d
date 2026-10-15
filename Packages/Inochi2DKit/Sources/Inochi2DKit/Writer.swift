// Saving puppets in the Inochi2D 0.8 file format (.inp / .inx), as written by
// Inochi Creator (inochi2d.fmt.inWriteINPPuppetMemory).

import Foundation

extension Puppet {
    func serializeJSON() -> [String: Any] {
        var j = extraJSON
        var m = (extraJSON["meta"] as? [String: Any]) ?? [:]
        m["name"] = meta.name ?? NSNull()
        m["version"] = "v0.8.7"
        if let v = meta.rigger { m["rigger"] = v }
        if let v = meta.artist { m["artist"] = v }
        if let v = meta.copyright { m["copyright"] = v }
        if let v = meta.licenseURL { m["licenseURL"] = v }
        if let v = meta.contact { m["contact"] = v }
        if let v = meta.reference { m["reference"] = v }
        if m["thumbnailId"] == nil { m["thumbnailId"] = UInt32.max }
        m["preservePixels"] = meta.preservePixels
        j["meta"] = m
        j["physics"] = ["pixelsPerMeter": physics.pixelsPerMeter, "gravity": physics.gravity] as [String: Any]
        j["nodes"] = root.serialize()
        j["param"] = parameters.map { $0.serialize() }
        j["automation"] = automation.map { $0.serialize() }
        j["animations"] = animations.mapValues { $0.serialize() }
        j["groups"] = groups.map { $0.serialize() }
        return j
    }

    /// Encodes the puppet as an `.inp`/`.inx` file.
    public func fileData() -> Data {
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        let json = JSONWriter.encode(serializeJSON())
        var d = Data(INPFile.magic)
        d.append(contentsOf: be32(json.count))
        d.append(json)
        d.append(contentsOf: INPFile.textureSection)
        d.append(contentsOf: be32(textures.count))
        for t in textures {
            d.append(contentsOf: be32(t.data.count))
            d.append(t.encoding?.rawValue ?? 1)
            d.append(t.data)
        }
        if !extensions.isEmpty {
            d.append(contentsOf: INPFile.extSection)
            d.append(contentsOf: be32(extensions.count))
            for (name, payload) in extensions.sorted(by: { $0.key < $1.key }) {
                let n = Array(name.utf8)
                d.append(contentsOf: be32(n.count))
                d.append(contentsOf: n)
                d.append(contentsOf: be32(payload.count))
                d.append(payload)
            }
        }
        return d
    }
}

/// Small JSON encoder: compact, sorted keys, shortest float representation.
final class JSONWriter {
    private var out = [UInt8]()

    static func encode(_ value: Any) -> Data {
        let w = JSONWriter()
        w.out.reserveCapacity(1 << 20)
        w.write(value)
        return Data(w.out)
    }

    private func raw(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
    private func byte(_ c: Unicode.Scalar) { out.append(UInt8(ascii: c)) }

    private func array<T>(_ a: [T], _ each: (T) -> Void) {
        byte("[")
        for (i, e) in a.enumerated() {
            if i > 0 { byte(",") }
            each(e)
        }
        byte("]")
    }

    private func write(_ v: Any) {
        switch v {
        case let d as [String: Any]:
            byte("{")
            var first = true
            for k in d.keys.sorted() {
                if !first { byte(",") }
                first = false
                string(k)
                byte(":")
                write(d[k]!)
            }
            byte("}")
        case let a as [Float]: array(a) { self.float($0) }
        case let a as [Int]: array(a) { self.raw(String($0)) }
        case let a as [UInt32]: array(a) { self.raw(String($0)) }
        case let a as [[Float]]: array(a) { row in self.array(row) { self.float($0) } }
        case let a as [[Bool]]: array(a) { row in self.array(row) { self.raw($0 ? "true" : "false") } }
        case let a as [Any]: array(a) { self.write($0) }
        default: scalar(v)
        }
    }

    private func number(_ d: Double) {
        guard d.isFinite else { raw("0"); return }
        raw(d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : "\(d)")
    }

    private func scalar(_ v: Any) {
        let t = type(of: v)
        if t == Bool.self {
            raw((v as! Bool) ? "true" : "false")
        } else if t == Float.self {
            float(v as! Float)
        } else if t == Double.self {
            number(v as! Double)
        } else if t == Int.self || t == UInt32.self || t == Int32.self || t == UInt16.self || t == Int64.self || t == UInt64.self {
            raw("\(v)")
        } else if let s = v as? String {
            string(s)
        } else if v is NSNull {
            raw("null")
        } else if let n = v as? NSNumber {
            // Values read back through JSONSerialization.
            if String(cString: n.objCType) == "c" {
                raw(n.boolValue ? "true" : "false")
            } else {
                number(n.doubleValue)
            }
        } else {
            raw("null")
        }
    }

    private func float(_ f: Float) {
        guard f.isFinite else { raw("0"); return }
        raw(f == f.rounded() && abs(f) < 1e7 ? String(Int(f)) : "\(f)")
    }

    private func string(_ s: String) {
        byte("\"")
        for u in s.utf8 {
            switch u {
            case 34: out.append(contentsOf: [92, 34])
            case 92: out.append(contentsOf: [92, 92])
            case 10: out.append(contentsOf: [92, 110])
            case 13: out.append(contentsOf: [92, 114])
            case 9: out.append(contentsOf: [92, 116])
            case 0..<32: raw(String(format: "\\u%04x", u))
            default: out.append(u)
            }
        }
        byte("\"")
    }
}
