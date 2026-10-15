import Foundation

/// Minimal Truevision TGA decoder: the format Inochi Creator writes textures in.
/// Supports uncompressed and RLE true-colour (24/32 bit) and greyscale images.
public enum TGADecoder {
    public struct Image: Sendable {
        public var width: Int
        public var height: Int
        /// Straight-alpha RGBA8, top row first.
        public var rgba: [UInt8]
    }

    public enum Failure: Error { case unsupported, truncated }

    public static func decode(_ data: Data) throws -> Image {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Image in
            let b = raw.bindMemory(to: UInt8.self)
            guard b.count >= 18 else { throw Failure.truncated }
            let idLength = Int(b[0])
            let colorMapType = b[1]
            let imageType = b[2]
            let width = Int(b[12]) | Int(b[13]) << 8
            let height = Int(b[14]) | Int(b[15]) << 8
            let bpp = Int(b[16])
            let descriptor = b[17]
            guard colorMapType == 0, width > 0, height > 0 else { throw Failure.unsupported }
            let rle: Bool
            let grey: Bool
            switch imageType {
            case 2: rle = false; grey = false
            case 3: rle = false; grey = true
            case 10: rle = true; grey = false
            case 11: rle = true; grey = true
            default: throw Failure.unsupported
            }
            let pixelBytes = bpp / 8
            guard grey ? (pixelBytes == 1 || pixelBytes == 2) : (pixelBytes == 3 || pixelBytes == 4) else {
                throw Failure.unsupported
            }

            var pos = 18 + idLength
            let total = width * height
            var out = [UInt8](repeating: 255, count: total * 4)

            func readPixel(into i: Int) throws {
                guard pos + pixelBytes <= b.count else { throw Failure.truncated }
                let o = i * 4
                if grey {
                    let v = b[pos]
                    out[o] = v; out[o + 1] = v; out[o + 2] = v
                    out[o + 3] = pixelBytes == 2 ? b[pos + 1] : 255
                } else {
                    out[o] = b[pos + 2]
                    out[o + 1] = b[pos + 1]
                    out[o + 2] = b[pos]
                    out[o + 3] = pixelBytes == 4 ? b[pos + 3] : 255
                }
                pos += pixelBytes
            }

            if rle {
                var i = 0
                while i < total {
                    guard pos < b.count else { throw Failure.truncated }
                    let header = Int(b[pos]); pos += 1
                    let count = (header & 0x7F) + 1
                    if header & 0x80 != 0 {
                        try readPixel(into: i)
                        let o = i * 4
                        for k in 1..<count where i + k < total {
                            let d = (i + k) * 4
                            out[d] = out[o]; out[d + 1] = out[o + 1]; out[d + 2] = out[o + 2]; out[d + 3] = out[o + 3]
                        }
                    } else {
                        for k in 0..<count where i + k < total { try readPixel(into: i + k) }
                    }
                    i += count
                }
            } else {
                for i in 0..<total { try readPixel(into: i) }
            }

            // Bit 5 set = rows stored top-to-bottom; otherwise flip.
            if descriptor & 0x20 == 0 {
                let row = width * 4
                var flipped = [UInt8](repeating: 0, count: out.count)
                for y in 0..<height {
                    let src = (height - 1 - y) * row
                    flipped.replaceSubrange(y * row..<(y + 1) * row, with: out[src..<(src + row)])
                }
                out = flipped
            }
            // Bit 4 set = right-to-left.
            if descriptor & 0x10 != 0 {
                for y in 0..<height {
                    for x in 0..<(width / 2) {
                        let a = (y * width + x) * 4, c = (y * width + width - 1 - x) * 4
                        for k in 0..<4 { out.swapAt(a + k, c + k) }
                    }
                }
            }
            return Image(width: width, height: height, rgba: out)
        }
    }

    /// Converts straight alpha to premultiplied alpha in place (inTexPremultiply).
    public static func premultiply(_ rgba: inout [UInt8]) {
        rgba.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i + 3 < p.count {
                let a = Int(p[i + 3])
                if a != 255 {
                    p[i] = UInt8(Int(p[i]) * a / 255)
                    p[i + 1] = UInt8(Int(p[i + 1]) * a / 255)
                    p[i + 2] = UInt8(Int(p[i + 2]) * a / 255)
                }
                i += 4
            }
        }
    }
}
