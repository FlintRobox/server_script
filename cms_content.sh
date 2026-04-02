#!/bin/bash
# =====================================================================
# cms_content.sh - Управление контентом и файлами (CMS)
# Версия: 14.0 (универсальная: поддержка PHP и HTML, импорт в БД, роутер)
# =====================================================================

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
LOG_FILE="/var/log/setup.log"
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
WEB_ROOT_BASE="/var/www"
TINYMCE_VERSION="6.8.3"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Функции ---
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

table_exists() {
    mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SHOW TABLES LIKE '$1'" 2>/dev/null | grep -q "$1"
}

column_exists() {
    mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SHOW COLUMNS FROM $1 LIKE '$2'" 2>/dev/null | grep -q "$2"
}

# ----------------------------------------------------------------------
# Проверка и выдача прав БД (без глобальных прав)
# ----------------------------------------------------------------------
ensure_db_permissions() {
    echo -e "${YELLOW}Проверка и выдача прав пользователю $DB_USER...${NC}"
    local MYSQL_OPTS=""
    if [[ -f "/root/.my.cnf" ]]; then
        MYSQL_OPTS="--defaults-file=/root/.my.cnf"
    else
        echo -e "${RED}Файл /root/.my.cnf не найден.${NC}"
        exit 1
    fi
    mysql $MYSQL_OPTS -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
    mysql $MYSQL_OPTS -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
    mysql $MYSQL_OPTS -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
    mysql $MYSQL_OPTS -e "FLUSH PRIVILEGES;"
    if mysql -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1" &>/dev/null; then
        echo -e "${GREEN}Подключение работает.${NC}"
    else
        echo -e "${RED}Ошибка подключения.${NC}"
        exit 1
    fi
}

# ----------------------------------------------------------------------
# Добавление колонки template в таблицу pages
# ----------------------------------------------------------------------
add_template_column() {
    if ! column_exists "pages" "template"; then
        echo -e "${YELLOW}Добавление колонки template в pages...${NC}"
        mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "ALTER TABLE pages ADD COLUMN template VARCHAR(100) DEFAULT 'default';"
        log_only "Колонка template добавлена."
    fi
}

# ----------------------------------------------------------------------
# Создание таблицы files
# ----------------------------------------------------------------------
create_files_table() {
    local sql="CREATE TABLE IF NOT EXISTS files (
        id INT AUTO_INCREMENT PRIMARY KEY,
        original_name VARCHAR(255) NOT NULL,
        path VARCHAR(255) NOT NULL,
        size INT NOT NULL,
        type VARCHAR(100) NOT NULL,
        uploaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        uploaded_by INT NOT NULL,
        INDEX (uploaded_by),
        FOREIGN KEY (uploaded_by) REFERENCES users(id) ON DELETE CASCADE
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
    if ! table_exists "files"; then
        run_cmd mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "$sql"
        log_only "Таблица files создана."
    fi
}

# ----------------------------------------------------------------------
# Создание content_functions.php
# ----------------------------------------------------------------------
create_content_functions() {
    mkdir -p "$ADMIN_DIR/includes"
    cat > "$ADMIN_DIR/includes/content_functions.php" <<'EOF'
<?php
function getPageStatus($status) {
    return $status == "published" ? "Опубликовано" : "Черновик";
}
function getPageStatusBadge($status) {
    $class = $status == "published" ? "success" : "secondary";
    return "<span class=\"badge bg-{$class}\">" . getPageStatus($status) . "</span>";
}
function getPageTemplates() {
    $templates = [];
    $dir = __DIR__ . "/../../templates";
    if (is_dir($dir)) {
        foreach (glob($dir . "/*.php") as $file) {
            $templates[] = basename($file, ".php");
        }
    }
    if (empty($templates)) $templates[] = "default";
    return $templates;
}
function generateSlug($title) {
    $slug = preg_replace("/[^a-z0-9-]+/", "-", strtolower($title));
    $slug = trim($slug, "-");
    return $slug ?: "page";
}
EOF
    log_only "content_functions.php создан."
}

# ----------------------------------------------------------------------
# Создание роутера cms-router.php (единая точка входа)
# ----------------------------------------------------------------------
create_cms_router() {
    if [[ ! -f "$SITE_DIR/cms-router.php" ]]; then
        cat > "$SITE_DIR/cms-router.php" <<'EOF'
<?php
require_once __DIR__ . "/config.php";

$request = trim($_SERVER['REQUEST_URI'], '/');
if ($request === '') {
    $slug = 'index';
} else {
    $slug = $request;
}

// Сначала ищем страницу в БД
$stmt = $pdo->prepare("SELECT * FROM pages WHERE slug = ? AND status = 'published'");
$stmt->execute([$slug]);
$page = $stmt->fetch(PDO::FETCH_ASSOC);

if ($page) {
    $template = $page['template'] ?? 'default';
    $template_file = __DIR__ . "/templates/{$template}.php";
    if (file_exists($template_file)) {
        include $template_file;
    } else {
        http_response_code(404);
        echo "Шаблон не найден";
    }
} else {
    // Если в БД нет, пробуем отдать статический файл
    $file_path = __DIR__ . "/" . ($slug === 'index' ? 'index.html' : $slug . '.html');
    if (file_exists($file_path) && is_file($file_path)) {
        $ext = pathinfo($file_path, PATHINFO_EXTENSION);
        $mime = match($ext) {
            'html' => 'text/html',
            'css'  => 'text/css',
            'js'   => 'application/javascript',
            'jpg', 'jpeg' => 'image/jpeg',
            'png'  => 'image/png',
            'gif'  => 'image/gif',
            default => 'text/plain'
        };
        header("Content-Type: $mime");
        readfile($file_path);
    } else {
        http_response_code(404);
        echo "Страница не найдена";
    }
}
EOF
        log_only "cms-router.php создан."
    fi
}

