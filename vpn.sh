#!/bin/bash
# =====================================================================
# vpn.sh - Развертывание VPN-сервера (3X-UI) с интеграцией на одном домене
# Версия: 3.8 (принудительная перезапись конфигурации Nginx)
# =====================================================================

set -euo pipefail

# Подключаем общую библиотеку
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    echo -e "\033[0;31mОшибка: файл lib.sh не найден в директории $SCRIPT_DIR.\033[0m"
    exit 1
fi
source "$SCRIPT_DIR/lib.sh"

init_force_mode "$@"

sqlite3_escape() {
    sed "s/'/''/g"
}

add_to_env() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" "$SCRIPT_DIR/.env"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$SCRIPT_DIR/.env"
    else
        echo "${key}=\"${value}\"" >> "$SCRIPT_DIR/.env"
    fi
}

if [[ $EUID -ne 0 ]]; then
    log "${RED}Ошибка: скрипт должен запускаться от root (или с sudo).${NC}"
    exit 1
fi

load_env "DOMAIN" "ADMIN_EMAIL"

SITE_DIR="${WEB_ROOT_BASE:-/var/www}/${DOMAIN}"
PHP_SOCKET="/run/php/php8.3-fpm.sock"

for pkg in sqlite3 jq curl; do
    if ! command -v $pkg &>/dev/null; then
        log "${YELLOW}Установка $pkg...${NC}"
        apt update && apt install -y $pkg >> "$LOG_FILE" 2>&1
    fi
done

SSL_DIR="/etc/letsencrypt/live/$DOMAIN"
if [[ ! -f "$SSL_DIR/fullchain.pem" || ! -f "$SSL_DIR/privkey.pem" ]]; then
    log "${YELLOW}SSL-сертификат для $DOMAIN не найден. Получаем через Let's Encrypt...${NC}"
    if ! command -v certbot &>/dev/null; then
        apt update && apt install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1
    fi
    if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL" >> "$LOG_FILE" 2>&1; then
        log "${GREEN}SSL-сертификат успешно получен.${NC}"
    else
        log "${RED}Не удалось получить SSL-сертификат.${NC}"
        exit 1
    fi
else
    log "${GREEN}SSL-сертификат уже существует.${NC}"
fi

NGINX_LOCAL_PORT="${NGINX_LOCAL_PORT:-}"
if [[ -z "$NGINX_LOCAL_PORT" ]]; then
    for port in {10443..10543}; do
        if ! ss -tlnp | grep -q ":$port "; then
            NGINX_LOCAL_PORT=$port
            break
        fi
    done
    if [[ -z "$NGINX_LOCAL_PORT" ]]; then
        log "${RED}Не найден свободный порт.${NC}"
        exit 1
    fi
    add_to_env "NGINX_LOCAL_PORT" "$NGINX_LOCAL_PORT"
fi

NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
if [[ ! -f "$NGINX_CONF" ]]; then
    log "${RED}Конфигурация Nginx для $DOMAIN не найдена. Сначала выполните cms.sh.${NC}"
    exit 1
fi

# Принудительно перезаписываем конфигурацию, предварительно создав бэкап
log "${YELLOW}Создаём резервную копию текущей конфигурации и генерируем новую...${NC}"
cp "$NGINX_CONF" "$NGINX_CONF.bak.$(date +%Y%m%d%H%M%S)"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 127.0.0.1:$NGINX_LOCAL_PORT ssl;
    listen [::1]:$NGINX_LOCAL_PORT ssl;
    server_name $DOMAIN;
    root $SITE_DIR;
    index index.php index.html;

    ssl_certificate $SSL_DIR/fullchain.pem;
    ssl_certificate_key $SSL_DIR/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
    }

    location ^~ /uploads {
        location ~ \.php\$ { deny all; }
    }

    server_tokens off;
}
EOF

if nginx -t >> "$LOG_FILE" 2>&1; then
    systemctl reload nginx
    log "${GREEN}Конфигурация Nginx успешно обновлена.${NC}"
else
    log "${RED}Ошибка: сгенерированная конфигурация невалидна. Выход.${NC}"
    nginx -t 2>&1 | tee -a "$LOG_FILE"
    exit 1
fi

XUI_SERVICE="x-ui"
if systemctl list-units --full --all | grep -q "$XUI_SERVICE.service"; then
    log "${GREEN}3X-UI уже установлен.${NC}"
