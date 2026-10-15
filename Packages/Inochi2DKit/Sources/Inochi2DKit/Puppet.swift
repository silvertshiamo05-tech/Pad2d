// Port of Inochi2D 0.8 Puppet (inochi2d.core.puppet).
// Copyright © 2020, Inochi2D Project. Distributed under the 2-Clause BSD License.

import Foundation

public struct PuppetMeta: Sendable {
    public var name: String?
    public var version: String?
    public var rigger: String?
    public var artist: String?
    public var copyright: String?
    public var licenseURL: String?
    public var contact: String?
    public var reference: String?
    public var preservePixels = false
}

public struct PuppetPhysics: Sendable {
    public var pixelsPerMeter: Float = 1000
    public var gravity: Float = 9.8
}

/// A loaded Inochi2D puppet.
public final class Puppet {
    public let root: Node
    public private(set) var parameters: [Parameter] = []
    public private(set) var meta = PuppetMeta()
    public var physics = PuppetPhysics()
    public private(set) var textures: [TextureBlob]
    public private(set) var automation: [SineAutomation] = []
    public var transform = Transform()

    /// Run parameter bindings (turn off to see the rest pose).
    public var renderParameters = true
    /// Run physics drivers.
    public var enableDrivers = true

    private var rootParts: [Node] = []
    private var drivers: [SimplePhysics] = []
    private var drivenParameters = Set<ObjectIdentifier>()
    public private(set) var time: Double = 0

    /// Loads an `.inp` or `.inx` file.
    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        let file = try INPFile(data: data)
        textures = file.textures
        let json = file.json

        if let m = json.object("meta") {
            meta = PuppetMeta(name: m.string("name"), version: m.string("version"), rigger: m.string("rigger"),
                              artist: m.string("artist"), copyright: m.string("copyright"),
                              licenseURL: m.string("licenseURL"), contact: m.string("contact"),
                              reference: m.string("reference"), preservePixels: m.bool("preservePixels") ?? false)
        }
        if let p = json.object("physics") {
            physics.pixelsPerMeter = p.float("pixelsPerMeter") ?? 1000
            physics.gravity = p.float("gravity") ?? 9.8
        }

        let rootJSON = json.object("nodes") ?? [:]
        let r = Node.make(type: rootJSON.string("type") ?? "Node") ?? Node()
        r.deserialize(rootJSON)
        r.name = "Root"
        root = r
        root.puppetRef = self

        parameters = (json.array("param") ?? []).compactMap { ($0 as? [String: Any]).map(Parameter.init(json:)) }
        for case let a as [String: Any] in json.array("automation") ?? [] where a.string("type") == "sine" {
            automation.append(SineAutomation(json: a))
        }

        finalize()
    }

    private func finalize() {
        root.finalize()
        for p in parameters { p.finalize(self) }
        for a in automation { a.finalize(self) }
        scanParts()
        sortParts()
    }

    private func scanParts() {
        rootParts = []
        drivers = []
        drivenParameters = []
        func recurse(_ node: Node, driversOnly: Bool) {
            var driversOnly = driversOnly
            if let d = node as? SimplePhysics {
                drivers.append(d)
                if let p = d.param { drivenParameters.insert(ObjectIdentifier(p)) }
            } else if !driversOnly {
                if let c = node as? Composite {
                    c.scanParts()
                    rootParts.append(c)
                    driversOnly = true
                } else if node is Part {
                    rootParts.append(node)
                }
            }
            for c in node.children { recurse(c, driversOnly: driversOnly) }
        }
        recurse(root, driversOnly: false)
    }

    /// Higher z-sort draws first; ties keep tree order.
    private func sortParts() {
        rootParts = rootParts.enumerated().sorted {
            $0.element.zSort != $1.element.zSort ? $0.element.zSort > $1.element.zSort : $0.offset < $1.offset
        }.map(\.element)
    }

    public func parameter(named name: String) -> Parameter? {
        parameters.first { $0.name == name }
    }

    /// Whether a parameter is controlled by physics (and so ignores manual values).
    public func isDriven(_ p: Parameter) -> Bool {
        enableDrivers && drivenParameters.contains(ObjectIdentifier(p))
    }

    /// Advances the puppet by `deltaTime` seconds.
    public func update(deltaTime: Double) {
        time += deltaTime
        transform.update()
        for a in automation { a.update(time: time) }
        root.beginUpdate()
        if renderParameters {
            for p in parameters where !enableDrivers || !drivenParameters.contains(ObjectIdentifier(p)) {
                p.update()
            }
        }
        root.transformChanged()
        if renderParameters && enableDrivers {
            for d in drivers { d.updateDriver(deltaTime: Float(deltaTime)) }
        }
        root.update()
    }

    /// Restarts physics from rest.
    public func resetDrivers() {
        for d in drivers { d.reset() }
    }

    /// Produces this frame's drawing instructions.
    public func draw() -> DrawList {
        sortParts()
        var builder = DrawListBuilder(puppetMatrix: transform.matrix)
        for node in rootParts where node.renderEnabled {
            if let p = node as? Part {
                p.drawOne(into: &builder)
            } else if let c = node as? Composite {
                c.drawOne(into: &builder)
            }
        }
        return builder.list
    }

    /// All parts, in tree order.
    public var parts: [Part] { root.allNodes().compactMap { $0 as? Part } }
}

// MARK: - Automation

/// Sine-wave automation (inochi2d.core.automation.sine).
public final class SineAutomation {
    struct BindingRef {
        var paramName: String
        var axis: Int
        var range: Vec2
        weak var param: Parameter?
    }

    var name: String
    var enabled = true
    var speed: Float = 1
    var phase: Float = 0
    var sineType = 0
    var bindings: [BindingRef] = []

    init(json: [String: Any]) {
        name = json.string("name") ?? ""
        speed = json.float("speed") ?? 1
        sineType = (json["sine_type"] as? NSNumber)?.intValue ?? 0
        for case let b as [String: Any] in json.array("bindings") ?? [] {
            bindings.append(BindingRef(paramName: b.string("param") ?? "",
                                       axis: (b["axis"] as? NSNumber)?.intValue ?? 0,
                                       range: b.vec2("range") ?? Vec2(0, 1), param: nil))
        }
    }

    func finalize(_ puppet: Puppet) {
        for i in bindings.indices {
            bindings[i].param = puppet.parameters.first { $0.name == bindings[i].paramName }
        }
    }

    func update(time: Double) {
        guard enabled else { return }
        let x = Float(time) * speed + phase
        let wave: Float
        switch sineType {
        case 1: wave = (cos(x) + 1) / 2
        case 2: wave = (tan(x) + 1) / 2
        default: wave = (sin(x) + 1) / 2
        }
        for b in bindings {
            b.param?.pushOffset(axis: b.axis, b.range.x + wave * (b.range.y - b.range.x))
        }
    }
}
