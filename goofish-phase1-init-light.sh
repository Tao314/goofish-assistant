#!/usr/bin/env bash
# Goofish Assistant - lightweight phase-1 initializer
# Supported: Debian/Ubuntu, AMD64 (x86_64) and ARM64 (aarch64).
# Read-only scaffold only: no message sending, delivery, listing edits or relisting.

set -Eeuo pipefail
umask 077

PROJECT="${GOOFISH_HOME:-$HOME/goofish-assistant}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "找不到 $PYTHON_BIN"
[[ "$(uname -s)" == "Linux" ]] || die "仅支持 Linux。"
[[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。"
. /etc/os-release

case "${ID:-}" in
  debian|ubuntu) ;;
  *) die "暂不支持：${PRETTY_NAME:-${ID:-unknown}}；仅支持 Debian / Ubuntu。" ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH_FAMILY="AMD64" ;;
  aarch64|arm64) ARCH_FAMILY="ARM64" ;;
  *) die "暂不支持架构：$ARCH；仅支持 AMD64/x86_64 和 ARM64/aarch64。" ;;
esac

PY_VER="$("$PYTHON_BIN" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
log "系统：${PRETTY_NAME:-$ID}；架构：$ARCH_FAMILY ($ARCH)；Python：$PY_VER"
log "项目目录：$PROJECT"

# Root uses apt-get directly. Non-root users retain sudo compatibility.
if [[ "$EUID" -eq 0 ]]; then
  APT=(apt-get)
  log "root 模式：直接使用 apt-get。"
else
  command -v sudo >/dev/null 2>&1 || die "非 root 执行需要 sudo。"
  APT=(sudo apt-get)
  log "普通用户模式：通过 sudo 使用 apt-get。"
fi

log "更新软件包索引"
"${APT[@]}" update

# Select package names available in the current distro (Debian 13 t64 included).
choose_pkg() {
  local candidate
  for candidate in "$@"; do
    if apt-cache show "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die "软件源中找不到依赖包：$*"
}

SYSTEM_PACKAGES=(
  ca-certificates
  python3-venv
  python3-pip
  libnss3
  libgbm1
  libx11-6
  libx11-xcb1
  libxcomposite1
  libxdamage1
  libxext6
  libxfixes3
  libxrandr2
  libxkbcommon0
  libpango-1.0-0
  libcairo2
  libdrm2
  libglib2.0-0
  libxshmfence1
)
SYSTEM_PACKAGES+=("$(choose_pkg libatk1.0-0t64 libatk1.0-0)")
SYSTEM_PACKAGES+=("$(choose_pkg libatk-bridge2.0-0t64 libatk-bridge2.0-0)")
SYSTEM_PACKAGES+=("$(choose_pkg libasound2t64 libasound2)")
SYSTEM_PACKAGES+=("$(choose_pkg libcups2t64 libcups2)")
SYSTEM_PACKAGES+=("$(choose_pkg libatspi2.0-0t64 libatspi2.0-0)")

log "安装精简系统依赖（不安装桌面、Xvfb、VNC、Firefox、WebKit）"
"${APT[@]}" install -y --no-install-recommends "${SYSTEM_PACKAGES[@]}"

log "创建项目目录"
mkdir -p "$PROJECT"/{core,modules,scripts,data,secrets,logs}
chmod 700 "$PROJECT" "$PROJECT/data" "$PROJECT/secrets" "$PROJECT/logs"
cd "$PROJECT"

log "创建 Python 虚拟环境"
if [[ ! -x venv/bin/python ]]; then
  "$PYTHON_BIN" -m venv venv
fi
# shellcheck disable=SC1091
source venv/bin/activate

cat > requirements.txt <<'REQ'
playwright>=1.48,<2
REQ

log "安装 Python 依赖"
python -m pip install --disable-pip-version-check --no-warn-script-location -r requirements.txt

log "仅安装 Playwright Chromium headless shell"
if ! python -m playwright install chromium --only-shell; then
  cat >&2 <<'WARN'
