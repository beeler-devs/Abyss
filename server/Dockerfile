FROM node:20-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY src/ src/
COPY tsconfig.json ./
RUN npm run build

RUN npm prune --omit=dev

EXPOSE 8080

CMD ["node", "dist/src/server.js"]
