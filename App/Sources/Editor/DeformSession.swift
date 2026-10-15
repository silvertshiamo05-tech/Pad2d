import Foundation
import Inochi2DKit

/// State of the deform tools used while a parameter is armed (Inochi
/// Creator's deform-mode mesh editor). Positions are in model space.
@MainActor
final class DeformSession {
    enum BrushKind: String, CaseIterable, Identifiable {
        case circle, doubleThreshold, rectangle
        var id: String { rawValue }
        var title: String {
            switch self {
            case .circle: return "Circle"
            case .doubleThreshold: return "Double Threshold"
            case .rectangle: return "Rectangle"
            }
        }
    }

    // Selection of vertices per target drawable.
    var selection: [UInt32: Set<Int>] = [:]
    var mirrorH = false
    var mirrorV = false

    // Brush settings (model units, like Creator's brush sizes).
    var brushKind = BrushKind.circle
    var radius: Float = 300
    var innerRadius: Float = 100
    var rectWidth: Float = 300
    var rectHeight: Float = 300
    var flow = false
    var brushPoint: Vec2?

    var brush: DeformBrush {
        switch brushKind {
        case .circle: return .circle(radius: radius)
        case .doubleThreshold: return .doubleThreshold(radius: radius, inner: Swift.min(innerRadius, radius))
        case .rectangle: return .rectangle(width: rectWidth, height: rectHeight)
        }
    }

    // Path deform
    var path = CatmullSpline()
    var pathTarget: CatmullSpline?
    var pathTransform = false
    var lockedPoint: Int?
    var pathBindings: [UInt32: PathState] = [:]
    struct PathState {
        var binding = PathBinding()
        var startPositions: [Vec2] = []
        var startOffsets: [Vec2] = []
        var startValues: (Float, Float, Float) = (0, 0, 0)
    }

    // Lasso / box selection (model space)
    var lasso: [Vec2] = []
    var polyLasso = false
    var box: (Vec2, Vec2)?

    // Drag state
    var drag: Drag?
    struct Drag {
        enum Kind { case moveVertices, brush, box, lasso, pathPoint(Int), none }
        var kind: Kind
        var start: Vec2
        var last: Vec2
        var startOffsets: [UInt32: [Vec2]] = [:]
        var startPositions: [UInt32: [Vec2]] = [:]
        var weights: [UInt32: [Float]] = [:]
        var axisLock: Int? // 0 = horizontal only, 1 = vertical only
    }

    func reset() {
        selection = [:]
        lasso = []
        box = nil
        drag = nil
        brushPoint = nil
        path = CatmullSpline()
        pathTarget = nil
        pathTransform = false
        lockedPoint = nil
        pathBindings = [:]
    }

    var hasSelection: Bool { selection.values.contains { !$0.isEmpty } }
}

/// Dragging one of the move / scale / rotate handles.
struct HandleDrag {
    enum Kind { case move, scale, rotate }
    var kind: Kind
    var start: Vec2
    var last: Vec2
    var center: Vec2
    var nodes: [(Node, Vec3, Vec3, Vec2)] // node, translation, rotation, scale (rest or binding values)
    var lockAxis: Int?
}

/// Dragging a selected part's body to move it.
struct NodeDrag {
    var start: Vec2
    var nodes: [(Node, Vec3, Float, Float)] // node, rest translation, bound x, bound y
    var moved = false
}
