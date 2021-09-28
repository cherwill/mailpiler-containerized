# This dockerfile was created using the instructions from the guide in the link below
# https://patrik.kernstock.net/2020/08/mailpiler-installation-guide/

FROM Ubuntu:plplot/ubuntu-latest

# Specify Working Directory
WORKDIR '/piler_contents'

# Specify Environment Variables
ENV PILER_DOMAIN=hostname
ENV MAILSERVER_DOMAIN="mail.domain.tld" 

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
&& ldconfig

# MP Post Install

# Generate password and prepare DB
# TODO - Set ENV VAR for pw here
RUN PILER_MYSQL_USER_PW="$(pwgen -cnsB 32 1)" \ 
&& echo; echo "---"; echo "MYSQL PILER PASSWORD: $PILER_MYSQL_USER_PW"; echo "---"; echo \
&& cp util/postinstall.sh util/postinstall.sh.bak \
&& sed -i "s/   SMARTHOST=.*/   SMARTHOST="\"$MAILSERVER_DOMAIN\""/" util/postinstall.sh \
&& sed -i 's/   WWWGROUP=.*/   WWWGROUP="www-data"/' util/postinstall.sh

# Run post install script of mailpiler & automatically input required data
# TODO - setup usage of password ENV VAR and add additional password
RUN printf 'y\www-data\localhost\/var/run/mysqld/mysqld.sock\piler\piler\$PILER_MYSQL_USER_PW\password\$MAILSERVER_DOMAIN\25\Y\Y\' | make postinstall

# Adjust Piler and Sphinx Config
RUN cp /usr/local/etc/piler/piler.conf /usr/local/etc/piler/piler.conf.bak
RUN cp /usr/local/etc/piler/sphinx.conf /usr/local/etc/piler/sphinx.conf.bak

RUN sed -i "s/hostid=.*/hostid=$PILER_DOMAIN/" /usr/local/etc/piler/piler.conf
RUN sed -i "s/update_counters_to_memcached=.*/update_counters_to_memcached=1/" /usr/local/etc/piler/piler.conf
RUN sed -i "s/spam_header_line=.*/spam_header_line=X-Spam-Flag: YES/" /usr/local/etc/piler/piler.conf # rspamd in mailcow setup.

RUN sed -i "s/define('SPHINX_VERSION', .*/define('SPHINX_VERSION', 331);/" /usr/local/etc/piler/sphinx.conf
RUN sed -i "s/define('SPHINX_STRICT_SCHEMA', 0);/define('SPHINX_STRICT_SCHEMA', 1);/" /usr/local/etc/piler/sphinx.conf # required for Sphinx 3.3.1

# Start Mailpiler and searchd and enable autostart
RUN /etc/init.d/rc.piler start
RUN /etc/init.d/rc.searchd start

RUN update-rc.d rc.piler defaults
RUN update-rc.d rc.searchd defaults

# Setup mailpiler webUI
RUN mkdir -p /etc/nginx/ssl
RUN openssl req -x509 -nodes -days 3650 -newkey rsa:4096 -keyout /etc/nginx/ssl/piler.key -out /etc/nginx/ssl/piler.crt -subj "/CN=$PILER_DOMAIN" -addext "subjectAltName=DNS:$PILER_DOMAIN"

# Configure webserver and PHP
RUN cp contrib/webserver/piler-nginx.conf /etc/nginx/sites-enabled/piler
RUN sed -i "s|PILER_HOST|$PILER_DOMAIN|g" /etc/nginx/sites-enabled/piler
RUN sed -i "s|/var/run/php/php7.2-fpm.sock|/var/run/php/php7.4-fpm.sock|g" /etc/nginx/sites-enabled/piler

RUN sed -i "/server_name.*/a \\
        listen 443 ssl http2;\n\n\
        ssl_certificate /etc/nginx/ssl/piler.crt;\n\
        ssl_certificate_key /etc/nginx/ssl/piler.key;\n\n\
        ssl_session_timeout 1d;\n\
        ssl_session_cache shared:SSL:15m;\n\
        ssl_session_tickets off;\n\n\
        # modern configuration of Mozilla SSL configurator. Tweak to your needs.\n\
        ssl_protocols TLSv1.2 TLSv1.3;\n\
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;\n\
        ssl_prefer_server_ciphers off;\n\n\
        add_header X-Frame-Options SAMEORIGIN;\n\
        add_header X-Content-Type-Options nosniff;" /etc/nginx/sites-enabled/piler

RUN sed -i "/^server {.*/i\
\# HTTP to HTTPS redirect.\n\
server {\n\
        listen 80;\n\
        server_name $PILER_DOMAIN;\n\
        return 301 https://\$host\$request_uri;\n\
}" /etc/nginx/sites-enabled/piler

# Test and reload nginx config
RUN nginx -t && systemctl reload nginx

# Configure mailpiler webui
RUN cp /usr/local/etc/piler/config-site.php /usr/local/etc/piler/config-site.bak.php

RUN sed -i "s|\$config\['SITE_URL'\] = .*|\$config\['SITE_URL'\] = 'https://$PILER_DOMAIN/';|" /usr/local/etc/piler/config-site.php

RUN cat >> /usr/local/etc/piler/config-site.php <<EOF
// CUSTOM
\$config['PROVIDED_BY'] = '$MAILSERVER_DOMAIN';
\$config['SUPPORT_LINK'] = 'https://$MAILSERVER_DOMAIN';
\$config['COMPATIBILITY'] = '';
// fancy features.
\$config['ENABLE_INSTANT_SEARCH'] = 1;
\$config['ENABLE_TABLE_RESIZE'] = 1;
\$config['ENABLE_DELETE'] = 1;
\$config['ENABLE_ON_THE_FLY_VERIFICATION'] = 1;
// general settings.
\$config['TIMEZONE'] = 'UTC';
// authentication
// Enable authentication against an imap server
\$config['ENABLE_IMAP_AUTH'] = 1;
\$config['RESTORE_OVER_IMAP'] = 1;
\$config['IMAP_RESTORE_FOLDER_INBOX'] = 'INBOX';
\$config['IMAP_RESTORE_FOLDER_SENT'] = 'Sent';
\$config['IMAP_HOST'] = '$MAILSERVER_DOMAIN';
\$config['IMAP_PORT'] =  993;
\$config['IMAP_SSL'] = true;
// special settings.
\$config['MEMCACHED_ENABLED'] = 1;
\$config['SPHINX_STRICT_SCHEMA'] = 1; // required for Sphinx 3.3.1, see https://bitbucket.org/jsuto/piler/issues/1085/sphinx-331.
EOF

# Cleanup
RUN apt autoremove --yes
RUN apt clean

# Login to the webui at https://$PILER_DOMAIN
# Username: admin@local
# Password: pilerrocks