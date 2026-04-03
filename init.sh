#!/bin/bash
# =====================================================================
# init.sh - Базовая подготовка сервера (обязательный для всех)
# Версия: 3.0
# Выполняет обновление системы, установку базового ПО,
# настройку безопасности (UFW, fail2ban), установку выбранных компонентов
# (веб-стек, FTP, 3x-ui, БД) и подготовку инфраструктуры бэкапа.
# =====================================================================

set -euo pipefail

# Подключаем общую библиотеку
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    echo -e "\033[0;31mОшибка: файл lib.sh не найден в директории $SCRIPT_DIR.\033[0m"
    exit 1
fi
source "$SCRIPT_DIR/lib.sh"

# Инициализация флага принудительной перезаписи
init_force_mode "$@"

# --- Константы ---
ENV_FILE="$SCRIPT_DIR/.env"
APT_OPTS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
PHP_VERSION="8.3"
BACKUP_DIR="/var/backups"
BACKUP_SCRIPT="/usr/local/bin/backup.sh"

# --- Проверка прав root ---
if [[ $EUID -ne 0 ]]; then
    log "${RED}Ошибка: скрипт должен запускаться от root (или с sudo).${NC}"
    exit 1
fi

# --- Загрузка существующего .env или создание нового ---
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
    log_only ".env загружен."
else
    touch "$ENV_FILE"
    log_only "Создан новый .env."
fi

# --- Определение уже установленных целей ---
INSTALLED_PURPOSES="${INSTALLED_PURPOSES:-}"
mapfile -t INSTALLED_ARRAY < <(echo "$INSTALLED_PURPOSES" | tr ',' '\n' | grep -v '^$')
log_only "Уже установленные цели: ${INSTALLED_PURPOSES:-нет}"

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
    log "${YELLOW}=== Выбор назначения сервера ===${NC}"
    if [ -n "$INSTALLED_PURPOSES" ]; then
        log "✅ Уже установлены:"
        for p in "${INSTALLED_ARRAY[@]}"; do
            log "   - ${PURPOSE_NAMES[$p]}"
        done
        echo ""
        log "Доступные для добавления:"
    else
        log "Доступные варианты:"
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
        log "${GREEN}Все цели уже установлены. Выход.${NC}"
        exit 0
    fi

    echo ""
    read -p "Введите номера целей через запятую (например, 1,3) или 0 для выхода: " choice
    choice=$(echo "$choice" | tr -d ' ')
    
    if [ "$choice" = "0" ]; then
        log "Выход по запросу пользователя."
        exit 0
    fi

    IFS=',' read -ra SELECTED <<< "$choice"

    # Валидация
    local valid=true
    for sel in "${SELECTED[@]}"; do
        if ! [[ "$sel" =~ ^[1-6]$ ]] || is_purpose_installed "$sel"; then
            log "${RED}Ошибка: номер '$sel' недопустим или уже установлен.${NC}"
            valid=false
            break
        fi
    done
    if [ "$valid" = false ]; then
        log "Пожалуйста, повторите ввод."
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
    mapfile -t UNIQUE_SELECTED < <(printf "%s\n" "${expanded[@]}" | sort -u)
    SELECTED=("${UNIQUE_SELECTED[@]}")

    # Сохраняем исходные номера (без расширения) для .env
    ORIGINAL_SELECTED=("${SELECTED[@]}")
    if [[ " ${SELECTED[@]} " =~ " 1 " ]] && [[ " ${SELECTED[@]} " =~ " 3 " ]]; then
        if [[ " ${choice//,/ } " =~ " 4 " ]]; then
            ORIGINAL_SELECTED=("4")
        fi
    fi
}

# Вспомогательная функция: проверка установки цели (по номеру)
is_purpose_installed() {
    local needle="$1"
    local installed="${INSTALLED_PURPOSES:-}"
    [[ ",$installed," == *",$needle,"* ]]
}

# Добавление цели в список установленных
add_installed_purpose() {
    local new_purpose="$1"
    local installed="${INSTALLED_PURPOSES:-}"
    if [[ -z "$installed" ]]; then
        INSTALLED_PURPOSES="$new_purpose"
    elif ! is_purpose_installed "$new_purpose"; then
        INSTALLED_PURPOSES="$installed,$new_purpose"
    fi
}

