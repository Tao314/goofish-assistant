# Goofish Assistant

闲鱼自动化助手，模块化开发。

- 登录：Playwright + Chromium headless，人工扫码一次，会话复用；不用账号密码自动登录，不用非官方 API/SDK
- 第一阶段只做：环境初始化、浏览器、登录验证、会话持久化；不做订单抓取、自动发货、商品恢复
- 参数：单个闲鱼账号；发货先人工确认，稳定后自动发货；商品恢复仅限明确允许恢复的下架商品；通知：SSH 日志 + 本地日志文件
- 架构：模块化，14 个模块分 4 个阶段；一套代码同时适配 AMD64 + ARM64
- 形态：轻量化、纯命令行、root 可执行，装用户自己 VPS 上；不装桌面、Xvfb、VNC、Firefox、WebKit

## 第一阶段（轻量化）

```bash
cd /root
curl -L -o goofish-phase1-init-light.sh https://raw.githubusercontent.com/Tao314/goofish-assistant/main/goofish-phase1-init-light.sh
sha256sum goofish-phase1-init-light.sh
bash -n goofish-phase1-init-light.sh
chmod 700 goofish-phase1-init-light.sh
./goofish-phase1-init-light.sh
```

SHA256 为 `d98f2876bfa30831d65628363193be0e01c921ea20246960c031eb02f32ca069`。

脚本以 root 运行（直接 apt-get、Chromium 自动加 `--no-sandbox`），只装精简系统依赖和 Playwright Chromium headless shell，生成只读脚手架（`core/`、`modules/`、`scripts/`、`config.json`、SQLite 库）。登录：跑 `scripts/login.py`，无头打开闲鱼页，截图定期存到 `secrets/login-page.png`，用 scp 取回查看、扫码；登完按 Ctrl+C，再跑 `scripts/check_login.py` 验证。不绕过人脸、滑块、短信等平台验证。

资源目标：项目额外磁盘 0.4–0.7GB；不跑浏览器内存约 30–80MB；单实例浏览器约 180–350MB。


