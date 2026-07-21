server {
    listen 8443 ssl;
    server_name _;

    ssl_certificate ${PANEL_SSL_CERT};
    ssl_certificate_key ${PANEL_SSL_KEY};

    root ${PANEL_STATIC_DIR};
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:${PANEL_API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
