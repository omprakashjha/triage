import XCTest
@testable import TriageCore

final class RateLimiterTests: XCTestCase {

    func testAcquireWithinLimit() async {
        let limiter = RateLimiter(maxRequestsPerSecond: 10)

        // Should be able to acquire 10 tokens immediately
        for _ in 0..<10 {
            let acquired = await limiter.tryAcquire()
            XCTAssertTrue(acquired)
        }
    }

    func testAcquireExceedsLimit() async {
        let limiter = RateLimiter(maxRequestsPerSecond: 5)

        // Drain all tokens
        for _ in 0..<5 {
            _ = await limiter.tryAcquire()
        }

        // Next one should fail
        let acquired = await limiter.tryAcquire()
        XCTAssertFalse(acquired)
    }

    func testAcquireRefillsOverTime() async {
        let limiter = RateLimiter(maxRequestsPerSecond: 10)

        // Drain all tokens
        for _ in 0..<10 {
            _ = await limiter.tryAcquire()
        }

        // Wait for refill (200ms should give ~2 tokens at 10/sec)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let acquired = await limiter.tryAcquire()
        XCTAssertTrue(acquired)
    }

    func testAcquireWaitsWhenEmpty() async {
        let limiter = RateLimiter(maxRequestsPerSecond: 10)

        // Drain tokens
        for _ in 0..<10 {
            _ = await limiter.tryAcquire()
        }

        // acquire() should wait and eventually succeed
        let start = Date()
        await limiter.acquire()
        let elapsed = Date().timeIntervalSince(start)

        // Should have waited at least ~0.1s for one token to refill
        XCTAssertGreaterThan(elapsed, 0.05)
    }
}

final class RetryPolicyTests: XCTestCase {

    func testDelayGrowsExponentially() {
        let policy = RetryPolicy(
            maxRetries: 5,
            initialDelay: 1.0,
            maxDelay: 60.0,
            multiplier: 2.0
        )

        // Without jitter the delays would be 1, 2, 4, 8, 16
        // With jitter they should be higher but bounded
        let delay0 = policy.delay(for: 0)
        let delay1 = policy.delay(for: 1)
        let delay2 = policy.delay(for: 2)

        XCTAssertGreaterThanOrEqual(delay0, 1.0)
        XCTAssertGreaterThanOrEqual(delay1, 2.0)
        XCTAssertGreaterThanOrEqual(delay2, 4.0)
        XCTAssertLessThanOrEqual(delay0, 1.5)  // 1 + up to 50% jitter
        XCTAssertLessThanOrEqual(delay1, 3.0)
        XCTAssertLessThanOrEqual(delay2, 6.0)
    }

    func testMaxDelayIsCapped() {
        let policy = RetryPolicy(maxDelay: 30.0)
        let delay = policy.delay(for: 20)  // Very high attempt
        XCTAssertLessThanOrEqual(delay, 30.0)
    }

    func testRetryableStatusCodes() {
        let policy = RetryPolicy()
        XCTAssertTrue(policy.shouldRetry(statusCode: 429))
        XCTAssertTrue(policy.shouldRetry(statusCode: 500))
        XCTAssertTrue(policy.shouldRetry(statusCode: 503))
        XCTAssertFalse(policy.shouldRetry(statusCode: 400))
        XCTAssertFalse(policy.shouldRetry(statusCode: 401))
        XCTAssertFalse(policy.shouldRetry(statusCode: 404))
    }

    func testWithRetrySucceedsOnFirstAttempt() async throws {
        let policy = RetryPolicy(maxRetries: 3)
        var callCount = 0

        let result: String = try await withRetry(policy: policy) {
            callCount += 1
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 1)
    }

    func testWithRetryRetriesOnTransientError() async throws {
        let policy = RetryPolicy(maxRetries: 3, initialDelay: 0.01)
        var callCount = 0

        let result: String = try await withRetry(policy: policy) {
            callCount += 1
            if callCount < 3 {
                throw APIError.httpError(statusCode: 429, body: "rate limited")
            }
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertEqual(callCount, 3)
    }

    func testWithRetryDoesNotRetryNonRetryableError() async {
        let policy = RetryPolicy(maxRetries: 3)
        var callCount = 0

        do {
            let _: String = try await withRetry(policy: policy) {
                callCount += 1
                throw APIError.httpError(statusCode: 400, body: "bad request")
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 1)
        }
    }
}
