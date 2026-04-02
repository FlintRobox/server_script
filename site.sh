#!/bin/bash

# =============================================
# Скрипт 2: Установка сайта (site.sh)
# Версия: 10.0 (финальная, исправлена логика SSL)
# =============================================

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
LOG_FILE="/var/log/setup.log"
ENV_FILE=".env"
WEB_ROOT_BASE="/var/www"

# --- Цвета для вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Функции ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_only() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

run_cmd() {
    log_only "Выполнение: $*"
    "$@" >> "$LOG_FILE" 2>&1
}

show_progress() {
    local current=$1
    local total=$2
    local message=$3
    local percent=$(( (current - 1) * 100 / (total - 1) ))
    echo "[${percent}%] ${message}"
}

check_command() {
    command -v $1 &> /dev/null
}

validate_domain() {
    local domain=$1
    [[ -n "$domain" && "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

validate_email() {
    local email=$1
    [[ -n "$email" && "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

ask_with_default() {
    local var_name=$1
    local prompt=$2
    local default_value=$3
    local validation_func=$4
    local value

    while true; do
        read -p "$prompt [$default_value]: " value
        if [[ -z "$value" ]]; then
            value="$default_value"
        fi
        if [[ -n "$validation_func" ]]; then
            if $validation_func "$value"; then
                break
            else
                echo -e "${RED}Некорректное значение. Попробуйте снова.${NC}" >&2
            fi
        else
            break
        fi
    done
    eval "$var_name=\"$value\""
}

# Проверка, существует ли директория и не пуста ли она
is_dir_not_empty() {
    local dir=$1
    if [[ -d "$dir" ]]; then
        if [[ -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
            return 0
        fi
    fi
    return 1
}

# Проверка существования файла
file_exists() {
    [[ -f "$1" ]]
}

# Флаг принудительной перезаписи
FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
    echo -e "${YELLOW}Режим принудительной перезаписи включён.${NC}"
fi

# --- Начало скрипта ---
log "=== Запуск $SCRIPT_NAME ==="

if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен запускаться от root (или с sudo)." >&2
   exit 1
fi

# Загружаем существующий .env, если он есть
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
    echo -e "${GREEN}Загружен существующий файл .env${NC}"
else
    echo -e "${YELLOW}Файл .env не найден. Будет создан новый.${NC}"
    touch "$ENV_FILE"
fi

echo "======================================================"
echo "   Введите параметры для настройки сайта"
echo "   (если оставить поле пустым, будет использовано значение по умолчанию)"
echo "======================================================"

# --- Запрос домена ---
DEFAULT_DOMAIN="${DOMAIN:-example.com}"
ask_with_default DOMAIN "Введите доменное имя сайта" "$DEFAULT_DOMAIN" validate_domain

# --- Запрос названия сайта ---
DEFAULT_SITE_NAME="${SITE_NAME:-Мой сайт}"
ask_with_default SITE_NAME "Введите название сайта" "$DEFAULT_SITE_NAME" ""

# --- Запрос необходимости SSL и типа сертификата ---
DEFAULT_NEED_SSL="${NEED_SSL:-y}"
while true; do
    read -p "Требуется ли SSL-сертификат? (y/n) [$DEFAULT_NEED_SSL]: " ssl_answer
    if [[ -z "$ssl_answer" ]]; then
        ssl_answer="$DEFAULT_NEED_SSL"
    fi
    if [[ "$ssl_answer" =~ ^[YyДд]|yes|Yes|YES$ ]]; then
        NEED_SSL="y"
        break
    elif [[ "$ssl_answer" =~ ^[NnНн]|no|No|NO$ ]]; then
        NEED_SSL="n"
        break
    else
        echo -e "${RED}Пожалуйста, введите y или n.${NC}" >&2
    fi
done

SSL_TYPE=""
if [[ "$NEED_SSL" == "y" ]]; then
    DEFAULT_SSL_TYPE="${SSL_TYPE:-letsencrypt}"
    while true; do
        read -p "Использовать существующий сертификат или получить через Let's Encrypt? (existing/letsencrypt) [$DEFAULT_SSL_TYPE]: " ssl_type_answer
        if [[ -z "$ssl_type_answer" ]]; then
            ssl_type_answer="$DEFAULT_SSL_TYPE"
        fi
        if [[ "$ssl_type_answer" == "existing" || "$ssl_type_answer" == "letsencrypt" ]]; then
            SSL_TYPE="$ssl_type_answer"
            break
        else
            echo -e "${RED}Введите 'existing' или 'letsencrypt'.${NC}" >&2
        fi
    done

    if [[ "$SSL_TYPE" == "existing" ]]; then
        # Путь к папке с сертификатами
        DEFAULT_CERT_DIR="${SSL_CERT_DIR:-}"
        if [[ -z "$DEFAULT_CERT_DIR" ]]; then
            if [[ -d "/root/${DOMAIN}" ]]; then
                DEFAULT_CERT_DIR="/root/${DOMAIN}"
            elif [[ -d "/root/ssl/${DOMAIN}" ]]; then
                DEFAULT_CERT_DIR="/root/ssl/${DOMAIN}"
            fi
        fi
        read -p "Введите путь к папке с файлами сертификатов (должны быть .key, .crt/.cer, ca.cer/ca.crt) [$DEFAULT_CERT_DIR]: " CERT_DIR
        if [[ -z "$CERT_DIR" ]]; then
            CERT_DIR="$DEFAULT_CERT_DIR"
        fi
        while [[ ! -d "$CERT_DIR" ]]; do
            echo -e "${RED}Папка $CERT_DIR не существует.${NC}" >&2
            read -p "Введите путь к папке с сертификатами: " CERT_DIR
        done

        # Поиск файлов
        KEY_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f \( -name "*.key" -o -name "*.pem" \) | grep -i "key" | head -n1)
        [[ -z "$KEY_FILE" ]] && KEY_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f -name "*.key" | head -n1)

        CERT_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f \( -name "*.cer" -o -name "*.crt" -o -name "*.pem" \) | grep -v "ca" | grep -v "key" | head -n1)
        if [[ -z "$CERT_FILE" ]]; then
            CERT_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f -name "*.crt" | head -n1)
        fi
        [[ -z "$CERT_FILE" ]] && CERT_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f -name "*.cer" | head -n1)

        CA_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f \( -name "ca.cer" -o -name "ca.crt" -o -name "*.ca" \) | head -n1)
        if [[ -z "$CA_FILE" ]]; then
            CA_FILE=$(find "$CERT_DIR" -maxdepth 1 -type f \( -name "*.cer" -o -name "*.crt" -o -name "*.pem" \) | grep -v -F "$KEY_FILE" | grep -v -F "$CERT_FILE" | head -n1)
        fi

        if [[ -z "$KEY_FILE" || -z "$CERT_FILE" ]]; then
            echo -e "${RED}Не удалось найти ключ или сертификат в папке $CERT_DIR.${NC}" >&2
            echo "Убедитесь, что в папке есть файл с расширением .key и файл с расширением .cer/.crt (сертификат)."
            exit 1
        fi

        echo -e "${GREEN}Найдены файлы:${NC}"
        echo "  Ключ: $KEY_FILE"
        echo "  Сертификат: $CERT_FILE"
        if [[ -n "$CA_FILE" ]]; then
            echo "  CA-цепочка: $CA_FILE"
        else
            echo -e "${YELLOW}  CA-цепочка не найдена. Будет использован только сертификат домена.${NC}"
        fi

        SSL_CERT="$CERT_FILE"
        SSL_KEY="$KEY_FILE"
        SSL_CA="$CA_FILE"
        SSL_CERT_DIR="$CERT_DIR"
    fi
fi

# --- Запрос email ---
if [[ -n "${ADMIN_EMAIL:-}" ]]; then
    echo -e "Email администратора (из .env): ${GREEN}${ADMIN_EMAIL}${NC}"
    read -p "Использовать этот email? (оставьте пустым для подтверждения или введите новый): " new_email
    if [[ -n "$new_email" ]]; then
        while ! validate_email "$new_email"; do
            echo -e "${RED}Некорректный email. Попробуйте снова.${NC}" >&2
            read -p "Введите email администратора: " new_email
        done
        ADMIN_EMAIL="$new_email"
    fi
else
    ask_with_default ADMIN_EMAIL "Введите email администратора (для уведомлений)" "" validate_email
fi

# ===== Генерация параметров БД =====
echo -e "${GREEN}Генерация параметров базы данных...${NC}"

DB_SAFE_NAME="$(echo "$DOMAIN" | tr '.' '_')"
DB_NAME="$DB_SAFE_NAME"
DB_USER="user_${DB_SAFE_NAME}"

# Генерация пароля БД (только буквы и цифры)
DB_PASSWORD="$(openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c20)"
if [[ -z "$DB_PASSWORD" ]]; then
    DB_PASSWORD="$(date +%s | sha256sum | base64 | head -c20 | tr -dc 'A-Za-z0-9')"
fi

# Генерация пароля администратора, если не задан
if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    ADMIN_PASSWORD="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c16)"
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD="$(date +%s | sha256sum | base64 | head -c16 | tr -dc 'A-Za-z0-9')"
    fi
fi

# ===== Сохранение переменных в .env =====
echo -e "${GREEN}Сохранение параметров в .env...${NC}"
for key in DOMAIN SITE_NAME NEED_SSL SSL_TYPE SSL_CERT SSL_KEY SSL_CA SSL_CERT_DIR ADMIN_EMAIL DB_NAME DB_USER DB_PASSWORD ADMIN_PASSWORD; do
    sed -i "/^$key=/d" "$ENV_FILE" 2>/dev/null || true
    echo "$key=\"${!key}\"" >> "$ENV_FILE"
done
set -a; source "$ENV_FILE"; set +a
log_only "Переменные сохранены в .env"

# ===== Проверка зависимостей =====
log "Проверка наличия необходимого ПО..."
check_command "nginx" || { echo -e "${RED}Ошибка: nginx не установлен.${NC}" >&2; exit 1; }

if ! ls /run/php/php*-fpm.sock >/dev/null 2>&1; then
    echo -e "${RED}Ошибка: php-fpm не запущен (сокет не найден).${NC}" >&2
    exit 1
fi

check_command "mysql" || { echo -e "${RED}Ошибка: mysql клиент не установлен.${NC}" >&2; exit 1; }
log_only "Все необходимые компоненты найдены."

# ===== Основные шаги =====
TOTAL_STEPS=8
CURRENT_STEP=0

# Шаг 1: Создание структуры директорий
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Создание структуры директорий сайта"

SITE_DIR="${WEB_ROOT_BASE}/${DOMAIN}"
if [[ -d "$SITE_DIR" ]]; then
    if is_dir_not_empty "$SITE_DIR"; then
        echo -e "${YELLOW}Директория $SITE_DIR уже существует и не пуста.${NC}"
        if [[ "$FORCE" == false ]]; then
            read -p "Продолжить? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Пропуск создания структуры директорий."
            else
                run_cmd mkdir -p "$SITE_DIR"/{core,admin,templates,uploads}
            fi
        else
            run_cmd mkdir -p "$SITE_DIR"/{core,admin,templates,uploads}
        fi
    else
        run_cmd mkdir -p "$SITE_DIR"/{core,admin,templates,uploads}
    fi
else
    run_cmd mkdir -p "$SITE_DIR"/{core,admin,templates,uploads}
fi

# Установка прав для uploads
if [[ -d "$SITE_DIR/uploads" ]]; then
    if [[ "$(stat -c %U "$SITE_DIR/uploads")" != "www-data" ]] || [[ "$(stat -c %a "$SITE_DIR/uploads")" != "750" ]]; then
        run_cmd chown www-data:www-data "$SITE_DIR/uploads"
        run_cmd chmod 750 "$SITE_DIR/uploads"
    fi
fi
log_only "Директории проверены/созданы."

# Шаг 2: Создание файлов index.php и config.php
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Создание файлов index.php и config.php"

create_file() {
    local file=$1
    local content=$2
    if file_exists "$file" && [[ "$FORCE" == false ]]; then
        echo -e "${YELLOW}Файл $file уже существует. Пропуск.${NC}"
        log_only "Файл $file существует, пропуск создания."
    else
        echo "$content" > "$file"
        log_only "Файл $file создан."
        if [[ "$file" == "$SITE_DIR/config.php" ]]; then
            if ! grep -q "define('DB_NAME'" "$file"; then
                echo -e "${RED}Ошибка: файл config.php не содержит необходимых констант.${NC}" >&2
                log_only "Ошибка: config.php не содержит DB_NAME."
                exit 1
            fi
        fi
    fi
}

INDEX_CONTENT='<?php
require_once __DIR__ . "/config.php";
$request_uri = $_SERVER["REQUEST_URI"];
$base_path = str_replace("index.php", "", $_SERVER["SCRIPT_NAME"]);
$route = str_replace($base_path, "", $request_uri);
if (($pos = strpos($route, "?")) !== false) {
    $route = substr($route, 0, $pos);
}
$route = trim($route, "/");
?>
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?php echo SITE_NAME; ?></title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
        h1 { color: #333; }
        .info { background: #f4f4f4; padding: 20px; border-radius: 5px; }
    </style>
</head>
<body>
    <h1><?php echo SITE_NAME; ?></h1>
    <div class="info">
        <p><strong>Сайт работает!</strong></p>
        <p>Это заглушка. Для доступа к административной панели перейдите по <a href="/admin">ссылке</a>.</p>
        <p>Запрошенный путь: /<?php echo htmlspecialchars($route); ?></p>
    </div>
</body>
</html>'

CONFIG_CONTENT="<?php
define('SITE_NAME', '${SITE_NAME}');
define('DB_HOST', 'localhost');
define('DB_NAME', '${DB_NAME}');
define('DB_USER', '${DB_USER}');
define('DB_PASS', '${DB_PASSWORD}');
define('DEBUG_MODE', false);

spl_autoload_register(function (\$class_name) {
    \$file = __DIR__ . '/core/' . \$class_name . '.php';
    if (file_exists(\$file)) {
        require_once \$file;
    }
});

try {
    \$dsn = 'mysql:host=' . DB_HOST . ';dbname=' . DB_NAME . ';charset=utf8mb4';
    \$pdo = new PDO(\$dsn, DB_USER, DB_PASS);
    \$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    define('DB_CONNECTION', \$pdo);
} catch (PDOException \$e) {
    if (DEBUG_MODE) {
        die('Ошибка подключения к БД: ' . \$e->getMessage());
    } else {
        die('Ошибка подключения к базе данных.');
    }
}
"

create_file "$SITE_DIR/index.php" "$INDEX_CONTENT"
create_file "$SITE_DIR/config.php" "$CONFIG_CONTENT"

# ===== Шаг 3: Установка SSL-сертификата (до настройки nginx) =====
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Установка SSL-сертификата"

SSL_AVAILABLE=false
SSL_DIR="/etc/letsencrypt/live/${DOMAIN}"

if [[ "$NEED_SSL" == "y" ]]; then
    if [[ "$SSL_TYPE" == "existing" ]]; then
        if [[ -f "$SSL_DIR/fullchain.pem" && -f "$SSL_DIR/privkey.pem" && "$FORCE" == false ]]; then
            echo -e "${YELLOW}Сертификат для $DOMAIN уже установлен. Пропуск.${NC}"
            log_only "Сертификат уже существует в $SSL_DIR"
            SSL_AVAILABLE=true
        else
            log_only "Установка существующего сертификата в $SSL_DIR"
            run_cmd mkdir -p "$SSL_DIR"

            if [[ ! -f "$SSL_CERT" ]]; then
                echo -e "${RED}Ошибка: файл сертификата $SSL_CERT не найден.${NC}" >&2
                exit 1
            fi
            if [[ ! -f "$SSL_KEY" ]]; then
                echo -e "${RED}Ошибка: файл ключа $SSL_KEY не найден.${NC}" >&2
                exit 1
            fi

            if [[ -n "$SSL_CA" && -f "$SSL_CA" ]]; then
                cat "$SSL_CERT" "$SSL_CA" > "$SSL_DIR/fullchain.pem" 2>> "$LOG_FILE"
            else
                cp "$SSL_CERT" "$SSL_DIR/fullchain.pem" 2>> "$LOG_FILE"
            fi
            if [[ $? -ne 0 || ! -s "$SSL_DIR/fullchain.pem" ]]; then
                echo -e "${RED}Ошибка при создании fullchain.pem.${NC}" >&2
                exit 1
            fi

            cp "$SSL_KEY" "$SSL_DIR/privkey.pem" 2>> "$LOG_FILE"
            if [[ $? -ne 0 || ! -s "$SSL_DIR/privkey.pem" ]]; then
                echo -e "${RED}Ошибка при копировании ключа.${NC}" >&2
                exit 1
            fi

            chmod 644 "$SSL_DIR/fullchain.pem"
            chmod 600 "$SSL_DIR/privkey.pem"
            SSL_AVAILABLE=true
            log_only "Сертификат установлен."
        fi
    elif [[ "$SSL_TYPE" == "letsencrypt" ]]; then
        if run_cmd certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$ADMIN_EMAIL"; then
            SSL_AVAILABLE=true
            log_only "SSL-сертификат успешно получен."
        else
            log_only "ПРЕДУПРЕЖДЕНИЕ: Не удалось получить SSL-сертификат через Let's Encrypt."
            echo -e "${YELLOW}SSL-сертификат не получен. Сайт будет работать только по HTTP.${NC}" >&2
            SSL_AVAILABLE=false
        fi
    fi
else
    log_only "SSL-сертификат не запрашивался."
fi

# ===== Шаг 4: Настройка виртуального хоста nginx =====
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Настройка виртуального хоста nginx"

NGINX_CONF_AVAILABLE="/etc/nginx/sites-available/${DOMAIN}"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.3")
PHP_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"

if [[ -f "$NGINX_CONF_AVAILABLE" && "$FORCE" == false ]]; then
    echo -e "${YELLOW}Конфигурация nginx для $DOMAIN уже существует. Пропуск.${NC}"
    log_only "Конфиг nginx уже существует, пропуск."
else
    if [[ "$SSL_AVAILABLE" == true ]]; then
        # Конфигурация с HTTPS и редиректом
        cat > "$NGINX_CONF_AVAILABLE" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};
    root ${SITE_DIR};
    index index.php index.html;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCKET};
    }

    location ^~ /uploads {
        location ~ \.php\$ {
            deny all;
        }
    }

    server_tokens off;
    fastcgi_hide_header X-Powered-By;
}
EOF
    else
        # Конфигурация только HTTP
        cat > "$NGINX_CONF_AVAILABLE" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${SITE_DIR};
    index index.php index.html;
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCKET};
    }
    location ^~ /uploads {
        location ~ \.php\$ {
            deny all;
        }
    }
    server_tokens off;
    fastcgi_hide_header X-Powered-By;
}
EOF
    fi
    log_only "Конфигурационный файл nginx создан."
