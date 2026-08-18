import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif

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
        #if !canImport(ImageIO)
        /// There is no ImageIO here, so there is no downscale, so there is no
        /// image. **Distinct from `unreadable` on purpose** — that one means
        /// "this file is not a picture", and the two want opposite responses:
        /// one is the owner's file, the other is the build. A daemon that
        /// reported an owner's perfectly good photograph as unreadable would
        /// send them looking at the photograph.
        case noImageDecoderOnThisPlatform
        #endif
    }

    /// A downscaled JPEG of the image at `url`, ready to base64 into a request.
    ///
    /// Uses `CGImageSourceCreateThumbnailAtIndex`, which decodes at the target
    /// size rather than decoding full-size and shrinking afterwards — so a 12 MP
    /// photo never exists in memory at 12 MP. It also applies the EXIF
    /// orientation, without which a photo taken in portrait arrives at the model
    /// on its side.
    ///
    /// **Off Darwin this refuses rather than sending the file.** ImageIO is
    /// where both halves of the guarantee live — the decode-at-target-size that
    /// keeps a 12 MP photo out of memory, and the EXIF rotation without which a
    /// portrait photo reaches the model on its side. Passing the raw file
    /// through instead would be the context bomb this type exists to defuse:
    /// a single screenshot costing more of the window than the whole tool
    /// catalogue, on the one machine whose latency story is how many tokens it
    /// has to read. The caller logs the refusal and carries on with the words,
    /// which is a worse turn than a Mac gets and an honest one.
    public static func encoded(contentsOf url: URL) throws -> Data {
        #if !canImport(ImageIO)
        throw Failure.noImageDecoderOnThisPlatform
        #else
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
        #endif
    }
}
