// Inochi Creator's PSD merge (windows/psdmerge.d): updates an existing rig
// from a changed PSD. Layers are matched to parts by layer path, then by
// layer name; unmatched layers become new parts.

import Foundation

public struct PSDMergeItem: Identifiable, Sendable {
    public var id: Int { layerIndex }
    public let layerIndex: Int
    public let path: String
    public let name: String
    /// The part to replace, or nil to add a new part.
    public var target: UInt32?
    public var ignore = false
}

public extension Puppet {
    /// Layers of `doc` (top first) with their initial matches.
    func psdMergePlan(_ doc: PSDDocument) -> [PSDMergeItem] {
        let parts = self.parts
        var items: [PSDMergeItem] = []
        var stack: [String] = []
        for (i, layer) in doc.layers.enumerated().reversed() {
            switch layer.kind {
            case .groupStart: stack.append(layer.name)
            case .groupEnd: if !stack.isEmpty { stack.removeLast() }
            case .pixels:
                guard layer.width > 0, layer.height > 0 else { continue }
                let path = "/" + (stack + [layer.name]).joined(separator: "/")
                let base = layer.name
                let match = parts.first { $0.layerPath == path }
                    ?? parts.first { ($0.layerPath?.split(separator: "/").last).map(String.init) == base }
                items.append(PSDMergeItem(layerIndex: i, path: path, name: layer.name, target: match?.uuid))
            }
        }
        return items
    }

    /// Applies a merge plan: replaces matched parts' textures (and optionally
    /// names and positions) and adds the rest as new parts.
    func applyPSDMerge(_ doc: PSDDocument, items: [PSDMergeItem], rename: Bool, retranslate: Bool) throws {
        let center = Vec2(Float(doc.width / 2), Float(doc.height / 2))
        for item in items where !item.ignore {
            let layer = doc.layers[item.layerIndex]
            var rgba = try doc.rgba(for: layer)
            TGADecoder.premultiply(&rgba)
            let w = layer.width, h = layer.height
            let world = Vec2(Float(layer.left) + Float(w) / 2 - center.x, Float(layer.top) + Float(h) / 2 - center.y)
            let slot = addTexture(rgba: rgba, width: w, height: h)
            if let id = item.target, let part = root.find(uuid: id) as? Part {
                if rename { part.name = layer.name }
                part.textureIDs[0] = slot
                part.layerPath = item.path
                // Texture coordinates follow the new image size around the part's centre.
                part.uvs = part.vertices.map { Vec2($0.x / Float(w) + 0.5, $0.y / Float(h) + 0.5) }
                part.meshEdited = true
                if retranslate {
                    if part.lockToRoot {
                        part.localTransform.translation = Vec3(world.x, world.y, part.localTransform.translation.z)
                    } else {
                        let parent = part.parent?.transformNoLock().matrix ?? .identity
                        let local = parent.inverse.apply(world)
                        part.localTransform.translation = Vec3(local.x, local.y, part.localTransform.translation.z)
                    }
                    part.transformChanged()
                }
            } else {
                let part = makePart(name: layer.name, textureSlot: slot, width: w, height: h)
                part.layerPath = item.path
                part.localTransform.translation = Vec3(world.x, world.y, 0)
                part.enabled = layer.visible
                part.opacity = Float(layer.opacity) / 255
                part.blendMode = psdBlendMode(layer.blendKey)
                add(part, to: root, at: 0)
            }
        }
        pruneTextures()
        rebuild()
    }
}