# ----------------------------------------------------------------------
# Создание content.php (управление контентом)
# ----------------------------------------------------------------------
create_content_php() {
    cat > "$ADMIN_DIR/content.php" <<'EOF'
<?php
require_once __DIR__ . '/../config.php';
require_once "includes/auth.php";
requireLogin();
require_once "includes/content_functions.php";

$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = "Управление контентом";
$root_dir = __DIR__ . "/../";
$excluded_files = ['config.php', 'cms-router.php', 'index.php'];
$excluded_dirs = ['admin', 'uploads', 'core', 'templates', 'tinymce'];

$search = trim($_GET['search'] ?? '');
$order_by = $_GET['order_by'] ?? 'created_at';
$order_dir = strtoupper($_GET['order_dir'] ?? 'DESC');
$allowed_order = ['title', 'source', 'created_at'];
if (!in_array($order_by, $allowed_order)) $order_by = 'created_at';
$order_dir = ($order_dir === 'ASC') ? 'ASC' : 'DESC';

$db_pages = $pdo->query("SELECT id, title, slug, status, created_at, 'database' as source FROM pages ORDER BY created_at DESC")->fetchAll(PDO::FETCH_ASSOC);
$existing_slugs = array_column($db_pages, 'slug');

$file_pages = [];
$dir_handle = opendir($root_dir);
while ($entry = readdir($dir_handle)) {
    if ($entry == '.' || $entry == '..') continue;
    $full_path = $root_dir . $entry;
    if (is_dir($full_path)) continue;
    $ext = pathinfo($entry, PATHINFO_EXTENSION);
    $slug_without_ext = pathinfo($entry, PATHINFO_FILENAME);
    if (in_array($slug_without_ext, $existing_slugs)) continue;
    if (in_array($ext, ['php', 'html', 'htm']) && !in_array($entry, $excluded_files)) {
        $file_pages[] = [
            'id' => null,
            'title' => $slug_without_ext,
            'slug' => $entry,
            'status' => 'file',
            'created_at' => date("Y-m-d H:i:s", filemtime($full_path)),
            'source' => 'file'
        ];
    }
}
closedir($dir_handle);

if ($search) {
    $db_pages = array_filter($db_pages, function($item) use ($search) {
        return stripos($item['title'], $search) !== false;
    });
    $file_pages = array_filter($file_pages, function($item) use ($search) {
        return stripos($item['title'], $search) !== false;
    });
}

$all_pages = array_merge($db_pages, $file_pages);

usort($all_pages, function($a, $b) use ($order_by, $order_dir) {
    $val_a = $a[$order_by] ?? '';
    $val_b = $b[$order_by] ?? '';
    if ($order_by === 'created_at') {
        $val_a = strtotime($val_a);
        $val_b = strtotime($val_b);
    }
    if ($order_dir === 'ASC') {
        return $val_a <=> $val_b;
    } else {
        return $val_b <=> $val_a;
    }
});

function sort_link($field, $current_field, $current_dir) {
    $new_dir = ($current_field == $field && $current_dir == 'DESC') ? 'ASC' : 'DESC';
    $params = $_GET;
    $params['order_by'] = $field;
    $params['order_dir'] = $new_dir;
    $query = http_build_query($params);
    return "?$query";
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
                    <div class="btn-toolbar mb-2 mb-md-0">
                        <a href="edit_page.php" class="btn btn-sm btn-primary"><i class="bi bi-plus"></i> Новая страница (БД)</a>
                    </div>
                </div>

                <form method="get" class="row g-3 mb-4">
                    <div class="col-auto">
                        <input type="text" class="form-control" name="search" placeholder="Поиск по названию..." value="<?= htmlspecialchars($search) ?>">
                    </div>
                    <div class="col-auto">
                        <button type="submit" class="btn btn-primary">Найти</button>
                        <a href="content.php" class="btn btn-secondary">Сбросить</a>
                    </div>
                </form>

                <div class="table-responsive">
                    <table class="table table-striped">
                        <thead>
                            <tr>
                                <th><a href="<?= sort_link('title', $order_by, $order_dir) ?>">Название</a></th>
                                <th>Slug / Файл</th>
                                <th>Статус</th>
                                <th><a href="<?= sort_link('source', $order_by, $order_dir) ?>">Источник</a></th>
                                <th><a href="<?= sort_link('created_at', $order_by, $order_dir) ?>">Дата</a></th>
                                <th>Действия</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php foreach ($all_pages as $item): ?>
                            <tr>
                                <td><?= htmlspecialchars($item['title']) ?></td>
                                <td><?= htmlspecialchars($item['slug']) ?></td>
                                <td>
                                    <?php if ($item['source'] == 'database'): ?>
                                        <?= getPageStatusBadge($item['status']) ?>
                                    <?php else: ?>
                                        <span class="badge bg-secondary">Файл</span>
                                    <?php endif; ?>
                                </td>
                                <td>
                                    <?php if ($item['source'] == 'database'): ?>
                                        <i class="bi bi-database"></i> База данных
                                    <?php else: ?>
                                        <i class="bi bi-file-earmark-code"></i> Файловая система
                                    <?php endif; ?>
                                </td>
                                <td><?= htmlspecialchars($item['created_at']) ?></td>
                                <td>
                                    <?php if ($item['source'] == 'database'): ?>
                                        <a href="edit_page.php?id=<?= $item['id'] ?>" class="btn btn-sm btn-primary"><i class="bi bi-pencil"></i> Редактировать</a>
                                        <a href="delete_page.php?id=<?= $item['id'] ?>" class="btn btn-sm btn-danger" onclick="return confirm('Удалить страницу из БД?')"><i class="bi bi-trash"></i></a>
                                    <?php else: ?>
                                        <a href="edit_file.php?file=<?= urlencode($item['slug']) ?>" class="btn btn-sm btn-primary"><i class="bi bi-pencil"></i> Редактировать</a>
                                    <?php endif; ?>
                                </td>
                            </tr>
                            <?php endforeach; ?>
                        </tbody>
                    </table>
                </div>
            </main>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF
    log_only "content.php создан."
}

# ----------------------------------------------------------------------
# Создание edit_file.php (с предпросмотром, предупреждением и кнопкой импорта)
# ----------------------------------------------------------------------
create_edit_file_php() {
    cat > "$ADMIN_DIR/edit_file.php" <<'EOF'
<?php
require_once __DIR__ . '/../config.php';
require_once "includes/auth.php";
requireLogin();
require_once "includes/content_functions.php";

$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = "Редактирование файла";
$root_dir = __DIR__ . "/../";
$file_name = isset($_GET['file']) ? basename($_GET['file']) : '';
$file_path = $root_dir . $file_name;
$message = "";

if ($_SERVER["REQUEST_METHOD"] === "POST" && isset($_POST['save_file'])) {
    $content = $_POST['content'];
    if (is_writable($file_path)) {
        $backup = $file_path . '.bak.' . date('Ymd_His');
        copy($file_path, $backup);
        if (file_put_contents($file_path, $content) !== false) {
            $message = "<div class=\"alert alert-success\">Файл сохранён. Бэкап: " . basename($backup) . "</div>";
        } else {
            $message = "<div class=\"alert alert-danger\">Ошибка записи файла</div>";
        }
    } else {
        $message = "<div class=\"alert alert-danger\">Файл не доступен для записи</div>";
    }
}

$content = "";
$is_html = false;
$has_code = false;
if ($file_name && file_exists($file_path) && is_readable($file_path)) {
    $content = file_get_contents($file_path);
    $ext = pathinfo($file_name, PATHINFO_EXTENSION);
    $is_html = in_array($ext, ['html', 'htm', 'php', 'phtml', 'inc']);
    if ($is_html) {
        $has_code = preg_match('/<(style|script)/i', $content) ? true : false;
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
    <?php if ($is_html && $file_name): ?>
    <script src="/admin/tinymce/tinymce.min.js" referrerpolicy="origin"></script>
    <script>
    tinymce.init({
        selector: "#content",
        height: 500,
        plugins: "advlist anchor autolink autosave code codesample directionality emoticons fullscreen help hr image insertdatetime link lists media nonbreaking pagebreak paste preview print save searchreplace table visualblocks visualchars wordcount",
        toolbar: "undo redo | styles | bold italic underline strikethrough removeformat | alignleft aligncenter alignright alignjustify | bullist numlist outdent indent | link anchor image media | forecolor backcolor | fontselect fontsizeselect | code codesample | table | hr charmap pagebreak | visualblocks visualchars | fullscreen preview | wordcount save print | searchreplace | help",
        toolbar_mode: "floating",
        fontsize_formats: "8pt 10pt 12pt 14pt 16pt 18pt 24pt 36pt",
        image_title: true,
        automatic_uploads: true,
        images_upload_url: "/admin/upload.php",
        file_picker_types: "image",
        file_picker_callback: function (cb, value, meta) {
            var input = document.createElement("input");
            input.setAttribute("type", "file");
            input.setAttribute("accept", "image/*");
            input.onchange = function () {
                var file = this.files[0];
                var formData = new FormData();
                formData.append("file", file);
                fetch("/admin/upload.php", {
                    method: "POST",
                    body: formData
                }).then(response => response.json()).then(result => {
                    cb(result.location, { title: result.original_name });
                }).catch(error => console.error(error));
            };
            input.click();
        },
        content_css: "/admin/css/editor.css"
    });
    </script>
    <?php endif; ?>
    <script>
    function previewFile() {
        var content;
        if (typeof tinymce !== 'undefined' && tinymce.get('content')) {
            content = tinymce.get('content').getContent();
        } else {
            content = document.getElementById('content').value;
        }
        var previewWindow = window.open('', '_blank', 'width=1024,height=768');
        previewWindow.document.write(content);
        previewWindow.document.close();
    }
    </script>
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid">
        <div class="row">
            <?php include "includes/sidebar.php"; ?>
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2"><?= $pageTitle ?></h1>
                    <div class="btn-toolbar mb-2 mb-md-0">
                        <a href="content.php" class="btn btn-sm btn-secondary"><i class="bi bi-arrow-left"></i> Назад к списку</a>
                    </div>
                </div>
                <?= $message ?>
                <?php if ($has_code): ?>
                <div class="alert alert-warning">
                    <i class="bi bi-exclamation-triangle"></i> 
                    <strong>Внимание!</strong> Файл содержит CSS/JS код. Редактирование в визуальном режиме может повредить оформление. Рекомендуется использовать режим "Код" (вкладка Source code в TinyMCE).
                </div>
                <?php endif; ?>
                <?php if ($file_name): ?>
                <form method="post">
                    <div class="mb-3">
                        <label class="form-label">Редактирование: <?= htmlspecialchars($file_name) ?></label>
                        <?php if ($is_html): ?>
                        <textarea id="content" name="content" style="height: 500px;"><?= htmlspecialchars($content) ?></textarea>
                        <?php else: ?>
                        <textarea name="content" class="form-control" rows="20"><?= htmlspecialchars($content) ?></textarea>
                        <?php endif; ?>
                    </div>
                    <button type="submit" name="save_file" class="btn btn-primary">Сохранить</button>
                    <button type="button" class="btn btn-info" onclick="previewFile()"><i class="bi bi-eye"></i> Предпросмотр</button>
                    <?php if ($file_name === 'index.html' || $file_name === 'index.php'): ?>
                    <a href="import_to_db.php?file=<?= urlencode($file_name) ?>" class="btn btn-success"><i class="bi bi-database"></i> Перенести в БД</a>
                    <?php endif; ?>
                    <a href="content.php" class="btn btn-secondary">Отмена</a>
                </form>
                <?php else: ?>
                <div class="alert alert-danger">Файл не найден.</div>
                <?php endif; ?>
            </main>
        </div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF
    log_only "edit_file.php создан."
}

# ----------------------------------------------------------------------
# Создание import_to_db.php (импорт файла в БД)
# ----------------------------------------------------------------------
create_import_to_db_php() {
    cat > "$ADMIN_DIR/import_to_db.php" <<'EOF'
<?php
require_once __DIR__ . '/../config.php';
require_once "includes/auth.php";
requireLogin();

$file_name = isset($_GET['file']) ? basename($_GET['file']) : '';
if (!$file_name) {
    header('Location: content.php');
    exit;
}
$file_path = __DIR__ . "/../" . $file_name;
if (!file_exists($file_path)) {
    $_SESSION['message'] = "Файл не найден";
    header('Location: content.php');
    exit;
}

$content = file_get_contents($file_path);
$title = pathinfo($file_name, PATHINFO_FILENAME);
$slug = $title === 'index' ? 'index' : $title;

$stmt = $pdo->prepare("SELECT id FROM pages WHERE slug = ?");
$stmt->execute([$slug]);
if ($stmt->fetch()) {
    $_SESSION['message'] = "Страница с таким slug уже существует. Сначала удалите её, если хотите импортировать заново.";
    header('Location: content.php');
    exit;
}

$stmt = $pdo->prepare("INSERT INTO pages (title, slug, content, status, template) VALUES (?, ?, ?, 'published', 'default')");
$stmt->execute([$title, $slug, $content]);
$new_id = $pdo->lastInsertId();

if ($file_name === 'index.html') {
    unlink($file_path);
}

header("Location: edit_page.php?id=$new_id");
EOF
    log_only "import_to_db.php создан."
}

# ----------------------------------------------------------------------
# Создание upload.php
# ----------------------------------------------------------------------
create_upload_php() {
    cat > "$ADMIN_DIR/upload.php" <<'EOF'
<?php
require_once __DIR__ . '/../config.php';
require_once "includes/auth.php";
requireLogin();

$response = ["error" => true, "message" => ""];
if ($_SERVER["REQUEST_METHOD"] !== "POST") {
    $response["message"] = "Метод не разрешён";
    header("Content-Type: application/json");
    echo json_encode($response);
    exit;
}
if (empty($_FILES["file"])) {
    $response["message"] = "Файл не передан";
    header("Content-Type: application/json");
    echo json_encode($response);
    exit;
}
$file = $_FILES["file"];
$original_name = $file["name"];
$tmp_name = $file["tmp_name"];
$size = $file["size"];
$error = $file["error"];
if ($error !== UPLOAD_ERR_OK) {
    $response["message"] = "Ошибка загрузки: код $error";
    header("Content-Type: application/json");
    echo json_encode($response);
    exit;
}
$allowed_mimes = ["image/jpeg","image/png","image/gif","image/webp","application/pdf","text/plain","application/msword","application/vnd.openxmlformats-officedocument.wordprocessingml.document"];
$finfo = finfo_open(FILEINFO_MIME_TYPE);
$mime_type = finfo_file($finfo, $tmp_name);
finfo_close($finfo);
if (!in_array($mime_type, $allowed_mimes)) {
    $response["message"] = "Недопустимый тип файла: $mime_type";
    header("Content-Type: application/json");
    echo json_encode($response);
    exit;
}
$max_size = getSetting("max_upload_size", 10 * 1024 * 1024);
if ($size > $max_size) {
    $response["message"] = "Файл превышает максимальный размер (" . ($max_size / 1024 / 1024) . " МБ)";
    header("Content-Type: application/json");
    echo json_encode($response);
    exit;
}
$upload_dir = __DIR__ . "/../uploads/";
if (!is_dir($upload_dir)) {
    mkdir($upload_dir, 0750, true);
    chown($upload_dir, "www-data");
    chgrp($upload_dir, "www-data");
}
$year = date("Y");
$month = date("m");
$target_dir = $upload_dir . $year . "/" . $month . "/";
if (!is_dir($target_dir)) {
    mkdir($target_dir, 0750, true);
    chown($target_dir, "www-data");
    chgrp($target_dir, "www-data");
}
$ext = pathinfo($original_name, PATHINFO_EXTENSION);
$new_name = uniqid() . "." . $ext;
$target_path = $target_dir . $new_name;
if (!move_uploaded_file($tmp_name, $target_path)) {
    $response["message"] = "Не удалось сохранить файл";
    header("Content-Type: application/json");
    echo json_encode($response);
    exit;
}
$relative_path = "/uploads/" . $year . "/" . $month . "/" . $new_name;
$stmt = $pdo->prepare("INSERT INTO files (original_name, path, size, type, uploaded_by) VALUES (?, ?, ?, ?, ?)");
$stmt->execute([$original_name, $relative_path, $size, $mime_type, $_SESSION["user_id"]]);
$response = [
    "error" => false,
    "location" => $relative_path,
    "original_name" => $original_name,
    "id" => $pdo->lastInsertId()
];
header("Content-Type: application/json");
echo json_encode($response);
EOF
    log_only "upload.php создан."
}

# ----------------------------------------------------------------------
# Создание files.php (управление загруженными файлами)
# ----------------------------------------------------------------------
create_files_php() {
    cat > "$ADMIN_DIR/files.php" <<'EOF'
<?php
require_once __DIR__ . '/../config.php';
require_once "includes/auth.php";
requireLogin();

$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = "Файлы";
$message = "";

$search = trim($_GET['search'] ?? '');
$order_by = $_GET['order_by'] ?? 'id';
$order_dir = strtoupper($_GET['order_dir'] ?? 'DESC');
$allowed_order = ['id', 'original_name', 'type', 'size', 'uploaded_at'];
if (!in_array($order_by, $allowed_order)) $order_by = 'id';
$order_dir = ($order_dir === 'ASC') ? 'ASC' : 'DESC';

if ($_SERVER["REQUEST_METHOD"] === "POST" && isset($_FILES["file"])) {
    $file = $_FILES["file"];
    $original_name = $file["name"];
    $tmp_name = $file["tmp_name"];
    $size = $file["size"];
    $error = $file["error"];
    if ($error !== UPLOAD_ERR_OK) {
        $message = "<div class=\"alert alert-danger\">Ошибка загрузки: код $error</div>";
    } else {
        $allowed_mimes = ["image/jpeg","image/png","image/gif","image/webp","application/pdf","text/plain","application/msword","application/vnd.openxmlformats-officedocument.wordprocessingml.document"];
        $finfo = finfo_open(FILEINFO_MIME_TYPE);
        $mime_type = finfo_file($finfo, $tmp_name);
        finfo_close($finfo);
        if (!in_array($mime_type, $allowed_mimes)) {
            $message = "<div class=\"alert alert-danger\">Недопустимый тип файла: $mime_type</div>";
        } else {
            $max_size = getSetting("max_upload_size", 10 * 1024 * 1024);
            if ($size > $max_size) {
                $message = "<div class=\"alert alert-danger\">Файл превышает максимальный размер</div>";
            } else {
                $upload_dir = __DIR__ . "/../uploads/";
                if (!is_dir($upload_dir)) {
                    mkdir($upload_dir, 0750, true);
                    chown($upload_dir, "www-data");
                    chgrp($upload_dir, "www-data");
                }
                $year = date("Y");
                $month = date("m");
                $target_dir = $upload_dir . $year . "/" . $month . "/";
                if (!is_dir($target_dir)) {
                    mkdir($target_dir, 0750, true);
                    chown($target_dir, "www-data");
                    chgrp($target_dir, "www-data");
                }
                $ext = pathinfo($original_name, PATHINFO_EXTENSION);
                $new_name = uniqid() . "." . $ext;
                $target_path = $target_dir . $new_name;
                if (move_uploaded_file($tmp_name, $target_path)) {
                    $relative_path = "/uploads/" . $year . "/" . $month . "/" . $new_name;
                    $stmt = $pdo->prepare("INSERT INTO files (original_name, path, size, type, uploaded_by) VALUES (?, ?, ?, ?, ?)");
                    $stmt->execute([$original_name, $relative_path, $size, $mime_type, $_SESSION["user_id"]]);
                    $message = "<div class=\"alert alert-success\">Файл загружен</div>";
                } else {
                    $message = "<div class=\"alert alert-danger\">Не удалось сохранить файл</div>";
                }
            }
        }
    }
}
if (isset($_GET["delete"])) {
    $id = (int)$_GET["delete"];
    $stmt = $pdo->prepare("SELECT path FROM files WHERE id = ?");
    $stmt->execute([$id]);
    $file = $stmt->fetch(PDO::FETCH_ASSOC);
    if ($file) {
        $full_path = __DIR__ . "/.." . $file["path"];
        if (file_exists($full_path)) unlink($full_path);
        $stmt = $pdo->prepare("DELETE FROM files WHERE id = ?");
        $stmt->execute([$id]);
        $message = "<div class=\"alert alert-success\">Файл удалён</div>";
    } else {
        $message = "<div class=\"alert alert-danger\">Файл не найден</div>";
    }
}

$sql = "SELECT * FROM files WHERE 1=1";
$params = [];
if ($search) {
    $sql .= " AND original_name LIKE :search";
    $params[':search'] = "%$search%";
}
$sql .= " ORDER BY $order_by $order_dir";
$stmt = $pdo->prepare($sql);
$stmt->execute($params);
$files = $stmt->fetchAll(PDO::FETCH_ASSOC);

function sort_link($field, $current_field, $current_dir) {
    $new_dir = ($current_field == $field && $current_dir == 'DESC') ? 'ASC' : 'DESC';
    $params = $_GET;
    $params['order_by'] = $field;
    $params['order_dir'] = $new_dir;
    unset($params['delete']);
    $query = http_build_query($params);
    return "?$query";
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
                    <button type="button" class="btn btn-sm btn-primary" data-bs-toggle="modal" data-bs-target="#uploadModal"><i class="bi bi-upload"></i> Загрузить файл</button>
                </div>

                <form method="get" class="row g-3 mb-4">
                    <div class="col-auto">
                        <input type="text" class="form-control" name="search" placeholder="Поиск по имени..." value="<?= htmlspecialchars($search) ?>">
                    </div>
                    <div class="col-auto">
                        <button type="submit" class="btn btn-primary">Найти</button>
                        <a href="files.php" class="btn btn-secondary">Сбросить</a>
                    </div>
                </form>

                <?= $message ?>

                <div class="table-responsive">
                    <table class="table table-striped">
                        <thead>
                            <tr>
                                <th><a href="<?= sort_link('id', $order_by, $order_dir) ?>">ID</a></th>
                                <th><a href="<?= sort_link('original_name', $order_by, $order_dir) ?>">Оригинальное имя</a></th>
                                <th>Путь</th>
                                <th><a href="<?= sort_link('type', $order_by, $order_dir) ?>">Тип</a></th>
                                <th><a href="<?= sort_link('size', $order_by, $order_dir) ?>">Размер (КБ)</a></th>
                                <th><a href="<?= sort_link('uploaded_at', $order_by, $order_dir) ?>">Загружен</a></th>
                                <th>Действия</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php foreach ($files as $file): ?>
                            <tr>
                                <td><?= $file["id"] ?></td>
                                <td><?= htmlspecialchars($file["original_name"]) ?></td>
                                <td><a href="<?= htmlspecialchars($file["path"]) ?>" target="_blank"><?= htmlspecialchars($file["path"]) ?></a></td>
                                <td><?= htmlspecialchars($file["type"]) ?></td>
                                <td><?= round($file["size"] / 1024, 2) ?></td>
                                <td><?= $file["uploaded_at"] ?></td>
                                <td><a href="?delete=<?= $file["id"] ?>&<?= http_build_query(array_diff_key($_GET, ['delete'=>1])) ?>" class="btn btn-sm btn-danger" onclick="return confirm('Удалить?')"><i class="bi bi-trash"></i></a></td>
                            </tr>
                            <?php endforeach; ?>
                        </tbody>
                    </table>
                </div>
            </main>
        </div>
    </div>
    <div class="modal fade" id="uploadModal" tabindex="-1"><div class="modal-dialog"><div class="modal-content"><form method="post" enctype="multipart/form-data"><div class="modal-header"><h5 class="modal-title">Загрузка файла</h5><button type="button" class="btn-close" data-bs-dismiss="modal"></button></div><div class="modal-body"><div class="mb-3"><label for="file" class="form-label">Выберите файл</label><input type="file" class="form-control" id="file" name="file" required></div></div><div class="modal-footer"><button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Отмена</button><button type="submit" class="btn btn-primary">Загрузить</button></div></form></div></div></div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF
    log_only "files.php создан."
}

# ----------------------------------------------------------------------
# Создание edit_page.php
# ----------------------------------------------------------------------
create_edit_page_php() {
    cat > "$ADMIN_DIR/edit_page.php" <<'EOF'
<?php
require_once __DIR__ . '/../config.php';
require_once "includes/auth.php";
requireLogin();
require_once "includes/content_functions.php";

$site_name = getSetting("site_name", SITE_NAME);
$pageTitle = "Редактирование страницы";
$id = isset($_GET["id"]) ? (int)$_GET["id"] : 0;
$is_new = $id === 0;

if ($is_new) {
    $page = ["id"=>0,"title"=>"","slug"=>"","content"=>"","meta_description"=>"","status"=>"draft","template"=>"default"];
} else {
    $stmt = $pdo->prepare("SELECT * FROM pages WHERE id = ?");
    $stmt->execute([$id]);
    $page = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$page) die("Страница не найдена");
}
$message = "";
if ($_SERVER["REQUEST_METHOD"] === "POST") {
    $title = trim($_POST["title"] ?? "");
    $slug = trim($_POST["slug"] ?? "");
    $content = $_POST["content"] ?? "";
    $meta_description = trim($_POST["meta_description"] ?? "");
    $status = $_POST["status"] ?? "draft";
    $template = $_POST["template"] ?? "default";
    $errors = [];
    if (empty($title)) $errors[] = "Заголовок обязателен";
    if (empty($slug)) $slug = generateSlug($title);
    $stmt = $pdo->prepare("SELECT id FROM pages WHERE slug = ? AND id != ?");
    $stmt->execute([$slug, $id]);
    if ($stmt->fetch()) $errors[] = "Slug уже существует";
    if (empty($errors)) {
        if ($is_new) {
            $stmt = $pdo->prepare("INSERT INTO pages (title, slug, content, meta_description, status, template) VALUES (?, ?, ?, ?, ?, ?)");
            $stmt->execute([$title, $slug, $content, $meta_description, $status, $template]);
            $message = "<div class='alert alert-success'>Страница добавлена</div>";
            $id = $pdo->lastInsertId();
            $is_new = false;
        } else {
            $stmt = $pdo->prepare("UPDATE pages SET title = ?, slug = ?, content = ?, meta_description = ?, status = ?, template = ? WHERE id = ?");
            $stmt->execute([$title, $slug, $content, $meta_description, $status, $template, $id]);
            $message = "<div class='alert alert-success'>Страница сохранена</div>";
        }
        $stmt = $pdo->prepare("SELECT * FROM pages WHERE id = ?");
        $stmt->execute([$id]);
        $page = $stmt->fetch(PDO::FETCH_ASSOC);
    } else {
        $message = "<div class='alert alert-danger'><ul><li>" . implode("</li><li>", $errors) . "</li></ul></div>";
    }
}
$templates = getPageTemplates();
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
    <script src="/admin/tinymce/tinymce.min.js" referrerpolicy="origin"></script>
    <script>
    tinymce.init({
        selector: "#content",
        height: 500,
        plugins: "advlist anchor autolink autosave code codesample directionality emoticons fullscreen help hr image insertdatetime link lists media nonbreaking pagebreak paste preview print save searchreplace table visualblocks visualchars wordcount",
        toolbar: "undo redo | styles | bold italic underline strikethrough removeformat | alignleft aligncenter alignright alignjustify | bullist numlist outdent indent | link anchor image media | forecolor backcolor | fontselect fontsizeselect | code codesample | table | hr charmap pagebreak | visualblocks visualchars | fullscreen preview | wordcount save print | searchreplace | help",
        toolbar_mode: "floating",
        fontsize_formats: "8pt 10pt 12pt 14pt 16pt 18pt 24pt 36pt",
        image_title: true,
        automatic_uploads: true,
        images_upload_url: "/admin/upload.php",
        file_picker_types: "image",
        file_picker_callback: function (cb, value, meta) {
            var input = document.createElement("input");
            input.setAttribute("type", "file");
            input.setAttribute("accept", "image/*");
            input.onchange = function () {
                var file = this.files[0];
                var formData = new FormData();
                formData.append("file", file);
                fetch("/admin/upload.php", {
                    method: "POST",
                    body: formData
                }).then(response => response.json()).then(result => {
                    cb(result.location, { title: result.original_name });
                }).catch(error => console.error(error));
            };
            input.click();
        },
        content_css: "/admin/css/editor.css"
    });
    function previewPage() {
        var title = document.getElementById('title').value;
        var content = tinymce.get('content').getContent();
        var previewWindow = window.open('', '_blank', 'width=1024,height=768');
        previewWindow.document.write(`
            <!DOCTYPE html>
            <html lang="ru">
            <head><meta charset="UTF-8"><title>Предпросмотр: ${escapeHtml(title)}</title>
            <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
            <style>body{padding:20px;}</style>
            </head>
            <body>
                <h1>${escapeHtml(title)}</h1>
                ${content}
            </body>
            </html>
        `);
        previewWindow.document.close();
    }
    function escapeHtml(text) {
        var div = document.createElement('div');
        div.appendChild(document.createTextNode(text));
        return div.innerHTML;
    }
    </script>
</head>
<body class="theme-<?= getSetting("admin_theme", "light") ?>">
    <?php include "includes/header.php"; ?>
    <div class="container-fluid"><div class="row"><?php include "includes/sidebar.php"; ?>
    <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4">
        <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
            <h1 class="h2"><?= $is_new ? "Новая страница" : "Редактирование: " . htmlspecialchars($page["title"]) ?></h1>
            <div class="btn-toolbar">
                <a href="content.php" class="btn btn-sm btn-secondary me-2"><i class="bi bi-arrow-left"></i> Назад к списку</a>
                <button type="button" class="btn btn-sm btn-info" onclick="previewPage()"><i class="bi bi-eye"></i> Предпросмотр</button>
            </div>
        </div>
        <?= $message ?>
        <form method="post">
            <div class="mb-3"><label for="title" class="form-label">Заголовок *</label><input type="text" class="form-control" id="title" name="title" value="<?= htmlspecialchars($page["title"]) ?>" required></div>
            <div class="mb-3"><label for="slug" class="form-label">Slug (URL)</label><input type="text" class="form-control" id="slug" name="slug" value="<?= htmlspecialchars($page["slug"]) ?>"><div class="form-text">Оставьте пустым для автоматической генерации.</div></div>
            <div class="mb-3"><label for="content" class="form-label">Содержимое</label><textarea class="form-control" id="content" name="content" rows="10"><?= htmlspecialchars($page["content"]) ?></textarea></div>
            <div class="mb-3"><label for="meta_description" class="form-label">Мета-описание</label><textarea class="form-control" id="meta_description" name="meta_description" rows="3"><?= htmlspecialchars($page["meta_description"]) ?></textarea></div>
            <div class="mb-3"><label for="status" class="form-label">Статус</label><select class="form-select" id="status" name="status"><option value="draft" <?= $page["status"]=="draft"?"selected":"" ?>>Черновик</option><option value="published" <?= $page["status"]=="published"?"selected":"" ?>>Опубликовано</option></select></div>
            <div class="mb-3"><label for="template" class="form-label">Шаблон</label><select class="form-select" id="template" name="template"><?php foreach($templates as $tpl): ?><option value="<?= $tpl ?>" <?= ($page["template"]??"default")==$tpl?"selected":"" ?>><?= ucfirst($tpl) ?></option><?php endforeach; ?></select></div>
            <button type="submit" class="btn btn-primary">Сохранить</button>
            <a href="content.php" class="btn btn-secondary">Отмена</a>
        </form>
    </main></div></div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF
    log_only "edit_page.php создан."
}

# ----------------------------------------------------------------------
# Создание delete_page.php
# ----------------------------------------------------------------------
create_delete_page_php() {
    cat > "$ADMIN_DIR/delete_page.php" <<'EOF'
<?php
require_once __DIR__ . '/../config.php';
require_once "includes/auth.php";
requireAdmin();
$id = isset($_GET["id"]) ? (int)$_GET["id"] : 0;
if ($id) {
    $stmt = $pdo->prepare("DELETE FROM pages WHERE id = ?");
    $stmt->execute([$id]);
}
header("Location: content.php");
exit;
EOF
    log_only "delete_page.php создан."
}

# ----------------------------------------------------------------------
# Создание file-list.php
# ----------------------------------------------------------------------
create_file_list_php() {
    cat > "$ADMIN_DIR/file-list.php" <<'EOF'
<?php
require_once __DIR__ . '/../config.php';
require_once "includes/auth.php";
requireLogin();
$stmt = $pdo->query("SELECT id, original_name, path, type, size, uploaded_at FROM files ORDER BY uploaded_at DESC");
$files = $stmt->fetchAll(PDO::FETCH_ASSOC);
header("Content-Type: application/json");
echo json_encode($files);
EOF
    log_only "file-list.php создан."
}

# ----------------------------------------------------------------------
# Создание file-picker.html
# ----------------------------------------------------------------------
create_file_picker_html() {
    cat > "$ADMIN_DIR/file-picker.html" <<'EOF'
<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><title>Выбор файла</title><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><style>.file-item{cursor:pointer}.file-item:hover{background:#f0f0f0}.thumbnail{width:100px;height:auto;max-height:100px;object-fit:cover;margin-right:15px}</style></head>
<body><div class="container"><h2>Выберите файл</h2><div id="file-list" class="list-group"><div class="text-center"><div class="spinner-border"></div></div></div></div>
<script>
fetch("/admin/file-list.php").then(r=>r.json()).then(files=>{
    const c=document.getElementById("file-list");c.innerHTML="";
    if(files.length===0){c.innerHTML='<div class="alert alert-info">Нет загруженных файлов</div>';return;}
    files.forEach(f=>{
        const d=document.createElement("div");d.className="list-group-item file-item";
        d.innerHTML=`<div class="row align-items-center"><div class="col-auto"><img src="${f.path}" class="thumbnail" onerror="this.style.display='none'"></div><div class="col"><strong>${escapeHtml(f.original_name)}</strong><br><small>${f.type} | ${(f.size/1024).toFixed(2)} KB</small><br><small>Загружен: ${f.uploaded_at}</small></div></div>`;
        d.addEventListener("click",()=>{window.parent.postMessage({mceAction:"FileSelected",url:f.path,title:f.original_name},"*");window.close();});
        c.appendChild(d);
    });
}).catch(e=>{console.error(e);document.getElementById("file-list").innerHTML='<div class="alert alert-danger">Ошибка</div>';});
function escapeHtml(t){var d=document.createElement("div");d.appendChild(document.createTextNode(t));return d.innerHTML;}
</script></body></html>
EOF
    log_only "file-picker.html создан."
}

# ----------------------------------------------------------------------
# Обновление sidebar.php (меню)
# ----------------------------------------------------------------------
restore_sidebar() {
    cat > "$ADMIN_DIR/includes/sidebar.php" <<'EOF'
<?php $current_page = basename($_SERVER["PHP_SELF"]); ?>
<nav id="sidebarMenu" class="col-md-3 col-lg-2 d-md-block bg-light sidebar collapse">
    <div class="position-sticky pt-3">
        <ul class="nav flex-column">
            <li class="nav-item"><a class="nav-link <?= $current_page=="index.php"?"active":"" ?>" href="/admin/"><i class="bi bi-speedometer2"></i> Дашборд</a></li>
            <?php if(isAdmin()): ?><li class="nav-item"><a class="nav-link <?= $current_page=="users.php"?"active":"" ?>" href="/admin/users.php"><i class="bi bi-people"></i> Пользователи</a></li><?php endif; ?>
            <li class="nav-item"><a class="nav-link <?= $current_page=="content.php"?"active":"" ?>" href="/admin/content.php"><i class="bi bi-files"></i> Управление контентом</a></li>
            <li class="nav-item"><a class="nav-link <?= $current_page=="files.php"?"active":"" ?>" href="/admin/files.php"><i class="bi bi-upload"></i> Загруженные файлы</a></li>
            <li class="nav-item"><a class="nav-link <?= $current_page=="stats.php"?"active":"" ?>" href="/admin/stats.php"><i class="bi bi-graph-up"></i> Статистика сервера</a></li>
            <li class="nav-item"><a class="nav-link <?= $current_page=="visitors.php"?"active":"" ?>" href="/admin/visitors.php"><i class="bi bi-eye"></i> Посетители</a></li>
            <li class="nav-item"><a class="nav-link <?= $current_page=="settings.php"?"active":"" ?>" href="/admin/settings.php"><i class="bi bi-gear"></i> Настройки</a></li>
            <li class="nav-item"><a class="nav-link" href="/admin/logout.php"><i class="bi bi-box-arrow-right"></i> Выход</a></li>
        </ul>
    </div>
</nav>
EOF
    log_only "sidebar.php обновлён."
}

# ----------------------------------------------------------------------
# Создание index.php (только если нет index.html)
# ----------------------------------------------------------------------
create_index_php() {
    if [[ ! -f "$SITE_DIR/index.php" && ! -f "$SITE_DIR/index.html" ]]; then
        cat > "$SITE_DIR/index.php" <<'EOF'
<?php require_once __DIR__ . "/config.php"; ?><!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><title><?= SITE_NAME ?></title></head><body><h1><?= SITE_NAME ?></h1><p>Админка: <a href="/admin">/admin</a></p></body></html>
EOF
        log_only "index.php создан (так как нет index.html)."
    else
        log_only "index.php не создан (index.html или index.php уже существует)."
    fi
}

# ----------------------------------------------------------------------
# Создание шаблона default (с подключением config.php)
# ----------------------------------------------------------------------
create_default_template() {
    mkdir -p "$TEMPLATES_DIR"
    cat > "$TEMPLATES_DIR/default.php" <<'EOF'
<?php require_once __DIR__ . "/../config.php"; ?>
<?php $page_title = $page["title"]; ?>
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><title><?= htmlspecialchars($page_title) ?> | <?= htmlspecialchars(getSetting("site_name", SITE_NAME)) ?></title><meta name="description" content="<?= htmlspecialchars($page["meta_description"]??"") ?>"><link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet"><style>body{font-family:"Segoe UI",Arial,sans-serif;line-height:1.6}header{background:#f8f9fa;padding:1rem;border-bottom:1px solid #dee2e6}main{padding:2rem}footer{background:#f8f9fa;padding:1rem;text-align:center;margin-top:2rem}</style></head><body><header><div class="container"><h1><a href="/" style="text-decoration:none;color:inherit;"><?= htmlspecialchars(getSetting("site_name", SITE_NAME)) ?></a></h1></div></header><main class="container"><article><h1><?= htmlspecialchars($page_title) ?></h1><?= $page["content"] ?></article></main><footer><div class="container">&copy; <?= date("Y") ?> <?= htmlspecialchars(getSetting("site_name", SITE_NAME)) ?></div></footer></body></html>
EOF
    log_only "default.php создан."
}

# ----------------------------------------------------------------------
# Установка прав доступа
# ----------------------------------------------------------------------
set_permissions() {
    chown -R www-data:www-data "$SITE_DIR"
    find "$SITE_DIR" -type d -exec chmod 755 {} \;
    find "$SITE_DIR" -type f -exec chmod 644 {} \;
    chmod 750 "$UPLOADS_DIR" 2>/dev/null || true
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    log_only "Права установлены."
}

# ----------------------------------------------------------------------
# Установка TinyMCE через npm (с очисткой)
# ----------------------------------------------------------------------
install_tinymce() {
    if [[ ! -d "$ADMIN_DIR/tinymce" ]] || [[ "$FORCE" == true ]]; then
        echo -e "${YELLOW}Установка TinyMCE ${TINYMCE_VERSION} через npm...${NC}"
        if ! command -v npm &> /dev/null; then
            echo -e "${RED}npm не установлен. Установите Node.js и npm.${NC}"
            exit 1
        fi
        local tmp_dir="/tmp/tinymce_npm_$$"
        mkdir -p "$tmp_dir"
        trap 'rm -rf "$tmp_dir"' EXIT
        cd "$tmp_dir"
        if ! npm install tinymce@${TINYMCE_VERSION} --production --no-audit --no-fund 2>>"$LOG_FILE"; then
            echo -e "${RED}Ошибка установки TinyMCE через npm.${NC}"
            cd - > /dev/null
            exit 1
        fi
        run_cmd rm -rf "$ADMIN_DIR/tinymce"
        run_cmd cp -r "$tmp_dir/node_modules/tinymce" "$ADMIN_DIR/tinymce"
        cd - > /dev/null
        rm -rf "$tmp_dir"
        trap - EXIT
        log_only "TinyMCE установлен через npm."
        echo -e "${GREEN}TinyMCE успешно установлен.${NC}"
    else
        echo -e "${YELLOW}TinyMCE уже установлен.${NC}"
        if [[ ! -f "$ADMIN_DIR/tinymce/tinymce.min.js" ]]; then
            echo -e "${RED}Файл tinymce.min.js отсутствует. Запустите скрипт с --force для переустановки.${NC}"
        fi
    fi
}

# ----------------------------------------------------------------------
# Импорт index.html в БД, если страницы с slug 'index' нет
# ----------------------------------------------------------------------
import_index_if_needed() {
    if [[ -f "$SITE_DIR/index.html" ]]; then
        local page_exists=$(mysql -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SELECT id FROM pages WHERE slug='index'" 2>/dev/null | grep -v '^id' | head -1)
        if [[ -z "$page_exists" ]]; then
            echo -e "${YELLOW}Обнаружен index.html, импортируем в базу данных...${NC}"
            # Вызываем import_to_db.php через PHP CLI
            php -r "
                \$_GET['file'] = 'index.html';
                include '$ADMIN_DIR/import_to_db.php';
            " 2>>"$LOG_FILE" && echo -e "${GREEN}index.html успешно импортирован в БД.${NC}" || echo -e "${RED}Ошибка импорта index.html.${NC}"
        fi
    fi
}

# ----------------------------------------------------------------------
# Основной блок
# ----------------------------------------------------------------------
FORCE=false
for arg in "$@"; do
    [[ "$arg" == "--force" || "$arg" == "-f" ]] && FORCE=true
done

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Запуск от root!${NC}" >&2; exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
else
    echo -e "${RED}.env не найден${NC}"; exit 1
fi

: "${DOMAIN:?}" "${DB_NAME:?}" "${DB_USER:?}" "${DB_PASSWORD:?}"

SITE_DIR="${WEB_ROOT_BASE}/${DOMAIN}"
ADMIN_DIR="${SITE_DIR}/admin"
UPLOADS_DIR="${SITE_DIR}/uploads"
TEMPLATES_DIR="${SITE_DIR}/templates"
CONFIG_PATH="${SITE_DIR}/config.php"

# Проверка необходимых таблиц
if ! table_exists "users"; then echo -e "${RED}Нет users${NC}"; exit 1; fi
if ! table_exists "pages"; then echo -e "${RED}Нет pages${NC}"; exit 1; fi
if [[ ! -f "$ADMIN_DIR/includes/auth.php" ]]; then echo -e "${RED}Нет auth.php${NC}"; exit 1; fi
if [[ ! -f "$CONFIG_PATH" ]]; then echo -e "${RED}Нет config.php${NC}"; exit 1; fi

TOTAL_STEPS=20
CURRENT=0

next_step() {
    CURRENT=$((CURRENT+1))
    show_progress $CURRENT $TOTAL_STEPS "$1"
}

ensure_db_permissions
next_step "Проверка прав БД"

add_template_column
next_step "Добавление колонки template"

create_files_table
next_step "Создание таблицы files"

create_content_functions
next_step "Создание функций"

create_cms_router
next_step "Создание CMS-роутера"

create_content_php
next_step "Создание content.php"

create_edit_file_php
next_step "Создание edit_file.php"

create_import_to_db_php
next_step "Создание импортера файлов"

create_upload_php
next_step "Создание upload.php"

create_files_php
next_step "Создание files.php"

create_edit_page_php
next_step "Создание edit_page.php"

create_delete_page_php
next_step "Создание delete_page.php"

create_file_list_php
next_step "Создание file-list.php"

create_file_picker_html
next_step "Создание file-picker.html"

restore_sidebar
next_step "Обновление меню"

create_index_php
next_step "Проверка index.php"

create_default_template
next_step "Создание шаблона"

install_tinymce
next_step "Установка TinyMCE"

import_index_if_needed
next_step "Импорт index.html в БД (если есть)"

set_permissions
next_step "Установка прав"

systemctl reload nginx 2>/dev/null || true
systemctl restart php8.3-fpm 2>/dev/null || systemctl restart php8.2-fpm 2>/dev/null || systemctl restart php-fpm 2>/dev/null || true

echo ""
echo "======================================================"
echo -e "${GREEN}✅ CMS Content успешно установлен/обновлён!${NC}"
echo "======================================================"
echo ""
echo "📄 Управление контентом (БД + файлы):"
echo "   https://${DOMAIN}/admin/content.php"
echo ""
echo "🖼️  Загруженные файлы:"
echo "   https://${DOMAIN}/admin/files.php"
echo ""
echo "✍️  Редактор TinyMCE установлен и настроен."
echo "   Доступны все плагины: форматирование, таблицы, медиа, код и др."
echo "   На странице редактирования страницы есть кнопка предпросмотра."
echo ""
echo "📁 Шаблоны: /templates/default.php"
echo ""
echo "⚠️  Важно:"
echo "   - Новые страницы создаются через кнопку 'Новая страница (БД)' в content.php."
echo "   - Существующие файлы (index.html, header.php и др.) можно редактировать через content.php."
echo "   - Для статического файла index.html доступна кнопка 'Перенести в БД'."
echo "   - Сайт работает через роутер cms-router.php (сначала БД, потом статические файлы)."
echo ""
echo "💡 Для перезаписи используйте: ./cms_content.sh --force"
echo "======================================================"

log_only "=== $SCRIPT_NAME завершён ==="
exit 0