# Railway-deployed backend. Node + Fastify only — GPU orchestration happens
# on RunPod pods via their HTTP API.
FROM node:22-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install deps first for layer caching
COPY package.json package-lock.json ./
RUN npm ci

# App source (tsconfig, src/, etc.)
COPY . .

RUN npm run build

EXPOSE 8080
CMD ["node", "dist/index.js"]
