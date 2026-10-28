//! Global speed limit: a token bucket shared by all the connections (pure logic, clock supplied).

use std::time::Duration;

#[derive(Debug, Clone)]
pub struct TokenBucket {
    /// Bytes per second (0 = no limit).
    rate: u64,
    tokens: f64,
    last_ms: u64,
}

impl TokenBucket {
    pub fn new(rate_bytes_per_second: u64, now_ms: u64) -> Self {
        Self {
            rate: rate_bytes_per_second,
            tokens: rate_bytes_per_second as f64,
            last_ms: now_ms,
        }
    }

    pub fn set_rate(&mut self, rate_bytes_per_second: u64) {
        self.rate = rate_bytes_per_second;
        self.tokens = self.tokens.min(rate_bytes_per_second as f64);
    }

    pub fn rate(&self) -> u64 {
        self.rate
    }

    /// Takes `bytes` tokens and says how long to wait before continuing (zero if no limit or enough tokens).
    /// Tokens may go negative: the wait pays back the debt, which keeps the average speed exact.
    pub fn take(&mut self, bytes: u64, now_ms: u64) -> Duration {
        if self.rate == 0 {
            return Duration::ZERO;
        }
        let elapsed = now_ms.saturating_sub(self.last_ms) as f64 / 1000.0;
        self.last_ms = now_ms;
        // One second of capacity: a small burst is allowed, no more.
        self.tokens = (self.tokens + elapsed * self.rate as f64).min(self.rate as f64);
        self.tokens -= bytes as f64;
        if self.tokens >= 0.0 {
            Duration::ZERO
        } else {
            Duration::from_secs_f64(-self.tokens / self.rate as f64)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_limit_never_waits() {
        let mut bucket = TokenBucket::new(0, 0);
        assert_eq!(bucket.take(1_000_000_000, 0), Duration::ZERO);
    }

    #[test]
    fn the_average_rate_is_respected() {
        // 1,000 bytes/s: after the one-second burst, taking 2,000 bytes requires waiting 2 s.
        let mut bucket = TokenBucket::new(1_000, 0);
        assert_eq!(bucket.take(1_000, 0), Duration::ZERO);
        assert_eq!(bucket.take(2_000, 0), Duration::from_secs(2));
        // Two seconds later, the debt is paid back.
        assert_eq!(bucket.take(0, 2_000), Duration::ZERO);
        // The pause does not create credit beyond one second.
        assert_eq!(bucket.take(1_500, 60_000), Duration::from_millis(500));
    }
}
