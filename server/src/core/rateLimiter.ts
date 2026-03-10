export class SlidingWindowRateLimiter {
  private readonly maxEvents: number;
  private readonly windowMs: number;
  private readonly timestamps: number[] = [];
  private head = 0;

  constructor(maxEvents: number, windowMs: number) {
    this.maxEvents = maxEvents;
    this.windowMs = windowMs;
  }

  allow(nowMs: number = Date.now()): boolean {
    this.prune(nowMs);

    if (this.size() >= this.maxEvents) {
      return false;
    }

    this.timestamps.push(nowMs);
    return true;
  }

  private prune(nowMs: number): void {
    const threshold = nowMs - this.windowMs;
    while (this.head < this.timestamps.length && this.timestamps[this.head] < threshold) {
      this.head += 1;
    }

    // Compact the array when the dead prefix exceeds half the total length
    // to prevent unbounded growth while avoiding frequent re-allocations.
    if (this.head > this.timestamps.length / 2 && this.head > 32) {
      this.timestamps.splice(0, this.head);
      this.head = 0;
    }
  }

  private size(): number {
    return this.timestamps.length - this.head;
  }
}
