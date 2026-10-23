# syntax=docker/dockerfile:1.7
#
# =============================================================================
#  Portable Laravel production image  (PHP-FPM + nginx + optional workers)
# =============================================================================
#  Copy BOTH files into the root of any Laravel project:
#
#      Dockerfile          <- this file
#      .dockerignore       <- required companion file (cannot be embedded here)
#
#  Then:
#      docker build -t myapp .
#      docker run -p 8080:80 -e APP_KEY="$(php artisan key:generate --show)" myapp
#
#  Requirements: Docker 23+ / BuildKit (this file uses BuildKit heredocs).
#  Works on linux/amd64 and linux/arm64.
#
#  ---------------------------------------------------------------------------
#  Coolify
#  ---------------------------------------------------------------------------
#    Build pack ......... Dockerfile
#    Base Directory ..... repo root (where Dockerfile + .dockerignore live)
#    Ports Exposes ...... 80            (must equal PORT; leave PORT unset)
#    Persistent Storage . volume  ->  /var/www/html/storage
#    Environment ........ APP_KEY, APP_URL, APP_ENV=production, DB_*, LOG_CHANNEL=stderr
#    Trusted proxies .... TRUSTED_PROXIES=*  (see "Behind a proxy" below)
#    Healthcheck ........ the image already defines one (TCP on $PORT)
#
#  ---------------------------------------------------------------------------
#  Dokploy
#  ---------------------------------------------------------------------------
#    Build type ............ Dockerfile
#    Dockerfile Path ....... ./Dockerfile        Docker Context Path: .
#    Domain ................ container port 80   (matches EXPOSE)
#    Advanced -> Volumes ... mount /var/www/html/storage
#    Environment ........... same variables as above
#    Build Time Arguments .. use these for PHP_VERSION / NODE_VERSION etc.
#
#  ---------------------------------------------------------------------------
#  Behind a proxy (Dokploy / Coolify use Traefik)
#  ---------------------------------------------------------------------------
#    nginx forwards X-Forwarded-For/Proto/Host to PHP, but Laravel still needs
#    to trust the proxy in order to use them:
#      - Laravel 11+: add ->trustProxies(at: '*') to bootstrap/app.php, or set
#        TRUSTED_PROXIES=* if your skeleton reads it.
#      - Older Laravel: configure App\Http\Middleware\TrustProxies.
#    Without it, $request->ip() is the proxy IP and HTTPS detection fails.
#
#  ---------------------------------------------------------------------------
#  Runtime environment (all optional, defaults shown)
#  ---------------------------------------------------------------------------
#    PORT=80                     nginx listen port
#    APP_ROOT=/var/www/html
#    RUN_MIGRATIONS=true         php artisan migrate --force, retried until DB answers
#    RUN_OPTIMIZE=true           route:cache + view:cache (failures only warn)
#    RUN_CONFIG_CACHE=false      also config:cache - only if env() is used solely in config/
#    QUEUE_WORKER=false          run queue:work, restarted on exit
#    QUEUE_NAME=default  QUEUE_TRIES=3  QUEUE_TIMEOUT=60
#    SCHEDULER=false             run schedule:work, restarted on exit
#    MIGRATE_RETRIES=10          attempts before giving up on the database
#    CHOWN_STORAGE=true          recursive chown of storage on boot (false = faster)
#    PHP_MEMORY_LIMIT=256M
#    PHP_MAX_EXECUTION_TIME=60   seconds; FPM and nginx timeouts derive from it
#    UPLOAD_MAX_FILESIZE=16M  POST_MAX_SIZE=20M  CLIENT_MAX_BODY_SIZE=25m
#    FPM_MAX_CHILDREN=10  FPM_MAX_REQUESTS=500
#
#  ---------------------------------------------------------------------------
#  Build arguments (all optional)
#  ---------------------------------------------------------------------------
#    PHP_VERSION=8.4.27          pin an exact patch release. The build refuses
#                                versions below the php2shell fixes
#                                (CVE-2026-109618 / CVE-2026-109619):
#                                8.2.35 / 8.3.36 / 8.4.27 / 8.5.12
#    NODE_VERSION=22
#    EXTENSIONS="bcmath exif gd intl pcntl pdo_mysql pdo_pgsql zip"
#    INSTALL_REDIS=true          phpredis, what Laravel's default REDIS_CLIENT uses
#    BUILD_ASSETS=true           false => skip npm entirely (API-only apps)
#
#  ---------------------------------------------------------------------------
#  Persistence
#  ---------------------------------------------------------------------------
#    Mount a volume at /var/www/html/storage, or uploads, sessions and logs
#    disappear on the next deploy. Never bake a .env into the image - set the
#    variables in the platform UI instead.
#
#  Note: PHP 8.2 reaches end of life on 2026-12-31. Prefer 8.3.36+ or 8.4.27+.
#  =============================================================================

