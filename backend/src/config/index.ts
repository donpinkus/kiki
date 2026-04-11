export interface AppConfig {
  readonly PORT: number;
  readonly HOST: string;
  readonly FLUX_KLEIN_URL: string;
  readonly NODE_ENV: 'development' | 'production' | 'test';
  readonly LOG_LEVEL: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace';
}

function validateConfig(): AppConfig {
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
    FLUX_KLEIN_URL: process.env['FLUX_KLEIN_URL'] ?? '',
    NODE_ENV: nodeEnv,
    LOG_LEVEL: logLevel,
  };
}

export const config: AppConfig = validateConfig();
