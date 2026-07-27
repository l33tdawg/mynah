import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a photo on disk into something safe to put in a prompt.
///
/// The naive version of this feature — read the file, base64 it, send it — is a
/// context bomb. Modern phone cameras produce 12 MP images and a Mac screenshot
/// on a Retina display is 3024×1964. Vision models tokenise at dynamic
/// resolution, so image tokens scale with pixel count: a full-size screenshot
/// can cost more context than the entire system prompt and tool catalogue put
/// together, on an appliance whose whole latency story is how many tokens it has
/// to read.
///
/// So every image is downscaled before it is encoded. 1024 px on the long edge
/// is the size vision encoders are happiest with, and it is comfortably enough to
/// read a screenshot or recognise a dog.
public enum VisionAttachment {

    /// Longest edge, in pixels, of an image handed to the model.
    public static let maximumPixelSize = 1024

    /// JPEG quality for the re-encode. 0.8 is the usual point where artefacts
    /// stop being visible and the file stops shrinking much.
    public static let compressionQuality = 0.8

    /// Refuse anything larger than this on disk before decoding it. A 100 MB
    /// "image" is a misfire or an attack, and decoding it would cost the
    /// appliance its memory before any of the limits above get a chance to help.
    public static let maximumSourceBytes = 40 * 1024 * 1024

    public enum Failure: Error, Equatable {
        case tooLarge(bytes: Int)
        case unreadable
    }

    /// A downscaled JPEG of the image at `url`, ready to base64 into a request.
    ///
    /// Uses `CGImageSourceCreateThumbnailAtIndex`, which decodes at the target
    /// size rather than decoding full-size and shrinking afterwards — so a 12 MP
    /// photo never exists in memory at 12 MP. It also applies the EXIF
    /// orientation, without which a photo taken in portrait arrives at the model
    /// on its side.
    public static func encoded(contentsOf url: URL) throws -> Data {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if let size, size > maximumSourceBytes {
            throw Failure.tooLarge(bytes: size)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.unreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw Failure.unreadable
        }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.unreadable
        }
        return output as Data
    }
}
