# Use official PHP FPM Alpine image (super lightweight)
FROM php:8.3-fpm-alpine

# Install system dependencies
RUN apk add --no-cache \
    freetype-dev \
    jpeg-dev \
    libpng-dev \
    libzip-dev \
    zip \
    unzip \
    git \
    curl \
    oniguruma-dev \
    nginx

# Install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install pdo_mysql mbstring exif pcntl bcmath gd zip opcache

# Install Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Set working directory
WORKDIR /var/www

# Copy existing application directory contents
COPY . .

# Install Laravel dependencies
RUN composer install --optimize-autoloader --no-dev

# Setup Nginx
COPY ./docker/nginx.conf /etc/nginx/nginx.conf

# Setup permissions
RUN chown -R www-data:www-data /var/www \
    && chmod -R 775 /var/www/storage \
    && chmod -R 775 /var/www/bootstrap/cache

# Expose port 80
EXPOSE 80

# Start Nginx & PHP-FPM
CMD ["sh", "-c", "php-fpm -D && nginx -g 'daemon off;'"]
