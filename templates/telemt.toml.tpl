[general]
prefer_ipv6 = false
fast_mode = true
use_middle_proxy = true
${AD_TAG_LINE}

[general.modes]
classic = false
secure = false
tls = true

[general.links]
public_host = "${DOMAIN}"
public_port = 443

[server]
port = 443
listen_addr_ipv4 = "0.0.0.0"

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true
mask_host = "127.0.0.1"
mask_port = 8444
tls_emulation = ${TLS_EMULATION}
unknown_sni_action = "mask"
fake_cert_len = 2048
tls_front_dir = "/opt/telemt/tlsfront"

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
default = "${SECRET}"
