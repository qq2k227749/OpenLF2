FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY server.js packs.js ./
ENV NODE_ENV=production PORT=10000
EXPOSE 10000
USER node
CMD ["node", "server.js"]