ARG PHP_VERSION=8.4.27
ARG NODE_VERSION=22

# =============================================================================
#  Stage 1 - frontend assets (only runs when package.json has a build script)
# =============================================================================
FROM node:${NODE_VERSION}-bookworm-slim AS assets

ARG BUILD_ASSETS=true

ENV CI=true \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0

WORKDIR /app

# Lockfiles are copied first so dependency installs survive source edits.
# BuildKit tolerates globs that match nothing, so projects without a
# package.json are fine.
COPY package*.json pnpm-lock.yaml* yarn.lock* ./

RUN set -eu; \
    if [ "${BUILD_ASSETS}" != "true" ] || [ ! -f package.json ]; then \
        echo "assets: no frontend build requested"; exit 0; \
    fi; \
    if [ -f pnpm-lock.yaml ]; then \
        echo "assets: pnpm"; corepack enable; pnpm install --frozen-lockfile; \
    elif [ -f yarn.lock ]; then \
        echo "assets: yarn"; corepack enable; yarn install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then \
        echo "assets: npm ci"; npm ci --no-audit --no-fund; \
    else \
        echo "assets: npm install (no lockfile)"; npm install --no-audit --no-fund; \
    fi

COPY . .

RUN set -eu; \
    if [ "${BUILD_ASSETS}" != "true" ] || [ ! -f package.json ]; then \
        echo "assets: skipping build"; exit 0; \
    fi; \
    if ! node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1)"; then \
        echo "assets: no 'build' script in package.json, skipping"; exit 0; \
    fi; \
    if [ -f pnpm-lock.yaml ]; then pnpm run build; \
    elif [ -f yarn.lock ]; then yarn run build; \
    else npm run build; \
    fi

# =============================================================================
#  Stage 2 - PHP-FPM runtime
# =============================================================================
FROM php:${PHP_VERSION}-fpm-bookworm

ARG EXTENSIONS="bcmath exif gd intl pcntl pdo_mysql pdo_pgsql zip"
ARG INSTALL_REDIS=true

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1 \
    APP_ROOT=/var/www/html

# Fails the build early when the base image predates the php2shell fixes.
# Used again at container start, so an old image can never be deployed.
RUN cat > /usr/local/bin/php-security-check <<'PHP'
<?php
// CVE-2026-109618 / CVE-2026-109619 ("php2shell", CVSS 9.2, unauthenticated
// RCE). Fixed 2026-10-21 in 8.2.35, 8.3.36, 8.4.27 and 8.5.12. Branches 8.0
// and 8.1 are end of life and will not receive a fix.
$fixed = ['8.2' => '8.2.35', '8.3' => '8.3.36', '8.4' => '8.4.27', '8.5' => '8.5.12'];
$branch = PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;

if (PHP_MAJOR_VERSION > 8 || (PHP_MAJOR_VERSION === 8 && PHP_MINOR_VERSION >= 6)) {
    exit(0); // later branches ship the fix
}

if (!isset($fixed[$branch])) {
    fwrite(STDERR, "FATAL: PHP {$branch} is out of support and has no php2shell fix. Use 8.2.35+, 8.3.36+, 8.4.27+ or 8.5.12+.\n");
    exit(1);
}

if (version_compare(PHP_VERSION, $fixed[$branch], '<')) {
    fwrite(STDERR, sprintf(
        "FATAL: PHP %s is vulnerable to CVE-2026-109618 / CVE-2026-109619. Minimum for %s: %s.\n",
        PHP_VERSION,
        $branch,
        $fixed[$branch]
    ));
    exit(1);
}

exit(0);
PHP

