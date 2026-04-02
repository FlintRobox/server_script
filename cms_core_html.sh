#!/bin/bash
# =====================================================================
# cms_core.sh - Ядро CMS (финальная версия, все ошибки исправлены)
# Создаёт рабочую админку с дашбордом, статистикой, посетителями,
# настройками, управлением пользователями.
# =====================================================================

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
LOG_FILE="/var/log/setup.log"
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
WEB_ROOT_BASE="/var/www"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# --- Функции логирования и выполнения ---
log_only() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
run_cmd() { log_only "Выполнение: $*"; "$@" >> "$LOG_FILE" 2>&1; }
show_progress() { local p=$(( ($1-1)*100/($2-1) )); echo "[${p}%] $3"; }

# --- Проверка прав ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: скрипт должен запускаться от root.${NC}" >&2
    exit 1
fi

# --- Загрузка .env ---
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
    log_only "Файл .env загружен."
else
    echo -e "${RED}Файл .env не найден. Сначала выполните site.sh.${NC}" >&2
    exit 1
fi

# --- Проверка обязательных переменных ---
: "${DOMAIN:?Переменная DOMAIN не задана в .env}"
: "${DB_NAME:?Переменная DB_NAME не задана в .env}"
: "${DB_USER:?Переменная DB_USER не задана в .env}"
: "${DB_PASSWORD:?Переменная DB_PASSWORD не задана в .env}"

SITE_DIR="${WEB_ROOT_BASE}/${DOMAIN}"
ADMIN_DIR="${SITE_DIR}/admin"

