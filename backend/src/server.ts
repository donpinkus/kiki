import { buildApp } from './app.js';
import { config } from './config/index.js';

const app = buildApp();

try {
  await app.listen({ port: config.PORT, host: config.HOST });
  app.log.info(`Server running on ${config.HOST}:${config.PORT}`);
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
