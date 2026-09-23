# lrn.webui - the Vite/React SPA, served as static files by nginx.
#
# Built from THIS folder (unlike the two .NET images, which need the repo root):
#
#   docker build -f lrn.webui/Dockerfile -t lrn-webui ./lrn.webui
#
# ── The build-time URL caveat ────────────────────────────────────────────────
# Vite substitutes import.meta.env.VITE_* at BUILD time, not at run time. The two
# backend URLs are therefore frozen into the JS bundle in this image, which means one
# image per environment - the same artifact cannot be promoted from staging to
# production. That matches how the app is built today (.env.development /
# .env.production), so it is what this Dockerfile does.
#
# If you would rather ship ONE image everywhere, src/config/apiConfig.js is already
# most of the way there: resolveMetricsBase()/resolveReportsApiBase() fall through to
# window.__LRN_METRICS_BASE and window.__LRN_DENIAL_API_BASE. So an entrypoint that
# writes those two globals into /usr/share/nginx/html/config.js at container start,
# plus a <script src="./config.js"> ahead of the bundle in index.html, gives runtime
# configuration without touching any application logic.
#
# One catch if you go that way: import.meta.env is checked BEFORE the window globals,
# so the image must then be built with the VITE_* args UNSET - a baked-in value wins
# and the runtime config would be silently ignored.

# ── Build ────────────────────────────────────────────────────────────────────
# Node 24 matches the toolchain on the dev machine. package.json pins nothing
# ("vite": "latest"), so a rebuild months from now can pull a different major - pin
# the deps if this image needs to be reproducible.
FROM node:24-alpine AS build
WORKDIR /app

# npm ci needs the lockfile and is reproducible; npm install would drift.
COPY package.json package-lock.json ./
RUN npm ci

# Defaults are the production URLs from .env.production. Override per environment:
#   --build-arg VITE_REPORTS_API_BASE_URL=https://staging.example.com/api/denialworkflow
ARG VITE_LRN_METRICS_BASE_URL=https://www.lrnanalytics.com/lrnAnalytics
ARG VITE_REPORTS_API_BASE_URL=https://www.lrnanalytics.com/lrnapi/api/denialworkflow
ENV VITE_LRN_METRICS_BASE_URL=$VITE_LRN_METRICS_BASE_URL \
    VITE_REPORTS_API_BASE_URL=$VITE_REPORTS_API_BASE_URL

COPY . .

# vite.config.js reads .certs/localhost.pem for the HTTPS dev server. That folder is
# excluded by .dockerignore and the check is existsSync, so the build just sees no
# certificate and carries on - `vite build` does not serve anything anyway.
RUN npm run build

# ── Runtime ──────────────────────────────────────────────────────────────────
FROM nginx:1.27-alpine AS final

COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

# nginx:alpine ships an unprivileged "nginx" user but the default config wants
# :80 and /var/cache. Listening on 8080 instead lets the container drop root.
RUN chown -R nginx:nginx /usr/share/nginx/html /var/cache/nginx \
    && touch /var/run/nginx.pid \
    && chown nginx:nginx /var/run/nginx.pid

EXPOSE 8080
USER nginx

# Foreground, or the container exits the moment nginx daemonizes.
CMD ["nginx", "-g", "daemon off;"]