警告：Playwright Chromium headless shell 安装失败。
项目骨架和数据库仍会创建，但浏览器相关脚本暂时无法运行。
请保留完整错误输出；不要下载其他架构的浏览器包或执行不明安装脚本。
WARN
fi

cat > config.json <<'JSON'
{
  "site_url": "https://www.goofish.com/",
  "browser_profile": "secrets/browser-profile",
  "database": "data/goofish.db",
  "log_file": "logs/app.log",
  "timezone": "Asia/Shanghai",
  "mode": "read_only",
  "headless": true,
  "browser_viewport": {
    "width": 1024,
    "height": 720
  },
  "login_screenshot": "secrets/login-page.png",
  "login_screenshot_interval_seconds": 20
}
JSON
chmod 600 config.json requirements.txt

cat > core/__init__.py <<'PY'
"""Core infrastructure for Goofish Assistant."""
PY
cat > modules/__init__.py <<'PY'
"""Feature modules are loaded explicitly when needed."""
PY

cat > core/logger.py <<'PY'
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

def setup_logger(project_dir: Path) -> logging.Logger:
    log_path = project_dir / "logs" / "app.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.parent.chmod(0o700)

    logger = logging.getLogger("goofish")
    logger.setLevel(logging.INFO)
    logger.propagate = False
    if logger.handlers:
        return logger

    fmt = logging.Formatter(
        "%(asctime)s %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )
    console = logging.StreamHandler()
    console.setFormatter(fmt)
    file_handler = RotatingFileHandler(
        log_path, maxBytes=1024 * 1024, backupCount=3, encoding="utf-8"
    )
    file_handler.setFormatter(fmt)
    logger.addHandler(console)
    logger.addHandler(file_handler)
    try:
        log_path.chmod(0o600)
    except OSError:
        pass
    return logger
PY

cat > core/database.py <<'PY'
import sqlite3
from pathlib import Path

SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id TEXT NOT NULL UNIQUE,
    title TEXT,
    price TEXT,
    status TEXT,
    status_reason TEXT,
    auto_relist INTEGER NOT NULL DEFAULT 0,
    last_checked TEXT,
    last_relisted TEXT,
    raw_snapshot TEXT
);
CREATE TABLE IF NOT EXISTS delivery_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id TEXT NOT NULL UNIQUE,
    delivery_type TEXT NOT NULL,
    template TEXT,
    enabled INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY(product_id) REFERENCES products(product_id)
);
CREATE TABLE IF NOT EXISTS inventory (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id TEXT NOT NULL,
    item_content_encrypted TEXT,
    status TEXT NOT NULL DEFAULT 'available'
        CHECK(status IN ('available','reserved','delivered','disabled')),
    reserved_order_id TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    used_at TEXT,
    FOREIGN KEY(product_id) REFERENCES products(product_id)
);
CREATE TABLE IF NOT EXISTS orders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id TEXT NOT NULL UNIQUE,
    product_id TEXT,
    buyer_ref TEXT,
    order_status TEXT,
    delivery_status TEXT NOT NULL DEFAULT 'not_started',
    inventory_id INTEGER,
    created_at TEXT,
    delivered_at TEXT,
    last_seen TEXT,
    raw_snapshot TEXT,
    FOREIGN KEY(inventory_id) REFERENCES inventory(id)
);
CREATE TABLE IF NOT EXISTS operations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_type TEXT NOT NULL,
    target_id TEXT NOT NULL,
    result TEXT NOT NULL,
    error_message TEXT,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS app_state (
    key TEXT PRIMARY KEY,
    value TEXT,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_orders_delivery_status
    ON orders(delivery_status);
CREATE INDEX IF NOT EXISTS idx_inventory_product_status
    ON inventory(product_id, status);
"""

def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    db_path.parent.chmod(0o700)
    conn = sqlite3.connect(str(db_path), timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.executescript(SCHEMA)
    try:
        db_path.chmod(0o600)
    except OSError:
        pass
    return conn
PY

cat > core/browser.py <<'PY'
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

def load_config(project_dir: Path):
    return json.loads((project_dir / "config.json").read_text(encoding="utf-8"))

def open_persistent_browser(project_dir: Path):
    cfg = load_config(project_dir)
    profile = project_dir / cfg["browser_profile"]
    profile.mkdir(parents=True, exist_ok=True)
    profile.chmod(0o700)
    vp = cfg.get("browser_viewport", {"width": 1024, "height": 720})

    # Headless-only operation: no X server, desktop, VNC or GUI packages.
    # Chromium sandbox is disabled only when the process is root.
    args = [
        "--disable-dev-shm-usage",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-sync",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-features=Translate,MediaRouter",
    ]
    if os.geteuid() == 0:
        args.append("--no-sandbox")

    pw = sync_playwright().start()
    try:
        context = pw.chromium.launch_persistent_context(
            user_data_dir=str(profile),
            headless=True,
            viewport=vp,
            locale="zh-CN",
            timezone_id=cfg.get("timezone", "Asia/Shanghai"),
            args=args,
        )
    except Exception:
        pw.stop()
        raise
    return pw, context
PY

cat > modules/auth.py <<'PY'
from pathlib import Path
import time
from core.browser import open_persistent_browser, load_config

def login(project_dir: Path, logger):
    cfg = load_config(project_dir)
    pw, context = open_persistent_browser(project_dir)
    try:
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(cfg["site_url"], wait_until="domcontentloaded", timeout=90000)
        screenshot = project_dir / cfg["login_screenshot"]
        screenshot.parent.mkdir(parents=True, exist_ok=True)
        screenshot.parent.chmod(0o700)
        interval = max(10, int(cfg.get("login_screenshot_interval_seconds", 20)))

        logger.info("无头浏览器已打开闲鱼页面。")
        logger.info("页面截图会定期保存到：%s", screenshot)
        logger.info("可通过 SSH/SCP 将截图取回本地查看；如页面显示二维码，可用手机尝试扫码。")
        logger.info("若平台要求人脸验证、滑块或其他风控验证，请停止并按平台正常流程处理；本程序不绕过验证。")
        logger.info("完成登录后按 Ctrl+C 退出；会话资料保存在 secrets/browser-profile。")
        while True:
            try:
                page.screenshot(path=str(screenshot), full_page=False, timeout=15000)
                screenshot.chmod(0o600)
                logger.info("登录页面截图已更新：%s", screenshot.name)
            except Exception as exc:
                logger.warning("截图更新失败：%s", exc)
            time.sleep(interval)
    finally:
        context.close()
        pw.stop()
PY

cat > scripts/login.py <<'PY'
#!/usr/bin/env python3
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from core.logger import setup_logger
from modules.auth import login

if __name__ == "__main__":
    logger = setup_logger(ROOT)
    try:
        login(ROOT, logger)
    except KeyboardInterrupt:
        logger.info("收到退出指令，正在关闭浏览器并保存会话资料。")
PY

cat > scripts/check_login.py <<'PY'
#!/usr/bin/env python3
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from core.browser import open_persistent_browser, load_config
from core.logger import setup_logger

logger = setup_logger(ROOT)

def main():
    pw, context = open_persistent_browser(ROOT)
    try:
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(load_config(ROOT)["site_url"],
                  wait_until="domcontentloaded", timeout=90000)
        page.wait_for_timeout(4000)
        cookies = context.cookies()
        logger.info("当前页面 URL：%s", page.url)
        logger.info("页面标题：%s", page.title())
        logger.info("浏览器 Cookie 数量：%d", len(cookies))
        for item in cookies:
            logger.info("Cookie 元数据：name=%s domain=%s expires=%s",
                        item.get("name"), item.get("domain"), item.get("expires"))
        logger.info("Cookie 存在不等于登录有效，请人工确认页面账号状态。")
    finally:
        context.close()
        pw.stop()

if __name__ == "__main__":
    main()
PY

cat > scripts/inspect_page.py <<'PY'
#!/usr/bin/env python3
"""只读检查页面摘要；不点击、不提交、不修改商品或订单。"""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from core.browser import open_persistent_browser, load_config
from core.logger import setup_logger

logger = setup_logger(ROOT)

def main():
    pw, context = open_persistent_browser(ROOT)
    try:
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(load_config(ROOT)["site_url"],
                  wait_until="domcontentloaded", timeout=90000)
        page.wait_for_timeout(3000)
        logger.info("URL: %s", page.url)
        logger.info("标题: %s", page.title())
        body = page.locator("body").inner_text(timeout=12000)
        logger.info("页面可见文本（前 3000 字符）:\n%s", body[:3000])
        logger.info("链接文字（最多 30 条）:")
        for item in page.locator("a").all()[:30]:
            try:
                label = (item.inner_text(timeout=700) or "").strip()
                href = item.get_attribute("href") or ""
                if label or href:
                    logger.info("link text=%r href=%r", label[:100], href[:200])
            except Exception:
                continue
        logger.info("只读检查结束：未点击链接、未提交表单。")
    finally:
        context.close()
        pw.stop()

if __name__ == "__main__":
    main()
PY

cat > main.py <<'PY'
#!/usr/bin/env python3
"""Phase-1 status command. Does not load browser or feature modules."""
from pathlib import Path
import json
from core.database import connect
from core.logger import setup_logger

ROOT = Path(__file__).resolve().parent
logger = setup_logger(ROOT)

def main():
    cfg = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
    db_path = ROOT / cfg["database"]
    with connect(db_path) as conn:
        tables = ("products", "orders", "delivery_rules", "inventory",
                  "operations", "app_state")
        counts = {
            table: conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            for table in tables
        }
    logger.info("Goofish Assistant - lightweight phase-1")
    logger.info("Mode: %s (read-only scaffold)", cfg["mode"])
    logger.info("Database: %s", db_path)
    logger.info("Table counts: %s", counts)

if __name__ == "__main__":
    main()
PY

cat > .gitignore <<'TXT'
venv/
__pycache__/
*.pyc
data/
logs/
secrets/
config.local.json
TXT

chmod 700 scripts/*.py
chmod 700 "$PROJECT" "$PROJECT/data" "$PROJECT/secrets" "$PROJECT/logs"
chmod 600 config.json requirements.txt

log "初始化 SQLite 数据库"
python - <<'PY'
from pathlib import Path
from core.database import connect
root = Path.cwd()
with connect(root / "data" / "goofish.db") as conn:
    names = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    )]
print("数据库初始化成功：", ", ".join(names))
PY

log "执行 Python 语法检查"
python -m compileall -q core modules scripts main.py

log "检查目录权限"
find "$PROJECT" -maxdepth 1 -type d -print >/dev/null
chmod 700 "$PROJECT/data" "$PROJECT/secrets" "$PROJECT/logs"
chmod 600 "$PROJECT/data/goofish.db" 2>/dev/null || true

cat <<EOF

============================================================
Goofish Assistant 轻量化第一阶段初始化完成

项目目录：$PROJECT
系统：${PRETTY_NAME:-$ID}
架构：$ARCH_FAMILY ($ARCH)

运行：
  cd "$PROJECT"
  source venv/bin/activate
  python main.py

登录尝试（无头 Chromium，页面截图每隔一段时间更新）：
  python scripts/login.py

查看截图：
  scp 用户名@VPS_IP:"$PROJECT/secrets/login-page.png" .
  # 在本地打开 login-page.png；若显示二维码，可用手机尝试扫码。

检查会话：
  python scripts/check_login.py

只读页面探测：
  python scripts/inspect_page.py

安全边界：
  - 第一阶段只读；不自动发货、不发送消息、不修改或恢复商品。
  - 不绕过人脸、滑块、短信或其他平台风控验证。
  - secrets、data、logs 权限为 700；配置和数据库文件为 600。
  - 浏览器 profile 只能由一个 Chromium 实例同时使用。
  - 不要上传 secrets/browser-profile、登录截图或 Cookie 到 GitHub。

轻量化说明：
  - 不安装桌面、Xvfb、VNC、Firefox 或 WebKit。
  - 仅安装 Playwright Chromium headless shell。
  - 浏览器仅在 login/check_login/inspect_page 命令运行时启动。
============================================================
EOF
