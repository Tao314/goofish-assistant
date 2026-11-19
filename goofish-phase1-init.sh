#!/usr/bin/env bash
# Goofish Assistant - Debian/Ubuntu AMD64+ARM64 phase-1 initializer
# Creates a read-only login/probing scaffold. It does NOT send messages,
# deliver goods, modify listings, or call undocumented seller APIs.

set -Eeuo pipefail
umask 077

PROJECT="${GOOFISH_HOME:-$HOME/goofish-assistant}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

log() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "找不到 $PYTHON_BIN"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH_FAMILY="AMD64" ;;
  aarch64|arm64) ARCH_FAMILY="ARM64" ;;
  *) die "暂不支持 CPU 架构：$ARCH（第一版仅支持 AMD64/x86_64 和 ARM64/aarch64）。" ;;
esac

[[ "$("$PYTHON_BIN" -c 'import platform; print(platform.system())')" == "Linux" ]] || die "此脚本只支持 Linux。"
[[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，无法识别操作系统。"
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) die "暂不支持此操作系统：${PRETTY_NAME:-${ID:-unknown}}（仅支持 Debian / Ubuntu）。" ;;
esac

PY_VER="$($PYTHON_BIN -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
log "系统：${PRETTY_NAME:-$ID}；架构：$ARCH_FAMILY ($ARCH)；Python：$PY_VER；项目目录：$PROJECT"

# Root 直接执行 apt-get；普通用户使用 sudo，保持两种运行方式兼容。
if [[ "${EUID}" -eq 0 ]]; then
  APT=(apt-get)
  log "当前为 root：系统依赖将直接使用 apt-get 安装。"
else
  command -v sudo >/dev/null 2>&1 || die "当前不是 root，且找不到 sudo。请安装 sudo 或改由 root 执行。"
  APT=(sudo apt-get)
  log "当前为普通用户：系统依赖将通过 sudo 安装。"
fi

log "更新软件包索引"
"${APT[@]}" update

# Debian 13 等较新的发行版使用部分 t64 包名；按仓库实际可用名称选择。
choose_pkg() {
  local candidate
  for candidate in "$@"; do
    if apt-cache show "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  die "软件源中找不到依赖包候选：$*"
}

SYSTEM_PACKAGES=(
  ca-certificates curl xvfb x11vnc xauth fluxbox fonts-noto-cjk
  libnss3 libgbm1 libx11-xcb1 libxcomposite1 libxdamage1 libxrandr2
  libxfixes3 libxkbcommon0 libpango-1.0-0 libdrm2 libxshmfence1
  python3-venv python3-pip
)
add_compatible_pkg() {
  local candidate
  for candidate in "$@"; do
    if apt-cache show "$candidate" >/dev/null 2>&1; then
      SYSTEM_PACKAGES+=("$candidate")
      return 0
    fi
  done
  die "软件源中找不到依赖包候选：$*"
}
add_compatible_pkg libatk1.0-0t64 libatk1.0-0
add_compatible_pkg libatk-bridge2.0-0t64 libatk-bridge2.0-0
add_compatible_pkg libasound2t64 libasound2
add_compatible_pkg libgtk-3-0t64 libgtk-3-0
log "安装系统依赖"
"${APT[@]}" install -y "${SYSTEM_PACKAGES[@]}"

log "创建项目目录"
mkdir -p "$PROJECT"/{core,modules,scripts,data,secrets,logs}
chmod 700 "$PROJECT/secrets" "$PROJECT/data" "$PROJECT/logs"
cd "$PROJECT"

log "创建 Python 虚拟环境"
"$PYTHON_BIN" -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
python -m pip install --upgrade pip wheel
cat > requirements.txt <<'REQ'
playwright>=1.48,<2
REQ
pip install -r requirements.txt

log "安装 Playwright Chromium（首次下载需要一些时间和磁盘空间）"
if ! python -m playwright install chromium; then
  cat >&2 <<'WARN'
警告：Playwright Chromium 下载/安装失败。
项目文件已创建，但暂时不能启动浏览器。
请保留完整错误输出；不要随意下载其他 CPU 架构的 Chromium 包。
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
  "order_poll_seconds": 120,
  "product_poll_seconds": 1800,
  "browser_viewport": {
    "width": 1280,
    "height": 800
  }
}
JSON
chmod 600 config.json

