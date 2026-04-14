# Railway-deployed backend. The orchestrator shells out to ssh/scp to
# provision per-session pods on RunPod, which the default Node runtime
# image doesn't ship — hence openssh-client in the runtime layer.
FROM node:22-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-client \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install deps first for layer caching
COPY package.json package-lock.json ./
RUN npm ci

# App source (tsconfig, src/, runtime-assets/, etc.)
COPY . .

RUN npm run build

EXPOSE 8080
CMD ["node", "dist/index.js"]
