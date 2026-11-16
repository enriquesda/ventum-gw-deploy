#!/usr/bin/env bash
set -euo pipefail

mkdir -p /var/www/backend /tmp/run/nginx_body /tmp/run/nginx_proxy /tmp/run/nginx_fastcgi /tmp/run/nginx_uwsgi /tmp/run/nginx_scgi

if [[ ! -f /var/www/backend/artisan ]]; then
    echo "[gw-start] Descifrando bundle de aplicacion en memoria..."
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in /opt/bundle.enc -pass env:BUNDLE_KEY | tar -xz -C /var/www/backend
    ln -sfn /opt/vendor /var/www/backend/vendor
    cd /var/www/backend
    rm -f bootstrap/cache/*.php
    composer dump-autoload --no-dev --optimize --no-interaction --no-scripts
fi

cd /var/www/backend
rm -f bootstrap/cache/*.php
mkdir -p storage/app/private storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache public_spa
chmod -R 0777 storage bootstrap/cache

LISTEN_PORT="${PORT:-7860}"
GW_PREFIX="${GW_SECRET:-_gw_local}"

cat > /tmp/run/php-fpm.conf <<'FPM_EOF'
[global]
pid = /tmp/run/php-fpm.pid
error_log = /dev/stderr
daemonize = no

[www]
user = www-data
group = www-data
listen = 127.0.0.1:9000
pm = dynamic
pm.max_children = 6
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
request_terminate_timeout = 180s
clear_env = no
catch_workers_output = yes
decorate_workers_output = no
php_admin_value[disable_functions] = exec,shell_exec,system,passthru,popen
FPM_EOF

cat > /tmp/run/nginx.conf <<NGX_EOF
worker_processes auto;
pid /tmp/run/nginx.pid;
error_log /dev/stderr warn;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;

    client_body_temp_path /tmp/run/nginx_body;
    proxy_temp_path       /tmp/run/nginx_proxy;
    fastcgi_temp_path     /tmp/run/nginx_fastcgi;
    uwsgi_temp_path       /tmp/run/nginx_uwsgi;
    scgi_temp_path        /tmp/run/nginx_scgi;

    sendfile on;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml text/javascript;
    keepalive_timeout 65;
    client_max_body_size 55m;
    server_tokens off;

    server {
        listen ${LISTEN_PORT};
        server_name _;
        root /var/www/backend/public_spa;
        index index.html;

        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "DENY" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        location = /up {
            default_type application/json;
            return 200 '{"status":"up"}';
        }

        location ^~ /${GW_PREFIX}/ {
            set \$clean_request_uri \$request_uri;
            if (\$request_uri ~ "^/${GW_PREFIX}(/.*)\$") {
                set \$clean_request_uri \$1;
            }
            set \$eff_referer \$http_referer;
            if (\$eff_referer = "") {
                set \$eff_referer "https://licitaciones-beta.vercel.app/";
            }
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_index index.php;
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME /var/www/backend/public/index.php;
            fastcgi_param SCRIPT_NAME /index.php;
            fastcgi_param DOCUMENT_ROOT /var/www/backend/public;
            fastcgi_param REQUEST_URI \$clean_request_uri;
            fastcgi_param HTTP_REFERER \$eff_referer;
            fastcgi_param HTTPS on;
            fastcgi_read_timeout 180s;
        }

        location ^~ /api/ {
            set \$eff_referer \$http_referer;
            if (\$eff_referer = "") {
                set \$eff_referer "https://licitaciones-api-wpyo.onrender.com/";
            }
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_index index.php;
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME /var/www/backend/public/index.php;
            fastcgi_param SCRIPT_NAME /index.php;
            fastcgi_param DOCUMENT_ROOT /var/www/backend/public;
            fastcgi_param HTTP_REFERER \$eff_referer;
            fastcgi_param HTTPS on;
            fastcgi_read_timeout 180s;
        }

        location ^~ /sanctum/ {
            set \$eff_referer \$http_referer;
            if (\$eff_referer = "") {
                set \$eff_referer "https://licitaciones-api-wpyo.onrender.com/";
            }
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_index index.php;
            include /etc/nginx/fastcgi_params;
            fastcgi_param SCRIPT_FILENAME /var/www/backend/public/index.php;
            fastcgi_param SCRIPT_NAME /index.php;
            fastcgi_param DOCUMENT_ROOT /var/www/backend/public;
            fastcgi_param HTTP_REFERER \$eff_referer;
            fastcgi_param HTTPS on;
            fastcgi_read_timeout 180s;
        }

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
NGX_EOF

echo "[gw-start] Iniciando Redis local..."
redis-server --daemonize yes --bind 127.0.0.1 --port 6379 --dir /tmp/run --pidfile /tmp/run/redis.pid --maxmemory 64mb --maxmemory-policy allkeys-lru --save "" --appendonly no

for _ in $(seq 1 30); do
    if redis-cli -h 127.0.0.1 -p 6379 ping >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if [[ ! -f .env ]]; then
    cp .env.example .env
fi

php artisan package:discover --ansi || true
php artisan config:clear || true
php artisan migrate --force || echo "[gw-start] WARN: migrate devolvio codigo no cero, continuando..."

(
    while true; do
        php-fpm -F -y /tmp/run/php-fpm.conf || true
        sleep 2
    done
) &

(
    while true; do
        php artisan queue:work redis --queue=default,ai,documents,ingest --timeout=1800 --tries=3 --backoff=30 --memory=192 --max-time=3600 || true
        sleep 3
    done
) &

if [[ "${ENABLE_INTERNAL_SCHEDULER:-true}" == "true" ]]; then
    (
        while true; do
            php artisan schedule:work || true
            sleep 5
        done
    ) &
fi

echo "[gw-start] Iniciando Nginx en el puerto ${LISTEN_PORT}..."
exec nginx -c /tmp/run/nginx.conf -g "daemon off;"
