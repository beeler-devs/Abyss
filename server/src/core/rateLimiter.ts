export class SlidingWindowRateLimiter {
  private readonly maxEvents: number;
  private readonly windowMs: number;
  private readonly timestamps: number[] = [];

  constructor(maxEvents: number, windowMs: number) {
    this.maxEvents = maxEvents;
    this.windowMs = windowMs;
  }

  allow(nowMs: number = Date.now()): boolean {
    this.prune(nowMs);

    if (this.timestamps.length >= this.maxEvents) {
      return false;
    }

    this.timestamps.push(nowMs);
    return true;
  }

  private prune(nowMs: number): void {
    const threshold = nowMs - this.windowMs;
    while (this.timestamps.length && this.timestamps[0] < threshold) {
      this.timestamps.shift();
    }
  }
}
