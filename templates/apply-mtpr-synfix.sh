#!/bin/bash
# MEKO SYN FIX inline rules — telemt-deploy bundle v3.0.1
set -e

if [ -f /opt/mtpr-simple/port ]; then
    PORTS=$(cat /opt/mtpr-simple/port)
else
    echo "SYN FIX: port file not found" >&2
    exit 1
fi

CHAIN="MTPR_SYNFIX"
SSH_PORT=$(sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}' || echo 22)

if ! iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -p tcp --dport "$SSH_PORT" -j ACCEPT
fi

iptables -t filter -N "$CHAIN" 2>/dev/null || true
iptables -t filter -F "$CHAIN"

if ! iptables -t filter -C INPUT -j "$CHAIN" 2>/dev/null; then
    iptables -t filter -I INPUT 2 -j "$CHAIN"
fi

iptables -t mangle -D PREROUTING -m u32 --u32 "32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000" -j MARK --set-mark 0x400 2>/dev/null || true
iptables -t mangle -A PREROUTING -m u32 --u32 "32 & 0x000FFFFF = 0x0002FFFF && 40 & 0xFF000000 = 0x02000000 && 44 & 0xFFFF0000 = 0x01030000 && 48 & 0xFFFFFF00 = 0x01010800 && 60 & 0xFFFFFFFF = 0x04020000" -j MARK --set-mark 0x400

IFS=',' read -ra PORT_ARRAY <<< "$PORTS"
for PORT in "${PORT_ARRAY[@]}"; do
    PORT=$(echo "$PORT" | xargs)
    [ -z "$PORT" ] && continue

    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn -m mark --mark 0x400 -j ACCEPT

    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -m hashlimit \
        --hashlimit-name "mtproto_${PORT}" \
        --hashlimit-mode srcip \
        --hashlimit-upto 54/minute \
        --hashlimit-burst 1 \
        --hashlimit-htable-expire 60000 \
        --hashlimit-htable-size 32768 \
        -j ACCEPT

    iptables -t filter -A "$CHAIN" -p tcp --dport "$PORT" --syn \
        -j REJECT --reject-with tcp-reset
done

iptables -t filter -A "$CHAIN" -j RETURN
