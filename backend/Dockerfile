# Railway-deployed backend. Node + Fastify only — image generation happens
# on fal.ai / Lambda Cloud, reached over WebSocket from the relay.
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
