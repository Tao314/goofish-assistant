# Goofish Assistant

闲鱼自动化助手，模块化开发，一个模块一个模块做。

- 登录：Playwright + Chromium，人工扫码一次，会话复用；不用账号密码自动登录，不用非官方 API/SDK
- 第一阶段只做：环境初始化、浏览器、登录验证、会话持久化；不做订单抓取、自动发货、商品恢复
- 参数：单个闲鱼账号；发货先人工确认，稳定后自动发货；商品恢复仅限明确允许恢复的下架商品；通知：SSH 日志 + 本地日志文件
- 架构：模块化，14 个模块分 4 个阶段；一套代码同时适配 AMD64 + ARM64
- 测试机：s-sj2.tao314.top（Debian 13 AMD64，方案原定 Debian 11 ARM64，脚本会提示但可继续）

## 第一阶段

```bash
chmod +x goofish-phase1-init.sh
sudo ./goofish-phase1-init.sh
```

脚本以普通用户运行（不要用 root），会装系统依赖、建虚拟环境、装 Playwright Chromium、生成只读脚手架（`core/`、`modules/`、`scripts/`、`config.json`、SQLite 库），并提供 VNC 手动登录入口 `scripts/login.py`。

输出物另存于 Google Drive 文件夹 `goofish-assistant`。
