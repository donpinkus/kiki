# Kiki Insights — multi-stage build (server + React SPA).
FROM node:22-slim AS build
WORKDIR /app
COPY . .
# Installs server deps, then build runs build:server (tsc + copy schema.sql) and
# build:web (installs web deps + vite build → web/dist).
RUN npm install && npm run build

FROM node:22-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm install --omit=dev
COPY --from=build /app/dist ./dist
COPY --from=build /app/web/dist ./web/dist
EXPOSE 8080
CMD ["node", "dist/index.js"]
