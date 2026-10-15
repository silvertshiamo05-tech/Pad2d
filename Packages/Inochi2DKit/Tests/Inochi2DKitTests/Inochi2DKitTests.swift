import XCTest
@testable import Inochi2DKit

private func close(_ a: Vec2, _ b: Vec2, _ tol: Float = 1e-3, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThan(a.distance(to: b), tol, "\(a) != \(b)", file: file, line: line)
}

/// Builds an in-memory .inp file.
private func makeINP(json: [String: Any], textures: [Data]) throws -> Data {
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    let payload = try JSONSerialization.data(withJSONObject: json)
    var d = Data(INPFile.magic)
    d.append(contentsOf: be32(payload.count))
    d.append(payload)
    d.append(contentsOf: Array("TEX_SECT".utf8))
    d.append(contentsOf: be32(textures.count))
    for t in textures {
        d.append(contentsOf: be32(t.count))
        d.append(1) // TGA
        d.append(t)
    }
    return d
}

/// 2x1 uncompressed 32-bit TGA, top-left origin: red, half-transparent blue.
private func tinyTGA() -> Data {
    var h = [UInt8](repeating: 0, count: 18)
    h[2] = 2; h[12] = 2; h[14] = 1; h[16] = 32; h[17] = 0x28
    return Data(h + [0, 0, 255, 255, /* */ 255, 0, 0, 128])
}

private func quad(_ size: Float) -> [String: Any] {
    ["verts": [-size, -size, size, -size, size, size, -size, size],
     "uvs": [0, 0, 1, 0, 1, 1, 0, 1],
     "indices": [0, 1, 2, 0, 2, 3],
     "origin": [0, 0]]
}

private func part(_ uuid: Int, _ name: String, x: Float, zsort: Float = 0, masks: [[String: Any]]? = nil) -> [String: Any] {
    var p: [String: Any] = [
        "uuid": uuid, "name": name, "type": "Part", "enabled": true, "zsort": zsort,
        "transform": ["trans": [x, 0, 0], "rot": [0, 0, 0], "scale": [1, 1]],
        "mesh": quad(10), "textures": [0], "blend_mode": "Normal",
        "tint": [1, 1, 1], "screenTint": [0, 0, 0], "mask_threshold": 0.5, "opacity": 1,
    ]
    if let masks { p["masks"] = masks }
    return p
}

final class MathTests: XCTestCase {
    func testTransformComposition() {
        var parent = Transform(translation: Vec3(10, 0, 0), rotation: Vec3(0, 0, .pi / 2))
        parent.update()
        var child = Transform(translation: Vec3(5, 0, 0))
        child.update()
        let g = child * parent
        // Child offset (5,0) rotated 90° then moved by (10,0).
        close(g.matrix.apply(.zero), Vec2(10, 5))
        close(g.matrix.inverse.apply(Vec2(10, 5)), .zero)
    }

    func testCubicWeightsMatchCubic() {
        for t: Float in [0, 0.25, 0.5, 0.9, 1] {
            let w = cubicWeights(t)
            XCTAssertEqual(cubic(1, 2, 4, 8, t), w.0 * 1 + w.1 * 2 + w.2 * 4 + w.3 * 8, accuracy: 1e-5)
            XCTAssertEqual(w.0 + w.1 + w.2 + w.3, 1, accuracy: 1e-5)
        }
    }
}

final class TGATests: XCTestCase {
    func testUncompressed() throws {
        let img = try TGADecoder.decode(tinyTGA())
        XCTAssertEqual(img.width, 2)
        XCTAssertEqual(img.rgba, [255, 0, 0, 255, 0, 0, 255, 128])
        var p = img.rgba
        TGADecoder.premultiply(&p)
        XCTAssertEqual(Array(p[4..<8]), [0, 0, 128, 128])
    }

    func testRLEBottomUp() throws {
        var h = [UInt8](repeating: 0, count: 18)
        h[2] = 10; h[12] = 2; h[14] = 2; h[16] = 24 // 2x2, RLE, bottom-left origin
        // Bottom row: run of 2 green pixels. Top row: 2 raw pixels (white, black).
        let body: [UInt8] = [0x81, 0, 255, 0, 0x01, 255, 255, 255, 0, 0, 0]
        let img = try TGADecoder.decode(Data(h + body))
        XCTAssertEqual(Array(img.rgba[0..<8]), [255, 255, 255, 255, 0, 0, 0, 255])
        XCTAssertEqual(Array(img.rgba[8..<16]), [0, 255, 0, 255, 0, 255, 0, 255])
    }
}

