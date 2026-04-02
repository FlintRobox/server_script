#!/bin/bash
# ==================================================
# init.sh - Универсальная базовая подготовка сервера
# Версия 2.1 (с меню выбора)
# ==================================================

set -euo pipefail

# --- Конфигурация ---
LOG_FILE="/var/log/setup.log"
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
TEMP_SQL="/tmp/mysql_secure.sql"
BACKUP_SCRIPT="/usr/local/bin/backup.sh"
BACKUP_DIR="/var/backups"

APT_OPTS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# --- Функции ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

progress() {
    local percent=$1
    local message=$2
    echo -e "\e[32m${percent}% – ${message}\e[0m"
    log "PROGRESS: ${percent}% – ${message}"
}

is_pkg_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q ^ii
}

user_exists() {
    id "$1" &>/dev/null
}

is_purpose_installed() {
    local needle="$1"
    local installed="${INSTALLED_PURPOSES:-}"
    [[ ",$installed," == *",$needle,"* ]]
}

add_installed_purpose() {
    local new_purpose="$1"
    local installed="${INSTALLED_PURPOSES:-}"
    if [[ -z "$installed" ]]; then
        INSTALLED_PURPOSES="$new_purpose"
    elif ! is_purpose_installed "$new_purpose"; then
        INSTALLED_PURPOSES="$installed,$new_purpose"
    fi
}

# --- Проверка прав ---
if [ "$EUID" -ne 0 ]; then
    echo "Ошибка: Скрипт должен запускаться от root или с sudo."
    exit 1
fi

# --- Инициализация лога ---
log "=== Начало выполнения init.sh (версия 2.1) ==="

# --- Загрузка/создание .env ---
if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
    echo "# Файл конфигурации, созданный init.sh" >> "$ENV_FILE"
fi
set -a
source "$ENV_FILE"
set +a

# --- Определение уже установленных целей ---
INSTALLED_PURPOSES="${INSTALLED_PURPOSES:-}"
mapfile -t INSTALLED_ARRAY < <(echo "$INSTALLED_PURPOSES" | tr ',' '\n' | grep -v '^$')
log "Уже установленные цели: ${INSTALLED_PURPOSES:-нет}"

# --- Определение доступных целей ---
declare -A PURPOSE_NAMES=(
    [1]="Сайт (веб-стек: Nginx + PHP + MariaDB)"
    [2]="Файловое хранилище (FTP/SFTP)"
    [3]="Сервер 3x-ui (прокси-панель)"
    [4]="3x-ui совместно с сайтом (комбинация 1+3)"
    [5]="База данных (только MariaDB)"
    [6]="Базовое ПО (минимальный набор)"
)

