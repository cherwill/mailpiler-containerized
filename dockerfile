# This dockerfile was created using the instructions from the guide in the link below
# https://patrik.kernstock.net/2020/08/mailpiler-installation-guide/

FROM Ubuntu:plplot/ubuntu-latest

# Specify Working Directory
WORKDIR '/piler_contents'

# Specify Environment Variables
ENV PILER_DOMAIN=hostname
# ENV MAILSERVER_DOMAIN="mail.domain.tld" #requires setup

# Install Dependencies
RUN apt install sysstat build-essential libwrap0-dev libpst-dev tnef libytnef0-dev unrtf catdoc libtre-dev tre-agrep \
 poppler-utils libzip-dev unixodbc libpq5 software-properties-common libpoppler-dev openssl libssl-dev python3-mysqldb \
 memcached pwgen telnet

# Prepare & Install MariaDB
# TODO - MOVE TO ANOTHER CONTAINER
RUN apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc' \
&& add-apt-repository 'deb [arch=amd64] https://mirror.netcologne.de/mariadb/repo/10.4/ubuntu focal main' \
&& apt install mariadb-{server,client} libmariadb-client-lgpl-dev-compat

# Optimize DB

RUN cat > /etc/mysql/conf.d/mailpiler.conf <<EOF 
innodb_buffer_pool_size=256M
innodb_flush_log_at_trx_commit=1
innodb_log_buffer_size=64M
innodb_log_file_size=16M
query_cache_size=0
query_cache_type=0
query_cache_limit=2M
EOF

RUN systemctl restart mariadb

# Install PHP
RUN add-apt-repository --yes ppa:ondrej/php \
&& apt install php7.4-{fpm,common,ldap,mysql,cli,opcache,phpdbg,gd,memcache,json,readline,zip}

# Install Webserver
RUN add-apt-repository --yes ppa:ondrej/nginx-mainline \
&& apt install nginx \
&& systemctl enable nginx

# Install SphinxSearch
RUN mkdir -p /root/mailpiler/sphinxsearch/ \
&& cd /root/mailpiler/sphinxsearch/ \
&& wget http://sphinxsearch.com/files/sphinx-3.3.1-b72d67b-linux-amd64.tar.gz \
&& tar xfz sphinx-*-linux-amd64.tar.gz \
&& cp -v sphinx-*/bin/* /usr/local/bin/ \
&& rm /etc/cron.d/sphinxsearch

# Install xlhtml
RUN mkdir -p /root/mailpiler/xlhtml/ \
&& cd /root/mailpiler/xlhtml/ \
&& wget https://bitbucket.org/jsuto/piler/downloads/xlhtml-0.5.1-sj-mod.tar.gz \
&& tar xzf xlhtml-*-sj-mod.tar.gz \
&& cd xlhtml-*-sj-mod/ \
&& ./configure \
&& make \
&& make install \
&& ldconfig

# Install MailPiler
# Create dedicated user and set permissions
RUN groupadd piler \
&& useradd -g piler -m -s /bin/bash -d /var/piler piler \
&& usermod -L piler \
&& chmod 755 /var/piler

# Download, Configure & Install
RUN mkdir -p /root/mailpiler/piler/ \
&& cd /root/mailpiler/piler/ \
&& wget https://bitbucket.org/jsuto/piler/downloads/piler-1.3.9.tar.gz \
&& tar xzf piler-*.tar.gz \
&& cd piler-*/ \
&& ./configure --localstatedir=/var --with-database=mysql --enable-memcached \
&& make \
&& make install \
&& ldconfig \