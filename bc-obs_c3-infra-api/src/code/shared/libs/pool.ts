/**
 * Async worker pool with configurable concurrency.
 * Limits parallel operations to avoid overwhelming SSH connections / CPU.
 */

const DEFAULT_CONCURRENCY = 6;

export class Pool {
  private running = 0;
  private queue: (() => void)[] = [];

  constructor(private concurrency = DEFAULT_CONCURRENCY) {}

  async run<T>(fn: () => Promise<T>): Promise<T> {
    if (this.running >= this.concurrency) {
      await new Promise<void>((resolve) => this.queue.push(resolve));
    }
    this.running++;
    try {
      return await fn();
    } finally {
      this.running--;
      if (this.queue.length > 0) this.queue.shift()!();
    }
  }

  async map<T, R>(items: T[], fn: (item: T) => Promise<R>): Promise<R[]> {
    return Promise.all(items.map((item) => this.run(() => fn(item))));
  }

  async settle<T, R>(
    items: T[],
    fn: (item: T) => Promise<R>,
  ): Promise<PromiseSettledResult<R>[]> {
    return Promise.allSettled(items.map((item) => this.run(() => fn(item))));
  }
}

/** Shared pool for SSH operations — 6 concurrent max */
export const sshPool = new Pool(DEFAULT_CONCURRENCY);

/** Shared pool for HTTP/curl probes — 6 concurrent max */
export const httpPool = new Pool(DEFAULT_CONCURRENCY);