# --- Основной процесс ---
select_purposes

# --- Подсчёт шагов ---
TOTAL_STEPS=10
CURRENT_STEP=0

next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress $CURRENT_STEP $TOTAL_STEPS "$1"
}

# ----------------------------------------------------------------------
# Шаг 1: Подготовка системы (обновление, базовая настройка)
# ----------------------------------------------------------------------
next_step "Подготовка системы: обновление пакетов и настройка окружения"
export DEBIAN_FRONTEND=noninteractive

apt update -y >> "$LOG_FILE" 2>&1
apt upgrade $APT_OPTS >> "$LOG_FILE" 2>&1
timedatectl set-timezone Europe/Moscow >> "$LOG_FILE" 2>&1 || true

# Базовый набор пакетов (общий для всех целей)
BASE_PKGS=(curl wget git ufw fail2ban cron openssl python3 unattended-upgrades)
for pkg in "${BASE_PKGS[@]}"; do
    if ! is_pkg_installed "$pkg"; then
        apt install $APT_OPTS "$pkg" >> "$LOG_FILE" 2>&1
        log_only "Установлен пакет: $pkg"
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
log_only "Автоматические обновления безопасности настроены."

# ----------------------------------------------------------------------
# Шаг 2: Установка компонентов (в зависимости от выбранных целей)
# ----------------------------------------------------------------------
NEED_WEB=false
if [[ " ${SELECTED[@]} " =~ " 1 " ]] || [[ " ${SELECTED[@]} " =~ " 3 " ]]; then
    NEED_WEB=true
fi

if [ "$NEED_WEB" = true ]; then
    next_step "Установка веб-стека (Nginx, PHP, MariaDB)"

    # Nginx
    if ! is_pkg_installed nginx; then
        apt install $APT_OPTS nginx >> "$LOG_FILE" 2>&1
        log_only "Nginx установлен."
    fi

    # MariaDB
    if ! is_pkg_installed mariadb-server; then
        apt install $APT_OPTS mariadb-server mariadb-client >> "$LOG_FILE" 2>&1
        log_only "MariaDB установлена."
    fi

    # Генерация пароля для root MariaDB, если нет
    if [ -z "${DB_ROOT_PASSWORD:-}" ]; then
        DB_ROOT_PASSWORD=$(openssl rand -base64 18)
        echo "DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD" >> "$ENV_FILE"
        log_only "Сгенерирован пароль для root MariaDB."
    fi

    # Автоматическая настройка безопасности MariaDB
    TEMP_SQL="/tmp/mysql_secure.sql"
    cat > "$TEMP_SQL" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

    if mysql -u root < "$TEMP_SQL" >> "$LOG_FILE" 2>&1; then
        log_only "MariaDB защищена (первый запуск)."
    else
        mysql -u root -p"$DB_ROOT_PASSWORD" < "$TEMP_SQL" >> "$LOG_FILE" 2>&1
        log_only "MariaDB защищена (с использованием пароля)."
    fi
    rm -f "$TEMP_SQL"

    # Сохраняем пароль в /root/.my.cnf
    cat > /root/.my.cnf <<EOF
