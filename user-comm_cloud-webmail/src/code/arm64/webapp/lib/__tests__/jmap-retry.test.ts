import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { retryWithBackoff } from '../jmap/retry';

describe('retryWithBackoff', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('returns immediately on success', async () => {
    const fn = vi.fn().mockResolvedValue(new Response('ok', { status: 200 }));
    const result = await retryWithBackoff(fn);
    expect(fn).toHaveBeenCalledTimes(1);
    expect(result.status).toBe(200);
  });

  it('retries on 503 and succeeds', async () => {
    const fn = vi.fn()
      .mockResolvedValueOnce(new Response('', { status: 503 }))
      .mockResolvedValue(new Response('ok', { status: 200 }));

    const promise = retryWithBackoff(fn);
    await vi.advanceTimersByTimeAsync(700);
    const result = await promise;

    expect(fn).toHaveBeenCalledTimes(2);
    expect(result.status).toBe(200);
  });

  it('retries on 429 and succeeds', async () => {
    const fn = vi.fn()
      .mockResolvedValueOnce(new Response('', { status: 429 }))
      .mockResolvedValue(new Response('ok', { status: 200 }));

    const promise = retryWithBackoff(fn);
    await vi.advanceTimersByTimeAsync(700);
    const result = await promise;

    expect(fn).toHaveBeenCalledTimes(2);
    expect(result.status).toBe(200);
  });

  it('retries on TypeError (network failure)', async () => {
    const fn = vi.fn()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValue(new Response('ok', { status: 200 }));

    const promise = retryWithBackoff(fn);
    await vi.advanceTimersByTimeAsync(700);
    const result = await promise;

    expect(fn).toHaveBeenCalledTimes(2);
    expect(result.status).toBe(200);
  });

  it('does NOT retry on 400', async () => {
    const fn = vi.fn().mockResolvedValue(new Response('bad', { status: 400 }));
    const result = await retryWithBackoff(fn);
    expect(fn).toHaveBeenCalledTimes(1);
    expect(result.status).toBe(400);
  });

  it('does NOT retry on 401', async () => {
    const fn = vi.fn().mockResolvedValue(new Response('unauthorized', { status: 401 }));
    const result = await retryWithBackoff(fn);
    expect(fn).toHaveBeenCalledTimes(1);
    expect(result.status).toBe(401);
  });

  it('gives up after max retries', async () => {
    const fn = vi.fn().mockResolvedValue(new Response('', { status: 503 }));

    const promise = retryWithBackoff(fn, { maxRetries: 3 });
    for (let i = 0; i < 3; i++) {
      await vi.advanceTimersByTimeAsync(3000);
    }
    const result = await promise;

    expect(fn).toHaveBeenCalledTimes(4); // 1 initial + 3 retries
    expect(result.status).toBe(503);
  });

  it('respects Retry-After header on 429', async () => {
    const headers = new Headers({ 'Retry-After': '2' });
    const fn = vi.fn()
      .mockResolvedValueOnce(new Response('', { status: 429, headers }))
      .mockResolvedValue(new Response('ok', { status: 200 }));

    const promise = retryWithBackoff(fn);
    await vi.advanceTimersByTimeAsync(2500);
    const result = await promise;

    expect(fn).toHaveBeenCalledTimes(2);
    expect(result.status).toBe(200);
  });

  it('respects AbortSignal', async () => {
    const controller = new AbortController();
    const fn = vi.fn().mockResolvedValue(new Response('', { status: 503 }));

    controller.abort();
    await expect(
      retryWithBackoff(fn, { signal: controller.signal })
    ).rejects.toThrow();
  });
});
