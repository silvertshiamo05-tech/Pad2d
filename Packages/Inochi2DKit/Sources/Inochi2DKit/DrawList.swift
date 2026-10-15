import Foundation

/// A range of the draw list's shared vertex/index buffers.
public struct MeshRange: Equatable, Sendable {
    public var baseVertex: Int
    public var indexStart: Int
    public var indexCount: Int
}

public struct PartDraw: Sendable {
    public var mesh: MeshRange
    /// Texture slot indices into `Puppet.textures`.
    public var albedo: Int
    public var emissive: Int?
    public var opacity: Float
    public var tint: Vec3
    public var screenTint: Vec3
    public var emissionStrength: Float
    public var blendMode: BlendMode
    public var nodeUUID: UInt32
}

public struct MaskDraw: Sendable {
    public var mesh: MeshRange
    public var texture: Int
    /// Fragments with alpha at or below this are discarded.
    public var threshold: Float
    /// Dodge masks cut holes (write 0); normal masks write 1.
    public var dodge: Bool
}

public struct CompositeDraw: Sendable {
    public var opacity: Float
    public var tint: Vec3
    public var screenTint: Vec3
    public var blendMode: BlendMode
}

/// Renderer-agnostic drawing instructions, in the order Inochi2D 0.8 issues them.
public enum DrawCommand: Sendable {
    /// Start masking: clear the stencil to 0 if any mask is a normal mask, else to 1.
    case beginMask(clearValue: UInt8)
    /// Draw a mask source into the stencil only.
    case maskSource(MaskDraw)
    /// Following draws only where stencil == 1.
    case beginMaskContent
    /// Stop masking.
    case endMask
    case part(PartDraw)
    /// Push a transparent offscreen layer; subsequent draws go into it.
    case beginComposite
    /// Pop back to the previous target (the layer stays available for the blit).
    case endComposite
    /// Blend the most recently ended layer onto the current target.
    case compositeBlit(CompositeDraw)
}

public struct DrawList: Sendable {
    /// Interleaved x, y, u, v in puppet space.
    public var vertices: [Float] = []
    public var indices: [UInt32] = []
    public var commands: [DrawCommand] = []

    /// Bounding box of all geometry: (minX, minY, maxX, maxY).
    public var bounds: (Float, Float, Float, Float)? {
        guard vertices.count >= 4 else { return nil }
        var b = (Float.infinity, Float.infinity, -Float.infinity, -Float.infinity)
        var i = 0
        while i + 1 < vertices.count {
            let x = vertices[i], y = vertices[i + 1]
            if x.isFinite && y.isFinite {
                b = (Swift.min(b.0, x), Swift.min(b.1, y), Swift.max(b.2, x), Swift.max(b.3, y))
            }
            i += 4
        }
        return b.0.isFinite ? b : nil
    }
}

struct DrawListBuilder {
    var list = DrawList()
    let puppetMatrix: Mat4
    private var meshes: [ObjectIdentifier: MeshRange] = [:]

    init(puppetMatrix: Mat4) {
        self.puppetMatrix = puppetMatrix
    }

    var commands: [DrawCommand] {
        get { list.commands }
        set { list.commands = newValue }
    }

    /// Geometry for a drawable, emitted once per frame and shared by masks.
    mutating func mesh(for d: Drawable) -> MeshRange {
        if let m = meshes[ObjectIdentifier(d)] { return m }
        let base = list.vertices.count / 4
        let positions = d.deformedPositions(puppetMatrix: puppetMatrix)
        list.vertices.reserveCapacity(list.vertices.count + positions.count * 4)
        for i in positions.indices {
            let uv = i < d.uvs.count ? d.uvs[i] : .zero
            list.vertices.append(positions[i].x)
            list.vertices.append(positions[i].y)
            list.vertices.append(uv.x)
            list.vertices.append(uv.y)
        }
        let start = list.indices.count
        list.indices.append(contentsOf: d.indices.map { UInt32($0) })
        let r = MeshRange(baseVertex: base, indexStart: start, indexCount: d.indices.count)
        meshes[ObjectIdentifier(d)] = r
        return r
    }

    mutating func beginMask(hasMasks: Bool) {
        list.commands.append(.beginMask(clearValue: hasMasks ? 0 : 1))
    }

    mutating func beginMaskContent() { list.commands.append(.beginMaskContent) }
    mutating func endMask() { list.commands.append(.endMask) }
}
