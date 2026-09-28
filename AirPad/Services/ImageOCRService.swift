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

    /// Brief BK — the confidence floor + cap for `classify`. VNClassifyImageRequest returns
    /// the whole ~1300-label taxonomy each with a calibrated confidence; 0.10 keeps the
    /// concepts clearly present without a tail of near-zero guesses. Top 8 by confidence.
    /// The knobs to dial if labels read too sparse (lower) or too noisy (raise).
    static let labelConfidenceFloor: Float = 0.10
    static let maxLabels = 8

    /// On-device image LABELS (Vision taxonomy), top `maxLabels` at or above the floor,
    /// highest confidence first. DERIVED text for the Librarian ("find my beach photos") —
    /// **never a title**. Empty when nothing clears the floor. Call OFF the main actor.
    static func classify(cgImage: CGImage) -> [String] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try? handler.perform([request])
        return (request.results ?? [])
            .filter { $0.confidence >= labelConfidenceFloor }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxLabels)
            .map { $0.identifier }
    }

    /// Classify the image file at `url` — decodes it itself (same downsample as OCR).
    static func classify(fileURL url: URL) -> [String] {
        guard let cg = downsampledCGImage(url: url, maxPixel: maxPixel) else { return [] }
        return classify(cgImage: cg)
    }

    /// Brief BK — ONE decode, BOTH passes (OCR text + classification labels). The enrichment
    /// write-back path uses this so a photo is decoded once, not twice. Call OFF the main actor.
    static func analyze(fileURL url: URL) -> (text: String, labels: [String]) {
        guard let cg = downsampledCGImage(url: url, maxPixel: maxPixel) else { return ("", []) }
        return (recognizeText(cgImage: cg), classify(cgImage: cg))
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
