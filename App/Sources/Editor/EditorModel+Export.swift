import SwiftUI
import AVFoundation
import simd
import Inochi2DKit

/// Image, video and INP export (Creator's io/imageexport, videoexport, inpexport).
extension EditorModel {
    var cameras: [Camera] { (puppet?.root.allNodes() ?? []).compactMap { $0 as? Camera } }

    /// View-projection that shows exactly what a camera node frames.
    func cameraProjection(_ cam: Camera) -> simd_float4x4 {
        let inv = cam.transform().matrix.inverse
        var m = simd_float4x4()
        for r in 0..<4 { for c in 0..<4 { m[c][r] = inv[r, c] } }
        let ortho = simd_float4x4(rows: [
            SIMD4(2 / cam.viewport.x, 0, 0, 0),
            SIMD4(0, -2 / cam.viewport.y, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1),
        ])
        return ortho * m
    }

    /// Renders the puppet through a camera (premultiplied RGBA8).
    func renderCamera(_ cam: Camera, transparent: Bool, renderer: Renderer) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let puppet else { return nil }
        let w = Int(cam.viewport.x), h = Int(cam.viewport.y)
        guard w > 0, h > 0 else { return nil }
        let list = puppet.draw()
        let frame = RenderFrame(list: list, viewProjection: cameraProjection(cam), preservePixels: puppet.meta.preservePixels,
                                textures: textures)
        let bgColor = backgroundColor ?? background.color
        let bg: Renderer.Background? = transparent ? nil : Renderer.Background(a: bgColor, b: bgColor, cell: 64)
        guard let px = renderer.renderImage(frame, width: w, height: h, background: bg) else { return nil }
        return (px, w, h)
    }

    enum ImageFormat: String, CaseIterable, Identifiable {
        case png, jpeg, tga
        var id: String { rawValue }
    }

    func exportImage(camera: Camera, transparent: Bool, format: ImageFormat) -> Data? {
        guard let renderer = Renderer(device: GPU.device) else { return nil }
        puppet?.update(deltaTime: 0)
        guard let (px, w, h) = renderCamera(camera, transparent: transparent, renderer: renderer) else { return nil }
        switch format {
        case .tga:
            var straight = px
            for i in stride(from: 0, to: straight.count, by: 4) {
                let a = Int(straight[i + 3])
                if a > 0 && a < 255 { for c in 0..<3 { straight[i + c] = UInt8(min(255, Int(straight[i + c]) * 255 / a)) } }
            }
            return TGAEncoder.encode(rgba: straight, width: w, height: h)
        case .png:
            return Self.image(px, w, h)?.pngData()
        case .jpeg:
            return Self.image(px, w, h)?.jpegData(compressionQuality: 0.92)
        }
    }

    /// Writes an animation through a camera to a movie (H.264, or HEVC with alpha).
    func exportVideo(camera: Camera, animation name: String, loops: Int, fps requested: Int, transparent: Bool,
                     to url: URL, progress: @escaping (Double) -> Void) async throws {
        guard let puppet, let anim = puppet.animations[name], let renderer = Renderer(device: GPU.device) else { return }
        let w = Int(camera.viewport.x), h = Int(camera.viewport.y)
        let player = AnimationPlayer(puppet: puppet)
        guard let pb = player.playback(name) else { return }
        let fps = requested >= 1 ? requested : max(anim.fps, 1)
        let frameTime = 1 / Double(fps)
        let lengthFactor = Double(fps) / Double(max(anim.fps, 1))
        let loopsN = max(loops, 1)
        let begin = pb.animationLoopBegin, end = pb.animationLoopEnd
        let total = Int(ceil(Double(begin) * lengthFactor)) + Int(ceil(Double(end - begin) * lengthFactor)) * loopsN
            + Int(ceil(Double(anim.length - end) * lengthFactor))

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoWidthKey: w, AVVideoHeightKey: h]
        if transparent {
            settings[AVVideoCodecKey] = AVVideoCodecType.hevcWithAlpha
        } else {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        puppet.resetDrivers()
        let wasDrivers = puppet.enableDrivers
        puppet.enableDrivers = true
        defer { puppet.enableDrivers = wasDrivers; puppet.resetDrivers() }
        pb.play(loop: true, playLeadOut: true)
        for i in 0..<max(total, 1) {
            player.update(frameTime)
            if pb.looped >= loopsN { pb.stop(immediate: false) }
            puppet.update(deltaTime: frameTime)
            guard let (px, _, _) = renderCamera(camera, transparent: transparent, renderer: renderer) else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buf = buffer else { continue }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buf)
                px.withUnsafeBytes { src in
                    for y in 0..<h {
                        let d = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<w {
                            let s = (y * w + x) * 4
                            d[x * 4] = src[s + 2]; d[x * 4 + 1] = src[s + 1]; d[x * 4 + 2] = src[s]; d[x * 4 + 3] = src[s + 3]
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
            progress(Double(i + 1) / Double(max(total, 1)))
            await Task.yield()
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    func exportINP(_ settings: INPExportSettings) throws -> INPExportResult {
        guard let puppet else { throw CocoaError(.fileWriteUnknown) }
        commitPending()
        return try puppet.exportINP(settings) { blob in
            guard var (px, w, h) = TextureLoader.decode(blob) else { return nil }
            if blob.encoding != .tga { TGADecoder.premultiply(&px) }
            return (px, w, h)
        }
    }

    func recalculateOrigin(_ node: Node) {
        puppet?.recalculateOrigin(node)
        changed("Recalculate origin")
    }
}

extension AnimationPlayback {
    var animationLoopBegin: Int { animation.leadIn > 0 && animation.leadIn + 1 < animation.length ? animation.leadIn : 0 }
    var animationLoopEnd: Int { animation.leadOut > 0 && animation.leadOut + 1 < animation.length ? animation.leadOut : animation.length }
}
