server {
    listen 80 default_server;
    listen 127.0.0.1:8444 ssl default_server;
    server_name _;
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    return 444;
}

server {
    listen 80;
    server_name ${DOMAIN};
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }
    location / {
        return 301 https://${DOMAIN}$request_uri;
    }
}

server {
    listen 127.0.0.1:8444 ssl;
    server_name ${DOMAIN};
    server_tokens off;
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    root /var/www/html;
    index index.html;
    location ~* "(wget|curl|chmod|/tmp/|eval\\(|base64)" {
        return 403;
    }
    location / {
        try_files $uri $uri/ =404;
    }
}
