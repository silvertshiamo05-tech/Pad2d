import XCTest
@testable import Inochi2DKit

/// Cases from the reInterpolate unittest in Inochi2D 0.8 (core/param/binding.d).
final class ReinterpolateTests: XCTestCase {
    private let x = Float.nan

    private func run(_ input: [[Float]], _ expect: [[Float]], axis: [[Float]]? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
        func uniform(_ n: Int) -> [Float] { n > 1 ? (0..<n).map { Float($0) / Float(n - 1) } : [0] }
        let axisPoints = axis ?? [uniform(input.count), uniform(input[0].count)]
        var values = input
        let isSet = input.map { $0.map { !$0.isNaN } }
        reinterpolate(&values, isSet: isSet, axisPoints: axisPoints, add: +, scale: *)
        for i in values.indices {
            for j in values[i].indices where !(abs(values[i][j] - expect[i][j]) <= 1e-4) {
                XCTFail("mismatch at \(i),\(j): got \(values) expected \(expect)", file: file, line: line)
                return
            }
        }
    }

    func testOneDimensional() {
        run([[1], [x], [x], [4]], [[1], [2], [3], [4]])
        run([[0], [x], [x], [4]], [[0], [1], [3], [4]], axis: [[0, 0.25, 0.75, 1], [0]])
    }

    func testSquareAndCorner() {
        let expect: [[Float]] = [[4, 6, 8, 10], [3, 5, 7, 9], [2, 4, 6, 8], [1, 3, 5, 7]]
        run([[4, x, x, 10], [x, x, x, x], [x, x, x, x], [1, x, x, 7]], expect)
        run([[4, x, x, x], [x, x, x, x], [x, x, x, x], [1, x, x, 7]], expect)
    }

    func testCross() {
        run([[9, x, x, 0], [x, x, x, x], [x, x, x, x], [0, x, x, 9]],
            [[9, 6, 3, 0], [6, 5, 4, 3], [3, 4, 5, 6], [0, 3, 6, 9]])
    }

    func testDiamond() {
        run([[x, x, 2, x, x], [x, x, x, x, x], [0, x, x, x, 4], [x, x, x, x, x], [x, x, 10, x, x]],
            [[-2, 0, 2, 2, 2], [-1, 1, 3, 3, 3], [0, 2, 4, 4, 4], [3, 5, 7, 7, 7], [6, 8, 10, 10, 10]])
    }

    func testExpansion() {
        run([[x, x, x, x], [x, 3, 4, x], [x, 1, 2, x], [x, x, x, x]],
            [[3, 3, 4, 4], [3, 3, 4, 4], [1, 1, 2, 2], [1, 1, 2, 2]])
        run([[x, x, x, x], [x, x, 4, x], [x, x, x, x], [0, x, x, x]],
            [[2, 3, 4, 4], [2, 3, 4, 4], [1, 2, 3, 3], [0, 1, 2, 2]])
        run([[x, 5, x], [x, x, x], [0, x, x]], [[4, 5, 5], [2, 3, 3], [0, 1, 1]])
    }
}

final class EditingTests: XCTestCase {
    /// Builds a one-part puppet with a parameter that moves the part's top edge.
    private func makeRig() throws -> (Puppet, Part, Parameter) {
        let puppet = Puppet()
        let px = [UInt8](repeating: 255, count: 8 * 8 * 4)
        let slot = puppet.addTexture(rgba: px, width: 8, height: 8)
        let part = puppet.makePart(name: "Face", textureSlot: slot, width: 100, height: 50)
        puppet.add(part, to: puppet.root)
        let param = puppet.createParameter(name: "Smile", isVec2: false, min: Vec2(0, 0), max: Vec2(1, 0))
        let offsets = part.vertices.map { $0.y < 0 ? Vec2(0, -10) : Vec2.zero }
        puppet.setDeformation(param, part, at: Keypoint(1, 0), offsets: offsets)
        puppet.setValue(param, part, target: "opacity", at: Keypoint(1, 0), value: 0.5)
        return (puppet, part, param)
    }

    private func positions(_ p: Puppet, _ uuid: UInt32) -> (verts: [Vec2], opacity: Float) {
        p.update(deltaTime: 1 / 60)
        let list = p.draw()
        for case let .part(d) in list.commands where d.nodeUUID == uuid {
            let verts = (0..<(list.vertices.count / 4 - d.mesh.baseVertex)).prefix(4).map { i -> Vec2 in
                let v = (d.mesh.baseVertex + i) * 4
                return Vec2(list.vertices[v], list.vertices[v + 1])
            }
            return (verts, d.opacity)
        }
        return ([], 0)
    }

