export interface AppConfig {
  readonly PORT: number;
  readonly HOST: string;
  readonly RUNPOD_API_KEY: string;
  readonly RUNPOD_SSH_PRIVATE_KEY: string;
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

  const runpodApiKey = process.env['RUNPOD_API_KEY'] ?? '';
  if (!runpodApiKey) {
    throw new Error('RUNPOD_API_KEY is required (orchestrator needs it to create/query/terminate pods)');
  }

  const runpodSshKey = process.env['RUNPOD_SSH_PRIVATE_KEY'] ?? '';
  if (!runpodSshKey) {
    throw new Error('RUNPOD_SSH_PRIVATE_KEY is required (orchestrator SSHes into pods to run setup)');
  }

  return {
    PORT: port,
    HOST: process.env['HOST'] ?? '0.0.0.0',
    RUNPOD_API_KEY: runpodApiKey,
    RUNPOD_SSH_PRIVATE_KEY: runpodSshKey,
    NODE_ENV: nodeEnv,
    LOG_LEVEL: logLevel,
  };
}

export const config: AppConfig = validateConfig();
