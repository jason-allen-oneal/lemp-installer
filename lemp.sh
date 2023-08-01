#!/bin/bash

# Detect package manager and set variables accordingly
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt-get"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
else
    echo "Unsupported package manager. Please install Nginx, MySQL, PHP, and phpMyAdmin manually."
    exit 1
fi

# Update package list and upgrade system
if [ "$PKG_MANAGER" = "apt-get" ]; then
    apt update
    apt upgrade -y
elif [ "$PKG_MANAGER" = "yum" ]; then
    yum update -y
fi

# Install Nginx
if [ "$PKG_MANAGER" = "apt-get" ]; then
    apt install nginx -y
elif [ "$PKG_MANAGER" = "yum" ]; then
    yum install nginx -y
fi

# Install MySQL
if [ "$PKG_MANAGER" = "apt-get" ]; then
    apt install mariadb-server -y
elif [ "$PKG_MANAGER" = "yum" ]; then
    yum install mariadb-server -y
fi

# Secure MySQL installation
if [ "$PKG_MANAGER" = "apt-get" ]; then
    apt install expect -y
elif [ "$PKG_MANAGER" = "yum" ]; then
    yum install expect -y
fi

read -sp "Enter a password for the MySQL root user: " MYSQL_ROOT_PASSWORD
echo -e "\n"