fi

if [[ ! -L "$NGINX_CONF_ENABLED" ]]; then
    run_cmd ln -s "$NGINX_CONF_AVAILABLE" "$NGINX_CONF_ENABLED"
    log_only "Сайт активирован."
fi

if nginx -t >> "$LOG_FILE" 2>&1; then
    run_cmd systemctl reload nginx
    log_only "Nginx перезагружен."
else
    echo -e "${RED}ОШИБКА: Конфигурация nginx не валидна. Проверьте лог.${NC}" >&2
    exit 1
fi

# Шаг 5: Инициализация базы данных
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Инициализация базы данных и создание таблиц"

DB_EXISTS=$(mysql -N -s -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';" 2>/dev/null || true)
if [[ -z "$DB_EXISTS" ]]; then
    run_cmd mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    log_only "База данных $DB_NAME создана."
else
    log_only "База данных $DB_NAME уже существует."
fi

run_cmd mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
run_cmd mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
run_cmd mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
run_cmd mysql -e "FLUSH PRIVILEGES;"
log_only "Пользователь БД проверен/обновлён."

run_cmd mysql "$DB_NAME" -e "CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    login VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role ENUM('admin', 'editor', 'viewer') DEFAULT 'viewer',
    email VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"

run_cmd mysql "$DB_NAME" -e "CREATE TABLE IF NOT EXISTS pages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    slug VARCHAR(100) UNIQUE NOT NULL,
    title VARCHAR(200) NOT NULL,
    content TEXT,
    meta_description VARCHAR(255),
    status ENUM('draft', 'published') DEFAULT 'draft',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"

run_cmd mysql "$DB_NAME" -e "CREATE TABLE IF NOT EXISTS settings (
    \`key\` VARCHAR(100) PRIMARY KEY,
    value TEXT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"

log_only "Таблицы созданы."

ADMIN_HASH=$(openssl passwd -6 "$ADMIN_PASSWORD")
run_cmd mysql "$DB_NAME" -e "INSERT IGNORE INTO users (login, password_hash, role, email) VALUES ('admin', '${ADMIN_HASH}', 'admin', '${ADMIN_EMAIL}');"

PAGE_COUNT=$(mysql "$DB_NAME" -N -s -e "SELECT COUNT(*) FROM pages;" 2>/dev/null || echo "0")
if [[ "$PAGE_COUNT" -eq 0 ]]; then
    run_cmd mysql "$DB_NAME" -e "INSERT INTO pages (slug, title, content, status) VALUES ('/', 'Главная', '<h1>Добро пожаловать!</h1><p>Это ваша главная страница.</p>', 'published');"
    log_only "Добавлена страница по умолчанию."
fi

# Шаг 6: Проверка защиты директории uploads
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Проверка защиты директории uploads"
if [[ -d "$SITE_DIR/uploads" ]]; then
    if [[ "$(stat -c %U "$SITE_DIR/uploads")" != "www-data" ]] || [[ "$(stat -c %a "$SITE_DIR/uploads")" != "750" ]]; then
        run_cmd chown www-data:www-data "$SITE_DIR/uploads"
        run_cmd chmod 750 "$SITE_DIR/uploads"
        log_only "Права директории uploads скорректированы."
    fi
fi
log_only "Директория uploads защищена."

# Шаг 7: Активация резервного копирования
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Активация резервного копирования"

BACKUP_SCRIPT="/usr/local/bin/backup.sh"
if [[ -f "$BACKUP_SCRIPT" ]]; then
    log_only "Обновление скрипта бэкапа ($BACKUP_SCRIPT)"
    cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
LOG_FILE="/var/log/backup.log"
BACKUP_DIR="/var/backups/site"
DATE=\$(date +%Y-%m-%d_%H-%M-%S)
SITE_DIR="$SITE_DIR"
DB_NAME="$DB_NAME"

echo "[\$(date)] Начало бэкапа" >> \$LOG_FILE

if mysqldump --defaults-file=/root/.my.cnf "$DB_NAME" > "\$BACKUP_DIR/db_\$DATE.sql"; then
    echo "[\$(date)] Бэкап БД создан" >> \$LOG_FILE
else
    echo "[\$(date)] ОШИБКА: не удалось создать бэкап БД" >> \$LOG_FILE
fi

if tar -czf "\$BACKUP_DIR/site_\$DATE.tar.gz" -C "\$SITE_DIR" --exclude=uploads .; then
    echo "[\$(date)] Бэкап файлов создан" >> \$LOG_FILE
else
    echo "[\$(date)] ОШИБКА: не удалось создать бэкап файлов" >> \$LOG_FILE
fi

find "\$BACKUP_DIR" -type f -name "*.sql" -mtime +7 -delete
find "\$BACKUP_DIR" -type f -name "*.tar.gz" -mtime +7 -delete

echo "[\$(date)] Бэкап завершён" >> \$LOG_FILE
EOF
    chmod +x "$BACKUP_SCRIPT"
    log_only "Скрипт бэкапа обновлён."
    echo -e "${GREEN}✅ Скрипт бэкапа активирован.${NC}"
else
    log_only "Скрипт бэкапа $BACKUP_SCRIPT не найден."
    echo -e "${YELLOW}⚠️ Скрипт бэкапа не найден. Убедитесь, что init.sh был выполнен.${NC}"
fi

# Шаг 8: Завершение настройки сайта
CURRENT_STEP=$((CURRENT_STEP + 1))
show_progress $CURRENT_STEP $TOTAL_STEPS "Завершение настройки сайта"

# Исправление прав на корневую директорию (если не www-data)
if [[ "$(stat -c %U "$SITE_DIR")" != "www-data" ]]; then
    run_cmd chown -R www-data:www-data "$SITE_DIR"
    log_only "Права корневой директории сайта исправлены."
fi

# Права на .env
chmod 600 "$ENV_FILE" 2>/dev/null || true
log_only "Права файла .env установлены в 600"

PROTOCOL="http"
if [[ "$SSL_AVAILABLE" == true ]]; then
    PROTOCOL="https"
fi

echo ""
echo "======================================================"
echo -e "${GREEN}🎉 Скрипт site.sh успешно выполнен!${NC}"
echo "======================================================"
echo ""
echo "✅ Ваш сайт доступен по адресу: ${PROTOCOL}://${DOMAIN}"
echo ""
echo "🔐 Данные для входа в административную панель (после установки cms_core.sh):"
echo "   URL:    ${PROTOCOL}://${DOMAIN}/admin"
echo "   Логин:  admin"
echo "   Пароль: ${ADMIN_PASSWORD}"
echo ""
echo "🗄️  Параметры базы данных:"
echo "   Имя БД:              ${DB_NAME}"
echo "   Пользователь БД:      ${DB_USER}"
echo "   Пароль БД:            ${DB_PASSWORD}"
echo ""
echo "📁 Важные пути:"
echo "   Корень сайта:        ${SITE_DIR}"
echo "   Конфиг nginx:        ${NGINX_CONF_AVAILABLE}"
echo "   Скрипт бэкапа:       ${BACKUP_SCRIPT}"
echo ""
if [[ "$SSL_AVAILABLE" == true && "$SSL_TYPE" == "existing" ]]; then
    echo "🔒 SSL-сертификат использован существующий (из $SSL_CERT_DIR)."
elif [[ "$SSL_AVAILABLE" == true && "$SSL_TYPE" == "letsencrypt" ]]; then
    echo "🔒 SSL-сертификат получен через Let's Encrypt."
elif [[ "$NEED_SSL" == "y" && "$SSL_AVAILABLE" == false ]]; then
    echo "⚠️  SSL-сертификат не установлен. Сайт работает только по HTTP."
fi
echo ""
echo "⚠️  Важно:"
echo "   - Файл .env защищён (права 600)."
echo "   - Бэкап выполняется ежедневно в 2:00, логи в /var/log/backup.log"
echo ""
echo "➡️  Следующий шаг: запустите скрипт cms_core.sh для установки ядра админки."
echo "======================================================"

log "=== Скрипт $SCRIPT_NAME завершён успешно ==="
exit 0