[client]
user=root
password="$DB_ROOT_PASSWORD"
EOF
    chmod 600 /root/.my.cnf
    log_only "Пароль root MariaDB сохранён в /root/.my.cnf."

    # PHP 8.3
    PHP_PKGS="php8.3-fpm php8.3-mysql php8.3-curl php8.3-xml php8.3-mbstring php8.3-zip php8.3-gd php8.3-intl php8.3-bcmath"
    if ! is_pkg_installed php8.3-fpm; then
        apt install $APT_OPTS $PHP_PKGS >> "$LOG_FILE" 2>&1
        log_only "PHP 8.3 и расширения установлены."
    fi

    # Настройка PHP-FPM
    POOL_CONF="/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"
    if [ -f "$POOL_CONF" ]; then
        cp "$POOL_CONF" "$POOL_CONF.bak" 2>/dev/null || true
        sed -i 's/^pm = .*/pm = dynamic/' "$POOL_CONF"
        sed -i 's/^pm.max_children = .*/pm.max_children = 20/' "$POOL_CONF"
        sed -i 's/^pm.start_servers = .*/pm.start_servers = 5/' "$POOL_CONF"
        sed -i 's/^pm.min_spare_servers = .*/pm.min_spare_servers = 3/' "$POOL_CONF"
        sed -i 's/^pm.max_spare_servers = .*/pm.max_spare_servers = 10/' "$POOL_CONF"
        log_only "PHP-FPM настроен."
    fi

    systemctl enable php$PHP_VERSION-fpm >> "$LOG_FILE" 2>&1 || true
    systemctl restart php$PHP_VERSION-fpm >> "$LOG_FILE" 2>&1 || true

    # Composer и Node.js (полезны для сайта)
    if ! command -v composer &>/dev/null; then
        php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" >> "$LOG_FILE" 2>&1
        php composer-setup.php --install-dir=/usr/local/bin --filename=composer >> "$LOG_FILE" 2>&1
        rm composer-setup.php
        log_only "Composer установлен глобально."
    fi
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >> "$LOG_FILE" 2>&1
        apt install $APT_OPTS nodejs >> "$LOG_FILE" 2>&1
        log_only "Node.js установлен."
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
    log_only "Веб-стек полностью настроен."
fi

# ----------------------------------------------------------------------
# Шаг 3: Установка FTP (цель 2)
# ----------------------------------------------------------------------
if [[ " ${SELECTED[@]} " =~ " 2 " ]]; then
    next_step "Установка FTP-сервера (vsftpd)"
    if ! is_pkg_installed vsftpd; then
        apt install $APT_OPTS vsftpd >> "$LOG_FILE" 2>&1
        log_only "vsftpd установлен."
    fi

    # Создание пользователя для хранилища
    if ! id filestore &>/dev/null; then
        useradd -m -d /home/filestore -s /bin/bash filestore
        FTP_PASSWORD=$(openssl rand -base64 12)
        echo "filestore:$FTP_PASSWORD" | chpasswd
        echo "FTP_PASSWORD=$FTP_PASSWORD" >> "$ENV_FILE"
        log_only "Пользователь filestore создан, пароль сохранён в .env."
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
    log_only "FTP настроен."
fi

# ----------------------------------------------------------------------
# Шаг 4: Подготовка окружения для 3x-ui (цели 3 или 4)
# ----------------------------------------------------------------------
if [[ " ${SELECTED[@]} " =~ " 3 " ]]; then
    next_step "Подготовка окружения для 3x-ui"
    DEP_PKGS=(sqlite3 jq socat)
    for pkg in "${DEP_PKGS[@]}"; do
        if ! is_pkg_installed "$pkg"; then
            apt install $APT_OPTS "$pkg" >> "$LOG_FILE" 2>&1
            log_only "Установлен пакет: $pkg"
        fi
    done

    if ! id xui &>/dev/null; then
        useradd -m -s /bin/bash xui
        log_only "Пользователь xui создан."
    fi
    mkdir -p /opt/3x-ui
    log_only "Окружение 3x-ui подготовлено (панель не установлена, требуется vpn.sh)."
fi

# ----------------------------------------------------------------------
# Шаг 5: Установка только БД (цель 5, если не была установлена ранее)
# ----------------------------------------------------------------------
if [[ " ${SELECTED[@]} " =~ " 5 " ]] && [ "$NEED_WEB" = false ]; then
    next_step "Установка MariaDB (только БД)"
    if ! is_pkg_installed mariadb-server; then
        apt install $APT_OPTS mariadb-server mariadb-client >> "$LOG_FILE" 2>&1
        log_only "MariaDB установлена."
    fi

    if [ -z "${DB_ROOT_PASSWORD:-}" ]; then
        DB_ROOT_PASSWORD=$(openssl rand -base64 18)
        echo "DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD" >> "$ENV_FILE"
        log_only "Сгенерирован пароль для root MariaDB."
    fi

    # mysql_secure_installation
    TEMP_SQL="/tmp/mysql_secure.sql"
    cat > "$TEMP_SQL" <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

    if mysql -u root < "$TEMP_SQL" >> "$LOG_FILE" 2>&1; then
        log_only "MariaDB защищена (первый запуск)."
    else
        mysql -u root -p"$DB_ROOT_PASSWORD" < "$TEMP_SQL" >> "$LOG_FILE" 2>&1
        log_only "MariaDB защищена (с использованием пароля)."
    fi
    rm -f "$TEMP_SQL"

    cat > /root/.my.cnf <<EOF