# --- Проверка наличия таблиц, созданных site.sh, и создание недостающих ---
echo "Проверка и создание необходимых таблиц в БД..."
mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" <<EOF 2>>"$LOG_FILE"
CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    login VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role ENUM('admin', 'editor', 'viewer') DEFAULT 'viewer',
    email VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS pages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    slug VARCHAR(100) UNIQUE NOT NULL,
    title VARCHAR(200) NOT NULL,
    content TEXT,
    meta_description VARCHAR(255),
    status ENUM('draft', 'published') DEFAULT 'draft',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS settings (
    \`key\` VARCHAR(100) PRIMARY KEY,
    value TEXT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS visits (
    id INT AUTO_INCREMENT PRIMARY KEY,
    visit_date DATE NOT NULL,
    visitor_ip VARCHAR(45),
    user_agent TEXT,
    page_url VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX (visit_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS server_stats (
    id INT AUTO_INCREMENT PRIMARY KEY,
    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    load_1min FLOAT,
    load_5min FLOAT,
    load_15min FLOAT,
    memory_total BIGINT,
    memory_used BIGINT,
    disk_total BIGINT,
    disk_used BIGINT,
    INDEX (recorded_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sessions (
    session_id VARCHAR(128) PRIMARY KEY,
    data TEXT,
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
EOF
log_only "Все таблицы проверены/созданы."

# --- Проверка существования config.php и добавление глобальной $pdo ---
CONFIG_FILE="$SITE_DIR/config.php"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Файл config.php не найден в $SITE_DIR. Запустите site.sh.${NC}" >&2
    exit 1
fi

if ! grep -q '^\$pdo = DB_CONNECTION;' "$CONFIG_FILE"; then
    echo -e "${YELLOW}В config.php не найдена глобальная переменная \$pdo. Добавляем...${NC}"
    echo '$pdo = DB_CONNECTION;' >> "$CONFIG_FILE"
    log_only "В config.php добавлена строка \$pdo = DB_CONNECTION;"
fi

# --- Подсчёт шагов ---
TOTAL_STEPS=18
CURRENT_STEP=0

next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    show_progress $CURRENT_STEP $TOTAL_STEPS "$1"
}

# --- Функция для безопасного создания файла с проверкой синтаксиса ---
create_php_file() {
    local file="$1"
    local backup_ext=".backup.$(date +%Y%m%d%H%M%S)"
    if [[ -f "$file" ]]; then
        cp "$file" "$file$backup_ext"
        log_only "Создана резервная копия $file$backup_ext"
    fi
    mkdir -p "$(dirname "$file")"
    cat > "$file"
    log_only "Файл $file создан/обновлён."

    if ! php -l "$file" >> "$LOG_FILE" 2>&1; then
        echo -e "${RED}КРИТИЧЕСКАЯ ОШИБКА: Файл $file содержит синтаксическую ошибку.${NC}" >&2
        echo "Проверьте его содержимое вручную. Резервная копия: $file$backup_ext" >&2
        exit 1
    fi
}

# ----------------------------------------------------------------------
next_step "Создание структуры административной панели"
mkdir -p "$ADMIN_DIR"/{css,js,includes,api}
log_only "Директории админки созданы."

# ----------------------------------------------------------------------
next_step "Создание файла функций (functions.php)"
create_php_file "$ADMIN_DIR/includes/functions.php" <<'EOF'
<?php
function getSetting($key, $default = '') {
    global $pdo;
    static $settings = null;
    if ($settings === null) {
        $stmt = $pdo->query("SELECT `key`, `value` FROM settings");
        $settings = $stmt->fetchAll(PDO::FETCH_KEY_PAIR);
    }
    return $settings[$key] ?? $default;
}
EOF

# ----------------------------------------------------------------------
next_step "Создание файла аутентификации (auth.php)"
create_php_file "$ADMIN_DIR/includes/auth.php" <<'EOF'
<?php
session_start();
require_once __DIR__ . '/../../config.php';
require_once __DIR__ . '/functions.php';

function isLoggedIn() {
    return isset($_SESSION["user_id"]);
}

function requireLogin() {
    if (!isLoggedIn()) {
        header("Location: /admin/login.php");
        exit;
    }
}

function isAdmin() {
    return isset($_SESSION["role"]) && $_SESSION["role"] === "admin";
}

function requireAdmin() {
    requireLogin();
    if (!isAdmin()) {
        die("Доступ запрещён.");
    }
}

function currentUser() {
    global $pdo;
    if (!isset($_SESSION["user_id"])) return null;
    $stmt = $pdo->prepare("SELECT * FROM users WHERE id = ?");
    $stmt->execute([$_SESSION["user_id"]]);
    return $stmt->fetch(PDO::FETCH_ASSOC);
}
EOF

# ----------------------------------------------------------------------
next_step "Создание страницы входа (login.php)"
create_php_file "$ADMIN_DIR/login.php" <<'EOF'
<?php
session_start();
require_once __DIR__ . '/../config.php';

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $login = $_POST["login"] ?? "";
    $password = $_POST["password"] ?? "";

    $stmt = $pdo->prepare("SELECT * FROM users WHERE login = ?");
    $stmt->execute([$login]);
    $user = $stmt->fetch(PDO::FETCH_ASSOC);

    if ($user && password_verify($password, $user["password_hash"])) {
        $_SESSION["user_id"] = $user["id"];
        $_SESSION["role"] = $user["role"];
        header("Location: /admin/");
        exit;
    } else {
        $error = "Неверный логин или пароль";
    }
}
?>
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Вход в панель управления</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="/admin/css/admin.css">
    <style>
        body { display: flex; align-items: center; height: 100vh; }
        .login-form { max-width: 400px; margin: 0 auto; background: var(--card-bg); padding: 30px; border-radius: var(--border-radius); border: 2px solid var(--accent-gold); }
    </style>
</head>
<body>
    <div class="container">
        <div class="login-form">
            <h2 class="text-center mb-4">Вход в панель управления</h2>
            <?php if (isset($error)): ?>
                <div class="alert alert-danger"><?= htmlspecialchars($error) ?></div>
            <?php endif; ?>
            <form method="post">
                <div class="mb-3">
                    <label for="login" class="form-label">Логин</label>
                    <input type="text" class="form-control" id="login" name="login" required>
                </div>
                <div class="mb-3">
                    <label for="password" class="form-label">Пароль</label>
                    <input type="password" class="form-control" id="password" name="password" required>
                </div>
                <button type="submit" class="btn btn-primary w-100">Войти</button>
            </form>
        </div>
    </div>
</body>
</html>
EOF

# ----------------------------------------------------------------------
next_step "Создание выхода (logout.php)"
create_php_file "$ADMIN_DIR/logout.php" <<'EOF'
<?php
session_start();
session_destroy();
header("Location: /admin/login.php");
exit;
EOF

# ----------------------------------------------------------------------
next_step "Создание дашборда (index.php)"
STATUS_EXISTS=$(mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -N -e "SHOW COLUMNS FROM pages LIKE 'status'" 2>/dev/null | wc -l)
if [[ $STATUS_EXISTS -gt 0 ]]; then
    PAGES_QUERY="SELECT COUNT(*) FROM pages WHERE status='published'"
else
    PAGES_QUERY="SELECT COUNT(*) FROM pages"
fi

create_php_file "$ADMIN_DIR/index.php" <<EOF
<?php
require_once "includes/auth.php";
requireLogin();
\$site_name = getSetting("site_name", SITE_NAME);
\$pageTitle = "Дашборд";
?>
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars(\$site_name) ?> | <?= \$pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= \$pageTitle ?></h1>
                </div>

                <div class="row">
                    <?php
                    \$load = sys_getloadavg();
                    \$cpu_load = \$load[0] ?? 0;

                    \$meminfo = file_get_contents("/proc/meminfo");
                    preg_match("/MemTotal:\s+(\d+)/", \$meminfo, \$matches);
                    \$mem_total = \$matches[1] ?? 0;
                    preg_match("/MemAvailable:\s+(\d+)/", \$meminfo, \$matches);
                    \$mem_avail = \$matches[1] ?? 0;
                    \$mem_used_percent = \$mem_total ? round((\$mem_total - \$mem_avail) / \$mem_total * 100, 1) : 0;

                    \$disk_total = disk_total_space("/");
                    \$disk_free = disk_free_space("/");
                    \$disk_used_percent = \$disk_total ? round((\$disk_total - \$disk_free) / \$disk_total * 100, 1) : 0;

                    \$stmt = \$pdo->query("$PAGES_QUERY");
                    \$pages_count = \$stmt->fetchColumn();

                    \$stmt = \$pdo->prepare("SELECT COUNT(*) FROM visits WHERE DATE(visit_date) = CURDATE()");
                    \$stmt->execute();
                    \$visits_today = \$stmt->fetchColumn();
                    ?>
                    <div class="col-md-3 mb-3">
                        <div class="card text-white bg-primary">
                            <div class="card-body">
                                <h5 class="card-title"><i class="bi bi-cpu"></i> CPU Load</h5>
                                <p class="display-6"><?= \$cpu_load ?></p>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-3 mb-3">
                        <div class="card text-white bg-success">
                            <div class="card-body">
                                <h5 class="card-title"><i class="bi bi-memory"></i> RAM</h5>
                                <p class="display-6"><?= \$mem_used_percent ?>%</p>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-3 mb-3">
                        <div class="card text-white bg-warning">
                            <div class="card-body">
                                <h5 class="card-title"><i class="bi bi-hdd"></i> Диск</h5>
                                <p class="display-6"><?= \$disk_used_percent ?>%</p>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-3 mb-3">
                        <div class="card text-white bg-info">
                            <div class="card-body">
                                <h5 class="card-title"><i class="bi bi-file-text"></i> Страниц</h5>
                                <p class="display-6"><?= \$pages_count ?></p>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="row mt-4">
                    <div class="col-md-12">
                        <div class="card">
                            <div class="card-header">
                                <i class="bi bi-bar-chart-line"></i> Посещаемость за последние 7 дней
                            </div>
                            <div class="card-body">
                                <canvas id="visitsChart" style="height: 300px;"></canvas>
                            </div>
                        </div>
                    </div>
                </div>

                <div class="row mt-4">
                    <div class="col-md-12">
                        <div class="card">
                            <div class="card-header">
                                <i class="bi bi-clock-history"></i> Последние 5 посещений
                            </div>
                            <div class="card-body">
                                <table class="table table-sm">
                                    <thead>
                                        32<th>Время</th>
                                            <th>IP</th>
                                            <th>Страница</th>
                                            <th>User Agent</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        <?php
                                        \$stmt = \$pdo->query("SELECT * FROM visits ORDER BY created_at DESC LIMIT 5");
                                        while (\$row = \$stmt->fetch(PDO::FETCH_ASSOC)): ?>
                                        <tr>
                                            <td><?= htmlspecialchars(\$row["created_at"]) ?></td>
                                            <td><?= htmlspecialchars(\$row["visitor_ip"]) ?></td>
                                            <td><?= htmlspecialchars(\$row["page_url"]) ?></td>
                                            <td><?= htmlspecialchars(substr(\$row["user_agent"], 0, 50)) ?>…</td>
                                        </tr>
                                        <?php endwhile; ?>
                                    </tbody>
                                </table>
                            </div>
                        </div>
                    </div>
                </div>
            </main>
        </div>
    </div>

    <script>
    fetch("/admin/api/visits_last_7.php")
        .then(res => res.json())
        .then(data => {
            new Chart(document.getElementById("visitsChart"), {
                type: "line",
                data: {
                    labels: data.labels,
                    datasets: [{
                        label: "Посещения",
                        data: data.values,
                        borderColor: "rgb(75, 192, 192)",
                        tension: 0.1
                    }]
                }
            });
        });
    </script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# ----------------------------------------------------------------------
next_step "Создание API для графика посещений"
create_php_file "$ADMIN_DIR/api/visits_last_7.php" <<'EOF'
<?php
require_once __DIR__ . '/../../config.php';

$stmt = $pdo->query("
    SELECT DATE(visit_date) as day, COUNT(*) as cnt
    FROM visits
    WHERE visit_date >= DATE_SUB(CURDATE(), INTERVAL 6 DAY)
    GROUP BY day
    ORDER BY day
");
$data = ["labels" => [], "values" => []];
while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $data["labels"][] = $row["day"];
    $data["values"][] = (int)$row["cnt"];
}
header("Content-Type: application/json");
echo json_encode($data);
EOF

# ----------------------------------------------------------------------
next_step "Создание общего шаблона (header, sidebar)"
create_php_file "$ADMIN_DIR/includes/header.php" <<'EOF'
<?php
if (!isset($pageTitle)) $pageTitle = "Админка";
$current_user = currentUser();
$site_name = getSetting("site_name", SITE_NAME);
?>
<header class="navbar navbar-dark sticky-top bg-dark flex-md-nowrap p-0 shadow">
    <a class="navbar-brand col-md-3 col-lg-2 me-0 px-3" href="/admin/"><?= htmlspecialchars($site_name) ?></a>
    <button class="navbar-toggler position-absolute d-md-none collapsed" type="button" data-bs-toggle="collapse" data-bs-target="#sidebarMenu">
        <span class="navbar-toggler-icon"></span>
    </button>
    <div class="w-100"></div>
    <div class="navbar-nav">
        <div class="nav-item text-nowrap">
            <span class="nav-link px-3 text-white"><?= htmlspecialchars($current_user["login"] ?? "") ?></span>
        </div>
    </div>
</header>
EOF

create_php_file "$ADMIN_DIR/includes/sidebar.php" <<'EOF'
<?php
$current_page = basename($_SERVER["PHP_SELF"]);
?>
<nav id="sidebarMenu" class="col-md-3 col-lg-2 d-md-block bg-light sidebar collapse">
    <div class="position-sticky pt-3">
        <ul class="nav flex-column">
            <li class="nav-item">
                <a class="nav-link <?= $current_page == "index.php" ? "active" : "" ?>" href="/admin/">
                    <i class="bi bi-speedometer2"></i> Дашборд
                </a>
            </li>
            <?php if (isAdmin()): ?>
            <li class="nav-item">
                <a class="nav-link <?= $current_page == "users.php" ? "active" : "" ?>" href="/admin/users.php">
                    <i class="bi bi-people"></i> Пользователи
                </a>
            </li>
            <?php endif; ?>
            <li class="nav-item">
                <a class="nav-link <?= $current_page == "stats.php" ? "active" : "" ?>" href="/admin/stats.php">
                    <i class="bi bi-graph-up"></i> Статистика сервера
                </a>
            </li>
            <li class="nav-item">
                <a class="nav-link <?= $current_page == "visitors.php" ? "active" : "" ?>" href="/admin/visitors.php">
                    <i class="bi bi-eye"></i> Посетители
                </a>
            </li>
            <li class="nav-item">
                <a class="nav-link <?= $current_page == "settings.php" ? "active" : "" ?>" href="/admin/settings.php">
                    <i class="bi bi-gear"></i> Настройки
                </a>
            </li>
            <li class="nav-item">
                <a class="nav-link" href="/admin/logout.php">
                    <i class="bi bi-box-arrow-right"></i> Выход
                </a>
            </li>
        </ul>
    </div>
</nav>
EOF

# ----------------------------------------------------------------------
next_step "Создание страницы управления пользователями (users.php)"
create_php_file "$ADMIN_DIR/users.php" <<'EOF'
<?php
require_once "includes/auth.php";
requireAdmin();

$message = "";

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    if (isset($_POST["add"])) {
        $login = $_POST["login"];
        $password = $_POST["password"];
        $role = $_POST["role"];
        $email = $_POST["email"];

        $hash = password_hash($password, PASSWORD_DEFAULT);
        $stmt = $pdo->prepare("INSERT INTO users (login, password_hash, role, email) VALUES (?, ?, ?, ?)");
        if ($stmt->execute([$login, $hash, $role, $email])) {
            $message = "<div class=\"alert alert-success\">Пользователь добавлен</div>";
        } else {
            $message = "<div class=\"alert alert-danger\">Ошибка добавления</div>";
        }
    } elseif (isset($_POST["delete"])) {
        $id = $_POST["id"];
        $stmt = $pdo->prepare("DELETE FROM users WHERE id = ? AND role != 'admin'");
        if ($stmt->execute([$id])) {
            $message = "<div class=\"alert alert-success\">Пользователь удалён</div>";
        } else {
            $message = "<div class=\"alert alert-danger\">Ошибка удаления</div>";
        }
    }
}

$users = $pdo->query("SELECT * FROM users ORDER BY id")->fetchAll(PDO::FETCH_ASSOC);
$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = "Управление пользователями";
?>
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                </div>

                <?= $message ?>

                <div class="row">
                    <div class="col-md-6">
                        <h4>Существующие пользователи</h4>
                        <table class="table table-striped">
                            <thead>
                                32<th>ID</th>
                                    <th>Логин</th>
                                    <th>Роль</th>
                                    <th>Email</th>
                                    <th>Действия</th>
                                </tr>
                            </thead>
                            <tbody>
                                <?php foreach ($users as $user): ?>
                                <tr>
                                    <td><?= $user["id"] ?></td>
                                    <td><?= htmlspecialchars($user["login"]) ?></td>
                                    <td><?= $user["role"] ?></td>
                                    <td><?= htmlspecialchars($user["email"]) ?></td>
                                    <td>
                                        <?php if ($user["role"] !== "admin"): ?>
                                        <form method="post" style="display:inline;">
                                            <input type="hidden" name="id" value="<?= $user["id"] ?>">
                                            <button type="submit" name="delete" class="btn btn-sm btn-danger" onclick="return confirm('Удалить?')"><i class="bi bi-trash"></i></button>
                                        </form>
                                        <?php endif; ?>
                                    </td>
                                </tr>
                                <?php endforeach; ?>
                            </tbody>
                        </table>
                    </div>
                    <div class="col-md-6">
                        <h4>Добавить нового пользователя</h4>
                        <form method="post">
                            <div class="mb-3">
                                <label for="login" class="form-label">Логин</label>
                                <input type="text" class="form-control" id="login" name="login" required>
                            </div>
                            <div class="mb-3">
                                <label for="password" class="form-label">Пароль</label>
                                <input type="password" class="form-control" id="password" name="password" required>
                            </div>
                            <div class="mb-3">
                                <label for="role" class="form-label">Роль</label>
                                <select class="form-select" id="role" name="role">
                                    <option value="editor">Редактор</option>
                                    <option value="viewer">Наблюдатель</option>
                                </select>
                            </div>
                            <div class="mb-3">
                                <label for="email" class="form-label">Email</label>
                                <input type="email" class="form-control" id="email" name="email">
                            </div>
                            <button type="submit" name="add" class="btn btn-primary">Добавить</button>
                        </form>
                    </div>
                </div>
            </main>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# ----------------------------------------------------------------------
next_step "Создание страницы статистики сервера (stats.php)"
create_php_file "$ADMIN_DIR/stats.php" <<'EOF'
<?php
require_once "includes/auth.php";
requireLogin();

$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = "Статистика сервера";
?>
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                </div>

                <div class="row">
                    <div class="col-md-12 mb-4">
                        <canvas id="cpuChart" style="height: 200px;"></canvas>
                    </div>
                    <div class="col-md-12 mb-4">
                        <canvas id="ramChart" style="height: 200px;"></canvas>
                    </div>
                    <div class="col-md-12 mb-4">
                        <canvas id="diskChart" style="height: 200px;"></canvas>
                    </div>
                </div>
            </main>
        </div>
    </div>

    <script>
    fetch("/admin/api/server_stats.php?type=cpu")
        .then(res => res.json())
        .then(data => {
            new Chart(document.getElementById("cpuChart"), {
                type: "line",
                data: {
                    labels: data.labels,
                    datasets: [{
                        label: "Load Average (1 min)",
                        data: data.values,
                        borderColor: "rgb(255, 99, 132)",
                        tension: 0.1
                    }]
                },
                options: { responsive: true, maintainAspectRatio: false }
            });
        });

    fetch("/admin/api/server_stats.php?type=ram")
        .then(res => res.json())
        .then(data => {
            new Chart(document.getElementById("ramChart"), {
                type: "line",
                data: {
                    labels: data.labels,
                    datasets: [{
                        label: "Использование RAM (МБ)",
                        data: data.values,
                        borderColor: "rgb(54, 162, 235)",
                        tension: 0.1
                    }]
                },
                options: { responsive: true, maintainAspectRatio: false }
            });
        });

    fetch("/admin/api/server_stats.php?type=disk")
        .then(res => res.json())
        .then(data => {
            new Chart(document.getElementById("diskChart"), {
                type: "line",
                data: {
                    labels: data.labels,
                    datasets: [{
                        label: "Использование диска (ГБ)",
                        data: data.values,
                        borderColor: "rgb(75, 192, 192)",
                        tension: 0.1
                    }]
                },
                options: { responsive: true, maintainAspectRatio: false }
            });
        });
    </script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# ----------------------------------------------------------------------
next_step "Создание API для статистики сервера"
create_php_file "$ADMIN_DIR/api/server_stats.php" <<'EOF'
<?php
require_once __DIR__ . '/../../config.php';

$type = $_GET["type"] ?? "cpu";
$period = $_GET["period"] ?? 24;

$stmt = $pdo->prepare("
    SELECT recorded_at, load_1min, memory_used, disk_used
    FROM server_stats
    WHERE recorded_at >= DATE_SUB(NOW(), INTERVAL :period HOUR)
    ORDER BY recorded_at
");
$stmt->execute(["period" => $period]);
$rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

$labels = [];
$values = [];

foreach ($rows as $row) {
    $labels[] = date("H:i", strtotime($row["recorded_at"]));
    if ($type === "cpu") {
        $values[] = $row["load_1min"];
    } elseif ($type === "ram") {
        $values[] = round($row["memory_used"] / 1024 / 1024, 2);
    } elseif ($type === "disk") {
        $values[] = round($row["disk_used"] / 1024 / 1024 / 1024, 2);
    }
}

header("Content-Type: application/json");
echo json_encode(["labels" => $labels, "values" => $values]);
EOF

# ----------------------------------------------------------------------
next_step "Создание страницы посетителей (visitors.php)"
create_php_file "$ADMIN_DIR/visitors.php" <<'EOF'
<?php
require_once "includes/auth.php";
requireLogin();

$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = "Посетители";

$date_from = $_GET["date_from"] ?? date("Y-m-d", strtotime("-7 days"));
$date_to = $_GET["date_to"] ?? date("Y-m-d");
$ip_filter = $_GET["ip"] ?? "";

$sql = "SELECT * FROM visits WHERE visit_date BETWEEN :from AND :to";
$params = ["from" => $date_from, "to" => $date_to];
if ($ip_filter) {
    $sql .= " AND visitor_ip LIKE :ip";
    $params["ip"] = "%$ip_filter%";
}
$sql .= " ORDER BY created_at DESC";

$stmt = $pdo->prepare($sql);
$stmt->execute($params);
$visits = $stmt->fetchAll(PDO::FETCH_ASSOC);

$total_visits = count($visits);
$unique_ips = count(array_unique(array_column($visits, "visitor_ip")));
?>
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                </div>

                <div class="row mb-3">
                    <div class="col-md-3">
                        <div class="card text-white bg-info">
                            <div class="card-body">
                                <h5 class="card-title">Всего посещений</h5>
                                <p class="display-6"><?= $total_visits ?></p>
                            </div>
                        </div>
                    </div>
                    <div class="col-md-3">
                        <div class="card text-white bg-success">
                            <div class="card-body">
                                <h5 class="card-title">Уникальных IP</h5>
                                <p class="display-6"><?= $unique_ips ?></p>
                            </div>
                        </div>
                    </div>
                </div>

                <form method="get" class="row g-3 mb-4">
                    <div class="col-auto">
                        <label for="date_from" class="form-label">С</label>
                        <input type="date" class="form-control" id="date_from" name="date_from" value="<?= $date_from ?>">
                    </div>
                    <div class="col-auto">
                        <label for="date_to" class="form-label">По</label>
                        <input type="date" class="form-control" id="date_to" name="date_to" value="<?= $date_to ?>">
                    </div>
                    <div class="col-auto">
                        <label for="ip" class="form-label">IP</label>
                        <input type="text" class="form-control" id="ip" name="ip" placeholder="часть IP" value="<?= htmlspecialchars($ip_filter) ?>">
                    </div>
                    <div class="col-auto align-self-end">
                        <button type="submit" class="btn btn-primary">Фильтр</button>
                    </div>
                </form>

                <table class="table table-striped">
                    <thead>
                        32<th>Время</th>
                            <th>IP</th>
                            <th>Страница</th>
                            <th>User Agent</th>
                        </tr>
                    </thead>
                    <tbody>
                        <?php foreach ($visits as $v): ?>
                        <tr>
                            <td><?= $v["created_at"] ?></td>
                            <td><?= $v["visitor_ip"] ?></td>
                            <td><?= htmlspecialchars($v["page_url"]) ?></td>
                            <td><?= htmlspecialchars($v["user_agent"]) ?></td>
                        </tr>
                        <?php endforeach; ?>
                    </tbody>
                </table>
            </main>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# ----------------------------------------------------------------------
next_step "Создание страницы настроек (settings.php)"
create_php_file "$ADMIN_DIR/settings.php" <<'EOF'
<?php
require_once "includes/auth.php";
requireAdmin();

$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = "Настройки";

$settings = [];
$stmt = $pdo->query("SELECT `key`, `value` FROM settings");
while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
    $settings[$row["key"]] = $row["value"];
}

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $keys = ['site_name', 'admin_email', 'admin_theme', 'stats_retention'];
    foreach ($keys as $key) {
        if (isset($_POST[$key])) {
            $value = $_POST[$key];
            $pdo->prepare("INSERT INTO settings (`key`, `value`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)")
                ->execute([$key, $value]);
        }
    }
    $message = "<div class=\"alert alert-success\">Настройки сохранены</div>";
    $stmt = $pdo->query("SELECT `key`, `value` FROM settings");
    $settings = [];
    while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
        $settings[$row["key"]] = $row["value"];
    }
}
?>
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= htmlspecialchars($site_name) ?> | <?= $pageTitle ?></title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <link rel="stylesheet" href="/admin/css/admin.css">
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                </div>

                <?php if (isset($message)) echo $message; ?>

                <form method="post">
                    <div class="mb-3">
                        <label for="site_name" class="form-label">Название сайта</label>
                        <input type="text" class="form-control" id="site_name" name="site_name" value="<?= htmlspecialchars($settings["site_name"] ?? SITE_NAME ?? '') ?>">
                        <div class="form-text">Будет отображаться в заголовках страниц админки.</div>
                    </div>
                    <div class="mb-3">
                        <label for="admin_email" class="form-label">Email администратора</label>
                        <input type="email" class="form-control" id="admin_email" name="admin_email" value="<?= htmlspecialchars($settings["admin_email"] ?? '') ?>">
                        <div class="form-text">Для уведомлений (если будут реализованы).</div>
                    </div>
                    <div class="mb-3">
                        <label for="theme" class="form-label">Тема админки</label>
                        <select class="form-select" id="theme" name="admin_theme">
                            <option value="light" <?= ($settings["admin_theme"] ?? "light") == "light" ? "selected" : "" ?>>Светлая</option>
                            <option value="dark" <?= ($settings["admin_theme"] ?? "") == "dark" ? "selected" : "" ?>>Тёмная</option>
                        </select>
                        <div class="form-text">Выберите оформление панели управления.</div>
                    </div>
                    <div class="mb-3">
                        <label for="stats_retention" class="form-label">Срок хранения статистики (дней)</label>
                        <input type="number" class="form-control" id="stats_retention" name="stats_retention" value="<?= htmlspecialchars($settings["stats_retention"] ?? 30) ?>" min="1" max="365">
                        <div class="form-text">Записи старше этого количества дней будут автоматически удаляться.</div>
                    </div>
                    <button type="submit" name="save" class="btn btn-primary">Сохранить</button>
                </form>
            </main>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# ----------------------------------------------------------------------
next_step "Создание CSS-файла со стилями"
mkdir -p "$ADMIN_DIR/css"
cat > "$ADMIN_DIR/css/admin.css" <<'EOF'
/* admin.css — стили для админки в духе основного сайта */
@import url('https://fonts.googleapis.com/css2?family=Playfair+Display:wght@400;700&display=swap');

:root {
  --primary-dark: #1a3b4e;
  --primary-light: #0f5e7a;
  --accent-gold: #c9a96b;
  --accent-dark: #8a6d3b;
  --bg-light: #f0f7fa;
  --card-bg: rgba(255, 255, 255, 0.9);
  --text-dark: #2d3e4f;
  --border-radius: 20px;
}

body {
  background: linear-gradient(145deg, #f0f7fa 0%, #daeef5 100%);
  font-family: 'Segoe UI', Roboto, sans-serif;
  color: var(--text-dark);
  min-height: 100vh;
}

body.theme-dark {
  background: linear-gradient(145deg, #1e2f3a 0%, #0f2a33 100%);
  --card-bg: rgba(30, 40, 50, 0.9);
  --text-dark: #e0e8f0;
}

.navbar-dark.bg-dark {
  background: linear-gradient(135deg, var(--primary-dark), var(--primary-light)) !important;
  border-bottom: 3px solid var(--accent-gold);
  box-shadow: 0 4px 15px rgba(0,40,50,0.2);
}

.navbar-brand {
  font-family: 'Playfair Display', serif;
  font-weight: 700;
  font-size: 1.5rem;
  letter-spacing: 0.5px;
}

.sidebar {
  background: rgba(255,255,255,0.8) !important;
  backdrop-filter: blur(5px);
  border-right: 2px solid var(--accent-gold);
  box-shadow: 5px 0 15px rgba(0,0,0,0.05);
}

body.theme-dark .sidebar {
  background: rgba(30,40,50,0.8) !important;
  color: #e0e8f0;
}

.sidebar .nav-link {
  color: var(--primary-dark);
  font-weight: 500;
  border-radius: 10px;
  margin: 2px 8px;
  transition: all 0.3s;
}

body.theme-dark .sidebar .nav-link {
  color: #e0e8f0;
}

.sidebar .nav-link:hover,
.sidebar .nav-link.active {
  background: var(--accent-gold);
  color: var(--primary-dark);
  transform: translateX(5px);
  box-shadow: 0 2px 8px rgba(201,169,107,0.4);
}

.sidebar .nav-link i {
  margin-right: 8px;
  color: var(--primary-light);
}

.card {
  background: var(--card-bg);
  backdrop-filter: blur(3px);
  border: 2px solid var(--accent-gold);
  border-radius: var(--border-radius);
  box-shadow: 0 10px 20px rgba(0,30,40,0.1);
  transition: transform 0.3s, box-shadow 0.3s;
  overflow: hidden;
}

.card:hover {
  transform: translateY(-5px);
  box-shadow: 0 15px 30px rgba(0,50,60,0.2);
}

.card-header {
  background: rgba(201,169,107,0.15);
  border-bottom: 2px dotted var(--accent-gold);
  font-weight: 600;
  color: var(--primary-dark);
  font-family: 'Playfair Display', serif;
}

body.theme-dark .card-header {
  color: #e0e8f0;
}

.btn-primary {
  background: var(--primary-dark);
  border: 2px solid var(--accent-gold);
  color: white;
  border-radius: 40px;
  padding: 0.5rem 1.5rem;
  font-weight: 600;
  transition: all 0.3s;
}

.btn-primary:hover {
  background: var(--accent-gold);
  border-color: var(--primary-dark);
  color: var(--primary-dark);
  transform: scale(1.02);
  box-shadow: 0 5px 15px rgba(201,169,107,0.4);
}

.btn-danger {
  border-radius: 40px;
  border: 2px solid #dc3545;
}

.table {
  background: rgba(255,255,255,0.7);
  border-radius: 15px;
  overflow: hidden;
  border: 2px solid var(--accent-gold);
}

body.theme-dark .table {
  background: rgba(30,40,50,0.7);
  color: #e0e8f0;
}

.table thead {
  background: var(--primary-dark);
  color: white;
  font-family: 'Playfair Display', serif;
}

.table-striped tbody tr:nth-of-type(odd) {
  background-color: rgba(201,169,107,0.1);
}

h1, h2, h3, h4, .h1, .h2, .h3, .h4 {
  font-family: 'Playfair Display', serif;
  color: var(--primary-dark);
  border-bottom: 3px dotted var(--accent-gold);
  padding-bottom: 0.5rem;
  margin-bottom: 1.5rem;
}

body.theme-dark h1, body.theme-dark h2, body.theme-dark h3, body.theme-dark h4 {
  color: #e0e8f0;
}

@keyframes fadeIn {
  from { opacity: 0; transform: translateY(20px); }
  to { opacity: 1; transform: translateY(0); }
}

main {
  animation: fadeIn 0.6s ease-out;
}
EOF
log_only "CSS-файл создан/обновлён."

# ----------------------------------------------------------------------
next_step "Интеграция сбора статистики для статического сайта (index.html)"
TRACKER_PHP="$SITE_DIR/track.php"
TRACKER_JS="$SITE_DIR/js/tracker.js"

create_php_file "$TRACKER_PHP" <<'EOF'
<?php
require_once __DIR__ . "/config.php";

if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $ip = $_SERVER["HTTP_X_FORWARDED_FOR"] ?? $_SERVER["REMOTE_ADDR"] ?? "";
    $ua = $_SERVER["HTTP_USER_AGENT"] ?? "";
    $url = $_POST["url"] ?? $_SERVER["HTTP_REFERER"] ?? "";

    try {
        $stmt = $pdo->prepare("INSERT INTO visits (visit_date, visitor_ip, user_agent, page_url) VALUES (CURDATE(), ?, ?, ?)");
        $stmt->execute([$ip, $ua, $url]);
        http_response_code(204);
    } catch (Exception $e) {
        http_response_code(500);
    }
} else {
    http_response_code(405);
}
EOF

mkdir -p "$SITE_DIR/js"
create_php_file "$TRACKER_JS" <<'EOF'
// tracker.js
(function() {
    if (window._trackerInited) return;
    window._trackerInited = true;
    function trackVisit() {
        const url = window.location.pathname + window.location.search;
        const data = new URLSearchParams();
        data.append("url", url);
        navigator.sendBeacon("/track.php", data);
    }
    if (document.readyState === "complete") {
        trackVisit();
    } else {
        window.addEventListener("load", trackVisit);
    }
})();
EOF

if [[ -f "$SITE_DIR/index.html" ]] && ! grep -q "tracker.js" "$SITE_DIR/index.html"; then
    cp "$SITE_DIR/index.html" "$SITE_DIR/index.html.bak"
    sed -i 's|</body>|<script src="/js/tracker.js"></script>\n</body>|' "$SITE_DIR/index.html"
    log_only "Трекер добавлен в index.html"
fi

# ----------------------------------------------------------------------
next_step "Обновление cron-задания с учётом stats_retention"
CRON_SCRIPT="/usr/local/bin/collect_server_stats.sh"
if [[ -f "$CRON_SCRIPT" ]]; then
    cp "$CRON_SCRIPT" "$CRON_SCRIPT.bak"
fi

cat > "$CRON_SCRIPT" <<EOF
#!/bin/bash
LOG_FILE="/var/log/setup.log"
ENV_FILE="$ENV_FILE"

if [[ -f "\$ENV_FILE" ]]; then
    set -a
    source "\$ENV_FILE"
    set +a
else
    echo "Ошибка: .env не найден" >> "\$LOG_FILE"
    exit 1
fi

load=\$(awk '{print \$1}' /proc/loadavg)
mem_total=\$(grep MemTotal /proc/meminfo | awk '{print \$2}')
mem_avail=\$(grep MemAvailable /proc/meminfo | awk '{print \$2}')
mem_used=\$((mem_total - mem_avail))
disk_total=\$(df / | tail -1 | awk '{print \$2}')
disk_used=\$(df / | tail -1 | awk '{print \$3}')

mysql -u "\$DB_USER" -p"\$DB_PASSWORD" "\$DB_NAME" <<SQL 2>>"\$LOG_FILE"
INSERT INTO server_stats (load_1min, memory_total, memory_used, disk_total, disk_used)
VALUES (\$load, \$mem_total, \$mem_used, \$disk_total, \$disk_used);
SQL

retention=\$(mysql -u "\$DB_USER" -p"\$DB_PASSWORD" "\$DB_NAME" -N -e "SELECT value FROM settings WHERE key='stats_retention'" 2>/dev/null)
retention=\${retention:-30}
mysql -u "\$DB_USER" -p"\$DB_PASSWORD" "\$DB_NAME" -e "DELETE FROM visits WHERE visit_date < DATE_SUB(CURDATE(), INTERVAL \$retention DAY)" >> "\$LOG_FILE" 2>&1
mysql -u "\$DB_USER" -p"\$DB_PASSWORD" "\$DB_NAME" -e "DELETE FROM server_stats WHERE recorded_at < DATE_SUB(NOW(), INTERVAL \$retention DAY)" >> "\$LOG_FILE" 2>&1
EOF
chmod +x "$CRON_SCRIPT"
log_only "Cron-скрипт обновлён с поддержкой stats_retention."

CRON_JOB="*/5 * * * * root $CRON_SCRIPT > /dev/null 2>&1"
if ! grep -F "$CRON_SCRIPT" /etc/crontab >/dev/null; then
    echo "$CRON_JOB" >> /etc/crontab
    log_only "Cron-задание добавлено"
fi

# ----------------------------------------------------------------------
next_step "Обновление .env (добавление переменных по умолчанию)"
{
    echo "# Параметры для CMS (добавлено cms_core.sh)"
    echo "SITE_NAME=\"${SITE_NAME:-Мой сайт}\""
    echo "ADMIN_EMAIL=\"${ADMIN_EMAIL:-admin@example.com}\""
} >> "$ENV_FILE"
log_only ".env обновлён"

# ----------------------------------------------------------------------
next_step "Завершение: перезапуск служб и итоговый отчёт"
systemctl restart php8.3-fpm 2>/dev/null || systemctl restart php8.2-fpm 2>/dev/null || systemctl restart php-fpm 2>/dev/null || true
systemctl reload nginx 2>/dev/null || true

echo ""
echo "======================================================"
echo -e "${GREEN}✅ Ядро CMS успешно установлено/обновлено!${NC}"
echo "======================================================"
echo ""
echo "🌐 Административная панель доступна по адресу:"
echo "   https://${DOMAIN}/admin/"
echo ""
echo "🔐 Вход:"
echo "   Логин: admin"
echo "   Пароль: ${ADMIN_PASSWORD} (сохранён в .env)"
echo ""
echo "📊 Функционал:"
echo "   - Дашборд с графиками и метриками сервера"
echo "   - Управление пользователями (только для admin)"
echo "   - Детальная статистика сервера (CPU, RAM, диск) с графиками"
echo "   - Просмотр и фильтрация посещений"
echo "   - Настройки сайта (название, тема, срок хранения статистики)"
echo "   - Тёмная и светлая темы работают на всех страницах"
echo ""
if [[ -f "$SITE_DIR/index.html" ]]; then
    echo "📈 Для статического сайта (index.html) настроен JavaScript-трекер."
    echo "   Данные о посещениях отправляются на /track.php и сохраняются в БД."
fi
echo ""
echo "⏲️  Сбор метрик сервера запущен (каждые 5 минут)"
echo "   Автоматическая очистка старых записей согласно настройкам."
echo "📝 Все действия логируются в /var/log/setup.log"
echo ""
echo "======================================================"
echo -e "${YELLOW}Важно:${NC} защитите файл .env (chmod 600) и"
echo "при необходимости ограничьте доступ к админке по IP."
echo "======================================================"

log_only "=== $SCRIPT_NAME завершён успешно ==="
exit 0