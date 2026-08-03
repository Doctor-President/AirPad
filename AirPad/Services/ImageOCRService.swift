import Foundation
import Vision
import ImageIO
import CoreGraphics

/// The single on-device OCR entry point for the app. Lifted out of
/// `CameraCaptureView` (where it was a `private static` that ran only on the
/// pick-exactly-one-image path) so gallery images become searchable SUBSTRATE.
///
/// Recognition config is unchanged from the original: `.accurate` +
/// `usesLanguageCorrection`. Two entry points share one core:
///   • `recognizeText(fileURL:)` — for background enrichment. Import no longer
///     decodes, so the service owns its own decode via ImageIO, downsampled to
///     `maxPixel` on the longest edge (EXIF-oriented). Call it OFF the main
///     actor — Vision `perform` is synchronous.
///   • `recognizeText(cgImage:)` — the Vision core, for callers that already
///     hold a decoded image (`CameraCaptureView`), so they don't fabricate a URL.
enum ImageOCRService {

    /// Bump when the recognition config or a Vision revision changes materially;
    /// enrichment re-runs on items whose stored `extractorVersion` differs.
    static let extractorVersion = "vision-txt-1"

    /// Longest-edge cap for the enrichment decode. Big enough that small text —
    /// recipes, receipts, whiteboards, book pages, screenshots — stays legible;
    /// not full-res (OCR on a 48 MP frame is wasteful). If 2048 proves lossy on
    /// dense screenshots this is the knob to raise.
    static let maxPixel: Int = 2048

    /// OCR the image file at `url` — decodes it itself. Returns "" when the file
    /// can't be decoded or no text is found (callers treat empty as "no text").
    static func recognizeText(fileURL url: URL) -> String {
        guard let cg = downsampledCGImage(url: url, maxPixel: maxPixel) else { return "" }
        return recognizeText(cgImage: cg)
    }

    /// Vision core — for callers that already have a decoded `CGImage`.
    static func recognizeText(cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try? handler.perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: " ")
    }

    /// ImageIO thumbnail decode — bounded memory, honors EXIF orientation, and
    /// never fully-decodes the original bitmap (`ShouldCache: false`).
    private static func downsampledCGImage(url: URL, maxPixel: Int) -> CGImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // apply EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
