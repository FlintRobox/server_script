#!/bin/bash
# =====================================================================
# vpn.sh - Полностью автоматическая установка 3X-UI и интеграция с сайтом
# Версия: 19.0 (без x-ui setting, только SQL)
# =====================================================================

set -euo pipefail

LOG_FILE="/var/log/setup.log"
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
XUI_DB="/etc/x-ui/x-ui.db"
XUI_CMD="x-ui"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
run() { log "Выполнение: $*"; "$@" >> "$LOG_FILE" 2>&1; }
progress() { echo "[${1}%] ${2}"; }

# --- Проверка jq ---
if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}Устанавливаем jq...${NC}"
    apt update && apt install -y jq >> "$LOG_FILE" 2>&1
fi

# =========================================================================
#  ФУНКЦИИ ОПРЕДЕЛЕНИЯ ПАРАМЕТРОВ
# =========================================================================

detect_domain() {
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        if [[ -n "${DOMAIN:-}" ]]; then
            echo "$DOMAIN"
            return
        fi
    fi
    local domain=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1)
    if [[ -n "$domain" ]]; then
        echo "$domain"
        return
    fi
    domain=$(grep -h "server_name" /etc/nginx/sites-enabled/* 2>/dev/null | head -1 | awk '{print $2}' | sed 's/;//')
    echo "${domain:-}"
}

detect_site_root() {
    local domain="$1"
    if [[ -d "/var/www/$domain" ]]; then
        echo "/var/www/$domain"
        return
    fi
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        if [[ -n "${SITE_ROOT:-}" && -d "$SITE_ROOT" ]]; then
            echo "$SITE_ROOT"
            return
        fi
    fi
    local conf_file="$NGINX_ENABLED/$domain"
    if [[ -f "$conf_file" ]]; then
        local root=$(grep -h "root" "$conf_file" | grep -v "#" | head -1 | awk '{print $2}' | sed 's/;//')
        if [[ -n "$root" && -d "$root" ]]; then
            echo "$root"
            return
        fi
    fi
    echo "/var/www/$domain"
}

detect_php_socket() {
    for ver in 8.3 8.2 8.1 8.0; do
        if [[ -S "/run/php/php${ver}-fpm.sock" ]]; then
            echo "/run/php/php${ver}-fpm.sock"
            return
        fi
    done
    echo "/run/php/php8.3-fpm.sock"
}

get_free_port() {
    local port=$1
    while ss -tln | grep -q ":$port"; do
        port=$((port + 1))
    done
    echo "$port"
}

generate_random_string() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w "${1:-8}" | head -n1
}

# =========================================================================
#  ОСНОВНОЙ СКРИПТ
# =========================================================================

log "=== Запуск $(basename "$0") ==="
if [[ $EUID -ne 0 ]]; then echo -e "${RED}Запустите от root.${NC}" >&2; exit 1; fi

# --- Определение домена, корня, PHP ---
DOMAIN=$(detect_domain)
if [[ -z "$DOMAIN" ]]; then
    echo -e "${RED}Не удалось определить домен. Убедитесь, что сайт настроен.${NC}"
    exit 1
fi

SITE_ROOT=$(detect_site_root "$DOMAIN")
PHP_SOCKET=$(detect_php_socket)
log "Домен: $DOMAIN, Корень: $SITE_ROOT, PHP сокет: $PHP_SOCKET"

# --- SSL-сертификаты (уже есть от site.sh) ---
SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
    echo -e "${YELLOW}Сертификаты для $DOMAIN не найдены. HTTPS для панели не будет включён.${NC}"
    SSL_CERT=""; SSL_KEY=""
else
    log "Сертификаты: $SSL_CERT, $SSL_KEY"
fi

# =========================================================================
#  УСТАНОВКА 3X-UI (с остановкой Nginx)
# =========================================================================

progress 10 "Остановка Nginx для освобождения порта 80"
run systemctl stop nginx

progress 20 "Автоматическая установка 3X-UI (может занять 1-2 минуты)"
yes | bash <(curl -m 300 -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) >> "$LOG_FILE" 2>&1 || true

progress 30 "Запуск Nginx обратно"
run systemctl start nginx

# Убедимся, что команда x-ui доступна
if ! command -v x-ui &>/dev/null; then
    export PATH="$PATH:/usr/local/x-ui"
    if ! command -v x-ui &>/dev/null; then
        echo -e "${RED}Ошибка: x-ui не найден после установки.${NC}" >&2
        exit 1
    fi
fi

# =========================================================================
#  ПОСТ-УСТАНОВОЧНАЯ НАСТРОЙКА
# =========================================================================

# --- Локальный порт для Nginx ---
LOCAL_PORT=$(get_free_port 10443)
log "Локальный порт для Nginx: $LOCAL_PORT"

# --- Конфигурация Nginx (только локальный порт, без SSL) ---
progress 40 "Настройка Nginx на порту $LOCAL_PORT"
CONFIG_FILE="$NGINX_AVAILABLE/$DOMAIN"
cat > "$CONFIG_FILE" <<EOF
server {
    listen 127.0.0.1:$LOCAL_PORT;
    server_name $DOMAIN;
    root $SITE_ROOT;
    index index.php index.html;
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCKET;
    }
    location ^~ /uploads {
        location ~ \.php$ { deny all; }
    }
}
EOF

ln -sf "$CONFIG_FILE" "$NGINX_ENABLED/$DOMAIN"
if nginx -t >> "$LOG_FILE" 2>&1; then
    run systemctl reload nginx
else
    echo -e "${RED}Ошибка конфигурации Nginx.${NC}" >&2
    exit 1
fi

# --- Настройка панели 3X-UI (только SQL) ---
progress 50 "Настройка панели 3X-UI"

# Останавливаем панель
run systemctl stop x-ui || true
sleep 2

# Создаём таблицу settings, если её нет
sqlite3 "$XUI_DB" "CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);" 2>/dev/null || true

# Удаляем старые TLS-записи (от установщика)
sqlite3 "$XUI_DB" "DELETE FROM settings WHERE key IN ('webCertFile', 'webKeyFile', 'webEnable');" 2>/dev/null || true

# Генерируем параметры
PANEL_PORT=$(shuf -i 52000-53000 -n1)
PANEL_PATH="/$(generate_random_string 8)"
PANEL_USER="admin"
PANEL_PASS="$(generate_random_string 8)"

# Сохраняем параметры в базу (каждый запрос отдельно, с подавлением ошибок)
set +e
echo "Устанавливаем параметры панели: порт $PANEL_PORT, путь $PANEL_PATH, логин $PANEL_USER, пароль $PANEL_PASS" | tee -a "$LOG_FILE"
sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webPort', '$PANEL_PORT');" 2>&1 | tee -a "$LOG_FILE"
sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webBasePath', '$PANEL_PATH');" 2>&1 | tee -a "$LOG_FILE"
sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('username', '$PANEL_USER');" 2>&1 | tee -a "$LOG_FILE"
sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('password', '$PANEL_PASS');" 2>&1 | tee -a "$LOG_FILE"

# Включаем HTTPS для панели, если есть сертификаты
if [[ -n "$SSL_CERT" && -n "$SSL_KEY" && -f "$SSL_CERT" && -f "$SSL_KEY" ]]; then
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webCertFile', '$SSL_CERT');" 2>&1 | tee -a "$LOG_FILE"
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webKeyFile', '$SSL_KEY');" 2>&1 | tee -a "$LOG_FILE"
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webEnable', 'true');" 2>&1 | tee -a "$LOG_FILE"
    log "HTTPS для панели включён"
else
    sqlite3 "$XUI_DB" "INSERT OR REPLACE INTO settings (key, value) VALUES ('webEnable', 'false');" 2>&1 | tee -a "$LOG_FILE"
fi
set -e

# Запускаем панель
run systemctl start x-ui
sleep 3

# Проверяем, что панель запустилась
if ! systemctl is-active --quiet x-ui; then
    echo -e "${RED}Ошибка: панель 3X-UI не запустилась.${NC}" >&2
    exit 1
fi

# --- Создание inbound ---
progress 70 "Настройка inbound на порту 443"
sqlite3 "$XUI_DB" "CREATE TABLE IF NOT EXISTS inbounds (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    up INTEGER,
    down INTEGER,
    total INTEGER,
    remark TEXT,
    enable INTEGER,
    expiry_time INTEGER,
    listen TEXT,
    port INTEGER,
    protocol TEXT,
    settings TEXT,
    stream_settings TEXT,
    tag TEXT,
    sniffing TEXT
);" 2>/dev/null || true

COUNT=$(sqlite3 "$XUI_DB" "SELECT COUNT(*) FROM inbounds WHERE port=443 AND enable=1;" 2>/dev/null || echo "0")
if [[ "$COUNT" -eq 0 ]]; then
    CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)
    SETTINGS_JSON=$(jq -n \
        --arg uuid "$CLIENT_UUID" \
        --arg port "$LOCAL_PORT" \
        '{
            clients: [{ id: $uuid, flow: "xtls-rprx-vision", email: "client1", enable: true }],
            decryption: "none",
            fallbacks: [{ dest: ("127.0.0.1:" + $port) }]
        }')
    STREAM_JSON=$(jq -n \
        --arg domain "$DOMAIN" \
        --arg cert "$SSL_CERT" \
        --arg key "$SSL_KEY" \
        '{
            network: "tcp",
            security: "tls",
            tlsSettings: {
                serverName: $domain,
                certificates: [{ certificateFile: $cert, keyFile: $key }],
                alpn: ["http/1.1"]
            },
            tcpSettings: { header: { type: "none" } }
        }')
    SNIFFING_JSON='{"enabled":true,"destOverride":["http","tls"]}'
    sqlite3 "$XUI_DB" <<EOF
INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing) 
VALUES (1, 0, 0, 0, 'VLESS+TLS', 1, 0, '', 443, 'vless', '$SETTINGS_JSON', '$STREAM_JSON', 'inbound-443', '$SNIFFING_JSON');
EOF
    log "Inbound создан, UUID клиента: $CLIENT_UUID"
else
    CLIENT_UUID=$(sqlite3 "$XUI_DB" "SELECT json_extract(settings, '$.clients[0].id') FROM inbounds WHERE port=443;" 2>/dev/null || echo "")
    log "Inbound уже существует, UUID: $CLIENT_UUID"
fi

# --- UFW ---
progress 80 "Настройка брандмауэра"
ufw allow 443/tcp comment 'VLESS TCP' 2>/dev/null || true
ufw allow 443/udp comment 'VLESS UDP' 2>/dev/null || true
ufw allow "$PANEL_PORT"/tcp comment '3X-UI Panel' 2>/dev/null || true
SUB_PORT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort';" 2>/dev/null || echo "2096")
[[ -n "$SUB_PORT" ]] && ufw allow "$SUB_PORT"/tcp comment 'Subscription' 2>/dev/null || true
if ! ufw status | grep -q "Status: active"; then
    echo "y" | ufw enable 2>/dev/null || true
fi

# --- Перезапуск ---
progress 90 "Перезапуск сервисов"
run systemctl restart nginx
run systemctl restart x-ui

# --- Итог ---
progress 100 "Готово"
echo ""
echo "======================================================"
echo -e "${GREEN}✅ Установка и настройка 3X-UI завершена!${NC}"
echo "======================================================"
echo ""
echo "🌐 Сайт: https://$DOMAIN (локальный порт Nginx: $LOCAL_PORT)"
echo "🔐 Панель 3X-UI: https://$DOMAIN:$PANEL_PORT$PANEL_PATH"
echo "   Логин: $PANEL_USER | Пароль: $PANEL_PASS"
echo ""
echo "📡 VPN (VLESS+TLS):"
echo "   Адрес: $DOMAIN | Порт: 443"
echo "   UUID: ${CLIENT_UUID:-создайте в панели} | Flow: xtls-rprx-vision | Security: tls | SNI: $DOMAIN"
echo ""
echo "📌 Важно:"
echo "   - Убедитесь, что в настройках клиента 'allowInsecure' = false."
echo "   - Панель доступна по HTTPS, порт $PANEL_PORT открыт в UFW."
echo "   - Логи: /var/log/nginx/${DOMAIN}_error.log, /var/log/xray/error.log"
echo ""
echo "======================================================"

log "=== Скрипт завершён ==="
exit 0