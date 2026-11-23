import AppKit
import CoreImage
import Metal
import MetalKit
import SwiftUI

/// Hardware-accelerated `MTKView` rendering `CIImage` previews via the cached `previewContext`
/// (`CIRenderDestination`), supporting zoom, pan, checkerboard transparency, and dark/light backdrop.
struct MetalPreviewView: NSViewRepresentable {
    let image: CIImage?
    let previewContext: CIContext?
    let zoomScale: Double
    let darkBackground: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.framebufferOnly = false
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
        mtkView.delegate = context.coordinator
        context.coordinator.mtkView = mtkView
        context.coordinator.commandQueue = mtkView.device?.makeCommandQueue()
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.image = image
        context.coordinator.ciContext = previewContext
        context.coordinator.zoomScale = zoomScale
        context.coordinator.darkBackground = darkBackground
        nsView.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        weak var mtkView: MTKView?
        var image: CIImage?
        var ciContext: CIContext?
        var zoomScale: Double = 1.0
        var darkBackground: Bool = false

        var commandQueue: MTLCommandQueue?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let ciContext else {
                return
            }

            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0 else { return }

            let bounds = CGRect(origin: .zero, size: drawableSize)
            let bgColor = darkBackground
                ? CIColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1.0)
                : CIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
            var composed = CIImage(color: bgColor).cropped(to: bounds)

            if let img = image, img.extent.width > 0, img.extent.height > 0, !img.extent.isInfinite {
                let fitScale = min(drawableSize.width / img.extent.width, drawableSize.height / img.extent.height) * 0.95
                let effectiveScale = max(0.05, fitScale * CGFloat(zoomScale))

                // Checkerboard behind transparent regions
                if let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
                    "inputCenter": CIVector(x: 0, y: 0),
                    "inputColor0": darkBackground ? CIColor(red: 0.22, green: 0.22, blue: 0.24) : CIColor(red: 0.92, green: 0.92, blue: 0.94),
                    "inputColor1": darkBackground ? CIColor(red: 0.17, green: 0.17, blue: 0.19) : CIColor(red: 0.85, green: 0.85, blue: 0.88),
                    "inputWidth": 12.0 * (view.window?.backingScaleFactor ?? 2.0),
                    "inputSharpness": 1.0
                ])?.outputImage {
                    let scaledW = img.extent.width * effectiveScale
                    let scaledH = img.extent.height * effectiveScale
                    let dx = (drawableSize.width - scaledW) * 0.5
                    let dy = (drawableSize.height - scaledH) * 0.5
                    let targetRect = CGRect(x: dx, y: dy, width: scaledW, height: scaledH)

                    let checkerRect = checker.cropped(to: targetRect)
                    let scaledImg = img
                        .transformed(by: CGAffineTransform(translationX: -img.extent.origin.x, y: -img.extent.origin.y))
                        .transformed(by: CGAffineTransform(scaleX: effectiveScale, y: effectiveScale))
                        .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                    composed = scaledImg.composited(over: checkerRect).composited(over: composed).cropped(to: bounds)
                }
            }

            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let destination = CIRenderDestination(
                width: Int(drawableSize.width),
                height: Int(drawableSize.height),
                pixelFormat: view.colorPixelFormat,
                commandBuffer: commandBuffer,
                mtlTextureProvider: { drawable.texture }
            )
            destination.colorSpace = cs
            destination.isFlipped = true

            do {
                try ciContext.startTask(toRender: composed, to: destination)
            } catch {
                // Non-fatal fallback
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