# --- Интерактивный выбор целей ---
select_purposes() {
    echo ""
    echo "=== Выбор назначения сервера ==="
    if [ -n "$INSTALLED_PURPOSES" ]; then
        echo "✅ Уже установлены:"
        for p in "${INSTALLED_ARRAY[@]}"; do
            echo "   - ${PURPOSE_NAMES[$p]}"
        done
        echo ""
        echo "Доступные для добавления:"
    else
        echo "Доступные варианты:"
    fi

    local available=()
    for i in {1..6}; do
        if ! is_purpose_installed "$i"; then
            echo "$i) ${PURPOSE_NAMES[$i]}"
            available+=("$i")
        fi
    done
    echo "0) Выход без изменений"

    if [ ${#available[@]} -eq 0 ]; then
        echo "Все цели уже установлены. Выход."
        exit 0
    fi

    echo ""
    read -p "Введите номера целей через запятую (например, 1,3) или 0 для выхода: " choice
    # Удаляем пробелы
    choice=$(echo "$choice" | tr -d ' ')
    
    # Проверка на выход
    if [ "$choice" = "0" ]; then
        echo "Выход по запросу пользователя. Скрипт завершён."
        exit 0
    fi

    IFS=',' read -ra SELECTED <<< "$choice"

    # Валидация: все номера должны быть из доступных, и не содержать 0
    local valid=true
    for sel in "${SELECTED[@]}"; do
        if ! [[ "$sel" =~ ^[1-6]$ ]] || is_purpose_installed "$sel"; then
            echo "Ошибка: номер '$sel' недопустим или уже установлен."
            valid=false
            break
        fi
    done
    if [ "$valid" = false ]; then
        echo "Пожалуйста, повторите ввод."
        select_purposes
        return
    fi

    # Если выбрана цель 4, автоматически добавим 1 и 3 как зависимости, но сохраним только 4
    local expanded=()
    for sel in "${SELECTED[@]}"; do
        if [ "$sel" -eq 4 ]; then
            expanded+=(1 3)
        else
            expanded+=("$sel")
        fi
    done
    # Уникальные номера для установки
    mapfile -t UNIQUE_SELECTED < <(printf "%s\n" "${expanded[@]}" | sort -u)
    SELECTED=("${UNIQUE_SELECTED[@]}")

    # Сохраняем выбранные цели для последующей записи в .env (исходные номера, без расширения)
    ORIGINAL_SELECTED=("${SELECTED[@]}")
    # Если была выбрана 4, то в ORIGINAL_SELECTED должна быть 4, а не 1,3
    if [[ " ${SELECTED[@]} " =~ " 1 " ]] && [[ " ${SELECTED[@]} " =~ " 3 " ]]; then
        # Проверяем, была ли выбрана 4 изначально
        if [[ " ${choice//,/ } " =~ " 4 " ]]; then
            ORIGINAL_SELECTED=("4")
        fi
    fi
}

# --- Основной процесс ---
select_purposes

# Подсчёт шагов (упрощённо, будет обновляться динамически)
TOTAL_STEPS=10
CURRENT_STEP=0

next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    progress "$PERCENT" "$1"
}

# ----------------------------------------------------------------------
next_step "Подготовка системы: обновление пакетов и настройка окружения"
log "Начало: подготовка системы"

export DEBIAN_FRONTEND=noninteractive

apt update -y >> "$LOG_FILE" 2>&1
apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1

timedatectl set-timezone Europe/Moscow >> "$LOG_FILE" 2>&1 || true

# Базовый набор пакетов (общий для всех)
BASE_PKGS=(curl wget git ufw fail2ban cron openssl python3 unattended-upgrades)
for pkg in "${BASE_PKGS[@]}"; do
    if ! is_pkg_installed "$pkg"; then
        apt install $APT_OPTS "$pkg" >> "$LOG_FILE" 2>&1
        log "Установлен пакет: $pkg"
    else
        log "Пакет уже установлен: $pkg"
    fi
done

# Настройка unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
systemctl enable unattended-upgrades >> "$LOG_FILE" 2>&1
systemctl restart unattended-upgrades >> "$LOG_FILE" 2>&1
log "Подготовка системы завершена"

# ----------------------------------------------------------------------
# Блок установки веб-стека (цели 1 или 3 (для 3x-ui), или 4)
NEED_WEB=false
if [[ " ${SELECTED[@]} " =~ " 1 " ]] || [[ " ${SELECTED[@]} " =~ " 3 " ]]; then
    NEED_WEB=true
fi

if [ "$NEED_WEB" = true ]; then
    next_step "Установка веб-стека (Nginx, PHP, MariaDB)"
    log "Установка веб-стека"

    # Nginx
    if ! is_pkg_installed nginx; then
        apt install $APT_OPTS nginx >> "$LOG_FILE" 2>&1
        log "Nginx установлен"
    else
        log "Nginx уже установлен"
    fi

    # MariaDB
    if ! is_pkg_installed mariadb-server; then
        apt install $APT_OPTS mariadb-server mariadb-client >> "$LOG_FILE" 2>&1
        log "MariaDB установлена"
    else
        log "MariaDB уже установлена"
    fi

    # Генерация пароля для root MariaDB, если нет
    if [ -z "${DB_ROOT_PASSWORD:-}" ]; then
        DB_ROOT_PASSWORD=$(openssl rand -base64 18)
        echo "DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD" >> "$ENV_FILE"
        log "Сгенерирован пароль для root MariaDB"
    fi

    # Автоматическая настройка безопасности MariaDB
    cat > "$TEMP_SQL" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

    if mysql -u root < "$TEMP_SQL" >> "$LOG_FILE" 2>&1; then
        log "MariaDB защищена (первый запуск)"
    else
        mysql -u root -p"$DB_ROOT_PASSWORD" < "$TEMP_SQL" >> "$LOG_FILE" 2>&1
        log "MariaDB защищена (с использованием пароля)"
    fi
    rm -f "$TEMP_SQL"

    cat > /root/.my.cnf <<EOF
[client]
user=root
password="$DB_ROOT_PASSWORD"
EOF
    chmod 600 /root/.my.cnf
    log "Пароль MariaDB сохранён в /root/.my.cnf"

    # PHP 8.3
    PHP_PKGS="php8.3-fpm php8.3-mysql php8.3-curl php8.3-xml php8.3-mbstring php8.3-zip php8.3-gd php8.3-intl php8.3-bcmath"
    if ! is_pkg_installed php8.3-fpm; then
        apt install $APT_OPTS $PHP_PKGS >> "$LOG_FILE" 2>&1
        log "PHP 8.3 и расширения установлены"
    else
        log "PHP 8.3 уже установлен"
    fi

    # Настройка PHP-FPM
    PHP_VERSION="8.3"
    POOL_CONF="/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"
    if [ -f "$POOL_CONF" ]; then
        cp "$POOL_CONF" "$POOL_CONF.bak" 2>/dev/null || true
        sed -i 's/^pm = .*/pm = dynamic/' "$POOL_CONF"
        sed -i 's/^pm.max_children = .*/pm.max_children = 20/' "$POOL_CONF"
        sed -i 's/^pm.start_servers = .*/pm.start_servers = 5/' "$POOL_CONF"
        sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 3/' "$POOL_CONF"
        sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 10/' "$POOL_CONF"
        log "PHP-FPM настроен"
    else
        log "ВНИМАНИЕ: файл $POOL_CONF не найден"
    fi

    systemctl enable php$PHP_VERSION-fpm >> "$LOG_FILE" 2>&1 || true
    systemctl restart php$PHP_VERSION-fpm >> "$LOG_FILE" 2>&1 || true

    # Composer и Node.js (полезны для сайта)
    if ! command -v composer &>/dev/null; then
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" >> "$LOG_FILE" 2>&1
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer >> "$LOG_FILE" 2>&1
        rm composer-setup.php
        log "Composer установлен глобально"
    fi
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >> "$LOG_FILE" 2>&1
        apt install $APT_OPTS nodejs >> "$LOG_FILE" 2>&1
        log "Node.js установлен"
    fi

    # Создание шаблона конфига Nginx
    cat > /etc/nginx/sites-available/site-template <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name _;
    root /var/www/site;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }

    server_tokens off;
}
EOF
    sed -i 's/# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf
    systemctl enable nginx >> "$LOG_FILE" 2>&1
    systemctl restart nginx >> "$LOG_FILE" 2>&1
    log "Веб-стек настроен"
