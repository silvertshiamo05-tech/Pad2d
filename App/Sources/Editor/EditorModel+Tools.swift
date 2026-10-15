import SwiftUI
import Inochi2DKit

/// Tools menu operations and texture slot helpers.
extension EditorModel {
    func resetParameters() {
        for p in puppet?.parameters ?? [] { p.value = p.defaults }
        deform.reset()
        revision &+= 1
    }

    func premultiplyTextures() {
        puppet?.premultiplyTextures(decode: TextureLoader.decode)
        syncTextures()
        changed("Premultiply textures")
    }

    func bleedTextures() {
        puppet?.bleedTextures(decode: TextureLoader.decode)
        syncTextures()
        changed("Bleed textures")
        message = "Texture bleeding completed."
    }

    func generateLayerNames() {
        puppet?.generateLayerNames()
        changed("Generate layer names")
    }

    func repairPuppet() {
        puppet?.repair()
        selectedIDs = []
        changed("Repair puppet")
    }

    func regenerateNodeIDs() {
        puppet?.regenerateNodeIDs()
        selectedIDs = []
        changed("Regenerate node IDs")
    }

    // MARK: Texture slots

    /// A small image of a texture for the inspector.
    func thumbnail(texture index: Int) -> UIImage? {
        guard index < previews.count, let p = previews[index] else { return nil }
        return Self.image(p.rgba, p.width, p.height)
    }

    /// Premultiplied RGBA8 → UIImage.
    static func image(_ px: [UInt8], _ w: Int, _ h: Int) -> UIImage? {
        guard w > 0, h > 0, px.count >= w * h * 4 else { return nil }
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// The PNG of a part's texture slot.
    func pngData(part: Part, slot: Int) -> Data? {
        guard let puppet, let id = part.textureIDs[slot], id < puppet.textures.count,
              let (px, w, h) = TextureLoader.decode(puppet.textures[id]) else { return nil }
        var pm = px
        if puppet.textures[id].encoding != .tga { TGADecoder.premultiply(&pm) }
        return Self.image(pm, w, h)?.pngData()
    }

    /// Loads an image file into a part's texture slot. Emissive and bump maps
    /// must match the albedo's size, as in Creator.
    func loadTexture(_ url: URL, into part: Part, slot: Int) {
        guard let puppet else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), var (px, w, h) = TextureLoader.decodeImage(data) else {
            message = "\(url.lastPathComponent) is not supported."
            return
        }
        if slot > 0, let a = part.textureIDs[0], let (_, aw, ah) = TextureLoader.decode(puppet.textures[a]), aw != w || ah != h {
            message = "The texture must be the same size as the albedo (\(aw)×\(ah))."
            return
        }
        if slot == 0 {
            TGADecoder.premultiply(&px)
        } else {
            // Emissive and bump maps are colour only.
            for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        }
        let index = puppet.addTexture(rgba: px, width: w, height: h)
        puppet.setTexture(part, slot: slot, texture: index)
        if slot == 0 {
            // Other slots that no longer match the albedo's size are cleared.
            for s in 1..<3 {
                if let t = part.textureIDs[s], let (_, tw, th) = TextureLoader.decode(puppet.textures[t]), tw != w || th != h {
                    puppet.setTexture(part, slot: s, texture: nil)
                }
            }
        }
        syncTextures()
        changed("Load texture")
    }
}
