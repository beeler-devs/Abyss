export class SlidingWindowRateLimiter {
    maxEvents;
    windowMs;
    timestamps = [];
    constructor(maxEvents, windowMs) {
        this.maxEvents = maxEvents;
        this.windowMs = windowMs;
    }
    allow(nowMs = Date.now()) {
        this.prune(nowMs);
        if (this.timestamps.length >= this.maxEvents) {
            return false;
        }
        this.timestamps.push(nowMs);
        return true;
    }
    prune(nowMs) {
        const threshold = nowMs - this.windowMs;
        while (this.timestamps.length && this.timestamps[0] < threshold) {
            this.timestamps.shift();
        }
    }
}
