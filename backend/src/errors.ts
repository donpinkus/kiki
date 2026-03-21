export class AppError extends Error {
  readonly statusCode: number;

  constructor(statusCode: number, message: string) {
    super(message);
    this.name = 'AppError';
    this.statusCode = statusCode;
  }
}

export class RateLimitedError extends AppError {
  readonly retryAfter?: number;

  constructor(message = 'Rate limit exceeded', retryAfter?: number) {
    super(429, message);
    this.name = 'RateLimitedError';
    this.retryAfter = retryAfter;
  }
}

export class ProviderError extends AppError {
  readonly provider: string;

  constructor(provider: string, message: string) {
    super(502, message);
    this.name = 'ProviderError';
    this.provider = provider;
  }
}