RUN php /usr/local/bin/php-security-check

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nginx \
        gettext-base \
        tini \
        procps \
        git \
        unzip \
        libpq-dev \
        libzip-dev \
        libicu-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libfreetype6-dev \
    ; \
    if [ -n "${EXTENSIONS}" ]; then \
        docker-php-ext-configure gd --with-freetype --with-jpeg; \
        docker-php-ext-install -j"$(nproc)" ${EXTENSIONS}; \
    fi; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# phpredis is on by default because Laravel's stock config expects it.
RUN set -eux; \
    if [ "${INSTALL_REDIS}" = "true" ]; then \
        pecl install redis; \
        docker-php-ext-enable redis; \
        rm -rf /tmp/pear; \
    fi

COPY --from=composer:2.8 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

# Dependency layer first, so editing source does not reinstall packages.
COPY composer.json composer.lock* ./
RUN set -eux; \
    if [ -f composer.lock ]; then \
        composer install --no-dev --no-interaction --prefer-dist --no-progress \
            --no-scripts --no-autoloader --optimize-autoloader; \
    else \
        echo "WARN: composer.lock is missing - falling back to composer update (not reproducible)"; \
        composer update --no-dev --no-interaction --prefer-dist --no-progress \
            --no-scripts --no-autoloader --optimize-autoloader; \
    fi

COPY . .

