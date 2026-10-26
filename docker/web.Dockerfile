FROM node:22.14.0-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY index.html vite.config.js ./
COPY src ./src
COPY public ./public
RUN npm run build
FROM node:22.14.0-bookworm-slim
ENV NODE_ENV=production HOST=0.0.0.0 PORT=9012 BACKEND_URL=http://core:9006
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY server.js ./server.js
USER node
EXPOSE 9012
CMD ["node", "server.js"]
