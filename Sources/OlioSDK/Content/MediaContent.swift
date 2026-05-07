import Foundation

/// Content schema for MediaSlot — image, animation, video, or themed illustration.
public struct MediaContent: Decodable, Sendable, Equatable, SlotContent {
    public let source: Source
    public let aspectRatio: Double?
    public let fitMode: FitMode

    public enum Source: Decodable, Sendable, Equatable {
        case image(url: URL, alt: String)
        case lottie(url: URL, alt: String, loop: Bool)
        case video(url: URL, alt: String, autoplay: Bool)
        case themedIllustration(assetId: String, alt: String)

        private enum CodingKeys: String, CodingKey {
            case type, url, alt, loop, autoplay, assetId
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "image":
                let url = try container.decode(URL.self, forKey: .url)
                let alt = try container.decode(String.self, forKey: .alt)
                self = .image(url: url, alt: alt)
            case "lottie":
                let url = try container.decode(URL.self, forKey: .url)
                let alt = try container.decode(String.self, forKey: .alt)
                let loop = try container.decodeIfPresent(Bool.self, forKey: .loop) ?? true
                self = .lottie(url: url, alt: alt, loop: loop)
            case "video":
                let url = try container.decode(URL.self, forKey: .url)
                let alt = try container.decode(String.self, forKey: .alt)
                let autoplay = try container.decodeIfPresent(Bool.self, forKey: .autoplay) ?? false
                self = .video(url: url, alt: alt, autoplay: autoplay)
            case "themedIllustration":
                let assetId = try container.decode(String.self, forKey: .assetId)
                let alt = try container.decode(String.self, forKey: .alt)
                self = .themedIllustration(assetId: assetId, alt: alt)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown media source type: \(type)"
                )
            }
        }
    }

    public enum FitMode: String, Decodable, Sendable, Equatable {
        case fill
        case fit
        case cover
    }

    private enum CodingKeys: String, CodingKey {
        case source, aspectRatio, fitMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try container.decode(Source.self, forKey: .source)
        self.aspectRatio = try container.decodeIfPresent(Double.self, forKey: .aspectRatio)
        self.fitMode = try container.decodeIfPresent(FitMode.self, forKey: .fitMode) ?? .fit
    }
}
