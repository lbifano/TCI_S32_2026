FROM node:22-alpine

RUN npm install -g pnpm@12.6.0 --no-audit --no-fund

WORKDIR /app

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

COPY index.html tsconfig.json vite.config.ts ./
COPY src ./src

EXPOSE 5173

CMD ["pnpm", "dev", "--host", "0.0.0.0"]
