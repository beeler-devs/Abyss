export class SlidingWindowRateLimiter {
    maxEvents;
    windowMs;
    timestamps = [];
    head = 0;
    constructor(maxEvents, windowMs) {
        this.maxEvents = maxEvents;
        this.windowMs = windowMs;
    }
    allow(nowMs = Date.now()) {
        this.prune(nowMs);
        if (this.size() >= this.maxEvents) {
            return false;
        }
        this.timestamps.push(nowMs);
        return true;
    }
    prune(nowMs) {
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
    size() {
        return this.timestamps.length - this.head;
    }
}