[client]
user=root
password="$DB_ROOT_PASSWORD"
EOF
    chmod 600 /root/.my.cnf
    log_only "Пароль root MariaDB сохранён в /root/.my.cnf."
fi

# ----------------------------------------------------------------------
# Шаг 6: Настройка файервола (UFW)
# ----------------------------------------------------------------------
next_step "Настройка файервола (UFW)"
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
ufw --force enable >> "$LOG_FILE" 2>&1
log_only "UFW настроен."

# ----------------------------------------------------------------------
# Шаг 7: Настройка fail2ban
# ----------------------------------------------------------------------
next_step "Настройка fail2ban"
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
log_only "fail2ban настроен."

# ----------------------------------------------------------------------
# Шаг 8: Системные лимиты и настройка резервного копирования
# ----------------------------------------------------------------------
next_step "Настройка системных лимитов и бэкапа"
if ! grep -q "fs.file-max" /etc/sysctl.conf; then
    echo "fs.file-max = 65535" >> /etc/sysctl.conf
    sysctl -p >> "$LOG_FILE" 2>&1
    log_only "Лимит файлов увеличен."
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
    log_only "Cron-задание для бэкапа добавлено."
fi

# ----------------------------------------------------------------------
# Шаг 9: Сохранение выбранных целей в .env
# ----------------------------------------------------------------------
next_step "Сохранение выбранных целей в .env"
for new_purpose in "${ORIGINAL_SELECTED[@]}"; do
    add_installed_purpose "$new_purpose"
done

# Обновляем .env с актуальными переменными
{
    echo "# Файл конфигурации, созданный init.sh"
    echo "INSTALLED_PURPOSES=$INSTALLED_PURPOSES"
    [ -n "${DB_ROOT_PASSWORD:-}" ] && echo "DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD"
    [ -n "${FTP_PASSWORD:-}" ] && echo "FTP_PASSWORD=$FTP_PASSWORD"
} >> "$ENV_FILE"
log_only ".env обновлён, установленные цели: $INSTALLED_PURPOSES"

# ----------------------------------------------------------------------
# Шаг 10: Итоговый отчёт
# ----------------------------------------------------------------------
next_step "Завершение и вывод информации"
echo ""
log "${GREEN}======================================================"
log "${GREEN}✅ Инициализация сервера успешно завершена!${NC}"
log "${GREEN}======================================================"
echo ""
log "📦 Установленные компоненты:"
for p in $(echo "$INSTALLED_PURPOSES" | tr ',' ' '); do
    log "   - ${PURPOSE_NAMES[$p]}"
done
echo ""
log "🔐 Пароль root MariaDB сохранён в /root/.my.cnf"
if [ -n "${FTP_PASSWORD:-}" ]; then
    log "📁 FTP-пользователь: filestore, пароль: $FTP_PASSWORD"
fi
echo ""
log "📌 Рекомендации по следующим шагам:"
if [[ " $INSTALLED_PURPOSES " =~ " 1 " ]] || [[ " $INSTALLED_PURPOSES " =~ " 4 " ]]; then
    log "   - Запустите ./cms.sh для установки CMS и настройки домена."
fi
if [[ " $INSTALLED_PURPOSES " =~ " 3 " ]] || [[ " $INSTALLED_PURPOSES " =~ " 4 " ]]; then
    log "   - Для установки панели 3x-ui выполните ./vpn.sh."
fi
if [[ " $INSTALLED_PURPOSES " =~ " 2 " ]]; then
    log "   - FTP-сервер доступен по адресу сервера, порт 21."
fi
echo ""
log "📄 Лог выполнения: $LOG_FILE"
log "======================================================"

exit 0