else
    log "${YELLOW}Установка 3X-UI...${NC}"
    INSTALL_SCRIPT="/tmp/install_3xui.sh"
    if curl -fsSL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$INSTALL_SCRIPT"; then
        chmod +x "$INSTALL_SCRIPT"
        if timeout 300 bash "$INSTALL_SCRIPT" </dev/null >> "$LOG_FILE" 2>&1; then
            rm -f "$INSTALL_SCRIPT"
            systemctl stop $XUI_SERVICE
            log "${GREEN}3X-UI установлен.${NC}"
        else
            rm -f "$INSTALL_SCRIPT"
            log "${RED}Установка 3X-UI не удалась.${NC}"
            exit 1
        fi
    else
        log "${RED}Не удалось загрузить скрипт установки.${NC}"
        exit 1
    fi
fi

if [[ -z "${XUI_PORT:-}" ]]; then
    XUI_PORT=$(( RANDOM % 1000 + 52000 ))
    add_to_env "XUI_PORT" "$XUI_PORT"
fi
if [[ -z "${XUI_PATH:-}" ]]; then
    XUI_PATH="/$(openssl rand -hex 8)"
    add_to_env "XUI_PATH" "$XUI_PATH"
fi
if [[ -z "${XUI_USERNAME:-}" ]]; then
    XUI_USERNAME="admin_$(openssl rand -hex 4)"
    add_to_env "XUI_USERNAME" "$XUI_USERNAME"
fi
if [[ -z "${XUI_PASSWORD:-}" ]]; then
    XUI_PASSWORD=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9!?@#' | head -c20)
    add_to_env "XUI_PASSWORD" "$XUI_PASSWORD"
fi

log "Настройка панели 3X-UI..."
x-ui setting -port "$XUI_PORT" -username "$XUI_USERNAME" -password "$XUI_PASSWORD" >> "$LOG_FILE" 2>&1

DB_PATH="/etc/x-ui/x-ui.db"
if [[ ! -f "$DB_PATH" ]]; then
    log "${RED}База данных 3X-UI не найдена.${NC}"
    exit 1
fi
sqlite3 "$DB_PATH" "UPDATE settings SET value='$XUI_PATH' WHERE key='webBasePath';" >> "$LOG_FILE" 2>&1

log "Настройка UFW..."
if [[ -n "${ADMIN_IP:-}" ]]; then
    ufw allow from "$ADMIN_IP" to any port "$XUI_PORT" proto tcp >> "$LOG_FILE" 2>&1
    log "${GREEN}Доступ к панели ограничен IP $ADMIN_IP.${NC}"
else
    ufw allow "$XUI_PORT"/tcp >> "$LOG_FILE" 2>&1
    log "${YELLOW}Доступ к панели открыт для всех. Рекомендуется ограничить через ADMIN_IP.${NC}"
fi
ufw allow 443/tcp >> "$LOG_FILE" 2>&1
ufw allow 443/udp >> "$LOG_FILE" 2>&1

SUBSCRIPTION_PORT=$(sqlite3 "$DB_PATH" "SELECT value FROM settings WHERE key='subscriptionPort';" 2>/dev/null)
[[ -z "$SUBSCRIPTION_PORT" ]] && SUBSCRIPTION_PORT="2096"
ufw allow "$SUBSCRIPTION_PORT"/tcp >> "$LOG_FILE" 2>&1
ufw reload >> "$LOG_FILE" 2>&1

log "Генерация ключей Reality..."
if ! command -v xray &>/dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >> "$LOG_FILE" 2>&1
fi
XRAY_BIN=$(which xray 2>/dev/null || find /usr/local -name xray -type f 2>/dev/null | head -1)
if [[ -z "$XRAY_BIN" || ! -x "$XRAY_BIN" ]]; then
    log "${RED}Не найден xray.${NC}"
    exit 1
