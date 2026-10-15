// Dumps puppet geometry from the Swift port in the same format as the
// reference dumper: one line per drawn part, "<count> x,y x,y ...".
import Foundation
import Inochi2DKit

let args = CommandLine.arguments
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