# Scripts are enabled here so the project's post-autoload-dump hooks
# (package:discover and friends) run against the real source tree.
RUN set -eux; \
    mkdir -p \
        storage/app/public \
        storage/framework/cache/data \
        storage/framework/sessions \
        storage/framework/views \
        storage/logs \
        bootstrap/cache \
    ; \
    composer dump-autoload --no-dev --optimize; \
    rm -rf /root/.composer /root/.cache /tmp/*

# Take the whole built public/ directory so Vite, Mix and anything else that
# writes into public/ all land in the image.
COPY --from=assets /app/public ./public

# -----------------------------------------------------------------------------
# PHP settings (rendered at container start, so limits are runtime-tunable)
# -----------------------------------------------------------------------------
RUN cat > /usr/local/etc/php/zz-app.ini.template <<'PHPINI'
; Rendered by /usr/local/bin/app-entrypoint on every container start.
expose_php = Off
memory_limit = ${PHP_MEMORY_LIMIT}
max_execution_time = ${PHP_MAX_EXECUTION_TIME}
upload_max_filesize = ${UPLOAD_MAX_FILESIZE}
post_max_size = ${POST_MAX_SIZE}

; php2shell mitigations: the confirmed CVE-2026-109619 vector went through
; session upload progress; fatal_error_backtraces is the 8.5 variant and is
; ignored (harmlessly) on older branches.
session.upload_progress.enabled = 0
fatal_error_backtraces = 0

opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 0

realpath_cache_size = 4096K
realpath_cache_ttl = 600
PHPINI

# -----------------------------------------------------------------------------
# PHP-FPM pool (the stock www.conf is replaced by a rendered template)
# -----------------------------------------------------------------------------
RUN rm -f /usr/local/etc/php-fpm.d/www.conf \
    && cat > /usr/local/etc/php-fpm.d/www.conf.template <<'FPMPOOL'
; Rendered by /usr/local/bin/app-entrypoint on every container start.
[www]
user = www-data
group = www-data

listen = 127.0.0.1:9000

pm = dynamic
pm.max_children = ${FPM_MAX_CHILDREN}
pm.start_servers = ${FPM_START_SERVERS}
pm.min_spare_servers = ${FPM_START_SERVERS}
pm.max_spare_servers = ${FPM_MAX_SPARE_SERVERS}
pm.max_requests = ${FPM_MAX_REQUESTS}

; Pass container environment (APP_KEY, DB_*, ...) through to workers.
clear_env = no

catch_workers_output = yes
decorate_workers_output = no

; Slightly above PHP's max_execution_time so PHP reports the error itself.
request_terminate_timeout = ${FPM_REQUEST_TERMINATE_TIMEOUT}
FPMPOOL

# -----------------------------------------------------------------------------
# nginx (single server block; TLS and HTTP/2 terminate at the platform proxy)
# -----------------------------------------------------------------------------
RUN cat > /etc/nginx/app.conf.template <<'NGINXCONF'
server {
    listen ${PORT};
    server_name _;
    server_tokens off;

    root /var/www/html/public;
    index index.php;
    charset utf-8;

    client_max_body_size ${CLIENT_MAX_BODY_SIZE};

    access_log /dev/stdout;
    error_log /dev/stderr;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/json
        application/xml
        application/rss+xml
        image/svg+xml;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    # Vite/Mix output is content-hashed, so it can be cached forever.
    location ^~ /build/ {
        expires 1y;
        access_log off;
        try_files $uri =404;
    }

    error_page 404 /index.php;

    # Laravel routes can legitimately end in .php (e.g. /admin/login.php).
    # Without the try_files fallback below, PHP-FPM would look for that literal
    # file, fail, and return "File not found." for those routes.
    location ~ \.php$ {
        try_files $uri /index.php?$query_string;

        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_read_timeout ${FASTCGI_READ_TIMEOUT};
        fastcgi_hide_header X-Powered-By;

        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT $realpath_root;

        # nginx does not forward arbitrary headers to FastCGI. Without these,
        # an app behind Traefik sees the proxy IP and http:// instead of the
        # real client and scheme, and TrustProxies has nothing to trust.
        fastcgi_param HTTP_X_FORWARDED_FOR $http_x_forwarded_for;
        fastcgi_param HTTP_X_FORWARDED_PROTO $http_x_forwarded_proto;
        fastcgi_param HTTP_X_FORWARDED_HOST $http_x_forwarded_host;
        fastcgi_param HTTP_X_FORWARDED_PORT $http_x_forwarded_port;
        fastcgi_param HTTP_X_REAL_IP $http_x_real_ip;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINXCONF

# -----------------------------------------------------------------------------
# Entrypoint: renders config, boots the app, supervises the processes
# -----------------------------------------------------------------------------
RUN cat > /usr/local/bin/app-entrypoint <<'ENTRYPOINT'
#!/bin/sh
set -eu

APP_ROOT="${APP_ROOT:-/var/www/html}"
PORT="${PORT:-80}"

PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-256M}"
PHP_MAX_EXECUTION_TIME="${PHP_MAX_EXECUTION_TIME:-60}"
UPLOAD_MAX_FILESIZE="${UPLOAD_MAX_FILESIZE:-16M}"
POST_MAX_SIZE="${POST_MAX_SIZE:-20M}"
CLIENT_MAX_BODY_SIZE="${CLIENT_MAX_BODY_SIZE:-25m}"
FPM_MAX_CHILDREN="${FPM_MAX_CHILDREN:-10}"
FPM_MAX_REQUESTS="${FPM_MAX_REQUESTS:-500}"

RUN_MIGRATIONS="${RUN_MIGRATIONS:-true}"
RUN_OPTIMIZE="${RUN_OPTIMIZE:-true}"
RUN_CONFIG_CACHE="${RUN_CONFIG_CACHE:-false}"
QUEUE_WORKER="${QUEUE_WORKER:-false}"
SCHEDULER="${SCHEDULER:-false}"
QUEUE_NAME="${QUEUE_NAME:-default}"
QUEUE_TRIES="${QUEUE_TRIES:-3}"
QUEUE_TIMEOUT="${QUEUE_TIMEOUT:-60}"
MIGRATE_RETRIES="${MIGRATE_RETRIES:-10}"
CHOWN_STORAGE="${CHOWN_STORAGE:-true}"

log() { printf '[entrypoint] %s\n' "$*"; }

# Never start a vulnerable interpreter, even if the image is old.
php /usr/local/bin/php-security-check

[ -d "$APP_ROOT" ] || { echo "FATAL: APP_ROOT '$APP_ROOT' does not exist" >&2; exit 1; }
cd "$APP_ROOT"
[ -f artisan ] || { echo "FATAL: $APP_ROOT/artisan not found - is this a Laravel app?" >&2; exit 1; }

# --- derived values -----------------------------------------------------------
case "$PHP_MAX_EXECUTION_TIME" in ''|*[!0-9]*) PHP_MAX_EXECUTION_TIME=60 ;; esac
FASTCGI_READ_TIMEOUT="${FASTCGI_READ_TIMEOUT:-$((PHP_MAX_EXECUTION_TIME + 30))s}"
FPM_REQUEST_TERMINATE_TIMEOUT="${FPM_REQUEST_TERMINATE_TIMEOUT:-$((PHP_MAX_EXECUTION_TIME + 10))s}"

# Keep the pool coherent whatever FPM_MAX_CHILDREN says.
case "$FPM_MAX_CHILDREN" in ''|*[!0-9]*|0|1|2) FPM_MAX_CHILDREN=3 ;; esac
FPM_START_SERVERS=$((FPM_MAX_CHILDREN / 2))
[ "$FPM_START_SERVERS" -ge 1 ] || FPM_START_SERVERS=1
FPM_MAX_SPARE_SERVERS="$FPM_MAX_CHILDREN"

export PORT CLIENT_MAX_BODY_SIZE FASTCGI_READ_TIMEOUT \
       PHP_MEMORY_LIMIT PHP_MAX_EXECUTION_TIME UPLOAD_MAX_FILESIZE POST_MAX_SIZE \
       FPM_MAX_CHILDREN FPM_MAX_REQUESTS FPM_REQUEST_TERMINATE_TIMEOUT \
       FPM_START_SERVERS FPM_MAX_SPARE_SERVERS

# --- render config ------------------------------------------------------------
envsubst '${PORT} ${CLIENT_MAX_BODY_SIZE} ${FASTCGI_READ_TIMEOUT}' \
    < /etc/nginx/app.conf.template > /etc/nginx/conf.d/app.conf
if ! nginx -t >/tmp/nginx-t.log 2>&1; then
    echo "FATAL: generated nginx configuration is invalid:" >&2
    cat /tmp/nginx-t.log >&2
    exit 1
fi
rm -f /tmp/nginx-t.log

envsubst '${PHP_MEMORY_LIMIT} ${PHP_MAX_EXECUTION_TIME} ${UPLOAD_MAX_FILESIZE} ${POST_MAX_SIZE}' \
    < /usr/local/etc/php/zz-app.ini.template > /usr/local/etc/php/conf.d/zz-app.ini

envsubst '${FPM_MAX_CHILDREN} ${FPM_MAX_REQUESTS} ${FPM_REQUEST_TERMINATE_TIMEOUT} ${FPM_START_SERVERS} ${FPM_MAX_SPARE_SERVERS}' \
    < /usr/local/etc/php-fpm.d/www.conf.template > /usr/local/etc/php-fpm.d/www.conf

log "php $(php -r 'echo PHP_VERSION;') | nginx on :${PORT} | fpm children=${FPM_MAX_CHILDREN}"
log "migrate=${RUN_MIGRATIONS} optimize=${RUN_OPTIMIZE} config_cache=${RUN_CONFIG_CACHE} queue=${QUEUE_WORKER} scheduler=${SCHEDULER}"

# --- writable paths (volumes and bind mounts can reset ownership) -------------
install -d -o www-data -g www-data -m 0775 \
    storage/app/public \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/logs \
    bootstrap/cache

php artisan storage:link --force >/dev/null 2>&1 || true

# Caches baked into the image or left by a previous boot would otherwise
# contradict the flags below (e.g. a stale config.php after changing env).
rm -f bootstrap/cache/*.php

# --- boot the application -----------------------------------------------------
if [ "$RUN_MIGRATIONS" = "true" ]; then
    attempt=0
    until php artisan migrate --force --no-interaction; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$MIGRATE_RETRIES" ]; then
            echo "FATAL: database migrations failed after ${attempt} attempts" >&2
            exit 1
        fi
        log "database not ready (attempt ${attempt}/${MIGRATE_RETRIES}), retrying in 3s"
        sleep 3
    done
fi

if [ "$RUN_CONFIG_CACHE" = "true" ]; then
    if php artisan config:cache --no-interaction; then
        log "config cached"
    else
        log "WARN: config:cache failed - env() outside config/? Continuing without it"
        php artisan config:clear --no-interaction || true
    fi
fi

if [ "$RUN_OPTIMIZE" = "true" ]; then
    if php artisan route:cache --no-interaction; then
        log "routes cached"
    else
        log "WARN: route:cache failed (closure routes?) - continuing without route cache"
        php artisan route:clear --no-interaction || true
    fi
    php artisan view:cache --no-interaction || log "WARN: view:cache failed - continuing"
fi

if [ "$CHOWN_STORAGE" = "true" ]; then
    chown -R www-data:www-data storage bootstrap/cache
else
    log "WARN: CHOWN_STORAGE=false - storage must already be writable by UID 33"
fi

# --- optional workers ---------------------------------------------------------
QUEUE_PID=""
SCHEDULER_PID=""

if [ "$QUEUE_WORKER" = "true" ]; then
    (
        worker=""
        trap 'kill -TERM "$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true; exit 0' TERM INT
        while true; do
            php artisan queue:work \
                --queue="$QUEUE_NAME" \
                --tries="$QUEUE_TRIES" \
                --timeout="$QUEUE_TIMEOUT" \
                --sleep=1 \
                --max-time=3600 \
                --no-interaction &
            worker=$!
            wait "$worker" || true
            log "queue worker exited, restarting in 5s"
            sleep 5
        done
    ) &
    QUEUE_PID=$!
    log "queue worker started (queue=${QUEUE_NAME})"
fi

if [ "$SCHEDULER" = "true" ]; then
    (
        worker=""
        trap 'kill -TERM "$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true; exit 0' TERM INT
        while true; do
            php artisan schedule:work --no-interaction &
            worker=$!
            wait "$worker" || true
            log "scheduler exited, restarting in 5s"
            sleep 5
        done
    ) &
    SCHEDULER_PID=$!
    log "scheduler started (schedule:work)"
fi

# --- web processes ------------------------------------------------------------
log "starting php-fpm and nginx"
php-fpm -F &
FPM_PID=$!
nginx -g 'daemon off;' &
NGINX_PID=$!

stop_all() {
    trap - TERM INT QUIT
    if [ -n "$QUEUE_PID" ]; then kill -TERM "$QUEUE_PID" 2>/dev/null || true; fi
    if [ -n "$SCHEDULER_PID" ]; then kill -TERM "$SCHEDULER_PID" 2>/dev/null || true; fi
    kill -QUIT "$NGINX_PID" 2>/dev/null || true
    kill -QUIT "$FPM_PID" 2>/dev/null || true
    # Workers drain their current job before exiting.
    if [ -n "$QUEUE_PID" ]; then wait "$QUEUE_PID" 2>/dev/null || true; fi
    if [ -n "$SCHEDULER_PID" ]; then wait "$SCHEDULER_PID" 2>/dev/null || true; fi
    wait "$NGINX_PID" 2>/dev/null || true
    wait "$FPM_PID" 2>/dev/null || true
}

trap 'log "signal received, shutting down"; stop_all; exit 0' TERM INT QUIT

# A dead php-fpm behind a live nginx would serve 502 forever, so treat either
# process exiting as fatal and let the platform restart the container.
while kill -0 "$FPM_PID" 2>/dev/null && kill -0 "$NGINX_PID" 2>/dev/null; do
    sleep 2
done

log "FATAL: php-fpm or nginx exited unexpectedly - stopping container"
stop_all
exit 1
ENTRYPOINT

# -----------------------------------------------------------------------------
# Image metadata
# -----------------------------------------------------------------------------
RUN rm -f /etc/nginx/sites-enabled/default \
    && mkdir -p /var/log/nginx \
    && chmod +x /usr/local/bin/app-entrypoint /usr/local/bin/php-security-check \
    && chown -R www-data:www-data storage bootstrap/cache

ENV PORT=80 \
    PHP_MEMORY_LIMIT=256M \
    PHP_MAX_EXECUTION_TIME=60 \
    UPLOAD_MAX_FILESIZE=16M \
    POST_MAX_SIZE=20M \
    CLIENT_MAX_BODY_SIZE=25m \
    FPM_MAX_CHILDREN=10 \
    FPM_MAX_REQUESTS=500 \
    RUN_MIGRATIONS=true \
    RUN_OPTIMIZE=true \
    RUN_CONFIG_CACHE=false \
    QUEUE_WORKER=false \
    SCHEDULER=false \
    QUEUE_NAME=default \
    QUEUE_TRIES=3 \
    QUEUE_TIMEOUT=60 \
    MIGRATE_RETRIES=10 \
    CHOWN_STORAGE=true

EXPOSE 80

# The base image inherits STOPSIGNAL=SIGQUIT, which would bypass the trap in
# the entrypoint and force a SIGKILL after the full stop timeout.
STOPSIGNAL SIGTERM

# TCP check so it stays honest even if the app has no /up route.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
    CMD php -r 'exit(@fsockopen("127.0.0.1", (int) (getenv("PORT") ?: 80)) ? 0 : 1);'

# tini as PID 1 reaps zombies and forwards signals to the entrypoint.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/app-entrypoint"]
