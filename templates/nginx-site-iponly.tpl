server {
    listen 127.0.0.1:8444 ssl default_server;
    server_name _;
    ssl_certificate ${SSL_CERT_PATH};
    ssl_certificate_key ${SSL_KEY_PATH};
    return 444;
}

server {
    listen 127.0.0.1:8444 ssl;
    server_name ${TLS_DOMAIN};
    server_tokens off;
    ssl_certificate ${SSL_CERT_PATH};
    ssl_certificate_key ${SSL_KEY_PATH};
    root /var/www/html;
    index index.html;
    location ~* "(wget|curl|chmod|/tmp/|eval\\(|base64)" {
        return 403;
    }
    location / {
        try_files $uri $uri/ =404;
    }
}
