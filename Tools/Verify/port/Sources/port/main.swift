// Dumps puppet geometry from the Swift port in the same format as the
// reference dumper: one line per drawn part, "<count> x,y x,y ...".
import Foundation
import Inochi2DKit

let args = CommandLine.arguments
if args.count > 3 && args[2] == "save" {
    // save <model> save <out.inx>: load and re-save with Pad2D's writer.
    let p = try Puppet(contentsOf: URL(fileURLWithPath: args[1]))
    try p.fileData().write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}
if args.count > 3 && args[2] == "rig" {
    // - rig <out.inx>: build and rig a puppet from scratch with the editing API.
    try buildRig().fileData().write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}
if args.count > 2 && args[2] == "bench-snapshot" {
    let p = try Puppet(contentsOf: URL(fileURLWithPath: args[1]))
    var t = Date()
    let s = p.snapshot()
    print("snapshot", s.byteCount, Date().timeIntervalSince(t))
    t = Date()
    _ = try Puppet(snapshot: s)
    print("restore", Date().timeIntervalSince(t))
    exit(0)
}
if args.count > 8 && args[2] == "render" {
    // render <model> render <out.rgba> <width> <height> <centreX> <centreY> <scale>
    try renderToRGBA(model: args[1], out: args[3], width: Int(args[4])!, height: Int(args[5])!,
                     centre: Vec2(Float(args[6])!, Float(args[7])!), scale: Float(args[8])!)
    exit(0)
}
let puppet = try Puppet(contentsOf: URL(fileURLWithPath: args[1]))
let mode = args.count > 2 ? args[2] : "rest"
puppet.renderParameters = mode != "rest"
puppet.enableDrivers = mode == "physics"
if args.count > 4, let p = puppet.parameter(named: args[3]) {
    let v = args[4].split(separator: ",").map { Float($0)! }
    p.value = Vec2(v[0], v.count > 1 ? v[1] : 0)
}
let frames = mode == "physics" ? Int(ProcessInfo.processInfo.environment["FRAMES"] ?? "120")! : 1
for _ in 0..<frames { puppet.update(deltaTime: 1.0 / 60) }
let list = puppet.draw()
for case let .part(p) in list.commands {
    let used = Set(list.indices[p.mesh.indexStart..<(p.mesh.indexStart + p.mesh.indexCount)]).sorted()
    var line = "\(used.count)"
    for i in used {
        let v = (p.mesh.baseVertex + Int(i)) * 4
        line += String(format: " %.2f,%.2f", list.vertices[v], list.vertices[v + 1])
    }
    print(line)
}

/// A small puppet made only with editor operations: a group with two parts
/// (one auto-meshed and re-meshed), a 2D parameter with deforms, transform
/// and opacity bindings on an inserted keypoint, a mask and a physics driver.
func buildRig() -> Puppet {
    let puppet = Puppet()
    let w = 128, h = 96
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w where pow(Float(x - 64) / 60, 2) + pow(Float(y - 48) / 44, 2) < 1 {
            px[(y * w + x) * 4 ..< (y * w + x) * 4 + 4] = [200, 120, 90, 255]
        }
    }
    let slot = puppet.addTexture(rgba: px, width: w, height: h)
    let head = puppet.makeNode(.node, name: "Head")
    head.localTransform.translation = Vec3(10, -40, 0)
    puppet.add(head, to: puppet.root)
    let face = puppet.makePart(name: "Face", textureSlot: slot, width: w, height: h,
                               mesh: MeshGenerator.auto(rgba: px, width: w, height: h, spacing: 24))
    puppet.add(face, to: head)
    let eye = puppet.makePart(name: "Eye", textureSlot: slot, width: 40, height: 30)
    eye.localTransform.translation = Vec3(-20, -10, 0)
    eye.zsort = -0.1
    puppet.add(eye, to: head)
    puppet.setMasks(eye, sources: [(face.uuid, .mask)])

    let turn = puppet.createParameter(name: "Head:: Yaw-Pitch", isVec2: true)
    puppet.setDeformation(turn, face, at: Keypoint(1, 1), offsets: face.vertices.map { Vec2($0.x * 0.2, 4) })
    puppet.setDeformation(turn, face, at: Keypoint(0, 0), offsets: face.vertices.map { Vec2(-$0.y * 0.1, -3) })
    let mid = puppet.addKeypoint(turn, axis: 0, at: 0.5)
    puppet.setValue(turn, eye, target: "transform.t.x", at: Keypoint(mid, 0), value: 12)
    puppet.setValue(turn, eye, target: "opacity", at: Keypoint(0, 1), value: 0.4)

    // Re-mesh the eye after rigging: bindings must follow.
    var verts = eye.vertices
    verts.append(Vec2(0, 0))
    puppet.setMesh(eye, vertices: verts, indices: [0, 1, 4, 1, 3, 4, 3, 2, 4, 2, 0, 4])
    puppet.setDeformation(turn, eye, at: Keypoint(2, 1), offsets: verts.map { _ in Vec2(3, 2) })

    let sway = puppet.createParameter(name: "Hair Sway", isVec2: true)
    let physics = puppet.makeNode(.physics, name: "Hair Physics") as! SimplePhysics
    puppet.add(physics, to: head)
    physics.setParameter(sway)
    puppet.setValue(sway, face, target: "transform.r.z", at: Keypoint(1, 1), value: 0.2)

    puppet.move(eye, to: puppet.root)
    puppet.rebuild()
    return puppet
}
