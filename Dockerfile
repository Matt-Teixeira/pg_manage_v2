
FROM node:lts AS deps
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

FROM node:lts AS runner
WORKDIR /app
# Install pg client 16 (from PostgreSQL APT repo) + CA bundle
RUN apt-get update -qq \
  && apt-get install -y -qq curl gnupg ca-certificates lsb-release \
  && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
  && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
       | gpg --dearmor -o /etc/apt/trusted.gpg.d/pgdg.gpg \
  && apt-get update -qq \
  && apt-get install -y -qq postgresql-client-16 \
  && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY . .

USER node
ENTRYPOINT ["node", "index.js"]



# docker build . -t hhm_creds
# docker run --rm   --name pg_manage-app   --env-file ./.env   pg_manage SME00445
# docker run --rm   --name pg_manage-app   --env-file ./.env   pg_manage SME00445