fi

# ----------------------------------------------------------------------
# Блок установки FTP (цель 2)
if [[ " ${SELECTED[@]} " =~ " 2 " ]]; then
    next_step "Установка FTP-сервера (vsftpd)"
    log "Установка vsftpd"

    if ! is_pkg_installed vsftpd; then
        apt install $APT_OPTS vsftpd >> "$LOG_FILE" 2>&1
        log "vsftpd установлен"
    else
        log "vsftpd уже установлен"
    fi

    # Создание пользователя для хранилища
    if ! user_exists filestore; then
        useradd -m -d /home/filestore -s /bin/bash filestore
        echo "filestore:$(openssl rand -base64 12)" | chpasswd
        log "Пользователь filestore создан (пароль сгенерирован)"
    fi

    # Базовая конфигурация vsftpd
    cat > /etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
xferlog_std_format=YES
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
rsa_private_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
ssl_enable=NO
EOF
    systemctl restart vsftpd >> "$LOG_FILE" 2>&1
    systemctl enable vsftpd >> "$LOG_FILE" 2>&1
    log "FTP настроен"
fi

# ----------------------------------------------------------------------
# Блок установки зависимостей 3x-ui (цели 3 или 4)
if [[ " ${SELECTED[@]} " =~ " 3 " ]]; then
    next_step "Подготовка окружения для 3x-ui"
    log "Установка зависимостей 3x-ui"

    DEP_PKGS=(sqlite3 jq socat)
    for pkg in "${DEP_PKGS[@]}"; do
        if ! is_pkg_installed "$pkg"; then
            apt install $APT_OPTS "$pkg" >> "$LOG_FILE" 2>&1
            log "Установлен пакет: $pkg"
        fi
    done

    # Создание пользователя для 3x-ui (если потребуется)
    if ! user_exists xui; then
        useradd -m -s /bin/bash xui
        log "Пользователь xui создан"
    fi
    mkdir -p /opt/3x-ui
    log "3x-ui окружение подготовлено (панель не установлена, требуется отдельный скрипт)"
fi

