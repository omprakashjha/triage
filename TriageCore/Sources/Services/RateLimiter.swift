import Foundation

/// Token bucket rate limiter for API calls
public actor RateLimiter {
    private let maxTokens: Double
    private let refillRate: Double  // tokens per second
    private var tokens: Double
    private var lastRefill: Date

    /// Initialize with requests per second limit
    /// - Parameter maxRequestsPerSecond: Maximum requests allowed per second
    public init(maxRequestsPerSecond: Double) {
        self.maxTokens = maxRequestsPerSecond
        self.refillRate = maxRequestsPerSecond
        self.tokens = maxRequestsPerSecond
        self.lastRefill = Date()
    }

    /// Wait until a token is available, then consume it
    public func acquire() async {
        while true {
            refill()
            if tokens >= 1.0 {
                tokens -= 1.0
                return
            }
            // Calculate wait time for next token
            let waitTime = (1.0 - tokens) / refillRate
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
    }

    /// Try to acquire without waiting (returns false if rate limited)
    public func tryAcquire() -> Bool {
        refill()
        if tokens >= 1.0 {
            tokens -= 1.0
            return true
        }
        return false
    }

    private func refill() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        tokens = min(maxTokens, tokens + elapsed * refillRate)
        lastRefill = now
    }
}

/// Retry policy with exponential backoff
public struct RetryPolicy: Sendable {
    public let maxRetries: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let multiplier: Double
    public let retryableStatusCodes: Set<Int>

    public init(
        maxRetries: Int = 5,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        multiplier: Double = 2.0,
        retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]
    ) {
        self.maxRetries = maxRetries
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.multiplier = multiplier
        self.retryableStatusCodes = retryableStatusCodes
    }

    /// Calculate delay for a given attempt number (0-indexed)
    public func delay(for attempt: Int) -> TimeInterval {
        let delay = initialDelay * pow(multiplier, Double(attempt))
        let jitter = Double.random(in: 0...0.5) * delay  // Add jitter to prevent thundering herd
        return min(delay + jitter, maxDelay)
    }

    /// Whether a given HTTP status code should trigger a retry
    public func shouldRetry(statusCode: Int) -> Bool {
        retryableStatusCodes.contains(statusCode)
    }
}

/// Execute a network operation with retry logic
public func withRetry<T: Sendable>(
    policy: RetryPolicy,
    rateLimiter: RateLimiter? = nil,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var lastError: Error?

    for attempt in 0...policy.maxRetries {
        // Wait for rate limit token
        if let limiter = rateLimiter {
            await limiter.acquire()
        }

        do {
            return try await operation()
        } catch let error as APIError {
            lastError = error

            switch error {
            case .httpError(let statusCode, _):
                guard policy.shouldRetry(statusCode: statusCode),
                      attempt < policy.maxRetries else {
                    throw error
                }

                let delay = policy.delay(for: attempt)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            default:
                throw error
            }
        } catch {
            // Non-API errors are not retried
            throw error
        }
    }

    throw lastError ?? APIError.unknown("Retry exhausted with no error captured")
}

/// Generic API error type
public enum APIError: LocalizedError, Sendable {
    case httpError(statusCode: Int, body: String)
    case networkError(String)
    case decodingError(String)
    case invalidResponse
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .decodingError(let msg):
            return "Decoding error: \(msg)"
        case .invalidResponse:
            return "Invalid response from server"
        case .unknown(let msg):
            return "Unknown error: \(msg)"
        }
    }
}
