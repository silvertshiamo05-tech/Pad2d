// Port of ParameterBindingImpl.reInterpolate from Inochi2D 0.8
// (inochi2d.core.param.binding). Copyright © 2022, Inochi2D Project.
// Distributed under the 2-Clause BSD License.
//
// When a rigger sets values at some keypoints of a parameter, Inochi Creator
// fills every unset keypoint from its neighbours: first by interpolating along
// rows and columns, then by extrapolating corners, then by extending edges.

import Foundation

/// Fills unset keypoints of a binding's value grid (indexed [x][y]).
func reinterpolate<T>(_ values: inout [[T]], isSet: [[Bool]], axisPoints: [[Float]],
                      add: (T, T) -> T, scale: (T, Float) -> T) {
    let xCount = axisPoints[0].count, yCount = axisPoints[1].count
    guard values.count == xCount, values.allSatisfy({ $0.count == yCount }),
          isSet.count == xCount, isSet.allSatisfy({ $0.count == yCount }) else { return }

    var valid = isSet
    var validCount = isSet.reduce(0) { $0 + $1.filter { $0 }.count }
    let totalCount = xCount * yCount
    if validCount == 0 { return }

    var newlySet = [[Bool]](repeating: [Bool](repeating: false, count: yCount), count: xCount)
    var commitPoints: [(Int, Int)] = []
    var interpDistance = [[Float]](repeating: [Float](repeating: 0, count: yCount), count: xCount)
    var yMajor = false

    func majorCnt() -> Int { yMajor ? yCount : xCount }
    func minorCnt() -> Int { yMajor ? xCount : yCount }
    func isValid(_ maj: Int, _ mn: Int) -> Bool { yMajor ? valid[mn][maj] : valid[maj][mn] }
    func isNewlySet(_ maj: Int, _ mn: Int) -> Bool { yMajor ? newlySet[mn][maj] : newlySet[maj][mn] }
    func get(_ maj: Int, _ mn: Int) -> T { yMajor ? values[mn][maj] : values[maj][mn] }
    func getDistance(_ maj: Int, _ mn: Int) -> Float { yMajor ? interpDistance[mn][maj] : interpDistance[maj][mn] }
    func reset(_ maj: Int, _ mn: Int, _ val: T, _ distance: Float = 0) {
        let (x, y) = yMajor ? (mn, maj) : (maj, mn)
        guard !valid[x][y] else { return }
        values[x][y] = val
        interpDistance[x][y] = distance
        newlySet[x][y] = true
    }
    func set(_ maj: Int, _ mn: Int, _ val: T, _ distance: Float = 0) {
        reset(maj, mn, val, distance)
        commitPoints.append(yMajor ? (mn, maj) : (maj, mn))
    }
    func axisPoint(_ idx: Int) -> Float { yMajor ? axisPoints[0][idx] : axisPoints[1][idx] }
    func interp(_ maj: Int, _ left: Int, _ mid: Int, _ right: Int) -> T {
        let off = (axisPoint(mid) - axisPoint(left)) / (axisPoint(right) - axisPoint(left))
        return add(scale(get(maj, left), 1 - off), scale(get(maj, right), off))
    }

    func interpolate1D2D(_ secondPass: Bool) {
        yMajor = secondPass
        var detectedIntersections = false
        for i in 0..<majorCnt() {
            var l = 0
            let cnt = minorCnt()
            while l < cnt && !isValid(i, l) { l += 1 }
            if l >= cnt { continue }
            while true {
                while l < cnt - 1 && isValid(i, l + 1) { l += 1 }
                if l >= cnt - 1 { break }
                var r = l + 1
                while r < cnt && !isValid(i, r) { r += 1 }
                if r >= cnt { break }
                for m in (l + 1)..<r {
                    let val = interp(i, l, m, r)
                    if secondPass && isNewlySet(i, m) {
                        if !detectedIntersections { commitPoints.removeAll() }
                        set(i, m, scale(add(val, get(i, m)), 0.5))
                        detectedIntersections = true
                    }
                    if !detectedIntersections { set(i, m, val) }
                }
                l = r
            }
        }
    }

    func extrapolateCorners() {
        guard yCount > 1 && xCount > 1 else { return }
        func corner(_ bx: Int, _ by: Int, _ ox: Int, _ oy: Int) {
            let base = values[bx][by]
            let dX = add(values[bx + ox][by], scale(base, -1))
            let dY = add(values[bx][by + oy], scale(base, -1))
            values[bx + ox][by + oy] = add(add(base, dX), dY)
            commitPoints.append((bx + ox, by + oy))
        }
        for x in 0..<(xCount - 1) {
            for y in 0..<(yCount - 1) {
                let a = valid[x][y], b = valid[x + 1][y], c = valid[x][y + 1], d = valid[x + 1][y + 1]
                if a && b && c && !d { corner(x, y, 1, 1) }
                else if a && b && !c && d { corner(x + 1, y, -1, 1) }
                else if a && !b && c && d { corner(x, y + 1, 1, -1) }
                else if !a && b && c && d { corner(x + 1, y + 1, -1, -1) }
            }
        }
    }

    func extendAndIntersect(_ secondPass: Bool) {
        yMajor = secondPass
        var detectedIntersections = false
        func setOrAverage(_ maj: Int, _ mn: Int, _ val: T, _ origin: Float) {
            let minDist = abs(axisPoint(mn) - origin)
            if secondPass && isNewlySet(maj, mn) {
                if !detectedIntersections { commitPoints.removeAll() }
                let majDist = getDistance(maj, mn)
                let frac = minDist / (minDist + majDist * majDist / minDist)
                set(maj, mn, add(scale(val, 1 - frac), scale(get(maj, mn), frac)))
                detectedIntersections = true
            }
            if !detectedIntersections { set(maj, mn, val, minDist) }
        }
        for i in 0..<majorCnt() {
            let cnt = minorCnt()
            var j = 0
            while j < cnt && !isValid(i, j) { j += 1 }
            if j >= cnt { continue }
            var val = get(i, j)
            var origin = axisPoint(j)
            for k in 0..<j { setOrAverage(i, k, val, origin) }
            j = cnt - 1
            while j >= 0 && !isValid(i, j) { j -= 1 }
            val = get(i, j)
            origin = axisPoint(j)
            for k in (j + 1)..<cnt { setOrAverage(i, k, val, origin) }
        }
    }

    while true {
        for (x, y) in commitPoints where !valid[x][y] {
            valid[x][y] = true
            validCount += 1
        }
        commitPoints.removeAll()
        if validCount >= totalCount { break }
        newlySet = [[Bool]](repeating: [Bool](repeating: false, count: yCount), count: xCount)
        interpolate1D2D(false)
        interpolate1D2D(true)
        if !commitPoints.isEmpty { continue }
        extrapolateCorners()
        if !commitPoints.isEmpty { continue }
        extendAndIntersect(false)
        extendAndIntersect(true)
        if !commitPoints.isEmpty { continue }
        break
    }
}

extension ValueBinding {
    func reinterpolateValues() {
        reinterpolate(&values, isSet: isSet, axisPoints: parameter.axisPoints, add: +, scale: *)
    }
}

extension DeformBinding {
    func reinterpolateValues() {
        reinterpolate(&values, isSet: isSet, axisPoints: parameter.axisPoints,
                      add: { a, b in zip(a, b).map { $0 + $1 } },
                      scale: { a, s in a.map { $0 * s } })
    }
}