final class PuppetTests: XCTestCase {
    func makePuppet() throws -> Puppet {
        let root: [String: Any] = [
            "uuid": 1, "name": "Root", "type": "Node", "enabled": true, "zsort": 0,
            "transform": ["trans": [0, 0, 0], "rot": [0, 0, 0], "scale": [1, 1]],
            "children": [
                part(10, "Back", x: 0, zsort: 1),
                part(11, "Front", x: 100, zsort: -1, masks: [["source": 10, "mode": "Mask"]]),
                [
                    "uuid": 20, "name": "Group", "type": "Composite", "enabled": true, "zsort": 0,
                    "transform": ["trans": [0, 0, 0], "rot": [0, 0, 0], "scale": [1, 1]],
                    "blend_mode": "Multiply", "opacity": 0.5, "tint": [1, 1, 1], "screenTint": [0, 0, 0],
                    "children": [part(21, "Inner", x: -50)],
                ] as [String: Any],
            ],
        ]
        let param: [String: Any] = [
            "uuid": 99, "name": "Move", "is_vec2": false,
            "min": [-1, 0], "max": [1, 0], "defaults": [0, 0],
            "axis_points": [[0, 0.5, 1], [0]],
            "bindings": [
                ["node": 10, "param_name": "transform.t.x", "values": [[-20], [0], [20]],
                 "isSet": [[true], [true], [true]], "interpolate_mode": "Linear"],
                ["node": 11, "param_name": "deform",
                 "values": [[[[0, 0], [0, 0], [0, 0], [0, 0]]],
                            [[[0, 0], [0, 0], [0, 0], [0, 0]]],
                            [[[0, 10], [0, 10], [0, 10], [0, 10]]]],
                 "isSet": [[true], [true], [true]], "interpolate_mode": "Linear"],
                ["node": 11, "param_name": "opacity", "values": [[1], [1], [0.25]],
                 "isSet": [[true], [true], [true]]],
            ],
        ]
        let json: [String: Any] = ["meta": ["name": "Test"], "nodes": root, "param": [param]]
        return try Puppet(data: makeINP(json: json, textures: [tinyTGA()]))
    }

    func testLoad() throws {
        let p = try makePuppet()
        XCTAssertEqual(p.meta.name, "Test")
        XCTAssertEqual(p.textures.count, 1)
        XCTAssertEqual(p.parameters.first?.bindingCount, 3)
        XCTAssertEqual(p.parts.count, 3)
    }

    func testDrawOrderMasksAndComposite() throws {
        let p = try makePuppet()
        p.update(deltaTime: 1 / 60)
        let list = p.draw()
        let kinds: [String] = list.commands.map {
            switch $0 {
            case .beginMask(let v): return "beginMask\(v)"
            case .maskSource: return "maskSource"
            case .beginMaskContent: return "content"
            case .endMask: return "endMask"
            case .part(let d): return "part\(d.nodeUUID)"
            case .beginComposite: return "beginComposite"
            case .endComposite: return "endComposite"
            case .compositeBlit(let c): return "blit\(c.blendMode)"
            }
        }
        // Highest z-sort first: Back (1), Group (0), Front (-1, masked by Back).
        XCTAssertEqual(kinds, ["part10", "beginComposite", "part21", "endComposite", "blitmultiply",
                               "beginMask0", "maskSource", "content", "part11", "endMask"])
    }

    func testBindings() throws {
        let p = try makePuppet()
        let param = try XCTUnwrap(p.parameter(named: "Move"))
        func positions() -> [UInt32: [Vec2]] {
            p.update(deltaTime: 1 / 60)
            let list = p.draw()
            var out: [UInt32: [Vec2]] = [:]
            for case let .part(d) in list.commands {
                out[d.nodeUUID] = (0..<4).map { i in
                    let v = (d.mesh.baseVertex + i) * 4
                    return Vec2(list.vertices[v], list.vertices[v + 1])
                }
            }
            return out
        }
        var pos = positions()
        close(pos[10]![0], Vec2(-10, -10))
        close(pos[11]![0], Vec2(90, -10))

        param.value = Vec2(1, 0)
        pos = positions()
        close(pos[10]![0], Vec2(10, -10)) // translated +20
        close(pos[11]![0], Vec2(90, 0)) // deformed +10 in y

        param.value = Vec2(0.5, 0) // halfway between keypoints 0.5 and 1
        pos = positions()
        close(pos[10]![0], Vec2(0, -10))
        close(pos[11]![0], Vec2(90, -5))
        let list = p.draw()
        for case let .part(d) in list.commands where d.nodeUUID == 11 {
            XCTAssertEqual(d.opacity, 0.625, accuracy: 1e-4)
        }
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try Puppet(data: Data([1, 2, 3])))
    }
}