    func testQuadMatchesCreatorLayout() {
        let q = MeshGenerator.quad(width: 10, height: 20)
        XCTAssertEqual(q.points, [Vec2(0, 0), Vec2(0, 20), Vec2(10, 0), Vec2(10, 20)])
        XCTAssertEqual(q.indices, [0, 1, 2, 2, 1, 3])
    }

    func testRigSaveAndReload() throws {
        let (puppet, part, param) = try makeRig()
        param.value = Vec2(1, 0)
        let live = positions(puppet, part.uuid)
        XCTAssertEqual(live.verts[0].y, -35, accuracy: 1e-3) // top edge moved up by 10
        XCTAssertEqual(live.opacity, 0.5, accuracy: 1e-4)

        let reloaded = try Puppet(data: puppet.fileData())
        XCTAssertEqual(reloaded.textures.count, 1)
        let p2 = try XCTUnwrap(reloaded.parameter(named: "Smile"))
        XCTAssertEqual(p2.bindingCount, 2)
        p2.value = Vec2(0.5, 0)
        let half = positions(reloaded, part.uuid)
        XCTAssertEqual(half.verts[0].y, -30, accuracy: 1e-3)
        XCTAssertEqual(half.opacity, 0.75, accuracy: 1e-4)
    }

    func testKeypointInsertKeepsCurve() throws {
        let (puppet, part, param) = try makeRig()
        let k = puppet.addKeypoint(param, axis: 0, at: 0.5)
        XCTAssertEqual(k, 1)
        // The new keypoint is unset, so it is interpolated from its neighbours.
        XCTAssertEqual(puppet.deformation(param, part, at: Keypoint(1, 0))[0].y, -5, accuracy: 1e-4)
        XCTAssertEqual(puppet.value(param, part, target: "opacity", at: Keypoint(1, 0)), 0.75, accuracy: 1e-4)
        puppet.removeKeypoint(param, axis: 0, index: 1)
        XCTAssertEqual(param.axisKeypoints[0], [0, 1])
    }

    func testRemeshKeepsDeformation() throws {
        let (puppet, part, param) = try makeRig()
        // Split the quad with a vertex in the middle of the top edge.
        var verts = part.vertices
        verts.append(Vec2(0, -25))
        let uvs = verts.map { Vec2(($0.x + 50) / 100, ($0.y + 25) / 50) }
        puppet.setMesh(part, vertices: verts, indices: [0, 1, 4, 4, 1, 3, 4, 3, 2], uvs: uvs)
        let d = puppet.deformation(param, part, at: Keypoint(1, 0))
        XCTAssertEqual(d.count, 5)
        XCTAssertEqual(d[4].y, -10, accuracy: 1e-3)
    }

    func testMoveKeepsWorldPosition() throws {
        let puppet = Puppet()
        let group = puppet.makeNode(.node, name: "Group")
        group.localTransform.translation = Vec3(30, 40, 0)
        puppet.add(group, to: puppet.root)
        let child = puppet.makeNode(.node, name: "Child")
        puppet.add(child, to: puppet.root)
        child.localTransform.translation = Vec3(10, 10, 0)
        puppet.rebuild()
        puppet.move(child, to: group)
        XCTAssertTrue(child.parent === group)
        XCTAssertEqual(child.localTransform.translation.x, -20, accuracy: 1e-4)
        XCTAssertEqual(child.localTransform.translation.y, -30, accuracy: 1e-4)
        XCTAssertFalse(puppet.canMove(group, to: child))
    }
}

