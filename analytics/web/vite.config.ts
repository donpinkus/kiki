import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// In dev, the SPA runs on Vite's port and proxies API + blob requests to the
// Fastify server on :8080. In prod, Fastify serves the built SPA from web/dist
// and these proxies are irrelevant.
const proxy = {
  '/admin': 'http://localhost:8080',
  '/ingest': 'http://localhost:8080',
  '/blobs': 'http://localhost:8080',
  '/health': 'http://localhost:8080',
};

export default defineConfig({
  plugins: [react()],
  server: { proxy },
  build: { outDir: 'dist' },
});