# ----------------------------------------------------------------------
# Блок установки только БД (цель 5, если не была установлена ранее)
if [[ " ${SELECTED[@]} " =~ " 5 " ]] && [ "$NEED_WEB" = false ]; then
    next_step "Установка MariaDB (только БД)"
    log "Установка MariaDB"

    if ! is_pkg_installed mariadb-server; then
        apt install $APT_OPTS mariadb-server mariadb-client >> "$LOG_FILE" 2>&1
        log "MariaDB установлена"
    else
        log "MariaDB уже установлена"
    fi

    if [ -z "${DB_ROOT_PASSWORD:-}" ]; then
        DB_ROOT_PASSWORD=$(openssl rand -base64 18)
        echo "DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD" >> "$ENV_FILE"
        log "Сгенерирован пароль для root MariaDB"
    fi

    # mysql_secure_installation
    cat > "$TEMP_SQL" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

    if mysql -u root < "$TEMP_SQL" >> "$LOG_FILE" 2>&1; then
        log "MariaDB защищена (первый запуск)"
    else
        mysql -u root -p"$DB_ROOT_PASSWORD" < "$TEMP_SQL" >> "$LOG_FILE" 2>&1
        log "MariaDB защищена (с использованием пароля)"
    fi
    rm -f "$TEMP_SQL"

    cat > /root/.my.cnf <<EOF
[client]
user=root
password="$DB_ROOT_PASSWORD"
EOF
    chmod 600 /root/.my.cnf
    log "Пароль MariaDB сохранён в /root/.my.cnf"
fi

# ----------------------------------------------------------------------
# Настройка UFW (порты в зависимости от выбранных целей)
next_step "Настройка файервола (UFW)"
log "Настройка UFW"

ufw default deny incoming >> "$LOG_FILE" 2>&1
ufw default allow outgoing >> "$LOG_FILE" 2>&1
ufw allow 22/tcp comment 'SSH' >> "$LOG_FILE" 2>&1

if [[ " ${SELECTED[@]} " =~ " 1 " ]] || [[ " ${SELECTED[@]} " =~ " 3 " ]]; then
    ufw allow 80/tcp comment 'HTTP' >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp comment 'HTTPS' >> "$LOG_FILE" 2>&1
fi
if [[ " ${SELECTED[@]} " =~ " 2 " ]]; then
    ufw allow 21/tcp comment 'FTP' >> "$LOG_FILE" 2>&1
fi
# 3x-ui может использовать дополнительные порты, но они будут открыты в его скрипте
ufw --force enable >> "$LOG_FILE" 2>&1
log "UFW настроен"

# ----------------------------------------------------------------------
# Настройка fail2ban
next_step "Настройка fail2ban"
log "Настройка fail2ban"

cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s

[nginx-http-auth]
enabled = true
logpath = /var/log/nginx/error.log
EOF
systemctl enable fail2ban >> "$LOG_FILE" 2>&1
systemctl restart fail2ban >> "$LOG_FILE" 2>&1
log "fail2ban настроен"

# ----------------------------------------------------------------------
# Системные лимиты и бэкап
next_step "Настройка системных лимитов и бэкапа"
log "Настройка лимитов"

if ! grep -q "fs.file-max" /etc/sysctl.conf; then
    echo "fs.file-max = 65535" >> /etc/sysctl.conf
    sysctl -p >> "$LOG_FILE" 2>&1
    log "Лимит файлов увеличен"
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
BACKUP_DIR="$BACKUP_DIR"
DATE=\$(date +%Y-%m-%d_%H-%M-%S)
echo "[\$(date)] Начало бэкапа" >> /var/log/backup.log
# Пример: mysqldump --defaults-file=/root/.my.cnf --all-databases > \$BACKUP_DIR/db_\$DATE.sql
# find \$BACKUP_DIR -type f -name "*.sql" -mtime +7 -delete
echo "[\$(date)] Бэкап завершён" >> /var/log/backup.log
EOF
chmod +x "$BACKUP_SCRIPT"

CRON_JOB="0 2 * * * root $BACKUP_SCRIPT > /dev/null 2>&1"
if ! grep -F "$BACKUP_SCRIPT" /etc/crontab >/dev/null; then
    echo "$CRON_JOB" >> /etc/crontab
    log "Cron-задание для бэкапа добавлено"
fi

# ----------------------------------------------------------------------
# Обновление INSTALLED_PURPOSES в .env
for new_purpose in "${ORIGINAL_SELECTED[@]}"; do
    add_installed_purpose "$new_purpose"
done
# Перезаписываем .env с актуальными переменными
{
    echo "# Файл конфигурации, созданный init.sh"
    echo "INSTALLED_PURPOSES=$INSTALLED_PURPOSES"
    [ -n "${DB_ROOT_PASSWORD:-}" ] && echo "DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD"
} > "$ENV_FILE"
log "Файл .env обновлён, установленные цели: $INSTALLED_PURPOSES"