/// Writes a minimal 8-bit RGB PSD: a "Head" folder holding "Eye" over "Face".
private func makePSD() -> Data {
    var d = Data()
    func u8(_ v: Int) { d.append(UInt8(v & 0xff)) }
    func u16(_ v: Int) { u8(v >> 8); u8(v) }
    func u32(_ v: Int) { u16(v >> 16); u16(v) }
    func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }

    struct Layer {
        var name: String, rect: (Int, Int, Int, Int), section: Int?, color: [UInt8], blend = "norm"
    }
    // File order is bottom-most first; a folder's end marker sits below its contents.
    let layers = [
        Layer(name: "</Layer group>", rect: (0, 0, 0, 0), section: 3, color: []),
        Layer(name: "Face", rect: (10, 20, 50, 80), section: nil, color: [200, 150, 100, 255]),
        Layer(name: "Eye", rect: (20, 30, 30, 40), section: nil, color: [0, 0, 255, 255]),
        Layer(name: "Head", rect: (0, 0, 0, 0), section: 1, color: [], blend: "pass"),
    ]

    str("8BPS"); u16(1); d.append(contentsOf: [UInt8](repeating: 0, count: 6))
    u16(4); u32(64); u32(100); u16(8); u16(3)
    u32(0); u32(0)

    var info = Data()
    var channelData = Data()
    swap(&d, &info)
    u16(layers.count)
    for l in layers {
        let (t, le, b, r) = l.rect
        u32(t); u32(le); u32(b); u32(r)
        let n = (r - le) * (b - t)
        u16(4)
        for id in [-1, 0, 1, 2] { u16(id); u32(2 + n) }
        str("8BIM"); str(l.blend); u8(255); u8(0); u8(0); u8(0)
        var extra = Data()
        swap(&d, &extra)
        u32(0); u32(0)
        let name = Array(l.name.utf8)
        u8(name.count); d.append(contentsOf: name)
        for _ in 0..<((name.count + 4) / 4 * 4 - name.count - 1) { u8(0) }
        if let s = l.section { str("8BIM"); str("lsct"); u32(4); u32(s) }
        swap(&d, &extra)
        u32(extra.count); d.append(extra)

        swap(&d, &channelData)
        for c in [3, 0, 1, 2] {
            u16(0)
            d.append(contentsOf: [UInt8](repeating: n > 0 ? l.color[c] : 0, count: n))
        }
        swap(&d, &channelData)
    }
    d.append(channelData)
    swap(&d, &info)
    u32(info.count + 4); u32(info.count); d.append(info)
    return d
}

final class PSDTests: XCTestCase {
    func testReadLayers() throws {
        let raw = makePSD()
        let doc = try PSDDocument(data: raw)
        XCTAssertEqual(doc.width, 100)
        XCTAssertEqual(doc.height, 64)
        XCTAssertEqual(doc.layers.map(\.name), ["</Layer group>", "Face", "Eye", "Head"])
        let eye = doc.layers[2]
        XCTAssertEqual(Array(try doc.rgba(for: eye).prefix(4)), [0, 0, 255, 255])
    }

    func testImport() throws {
        var options = PSDImportOptions()
        options.autoMesh = false
        let puppet = try Puppet.importPSD(makePSD(), options: options)
        let head = try XCTUnwrap(puppet.root.children.first)
        XCTAssertEqual(head.name, "Head")
        XCTAssertEqual(head.children.map(\.name), ["Eye", "Face"])
        let eye = try XCTUnwrap(head.children.first as? Part)
        // Centred on the layer, relative to the document centre (50, 32).
        XCTAssertEqual(eye.localTransform.translation.x, -15, accuracy: 1e-4)
        XCTAssertEqual(eye.localTransform.translation.y, -7, accuracy: 1e-4)
        // Upper layers draw later, so they get a lower z-sort.
        XCTAssertLessThan(eye.zSort, head.children[1].zSort)
        XCTAssertEqual(puppet.textures.count, 2)

        // Survives a save and reload.
        let reloaded = try Puppet(data: puppet.fileData())
        XCTAssertEqual(reloaded.parts.map(\.name), ["Eye", "Face"])
    }

    func testAutoMeshCoversOpaquePixels() {
        let w = 64, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 16..<48 { for x in 16..<48 { px[(y * w + x) * 4 + 3] = 255 } }
        let m = MeshGenerator.auto(rgba: px, width: w, height: h, spacing: 16)
        XCTAssertGreaterThanOrEqual(m.points.count, 4)
        XCTAssertEqual(m.indices.count % 3, 0)
        let xs = m.points.map(\.x), ys = m.points.map(\.y)
        XCTAssertLessThanOrEqual(xs.min()!, 16)
        XCTAssertGreaterThanOrEqual(xs.max()!, 48)
        XCTAssertLessThanOrEqual(ys.min()!, 16)
        XCTAssertGreaterThanOrEqual(ys.max()!, 48)
    }
}
