import Accelerate
import CoreGraphics
import Foundation
// VideoToolbox's super-resolution scaler is in the macOS 26 SDK (Swift 6.2, Xcode 26) and later. CI builds with
// Xcode 16 (Swift 6.1, macOS 15 SDK), where the symbols don't exist: there the scaler is compiled out and reports
// `.unsupportedOS` (`.notInThisBuild` when running on macOS 26+). `-Xswiftc -DNO_MACOS26_SDK` compiles that same
// fallback on a newer toolchain.
#if compiler(>=6.2) && !NO_MACOS26_SDK
import CoreMedia
import CoreVideo
import VideoToolbox
#endif

/// Apple's image super-resolution model through VideoToolbox (macOS 26 and later): 4×, tiles up to 1920 × 1920.
/// It never downloads the model; the app's Resize editor does that, after asking (`MLEnlargeDownload` in the app).
public struct SystemSuperResolution: SuperResolutionScaler {
    public static let shared = SystemSuperResolution()
    /// For the app's own batch and preview: refusals say "Download it in the Resize step".
    public static let inApp = SystemSuperResolution(speaksFromApp: true)

    public let speaksFromApp: Bool

    public init(speaksFromApp: Bool = false) {
        self.speaksFromApp = speaksFromApp
    }

    public var factor: Int { 4 }

    /// True when this build contains the VideoToolbox scaler (built with the macOS 26 SDK or later).
    public static var isCompiledIn: Bool {
        #if compiler(>=6.2) && !NO_MACOS26_SDK
        return true
        #else
        return false
        #endif
    }

    public func availability() -> MLEnlargeAvailability {
        if let simulated = Self.simulatedStatus { return simulated }
        #if compiler(>=6.2) && !NO_MACOS26_SDK
        if #available(macOS 26, *) { return VideoToolboxScaler.availability() }
        #endif
        return Self.fallback(onMacOS26: ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
    }

    /// Without the scaler: a build that lacks the macOS 26 SDK says so on macOS 26 and later (`.notInThisBuild`);
    /// otherwise the system is too old.
    static func fallback(onMacOS26: Bool) -> MLEnlargeAvailability {
        onMacOS26 && !isCompiledIn ? .notInThisBuild : .unsupportedOS
    }

    /// DEBUG builds accept `-debugMLEnlargeStatus downloadRequired|downloading|ready|unsupportedHardware|unsupportedOS|`
    /// `notInThisBuild`
    /// (screenshots): the editor, preview, estimate and batch all see that status. Nothing is downloaded, and a
    /// simulated "ready" still needs the real model to run.
    public static let simulatedStatus: MLEnlargeAvailability? = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-debugMLEnlargeStatus"), index + 1 < args.count else { return nil }
        switch args[index + 1] {
        case "downloadRequired": return .downloadRequired
        case "downloading": return .downloading(progress: 0.35)
        case "ready": return .ready
        case "unsupportedHardware": return .unsupportedHardware
        case "unsupportedOS": return .unsupportedOS
        case "notInThisBuild": return .notInThisBuild
        default: return nil
        }
        #else
        return nil
        #endif
    }()

    public func makeSession(width: Int, height: Int, colorSpace: CGColorSpace) throws -> any SuperResolutionSession {
        #if compiler(>=6.2) && !NO_MACOS26_SDK
        if #available(macOS 26, *) {
            return try VideoToolboxScaler.Session(width: width, height: height, colorSpace: colorSpace,
                                                  inApp: speaksFromApp)
        }
        #endif
        throw ConversionError.mlEnlargeUnavailable(Self.fallback(onMacOS26: ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))), inApp: speaksFromApp)
    }
}

#if compiler(>=6.2) && !NO_MACOS26_SDK
@available(macOS 26, *)
enum VideoToolboxScaler {
    static let scaleFactor = 4
    /// The largest image input on macOS (per the SDK header; 1921 is refused).
    static let maxInput = 1920