cat > core/__init__.py <<'PY'
PY
cat > modules/__init__.py <<'PY'
PY

cat > core/logger.py <<'PY'
import json
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

def setup_logger(project_dir: Path) -> logging.Logger:
    log_path = project_dir / "logs" / "app.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)

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
        log_path, maxBytes=2 * 1024 * 1024,
        backupCount=5, encoding="utf-8"
    )
    file_handler.setFormatter(fmt)
    logger.addHandler(console)
    logger.addHandler(file_handler)
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
    conn = sqlite3.connect(str(db_path), timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.executescript(SCHEMA)
    return conn
PY

cat > core/browser.py <<'PY'
import json
from pathlib import Path
import os
from playwright.sync_api import sync_playwright

def load_config(project_dir: Path):
    return json.loads((project_dir / "config.json").read_text(encoding="utf-8"))

def open_persistent_browser(project_dir: Path):
    cfg = load_config(project_dir)
    profile = project_dir / cfg["browser_profile"]
    profile.mkdir(parents=True, exist_ok=True)
    profile.chmod(0o700)
    vp = cfg.get("browser_viewport", {"width": 1280, "height": 800})

    pw = sync_playwright().start()
    try:
        context = pw.chromium.launch_persistent_context(
            user_data_dir=str(profile),
            headless=False,
            viewport=vp,
            locale="zh-CN",
            timezone_id=cfg.get("timezone", "Asia/Shanghai"),
            # Chromium sandbox cannot run as root; keep it enabled for normal users.
            args=["--disable-dev-shm-usage"] + (["--no-sandbox"] if os.geteuid() == 0 else [])
        )
    except Exception:
        pw.stop()
        raise
    return pw, context
PY

cat > modules/auth.py <<'PY'
from pathlib import Path
from core.browser import open_persistent_browser, load_config

def login(project_dir: Path, logger):
    pw, context = open_persistent_browser(project_dir)
    try:
        page = context.pages[0] if context.pages else context.new_page()
        url = load_config(project_dir)["site_url"]
        logger.info("打开闲鱼网页：%s", url)
        page.goto(url, wait_until="domcontentloaded", timeout=90000)
        logger.info("网页已打开。请在 VNC 窗口中手动登录并完成平台要求的验证。")
        logger.info("登录完成后，在 SSH 终端按 Ctrl+C 退出；浏览器配置会保存在本地。")
        page.wait_for_timeout(1000)
        while True:
            page.wait_for_timeout(30000)
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
        logger.info("收到退出指令，正在关闭浏览器并保存配置。")
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
        page.wait_for_timeout(5000)

        # 只输出 Cookie 名称/域名/过期时间，不输出 Cookie 值。
        cookies = context.cookies()
        logger.info("当前页面 URL：%s", page.url)
        logger.info("页面标题：%s", page.title())
        logger.info("浏览器中 Cookie 数量：%d", len(cookies))
        for item in cookies:
            logger.info("Cookie 元数据：name=%s domain=%s expires=%s",
                        item.get("name"), item.get("domain"),
                        item.get("expires"))
        logger.info("注意：Cookie 存在不代表账号登录有效，请人工确认页面登录状态。")
    finally:
        context.close()
        pw.stop()

if __name__ == "__main__":
    main()
PY

cat > scripts/inspect_page.py <<'PY'
#!/usr/bin/env python3
"""只读页面检查：输出页面标题、URL、可见文本摘要和链接文字，不点击、不提交。"""
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
        page.wait_for_timeout(5000)
        title = page.title()
        url = page.url
        text = page.locator("body").inner_text(timeout=15000)
        logger.info("URL: %s", url)
        logger.info("标题: %s", title)
        logger.info("页面可见文本（前 5000 字符）:\n%s", text[:5000])
        logger.info("链接文字（前 100 条）:")
        for item in page.locator("a").all()[:100]:
            try:
                label = (item.inner_text(timeout=1000) or "").strip()
                href = item.get_attribute("href") or ""
                if label or href:
                    logger.info("link text=%r href=%r", label[:160], href[:300])
            except Exception:
                pass
        logger.info("这是只读检查；程序没有点击链接或提交表单。")
    finally:
        context.close()
        pw.stop()

if __name__ == "__main__":
    main()
PY

cat > main.py <<'PY'
#!/usr/bin/env python3
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
        counts = {}
        for table in ("products", "orders", "delivery_rules", "inventory", "operations"):
            counts[table] = conn.execute(
                "SELECT COUNT(*) FROM " + table
            ).fetchone()[0]
    logger.info("Goofish Assistant phase-1 scaffold")
    logger.info("Mode: %s (no transaction actions enabled)", cfg["mode"])
    logger.info("Database: %s", db_path)
    logger.info("Table counts: %s", counts)

if __name__ == "__main__":
    main()
PY

cat > start-desktop.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
DISPLAY_NUM="${DISPLAY_NUM:-:99}"
export DISPLAY="$DISPLAY_NUM"

if ! pgrep -f "Xvfb ${DISPLAY_NUM}" >/dev/null 2>&1; then
  Xvfb "$DISPLAY_NUM" -screen 0 1280x800x24 -ac -nolisten tcp \
    >/tmp/goofish-xvfb.log 2>&1 &
  sleep 2
fi

if ! pgrep -x fluxbox >/dev/null 2>&1; then
  fluxbox >/tmp/goofish-fluxbox.log 2>&1 &
fi

# VNC 仅监听 loopback；必须通过 SSH -L 隧道访问，切勿开放公网 5900 端口。
if ! pgrep -f "x11vnc.*5900" >/dev/null 2>&1; then
  x11vnc -display "$DISPLAY_NUM" -localhost -rfbport 5900 \
    -forever -shared -nopw >/tmp/goofish-vnc.log 2>&1 &
fi
echo "虚拟桌面已启动：DISPLAY=$DISPLAY_NUM；VNC 仅监听 localhost:5900"
SH

cat > stop-desktop.sh <<'SH'
#!/usr/bin/env bash
set -e
pkill -f 'x11vnc.*5900' 2>/dev/null || true
pkill -x fluxbox 2>/dev/null || true
pkill -f 'Xvfb :99' 2>/dev/null || true
echo "虚拟桌面已停止"
SH

cat > .gitignore <<'TXT'
venv/
__pycache__/
*.pyc
data/
logs/
secrets/
config.local.json
TXT

chmod 700 start-desktop.sh stop-desktop.sh scripts/*.py
chmod 700 secrets data logs

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

cat <<EOF

============================================================
Goofish Assistant 第一阶段初始化完成
项目目录：$PROJECT

下一步：
  1) cd "$PROJECT"
  2) source venv/bin/activate
  3) ./start-desktop.sh
  4) export DISPLAY=:99
  5) python scripts/login.py

在你自己的电脑上另开终端建立 SSH 隧道：
  ssh -L 5900:127.0.0.1:5900 用户名@VPS_IP

然后用 VNC Viewer 连接：
  127.0.0.1:5900

登录检查：
  python scripts/check_login.py

只读页面检查：
  python scripts/inspect_page.py

查看数据库和运行状态：
  python main.py

重要：
  - secrets、data、logs 目录权限为 700；浏览器 profile 权限为 700。
  - 不要公开 secrets/browser-profile 或 app.log。
  - 支持 Debian 11 ARM64 与 Debian 13 AMD64；第一版目标为 Debian/Ubuntu 的 AMD64、ARM64。
  - 不要将 VNC 5900 端口开放到公网。
  - 本版本不会自动发货、发送消息或修改商品。
  - Chromium 安装若失败，请保留完整错误信息。
============================================================
EOF
