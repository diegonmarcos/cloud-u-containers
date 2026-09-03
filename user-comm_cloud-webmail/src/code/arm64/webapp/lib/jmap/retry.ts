const RETRYABLE_STATUS_CODES = new Set([429, 502, 503, 504]);

interface RetryOptions {
  maxRetries?: number;
  baseDelay?: number;
  signal?: AbortSignal;
}

export async function retryWithBackoff(
  fn: () => Promise<Response>,
  options: RetryOptions = {}
): Promise<Response> {
  const { maxRetries = 3, baseDelay = 500, signal } = options;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    if (signal?.aborted) {
      throw new DOMException('Aborted', 'AbortError');
    }

    try {
      const response = await fn();

      if (attempt < maxRetries && RETRYABLE_STATUS_CODES.has(response.status)) {
        let delay: number;
        if (response.status === 429) {
          const retryAfter = response.headers.get('Retry-After');
          const retrySeconds = retryAfter ? parseInt(retryAfter, 10) : NaN;
          delay = !isNaN(retrySeconds) ? retrySeconds * 1000 : baseDelay * Math.pow(2, attempt);
        } else {
          delay = baseDelay * Math.pow(2, attempt);
        }
        const jitter = delay * (0.8 + Math.random() * 0.4);
        await new Promise(resolve => setTimeout(resolve, jitter));
        continue;
      }

      return response;
    } catch (error) {
      if (error instanceof TypeError && attempt < maxRetries) {
        const delay = baseDelay * Math.pow(2, attempt);
        const jitter = delay * (0.8 + Math.random() * 0.4);
        await new Promise(resolve => setTimeout(resolve, jitter));
        continue;
      }
      throw error;
    }
  }

  throw new Error('Retry loop exited unexpectedly');
}