SECURE_MYSQL=$(expect -c "
set timeout 10
spawn mysql_secure_installation

expect \"Enter current password for root (enter for none):\"
send \"$MYSQL_ROOT_PASSWORD\n\"

expect \"Change the root password?\"
send \"n\n\"

expect \"Remove anonymous users?\"
send \"y\r\"

expect \"Disallow root login remotely?\"
send \"y\r\"

expect \"Remove test database and access to it?\"
send \"y\r\"

expect \"Reload privilege tables now?\"
send \"y\r\"

expect eof
")
echo "$SECURE_MYSQL"

if [ "$PKG_MANAGER" = "apt-get" ]; then
    apt-get -qq purge expect
elif [ "$PKG_MANAGER" = "yum" ]; then
    yum remove expect -y
fi

# Install PHP and required extensions
if [ "$PKG_MANAGER" = "apt-get" ]; then
    apt install php-fpm php-mysql -y
elif [ "$PKG_MANAGER" = "yum" ]; then
    yum install php-fpm php-mysql -y
fi

# Configure PHP-FPM
sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php/7.4/fpm/php.ini

# Start and enable Nginx and PHP-FPM
if [ "$PKG_MANAGER" = "apt-get" ]; then
    systemctl start nginx
    systemctl enable nginx
    systemctl start php7.4-fpm
    systemctl enable php7.4-fpm
elif [ "$PKG_MANAGER" = "yum" ]; then
    systemctl start nginx
    systemctl enable nginx
    systemctl start php-fpm
    systemctl enable php-fpm
fi

# Install phpMyAdmin (Optional)
read -p "Do you want to install phpMyAdmin? (y/n): " INSTALL_PHPMYADMIN
if [[ "$INSTALL_PHPMYADMIN" =~ ^[Yy]$ ]]; then
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        apt install phpmyadmin -y
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install epel-release -y
        yum install phpmyadmin -y
    fi

    # Prompt for MySQL credentials
    read -p "Enter a new MySQL username for phpMyAdmin: " mysql_user
    read -sp "Enter the password for the new MySQL user: " mysql_password
    echo -e "\n"
    read -p "Enter a name for the new MySQL database: " database_name

    # Create a new MySQL user and grant privileges for phpMyAdmin
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE USER '$mysql_user'@'localhost' IDENTIFIED BY '$mysql_password';"
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "CREATE DATABASE $database_name;"
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "GRANT ALL PRIVILEGES ON $database_name.* TO '$mysql_user'@'localhost';"
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "FLUSH PRIVILEGES;"

    # Configure phpMyAdmin to use the new MySQL user
    echo "\$cfg['Servers'][\$i]['user'] = '$mysql_user';" >> /etc/phpmyadmin/config.inc.php
    echo "\$cfg['Servers'][\$i]['password'] = '$mysql_password';" >> /etc/phpmyadmin/config.inc.php

    # Change ownership of phpMyAdmin directory
    chown -R www-data:www-data /usr/share/phpmyadmin

    # Prompt for Nginx server name
    read -p "Enter the server name or IP to deploy phpMyAdmin: " server_name

    # Configure Nginx for phpMyAdmin if installed
    echo "
    server {
        listen 80;
        server_name $server_name;

        root /usr/share/phpmyadmin;
        index index.php;

        location / {
            try_files \$uri \$uri/ =404;
        }

        location ~ ^/phpmyadmin/(.+\.php)$ {
            alias /usr/share/phpmyadmin/\$1;
            fastcgi_pass unix:/var/run/php/php7.4-fpm.sock;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
            include fastcgi_params;
        }

        location ~ /\.ht {
            deny all;
        }
    }
    " > /etc/nginx/sites-available/phpmyadmin

    ln -s /etc/nginx/sites-available/phpmyadmin /etc/nginx/sites-enabled/
    rm /etc/nginx/sites-enabled/default

    # Restart Nginx and PHP-FPM
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        systemctl restart nginx
        systemctl restart php7.4-fpm
    elif [ "$PKG_MANAGER" = "yum" ]; then
        systemctl restart nginx
        systemctl restart php-fpm
    fi
fi

# Install Mail Server (Optional)
read -p "Do you want to install a Mail Server? (y/n): " INSTALL_MAIL_SERVER
if [[ "$INSTALL_MAIL_SERVER" =~ ^[Yy]$ ]]; then
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        apt install postfix dovecot-core dovecot-imapd dovecot-lmtpd -y
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install postfix dovecot -y
    fi
    
    # Ask if the user wants to generate a self-signed SSL certificate
    read -p "Do you want to generate a self-signed SSL certificate for Dovecot? (y/n): " GENERATE_SSL_CERT
    if [[ "$GENERATE_SSL_CERT" =~ ^[Yy]$ ]];
    then
      # Generate Self-Signed SSL Certificate for Dovecot
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/dovecot.pem -out /etc/ssl/certs/dovecot.pem
      chmod 600 /etc/ssl/private/dovecot.pem
      chmod 644 /etc/ssl/certs/dovecot.pem
    else
      # Ask for the paths to the user-provided SSL certificate and key
      read -p "Enter the path to the SSL certificate file: " SSL_CERT_FILE
      read -p "Enter the path to the SSL certificate key file: " SSL_KEY_FILE
      
      # Copy the user-provided SSL certificate and key to the Dovecot configuration directory
      cp "$SSL_CERT_FILE" /etc/ssl/certs/dovecot.pem
      cp "$SSL_KEY_FILE" /etc/ssl/private/dovecot.pem
      chmod 600 /etc/ssl/private/dovecot.pem
      chmod 644 /etc/ssl/certs/dovecot.pem
    fi


    # Postfix Configuration
    echo "myhostname = $(hostname -I | cut -d' ' -f1)" >> /etc/postfix/main.cf
    echo "mydomain = example.com" >> /etc/postfix/main.cf
    echo "relayhost =" >> /etc/postfix/main.cf
    echo "mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128" >> /etc/postfix/main.cf
    echo "smtpd_tls_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem" >> /etc/postfix/main.cf
    echo "smtpd_tls_key_file=/etc/ssl/private/ssl-cert-snakeoil.key" >> /etc/postfix/main.cf
    echo "smtpd_use_tls=yes" >> /etc/postfix/main.cf
    echo "smtpd_tls_auth_only = yes" >> /etc/postfix/main.cf
    echo "smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache" >> /etc/postfix/main.cf

    # Dovecot Configuration
    echo "protocols = imap lmtp" >> /etc/dovecot/dovecot.conf
    echo "ssl = required" >> /etc/dovecot/dovecot.conf
    echo "ssl_cert = </etc/ssl/certs/dovecot.pem" >> /etc/dovecot/dovecot.conf
    echo "ssl_key = </etc/ssl/private/dovecot.pem" >> /etc/dovecot/dovecot.conf

    # Restart Postfix and Dovecot
    if [ "$PKG_MANAGER" = "apt-get" ]; then
        systemctl restart postfix
        systemctl restart dovecot
    elif [ "$PKG_MANAGER" = "yum" ]; then
        systemctl restart postfix
        systemctl restart dovecot
    fi
fi


echo "LEMP stack and phpMyAdmin have been installed successfully."
