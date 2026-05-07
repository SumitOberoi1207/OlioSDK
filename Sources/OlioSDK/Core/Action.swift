import Foundation

/// A user-triggered action a slot can dispatch.
///
/// Closed enum — adding a new case requires an SDK release. New action types
/// in payloads from a newer dashboard are silently dropped on older SDKs
/// (forward compatibility).
public enum Action: Codable, Sendable {
    case next
    case back
    case skip
    case dismiss
    case navigate(screen: ScreenID)
    case openExternal(url: URL)
    case purchase(productId: String)
    case track(event: String, properties: [String: String])
    case permission(kind: PermissionKind)
    indirect case compose(actions: [Action])

    public enum PermissionKind: String, Codable, Sendable {
        case push
        case att
        case location
        case contacts
        case camera
        case microphone
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case screen
        case url
        case productId
        case event
        case properties
        case kind
        case actions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "next":
            self = .next
        case "back":
            self = .back
        case "skip":
            self = .skip
        case "dismiss":
            self = .dismiss
        case "navigate":
            let screen = try container.decode(ScreenID.self, forKey: .screen)
            self = .navigate(screen: screen)
        case "openExternal":
            let url = try container.decode(URL.self, forKey: .url)
            self = .openExternal(url: url)
        case "purchase":
            let productId = try container.decode(String.self, forKey: .productId)
            self = .purchase(productId: productId)
        case "track":
            let event = try container.decode(String.self, forKey: .event)
            let properties = try container.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
            self = .track(event: event, properties: properties)
        case "permission":
            let kind = try container.decode(PermissionKind.self, forKey: .kind)
            self = .permission(kind: kind)
        case "compose":
            let actions = try container.decode([Action].self, forKey: .actions)
            self = .compose(actions: actions)
        default:
            // Unknown action types from newer dashboard payloads degrade to no-op.
            self = .track(event: "olio.unknown_action", properties: ["type": type])
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .next:
            try container.encode("next", forKey: .type)
        case .back:
            try container.encode("back", forKey: .type)
        case .skip:
            try container.encode("skip", forKey: .type)
        case .dismiss:
            try container.encode("dismiss", forKey: .type)
        case .navigate(let screen):
            try container.encode("navigate", forKey: .type)
            try container.encode(screen, forKey: .screen)
        case .openExternal(let url):
            try container.encode("openExternal", forKey: .type)
            try container.encode(url, forKey: .url)
        case .purchase(let productId):
            try container.encode("purchase", forKey: .type)
            try container.encode(productId, forKey: .productId)
        case .track(let event, let properties):
            try container.encode("track", forKey: .type)
            try container.encode(event, forKey: .event)
            if !properties.isEmpty {
                try container.encode(properties, forKey: .properties)
            }
        case .permission(let kind):
            try container.encode("permission", forKey: .type)
            try container.encode(kind, forKey: .kind)
        case .compose(let actions):
            try container.encode("compose", forKey: .type)
            try container.encode(actions, forKey: .actions)
        }
    }
}

extension Action: Equatable {
    public static func == (lhs: Action, rhs: Action) -> Bool {
        switch (lhs, rhs) {
        case (.next, .next), (.back, .back), (.skip, .skip), (.dismiss, .dismiss):
            return true
        case (.navigate(let l), .navigate(let r)):
            return l == r
        case (.openExternal(let l), .openExternal(let r)):
            return l == r
        case (.purchase(let l), .purchase(let r)):
            return l == r
        case (.track(let le, let lp), .track(let re, let rp)):
            return le == re && lp == rp
        case (.permission(let l), .permission(let r)):
            return l == r
        case (.compose(let l), .compose(let r)):
            return l == r
        default:
            return false
        }
    }
}
