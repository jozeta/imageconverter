import CoreGraphics
import Foundation

extension Pipeline {
    /// A crop's detected focus in `image`, or nil (fixed anchor, or the crop keeps the whole image anyway).
    func cropFocus(_ options: CropOptions, in image: CGImage, step: Int, context: FocusContext,
                   notes: inout [String]) -> CGRect? {
        guard options.focus.isDetected else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        guard Geometry.cropRect(source: size, options: options).size != size else { return nil }
        return FocusDetector.focusRect(options.focus, in: image, at: position(of: step), context: context, notes: &notes)
    }

    /// A fill-and-crop resize's detected focus in `image`, or nil when the step crops nothing or uses its anchor.
    func resizeFocus(_ options: ResizeOptions, in image: CGImage, step: Int, context: FocusContext,
                     notes: inout [String]) -> CGRect? {
        guard options.cropsToFill, options.focus.isDetected,
              case .fillAndCrop = Geometry.resizePlan(source: CGSize(width: image.width, height: image.height),
                                                      options: options) else { return nil }
        return FocusDetector.focusRect(options.focus, in: image, at: position(of: step), context: context, notes: &notes)
    }

    /// Step `index` and the enabled operations before it (what made that step's input).
    private func position(of index: Int) -> StepPosition {
        StepPosition(index: index, before: steps.prefix(index).filter(\.isEnabled).map(\.operation))
    }
}
