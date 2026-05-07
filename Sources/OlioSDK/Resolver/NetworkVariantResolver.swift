import Foundation

/// Production-shaped resolver that fetches variant payloads over HTTP.
///
/// Sits between the demo-phase `BundledVariantResolver` and your eventual
/// edge variant service. In design-partner phase, point it at a static file
/// host (Cloudflare Pages, GitHub Pages, S3, Backblaze B2). When you ship a
/// real edge service, point it at that — the SDK contract doesn't change.
///
/// ## Default URL convention
///
/// For a base URL `https://variants.example.com`, the default URL builder
/// resolves a screen + variant key to:
///
///     <baseURL>/<screen>.json                       (no variant key)
///     <baseURL>/<screen>.<variantKey>.json          (variant key present)
///
/// You can override this with a custom `urlBuilder` in the configuration —
/// useful for REST-style routes, query-param-based variants, or whatever your
/// edge service prefers.
///
/// ## Server-side targeting
///
/// When `resolve(screen:attribution:context:)` is called with a
/// `UserContext` whose `userId` is non-nil **and** no explicit variant key
/// was derived from attribution/override, the resolver appends `?id=<userId>`
/// to the request URL. The Worker uses that to hash users into percentage
/// rollouts and (combined with `Cf-IPCountry`) to enforce country rules. If
/// a rule matches, the response carries `X-Tryolio-Targeting-Rule: <ruleId>`.
///
/// Explicit variant requests (`<screen>.<variantKey>.json`) bypass targeting:
/// they are fetched directly without `?id`.
///
/// ## Failure modes
///
/// All network errors, non-2xx responses, decoding errors, and timeouts
/// degrade to `nil`, which causes slots to use their default closures.
/// The container never crashes the host app on a failed fetch.
///
/// ## Caching
///
/// In-memory cache with a configurable TTL (default 60 seconds). Successful
/// fetches are cached per (screen, variantKey, userId) and considered fresh
/// until the TTL elapses; after that the next resolve refetches.
///
/// Including `userId` in the cache key is required for targeting correctness
/// — otherwise user A's targeted payload would be served to user B from
/// cache. Identical missing-id requests still share a cache slot.
///
/// `URLRequest.cachePolicy = .reloadRevalidatingCacheData` lets URLSession
/// satisfy fetches from its HTTP cache (respecting the server's `Cache-Control`)
/// when the local cache has expired but the server hasn't actually changed.
///
/// Use `clearCache()` to invalidate everything (e.g., after a debug edit in the
/// dashboard). No disk persistence or HTTP ETag handling yet — add when a
/// customer asks.
public actor NetworkVariantResolver: VariantResolver {
    public typealias Fetcher = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias URLBuilder = @Sendable (URL, ScreenID, String?) -> URL
    public typealias SchemaURLBuilder = @Sendable (URL, ScreenID) -> URL

    public struct Configuration: Sendable {
        public let baseURL: URL
        public let timeout: TimeInterval
        public let authorizationHeader: String?
        public let cacheTTL: TimeInterval
        public let attributionMapper: AttributionMapping.Mapper
        public let urlBuilder: URLBuilder
        public let schemaURLBuilder: SchemaURLBuilder

        public init(
            baseURL: URL,
            timeout: TimeInterval = 1.5,
            authorizationHeader: String? = nil,
            cacheTTL: TimeInterval = 60,
            attributionMapper: @escaping AttributionMapping.Mapper = AttributionMapping.defaultMapper,
            urlBuilder: @escaping URLBuilder = NetworkVariantResolver.defaultURLBuilder,
            schemaURLBuilder: @escaping SchemaURLBuilder = NetworkVariantResolver.defaultSchemaURLBuilder
        ) {
            self.baseURL = baseURL
            self.timeout = timeout
            self.authorizationHeader = authorizationHeader
            self.cacheTTL = cacheTTL
            self.attributionMapper = attributionMapper
            self.urlBuilder = urlBuilder
            self.schemaURLBuilder = schemaURLBuilder
        }
    }

    private struct CacheEntry {
        let payload: VariantPayload
        let fetchedAt: Date
    }

    private struct SchemaCacheEntry {
        let schema: ScreenSchema
        let fetchedAt: Date
    }

    private let configuration: Configuration
    private let fetch: Fetcher
    private var override: String?
    private var cache: [String: CacheEntry] = [:]
    private var schemaCache: [String: SchemaCacheEntry] = [:]

    public init(
        configuration: Configuration,
        fetch: @escaping Fetcher = NetworkVariantResolver.defaultFetcher
    ) {
        self.configuration = configuration
        self.fetch = fetch
    }

    /// Force a specific variant id, bypassing attribution-based mapping.
    public func setActiveVariantOverride(_ variantId: String?) {
        self.override = variantId
    }

    /// Drop all cached payloads (variants and schemas). Useful after the
    /// dashboard publishes a new variant during the same app session.
    public func clearCache() {
        cache.removeAll()
        schemaCache.removeAll()
    }

    public func resolve(screen: ScreenID, attribution: AttributionContext?) async -> VariantPayload? {
        await resolve(screen: screen, attribution: attribution, context: nil)
    }

    /// Resolve with optional per-user signals for server-side targeting.
    ///
    /// - Parameters:
    ///   - screen: The screen whose variant is being fetched.
    ///   - attribution: Optional attribution context. Used to derive an
    ///     explicit variant key via the configured mapper. When a key is
    ///     derived (or set via `setActiveVariantOverride`), the request goes
    ///     directly to that variant and **targeting is skipped**.
    ///   - context: Optional per-user signals. When `context.userId` is
    ///     non-nil and no explicit variant key was derived, the SDK appends
    ///     `?id=<userId>` so the server can evaluate targeting rules.
    /// - Returns: The resolved variant payload, or nil on failure (the
    ///   container will fall back to slot defaults).
    public func resolve(
        screen: ScreenID,
        attribution: AttributionContext?,
        context: UserContext?
    ) async -> VariantPayload? {
        let variantKey = override ?? attribution.flatMap(configuration.attributionMapper)

        // Targeting only applies to default-variant requests. Explicit variant
        // fetches are deterministic and must not have `?id` appended — the
        // Worker would treat them the same, but skipping the param keeps
        // request URLs identical for the same explicit variant across users
        // (better for shared CDN cache hit rates).
        let userId = (variantKey == nil) ? context?.userId : nil
        // Forward custom attributes only on default-variant requests (same
        // reasoning as `?id`). Empty-string values are noise and dropped.
        let attributePairs: [(String, String)] = (variantKey == nil)
            ? Self.sortedContextPairs(from: context?.attributes ?? [:])
            : []
        let attrsSignature = attributePairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let cacheKey = "\(screen.raw)|\(variantKey ?? "_default")|\(userId ?? "_anon")|\(attrsSignature)"

        // Serve from cache only if still fresh per TTL.
        if let entry = cache[cacheKey],
           Date().timeIntervalSince(entry.fetchedAt) < configuration.cacheTTL {
            return entry.payload
        }

        let baseRequestURL = configuration.urlBuilder(configuration.baseURL, screen, variantKey)
        let urlWithID = userId.map { Self.appendIDQuery(to: baseRequestURL, id: $0) } ?? baseRequestURL
        let url = attributePairs.isEmpty
            ? urlWithID
            : Self.appendContextQuery(to: urlWithID, attributes: attributePairs)

        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "GET"
        // Bypass URLSession's stale local cache so we honor the in-memory TTL.
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authHeader = configuration.authorizationHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            let payload = try JSONDecoder().decode(VariantPayload.self, from: data)
            cache[cacheKey] = CacheEntry(payload: payload, fetchedAt: Date())
            return payload
        } catch {
            // Fail-open: log and return nil so slots fall back to defaults.
            print("[Olio] Network resolver failed for \(screen): \(error)")
            return nil
        }
    }

    /// Resolve the layout schema for a screen.
    ///
    /// Schemas are public (no Bearer token) and not user-specific — they
    /// describe a screen's *layout*, not personalized content. Cached under
    /// `"schema|<screen>"` independently of variant cache slots.
    ///
    /// All failures (404, network, decode) degrade to `nil` silently because
    /// schemas are optional metadata used only for dev-time validation.
    public func resolveSchema(screen: ScreenID) async -> ScreenSchema? {
        let cacheKey = "schema|\(screen.raw)"

        if let entry = schemaCache[cacheKey],
           Date().timeIntervalSince(entry.fetchedAt) < configuration.cacheTTL {
            return entry.schema
        }

        let url = configuration.schemaURLBuilder(configuration.baseURL, screen)

        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Deliberately NO Authorization header — schemas are read-public.

        do {
            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            let schema = try JSONDecoder().decode(ScreenSchema.self, from: data)
            schemaCache[cacheKey] = SchemaCacheEntry(schema: schema, fetchedAt: Date())
            return schema
        } catch {
            // Schemas are optional — silent failure. Don't even log; we don't
            // want noise on every screen for tenants that haven't published
            // schemas yet.
            return nil
        }
    }

    /// Resolve the PM-authored journey for this user.
    ///
    /// Hits `<baseURL>/__journey/resolve` with the same context-forwarding
    /// rules as variant resolution: `?id=<userId>` when `context.userId` is
    /// non-nil, `?ctx_<key>=<value>` for each non-empty attribute (sorted
    /// alphabetically). The Worker returns a JSON body matching `JourneyDTO`
    /// (campaignId, order, skip).
    ///
    /// Failure modes (non-2xx, network error, decode error) all degrade to
    /// `.empty` so a journey lookup never disrupts onboarding — the host
    /// falls back to its hardcoded screen order.
    public func resolveJourney(context: UserContext?) async -> OlioJourney {
        let baseRequestURL = configuration.baseURL.appendingPathComponent("__journey").appendingPathComponent("resolve")

        let urlWithID: URL = {
            if let userId = context?.userId, !userId.isEmpty {
                return Self.appendIDQuery(to: baseRequestURL, id: userId)
            }
            return baseRequestURL
        }()

        let attributePairs = Self.sortedContextPairs(from: context?.attributes ?? [:])
        let url = attributePairs.isEmpty
            ? urlWithID
            : Self.appendContextQuery(to: urlWithID, attributes: attributePairs)

        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authHeader = configuration.authorizationHeader {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return .empty
            }
            let dto = try JSONDecoder().decode(JourneyDTO.self, from: data)
            return OlioJourney(
                campaignId: dto.campaignId,
                order: dto.order,
                skip: Set(dto.skip)
            )
        } catch {
            // Fail-open: log and return empty so the host falls back to its
            // hardcoded onboarding order.
            print("[Olio] Network resolver failed to resolve journey: \(error)")
            return .empty
        }
    }

    // MARK: - URL helpers

    /// Appends `id=<value>` to the URL's query string, preserving any
    /// existing query items contributed by a custom `urlBuilder`. The value
    /// is URL-encoded by `URLQueryItem`.
    static func appendIDQuery(to url: URL, id: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "id", value: id))
        components.queryItems = items
        return components.url ?? url
    }

    /// Appends `ctx_<key>=<value>` query items for each provided attribute,
    /// preserving any existing query items. Caller is responsible for sorting
    /// (we want determinism for cache keys / HTTP caching). Keys and values
    /// are URL-encoded by `URLQueryItem`.
    static func appendContextQuery(to url: URL, attributes: [(String, String)]) -> URL {
        guard !attributes.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        for (key, value) in attributes {
            items.append(URLQueryItem(name: "ctx_\(key)", value: value))
        }
        components.queryItems = items
        return components.url ?? url
    }

    /// Sort and filter `UserContext.attributes` into the canonical
    /// `[(key, value)]` form used for `ctx_*` query items. Empty-string
    /// values are dropped; remaining pairs are sorted by key for deterministic
    /// URL ordering (cache hit-rate + test stability).
    static func sortedContextPairs(from attributes: [String: String]) -> [(String, String)] {
        return attributes
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    // MARK: - Defaults

    public static let defaultURLBuilder: URLBuilder = { baseURL, screen, variantKey in
        let resourceName: String = {
            if let variantKey = variantKey {
                return "\(screen.raw).\(variantKey).json"
            } else {
                return "\(screen.raw).json"
            }
        }()
        return baseURL.appendingPathComponent(resourceName)
    }

    /// Default URL for the schema endpoint: `<baseURL>/__schema/<screen>`.
    ///
    /// The tenant prefix is expected to be encoded in `baseURL` (e.g.
    /// `https://variants.tryolio.app/<tenant>`), matching the variant URL
    /// convention. Customers who route schemas differently can supply a
    /// custom `schemaURLBuilder` in `Configuration`.
    public static let defaultSchemaURLBuilder: SchemaURLBuilder = { baseURL, screen in
        baseURL
            .appendingPathComponent("__schema")
            .appendingPathComponent(screen.raw)
    }

    public static let defaultFetcher: Fetcher = { request in
        try await URLSession.shared.data(for: request)
    }
}