# ----------------------------------------------------------------------
# Итоговый отчёт
progress 100 "Готово! Сервер инициализирован."
echo ""
echo "===================== ИТОГОВАЯ ИНФОРМАЦИЯ ====================="
echo "✅ Установленные цели:"
for p in $(echo "$INSTALLED_PURPOSES" | tr ',' ' '); do
    echo "   - ${PURPOSE_NAMES[$p]}"
done
echo ""

# --- Детальный список установленного ПО ---
echo "📦 Установленные компоненты:"

# Функция для вывода версии пакета, если установлен
print_version() {
    local pkg=$1
    local version_cmd=$2
    local version=$($version_cmd 2>/dev/null | head -n1)
    if [ -n "$version" ]; then
        echo "   - $pkg: $version"
    else
        echo "   - $pkg (установлен, версия не определена)"
    fi
}

# Общие системные утилиты (всегда есть)
echo "   - Базовые утилиты: curl, wget, git, ufw, fail2ban, cron, openssl, python3, unattended-upgrades"

# Веб-стек (если установлен)
if is_pkg_installed nginx || is_pkg_installed php8.3-fpm || is_pkg_installed mariadb-server; then
    echo "   --- Веб-стек ---"
    if is_pkg_installed nginx; then
        print_version "Nginx" "nginx -v 2>&1 | cut -d '/' -f2"
    fi
    if is_pkg_installed mariadb-server; then
        print_version "MariaDB" "mariadb --version 2>/dev/null | awk '{print \$5}' | sed 's/,//'"
    fi
    if is_pkg_installed php8.3-fpm; then
        print_version "PHP" "php -v 2>/dev/null | head -n1 | cut -d ' ' -f2"
        echo "   - Расширения PHP: mysql, curl, xml, mbstring, zip, gd, intl, bcmath"
    fi
    if command -v composer &>/dev/null; then
        print_version "Composer" "composer --version --no-interaction 2>/dev/null | cut -d ' ' -f3"
    fi
    if command -v node &>/dev/null; then
        print_version "Node.js" "node -v 2>/dev/null"
    fi
fi

# FTP-сервер (цель 2)
if is_pkg_installed vsftpd; then
    echo "   --- FTP-сервер ---"
    print_version "vsftpd" "vsftpd -v 2>&1 | head -n1"
    echo "   - Пользователь: filestore (пароль сгенерирован, см. лог)"
fi

# Зависимости 3x-ui (цели 3 или 4)
if is_pkg_installed sqlite3 || is_pkg_installed jq || is_pkg_installed socat; then
    echo "   --- Зависимости 3x-ui ---"
    for pkg in sqlite3 jq socat; do
        if is_pkg_installed "$pkg"; then
            print_version "$pkg" "$pkg --version 2>&1 | head -n1"
        fi
    done
fi

# Отдельная установка MariaDB (цель 5 без веб-стека)
if is_pkg_installed mariadb-server && [ "$NEED_WEB" = false ]; then
    echo "   --- База данных (отдельно) ---"
    print_version "MariaDB" "mariadb --version 2>/dev/null | awk '{print \$5}' | sed 's/,//'"
fi

echo ""
echo "🔐 Файл конфигурации: $ENV_FILE"
echo "📄 Лог выполнения: $LOG_FILE"

if [ -n "${DB_ROOT_PASSWORD:-}" ]; then
    echo "🔑 Пароль root MariaDB сохранён в /root/.my.cnf"
fi

echo ""
echo "📌 Рекомендации по следующим шагам:"
if [[ " $INSTALLED_PURPOSES " =~ " 1 " ]] || [[ " $INSTALLED_PURPOSES " =~ " 4 " ]]; then
    echo "   - Для установки сайта и получения SSL выполните скрипт site.sh"
fi
if [[ " $INSTALLED_PURPOSES " =~ " 2 " ]]; then
    echo "   - FTP-сервер доступен по адресу сервера, порт 21. Пользователь: filestore (пароль сгенерирован, см. лог)"
fi
if [[ " $INSTALLED_PURPOSES " =~ " 3 " ]] || [[ " $INSTALLED_PURPOSES " =~ " 4 " ]]; then
    echo "   - Для установки панели 3x-ui выполните отдельный скрипт (не входит в текущий комплект)"
fi
if [[ " $INSTALLED_PURPOSES " =~ " 5 " ]] && [ "$NEED_WEB" = false ]; then
    echo "   - База данных MariaDB готова. Пароль root сохранён в /root/.my.cnf"
fi
echo "================================================================="

log "=== init.sh успешно завершён ==="
exit 0