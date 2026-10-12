// Sliding-window counters for failed logins (per address) and requests (per device).

export class RateLimiter {
  private readonly hits = new Map<string, number[]>();
  private readonly blockedUntil = new Map<string, number>();
  private readonly limit: number;
  private readonly windowMs: number;
  private readonly blockMs: number;

  constructor(limit: number, windowMs: number, blockMs = 0) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.blockMs = blockMs;
  }

  isBlocked(key: string, now = Date.now()): boolean {
    const until = this.blockedUntil.get(key);
    if (until === undefined) return false;
    if (until > now) return true;
    this.blockedUntil.delete(key);
    return false;
  }

  /** Records a hit; returns false when the key is over its limit (and blocks it if configured). */
  hit(key: string, now = Date.now()): boolean {
    if (this.isBlocked(key, now)) return false;
    const recent = (this.hits.get(key) ?? []).filter((t) => now - t < this.windowMs);
    recent.push(now);
    this.hits.set(key, recent);
    if (recent.length > this.limit) {
      if (this.blockMs > 0) {
        this.blockedUntil.set(key, now + this.blockMs);
        this.hits.delete(key);
      }
      return false;
    }
    return true;
  }

  reset(key: string): void {
    this.hits.delete(key);
    this.blockedUntil.delete(key);
  }
}
