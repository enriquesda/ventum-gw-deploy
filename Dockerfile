FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --prefer-dist --no-progress --no-scripts --no-autoloader

FROM php:8.3-fpm-alpine

RUN apk add --no-cache \
      icu-libs libzip libpq oniguruma poppler-utils util-linux fcgi bash nginx redis openssl \
 && apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS icu-dev libzip-dev postgresql-dev oniguruma-dev linux-headers \
 && docker-php-ext-install -j"$(nproc)" pdo_mysql pdo_pgsql intl zip pcntl bcmath opcache \
 && pecl install redis \
 && docker-php-ext-enable redis \
 && apk del .build-deps

COPY --from=composer /usr/bin/composer /usr/bin/composer
COPY php.ini /usr/local/etc/php/conf.d/zz-app.ini
COPY --from=vendor /app/vendor /opt/vendor
COPY bundle.enc /opt/bundle.enc
COPY start.sh /usr/local/bin/start-prod

RUN chmod +x /usr/local/bin/start-prod \
 && mkdir -p /var/www/backend /tmp/run \
 && chmod -R 0777 /var/www/backend /tmp/run /opt/vendor

WORKDIR /var/www/backend
EXPOSE 7860
CMD ["start-prod"]
