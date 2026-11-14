import CoreImage
import Metal

/// The one Core Image context every Core Image step renders with (Adjust, Perspective, bicubic resizing).
/// `CIContext` is thread-safe, and one context keeps one set of GPU resources instead of one per step.
enum SharedCIContext {
    /// Metal-backed when the Mac has a GPU, else the software renderer. Linear extended sRGB at half float
    /// keeps out-of-gamut and HDR values; no intermediate cache, since each image is rendered once and a
    /// parallel batch would only pile up memory.
    static let context: CIContext = {
        var options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) { options[.workingColorSpace] = linear }
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        options[.useSoftwareRenderer] = true
        return CIContext(options: options)
    }()
}
