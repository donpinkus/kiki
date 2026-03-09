export interface AppConfig {
  readonly PORT: number;
  readonly HOST: string;
  readonly FAL_API_KEY: string;
  readonly NODE_ENV: 'development' | 'production' | 'test';
  readonly LOG_LEVEL: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace';
}

class ConfigValidationError extends Error {
  constructor(missing: string[]) {
    super(`Missing required config: ${missing.join(', ')}`);
    this.name = 'ConfigValidationError';
  }
}

function validateConfig(): AppConfig {
  const missing: string[] = [];

  const falApiKey = process.env['FAL_API_KEY'];
  if (!falApiKey) {
    missing.push('FAL_API_KEY');
  }

  if (missing.length > 0) {
    throw new ConfigValidationError(missing);
  }

  const nodeEnv = (process.env['NODE_ENV'] ?? 'development') as AppConfig['NODE_ENV'];
  if (!['development', 'production', 'test'].includes(nodeEnv)) {
    throw new Error(`Invalid NODE_ENV: ${nodeEnv}`);
  }

  const logLevel = (process.env['LOG_LEVEL'] ?? 'info') as AppConfig['LOG_LEVEL'];
  if (!['fatal', 'error', 'warn', 'info', 'debug', 'trace'].includes(logLevel)) {
    throw new Error(`Invalid LOG_LEVEL: ${logLevel}`);
  }

  const port = Number(process.env['PORT'] ?? 3000);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid PORT: ${process.env['PORT']}`);
  }

  return {
    PORT: port,
    HOST: process.env['HOST'] ?? '0.0.0.0',
    FAL_API_KEY: falApiKey!,
    NODE_ENV: nodeEnv,
    LOG_LEVEL: logLevel,
  };
}

export const config: AppConfig = validateConfig();