fi
KEY_PAIR=$("$XRAY_BIN" x25519)
PRIVATE_KEY=$(echo "$KEY_PAIR" | grep -E "(Private key:|PrivateKey:)" | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEY_PAIR" | grep -E "(Public key:|Password \(PublicKey\):|PublicKey:)" | awk '{print $2}')
if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
    log "${RED}Не удалось сгенерировать ключи.${NC}"
    exit 1
fi

INBOUND_JSON=$(cat <<EOF
{
  "protocol": "vless",
  "port": 443,
  "settings": {
    "clients": [],
    "decryption": "none",
    "fallbacks": [{"dest": "127.0.0.1:$NGINX_LOCAL_PORT", "xver": 0}]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$DOMAIN:443",
      "xver": 0,
      "serverNames": ["$DOMAIN"],
      "privateKey": "$PRIVATE_KEY",
      "publicKey": "$PUBLIC_KEY",
      "minClientVer": "",
      "maxClientVer": "",
      "maxTimeDiff": 0,
      "shortIds": ["", "1234567890abcdef"]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}
EOF
)

EXISTING_INBOUND=$(sqlite3 "$DB_PATH" "SELECT id FROM inbounds WHERE port=443 LIMIT 1;" 2>/dev/null)
if [[ -z "$EXISTING_INBOUND" ]] || $FORCE_MODE; then
    if [[ -n "$EXISTING_INBOUND" ]]; then
        sqlite3 "$DB_PATH" "DELETE FROM inbounds WHERE id=$EXISTING_INBOUND;" >> "$LOG_FILE" 2>&1
    fi
    ESCAPED_JSON=$(echo "$INBOUND_JSON" | sqlite3_escape)
    sqlite3 "$DB_PATH" "INSERT INTO inbounds (port, protocol, settings, stream_settings, sniffing, enable, tag) VALUES (443, 'vless', '$ESCAPED_JSON', '$ESCAPED_JSON', '$ESCAPED_JSON', 1, 'vless-reality-inbound');" >> "$LOG_FILE" 2>&1
    log "${GREEN}Inbound создан.${NC}"
else
    log "${YELLOW}Inbound уже существует.${NC}"
fi

CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
CLIENT_JSON=$(cat <<EOF
{
  "id": "$CLIENT_UUID",
  "flow": "xtls-rprx-vision",
  "email": "user1@$DOMAIN",
  "limitIp": 0,
  "totalGB": 0,
  "expiryTime": 0,
  "enable": true,
  "tgId": "",
  "subId": ""
}
EOF
)

INBOUND_ID=$(sqlite3 "$DB_PATH" "SELECT id FROM inbounds WHERE port=443 LIMIT 1;")
if [[ -n "$INBOUND_ID" ]]; then
    CURRENT_SETTINGS=$(sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id=$INBOUND_ID;")
    NEW_SETTINGS=$(echo "$CURRENT_SETTINGS" | jq ".clients += [$CLIENT_JSON]")
    ESCAPED_SETTINGS=$(echo "$NEW_SETTINGS" | sqlite3_escape)
    sqlite3 "$DB_PATH" "UPDATE inbounds SET settings='$ESCAPED_SETTINGS' WHERE id=$INBOUND_ID;" >> "$LOG_FILE" 2>&1
    log "${GREEN}Клиент добавлен (UUID: $CLIENT_UUID).${NC}"
fi

systemctl restart $XUI_SERVICE >> "$LOG_FILE" 2>&1
systemctl reload nginx

PROTOCOL="https"
[[ ! -f "$SSL_DIR/fullchain.pem" ]] && PROTOCOL="http"

echo ""
log "${GREEN}======================================================"
log "${GREEN}✅ VPN-сервер успешно развёрнут!${NC}"
log "${GREEN}======================================================"
echo ""
log "🌐 Панель управления 3X-UI:"
log "   URL: ${PROTOCOL}://${DOMAIN}:${XUI_PORT}${XUI_PATH}"
log "   Логин: ${XUI_USERNAME}"
log "   Пароль: ${XUI_PASSWORD}"
echo ""
log "🔐 Параметры VPN-клиента:"
log "   Адрес: ${DOMAIN}"
log "   Порт: 443"
log "   UUID: ${CLIENT_UUID}"
log "   Flow: xtls-rprx-vision"
log "   SNI: ${DOMAIN}"
log "   PublicKey: ${PUBLIC_KEY}"
log "   ShortId: 1234567890abcdef (или пустой)"
echo ""
log "📡 Порт подписок: ${SUBSCRIPTION_PORT}"
log "   Ссылка: ${PROTOCOL}://${DOMAIN}:${SUBSCRIPTION_PORT}/sub/${CLIENT_UUID}"
echo ""
log "${YELLOW}⚠️  Если сайт не открывается, проверьте Nginx: nginx -t${NC}"
log "======================================================"
exit 0