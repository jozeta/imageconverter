import Foundation
import ImageIO

/// The key lists behind "remove all" with kept fields, and "remove XMP".
extension MetadataOps {
    /// The IPTC fields the classic IIM block can hold (the rest exist only in XMP).
    static let iimKeys: Set<String> = Set([
        kCGImagePropertyIPTCObjectTypeReference, kCGImagePropertyIPTCObjectAttributeReference,
        kCGImagePropertyIPTCObjectName, kCGImagePropertyIPTCEditStatus, kCGImagePropertyIPTCEditorialUpdate,
        kCGImagePropertyIPTCUrgency, kCGImagePropertyIPTCSubjectReference, kCGImagePropertyIPTCCategory,
        kCGImagePropertyIPTCSupplementalCategory, kCGImagePropertyIPTCFixtureIdentifier, kCGImagePropertyIPTCKeywords,
        kCGImagePropertyIPTCContentLocationCode, kCGImagePropertyIPTCContentLocationName,
        kCGImagePropertyIPTCReleaseDate, kCGImagePropertyIPTCReleaseTime, kCGImagePropertyIPTCExpirationDate,
        kCGImagePropertyIPTCExpirationTime, kCGImagePropertyIPTCSpecialInstructions, kCGImagePropertyIPTCActionAdvised,
        kCGImagePropertyIPTCReferenceService, kCGImagePropertyIPTCReferenceDate, kCGImagePropertyIPTCReferenceNumber,
        kCGImagePropertyIPTCDateCreated, kCGImagePropertyIPTCTimeCreated, kCGImagePropertyIPTCDigitalCreationDate,
        kCGImagePropertyIPTCDigitalCreationTime, kCGImagePropertyIPTCOriginatingProgram,
        kCGImagePropertyIPTCProgramVersion, kCGImagePropertyIPTCObjectCycle, kCGImagePropertyIPTCByline,
        kCGImagePropertyIPTCBylineTitle, kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation,
        kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationCode,
        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCOriginalTransmissionReference,
        kCGImagePropertyIPTCHeadline, kCGImagePropertyIPTCCredit, kCGImagePropertyIPTCSource,
        kCGImagePropertyIPTCCopyrightNotice, kCGImagePropertyIPTCContact, kCGImagePropertyIPTCCaptionAbstract,
        kCGImagePropertyIPTCWriterEditor, kCGImagePropertyIPTCImageType, kCGImagePropertyIPTCImageOrientation,
        kCGImagePropertyIPTCLanguageIdentifier, kCGImagePropertyIPTCStarRating
    ].map { $0 as String })

    /// EXIF exposure settings kept with "camera info" (besides the camera and lens keys).
    private static let exifExposureKeys: [String] = [
        kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber, kCGImagePropertyExifExposureProgram,
        kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm,
        kCGImagePropertyExifFlash, kCGImagePropertyExifMeteringMode, kCGImagePropertyExifWhiteBalance,
        kCGImagePropertyExifExposureBiasValue, kCGImagePropertyExifApertureValue,
        kCGImagePropertyExifShutterSpeedValue, kCGImagePropertyExifMaxApertureValue, kCGImagePropertyExifExposureMode,
        kCGImagePropertyExifSceneCaptureType, kCGImagePropertyExifLightSource, kCGImagePropertyExifDigitalZoomRatio
    ].map { $0 as String }

    /// The fields of `source` that "remove all" keeps (see `KeepField`).
    static func kept(_ fields: Set<KeepField>, from source: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        func copy(_ keys: [String], from dictKey: String) {
            guard let dict = source[dictKey] as? [String: Any] else { return }
            var target = out[dictKey] as? [String: Any] ?? [:]
            for key in keys { if let value = dict[key] { target[key] = value } }
            store(target, at: dictKey, in: &out)
        }
        for field in fields {
            switch field {
            case .copyright:
                copy([kCGImagePropertyTIFFCopyright as String], from: tiffKey)
                copy([kCGImagePropertyIPTCCopyrightNotice as String, kCGImagePropertyIPTCRightsUsageTerms as String],
                     from: iptcKey)
                copy([kCGImagePropertyPNGCopyright as String], from: pngKey)
            case .author:
                copy([kCGImagePropertyTIFFArtist as String], from: tiffKey)
                copy([kCGImagePropertyExifCameraOwnerName as String], from: exifKey)
                copy(iptcAuthorKeys, from: iptcKey)
                copy([kCGImagePropertyPNGAuthor as String], from: pngKey)
            case .dateTaken:
                copy(MetadataDates.exifDateFamily, from: exifKey)
                copy([kCGImagePropertyTIFFDateTime as String], from: tiffKey)
                copy(MetadataDates.iptcDateFamily, from: iptcKey)
                copy([kCGImagePropertyPNGCreationTime as String], from: pngKey)
            case .orientation:
                out[kCGImagePropertyOrientation as String] = source[kCGImagePropertyOrientation as String]
                copy([kCGImagePropertyTIFFOrientation as String], from: tiffKey)
            case .colorProfile:
                break // embedded from the image's own color space, never stripped
            case .cameraInfo:
                copy(tiffCameraKeys, from: tiffKey)
                copy(exifCameraKeys.filter { $0 != kCGImagePropertyExifMakerNote as String } + exifExposureKeys,
                     from: exifKey)
                let aux = kCGImagePropertyExifAuxDictionary as String
                out[aux] = source[aux]
            case .location:
                out[gpsKey] = source[gpsKey]
                copy(iptcLocationKeys, from: iptcKey)
            }
        }
        return out
    }
}
