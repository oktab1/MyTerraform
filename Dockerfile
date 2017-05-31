FROM ubuntu:16.04

# Update the APT repository information
RUN apt-get update -y

# Make sure locales are set up and the timezone is set to UTC
RUN apt-get install -y locales
ENV TZ=UTC
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
RUN echo "en_US UTF-8" >/etc/locale.gen
RUN echo "en_US.UTF-8 UTF-8" >>/etc/locale.gen
RUN locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

# Install and configure supervisord which will manage our processes
RUN apt-get -y install supervisor
RUN mkdir -p /etc/supervisor && mkdir -p /etc/supervisor/conf.d
COPY etc/supervisor /etc/supervisor
COPY bin/manage-supervisord /usr/local/bin/manage-supervisord
RUN chmod +x /usr/local/bin/manage-supervisord
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisor.conf"]

# Make sure the runtime directoryies for PHP exist
RUN mkdir /run/php && chown www-data:www-data /run/php
RUN mkdir /var/log/php && chown www-data:www-data /var/log/php

# Install PHP and some utilities
RUN apt-get update -y && apt-get install -y \
   php7.0-cli \
   php7.0-fpm \
   php7.0-mysql \
   php7.0-mcrypt \
   php7.0-imap \
   php7.0-gmp \
   php7.0-curl \
   php7.0-xmlrpc \
   php7.0-xsl \
   php7.0-mbstring \
   php7.0-zip \
   php7.0-bz2 \
   php7.0-intl \
   php7.0-imap \
   php7.0-soap \
   php7.0-gd \
   nginx-extras \
   curl \
   mysql-client

# Copy the PHP and nginx configuration
COPY etc/php/php.ini /etc/php/7.0/fpm/php.ini
COPY etc/php/www.conf /etc/php/7.0/fpm/pool.d/www.conf
COPY etc/php/php-fpm.conf /etc/php/7.0/fpm/php-fpm.conf
COPY etc/nginx /etc/nginx

# Expose port 80 as a service
EXPOSE 80

# Health check
HEALTHCHECK --interval=5s --timeout=3s --retries=2 CMD curl --fail http://localhost/

# Copy our application
COPY src /srv/app/htdocs

