//
//  FeedbackImageEncoder.swift
//  Jot
//

import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// Loads PhotosPicker selections and converts them to base64 data URIs
/// for the `images` field in the feedback POST body.
///
/// The server caps `images` at 3 attachments and 5 MB combined
/// (base64-encoded). For a typical iPhone screenshot (1290×2796 PNG
/// ~3–5 MB) re-encoded as JPEG quality 0.8, each image drops to
/// ~400–800 KB and three fit comfortably. For edge cases the encoder
/// downsamples to a 2048px longer edge and iteratively lowers JPEG
/// quality (0.8 → 0.4) until the combined encoded length fits, then
/// surfaces a clear error if the smallest version still doesn't fit.
enum FeedbackImageEncoder {
    static let maxImages = 3
    static let maxTotalEncodedBytes = 5 * 1024 * 1024  // 5 MB — server's documented cap
    static let maxDimension: CGFloat = 2048

    enum EncodingError: LocalizedError {
        case tooLarge
        case loadFailed

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "Screenshots are too large (limit 5 MB total). Try fewer or smaller images."
            case .loadFailed:
                return "Couldn't read one of the selected images."
            }
        }
    }

    struct EncodedImage: Identifiable, Sendable {
        let id = UUID()
        let thumbnail: UIImage
        let dataURI: String
        var encodedBytes: Int { dataURI.utf8.count }
    }

    /// Load + encode picker selections in one pass. Returns an array of
    /// `EncodedImage` where `dataURI` is the base64 string ready for the
    /// `images` field. Throws on load failure or if even the lowest-quality
    /// encoding exceeds `maxTotalEncodedBytes`.
    static func process(_ items: [PhotosPickerItem]) async throws -> [EncodedImage] {
        var raw: [UIImage] = []
        for item in items.prefix(maxImages) {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw EncodingError.loadFailed
            }
            raw.append(image)
        }
        let resized = raw.map { resizeIfNeeded($0) }

        // Iteratively lower JPEG quality until the combined encoded size
        // fits the server cap. Quality steps chosen empirically: 0.8 is
        // visually lossless for screenshots; 0.4 is the floor before text
        // legibility starts degrading noticeably.
        let qualitySteps: [CGFloat] = [0.8, 0.65, 0.5, 0.4]
        for quality in qualitySteps {
            var encoded: [EncodedImage] = []
            var totalBytes = 0
            var ok = true
            for image in resized {
                guard let jpeg = image.jpegData(compressionQuality: quality) else {
                    ok = false
                    break
                }
                let base64 = jpeg.base64EncodedString()
                let uri = "data:image/jpeg;base64,\(base64)"
                totalBytes += uri.utf8.count
                encoded.append(EncodedImage(thumbnail: image, dataURI: uri))
            }
            if ok && totalBytes <= maxTotalEncodedBytes {
                return encoded
            }
        }
        throw EncodingError.tooLarge
    }

    /// Downscale to `maxDimension` on the longer edge, preserving aspect.
    /// No-op if the image is already within the cap.
    private static func resizeIfNeeded(_ image: UIImage) -> UIImage {
        let size = image.size
        let longerEdge = max(size.width, size.height)
        guard longerEdge > maxDimension else { return image }
        let scale = maxDimension / longerEdge
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
