server {
    listen 80;
    server_name ${DOMAIN};
    root /var/www/html;
    location /.well-known/acme-challenge/ { allow all; }
}
