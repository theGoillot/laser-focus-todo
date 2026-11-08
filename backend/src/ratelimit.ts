/** Sliding-window limiter: at most `max` units per `windowMs`. Lives in Durable Object memory. */
export class RateLimiter {
  private stamps: number[] = [];
  constructor(private max = 60, private windowMs = 60_000) {}

  /** Reserves `units` if they fit in the window; returns false (reserving nothing) otherwise. */
  allow(units: number, now = Date.now()): boolean {
    const floor = now - this.windowMs;
    while (this.stamps.length && this.stamps[0] <= floor) this.stamps.shift();
    if (this.stamps.length + units > this.max) return false;
    for (let i = 0; i < units; i++) this.stamps.push(now);
    return true;
  }
}