    static func configuration(width: Int, height: Int) -> VTSuperResolutionScalerConfiguration? {
        VTSuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: scaleFactor,
                                             inputType: .image, usePrecomputedFlow: false,
                                             qualityPrioritization: .normal,
                                             revision: VTSuperResolutionScalerConfiguration.defaultRevision)
    }

    /// Reads the status only (`configurationModelStatus`); never starts a download.
    static func availability() -> MLEnlargeAvailability {
        guard VTSuperResolutionScalerConfiguration.isSupported,
              VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(scaleFactor),
              let configuration = configuration(width: maxInput, height: maxInput) else { return .unsupportedHardware }
        return status(of: configuration)
    }

    static func status(of configuration: VTSuperResolutionScalerConfiguration) -> MLEnlargeAvailability {
        switch configuration.configurationModelStatus {
        case .ready: return .ready
        case .downloading: return .downloading(progress: Double(configuration.configurationModelPercentageAvailable))
        case .downloadRequired: return .downloadRequired
        @unknown default: return .downloadRequired
        }
    }

    /// One frame-processor session for tiles of one size. Pixels go in and out as 16-bit float RGBA (the only
    /// format the image model takes), converted from and to the 8-bit tiles.
    final class Session: SuperResolutionSession {
        private let processor = VTFrameProcessor()
        private let configuration: VTSuperResolutionScalerConfiguration
        private let colorSpace: CGColorSpace
        private let width: Int
        private let height: Int

        init(width: Int, height: Int, colorSpace: CGColorSpace, inApp: Bool) throws {
            guard let configuration = VideoToolboxScaler.configuration(width: width, height: height),
                  configuration.supportedPixelFormats.contains(kCVPixelFormatType_64RGBAHalf) else {
                throw ConversionError.processingFailed(StepKind.resize.displayName)
            }
            let status = VideoToolboxScaler.status(of: configuration)
            guard status.isReady else { throw ConversionError.mlEnlargeUnavailable(status, inApp: inApp) }
            try processor.startSession(configuration: configuration)
            self.configuration = configuration
            self.colorSpace = colorSpace
            self.width = width
            self.height = height
        }

        deinit { processor.endSession() }

        func upscale(_ tile: RGBA8Tile) throws -> RGBA8Tile {
            let failed = ConversionError.processingFailed(StepKind.resize.displayName)
            guard tile.width == width, tile.height == height else { throw failed }
            let factor = VideoToolboxScaler.scaleFactor
            let source = try Self.pixelBuffer(width: width, height: height, colorSpace: colorSpace)
            try Self.write(tile, into: source)
            let target = try Self.pixelBuffer(width: width * factor, height: height * factor, colorSpace: colorSpace)
            guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: .zero),
                  let targetFrame = VTFrameProcessorFrame(buffer: target, presentationTimeStamp: .zero),
                  let parameters = VTSuperResolutionScalerParameters(
                    sourceFrame: sourceFrame, previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil,
                    submissionMode: .random, destinationFrame: targetFrame) else { throw failed }
            try MLEnlarge.waitForModel { finished in
                processor.process(parameters: parameters) { _, error in finished(error) }
            }
            return try Self.read(target)
        }

        private static func pixelBuffer(width: Int, height: Int, colorSpace: CGColorSpace) throws -> CVPixelBuffer {
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
                                             attributes as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                throw ConversionError.processingFailed(StepKind.resize.displayName)
            }
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
            return buffer
        }

        /// 8-bit RGBA → 16-bit float RGBA (each byte / 255), channel by channel.
        private static func write(_ tile: RGBA8Tile, into buffer: CVPixelBuffer) throws {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw ConversionError.processingFailed(StepKind.resize.displayName)
            }
            var pixels = tile.pixels
            let error = pixels.withUnsafeMutableBytes { raw -> vImage_Error in
                var from = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(tile.height),
                                         width: vImagePixelCount(tile.width * 4), rowBytes: tile.width * 4)
                var into = vImage_Buffer(data: base, height: vImagePixelCount(tile.height),
                                         width: vImagePixelCount(tile.width * 4),
                                         rowBytes: CVPixelBufferGetBytesPerRow(buffer))
                return vImageConvert_Planar8toPlanar16F(&from, &into, vImage_Flags(kvImageNoFlags))
            }
            guard error == kvImageNoError else { throw ConversionError.processingFailed(StepKind.resize.displayName) }
        }

        /// 16-bit float RGBA → 8-bit RGBA (clamped, rounded).
        private static func read(_ buffer: CVPixelBuffer) throws -> RGBA8Tile {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw ConversionError.processingFailed(StepKind.resize.displayName)
            }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let error = pixels.withUnsafeMutableBytes { raw -> vImage_Error in
                var from = vImage_Buffer(data: base, height: vImagePixelCount(height),
                                         width: vImagePixelCount(width * 4), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
                var into = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height),
                                         width: vImagePixelCount(width * 4), rowBytes: width * 4)
                return vImageConvert_Planar16FtoPlanar8(&from, &into, vImage_Flags(kvImageNoFlags))
            }
            guard error == kvImageNoError else { throw ConversionError.processingFailed(StepKind.resize.displayName) }
            return RGBA8Tile(width: width, height: height, pixels: pixels)
        }
    }
}
#endif
