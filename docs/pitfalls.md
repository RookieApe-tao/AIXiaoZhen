# 坑记录

> 规则：遇到问题先读本文件；每次问题解决后，必须把坑（现象/原因/解决）追加到这里。
> 格式：日期 | 现象 | 原因 | 解决 | 涉及文件/命令

---

## 2026-11-13 | 项目副本残留大量日志与 .git 导致目录臃肿
- **现象**：项目根目录散落 17 个 `.log` 文件（backend/client_old1-10/godot/probe 等），microverse 下另有 4 个日志；根目录存在旧 `.git`；`backend/app` 下有 `__pycache__`；存在空的 `temp_mcp/`。
- **原因**：调试脚本把日志重定向到了项目根目录且未加入清理习惯；`.git` 为从旧机器拷贝带来的过期仓库。
- **解决**：删除全部日志、`.git`、`temp_mcp/`、项目自身的 `__pycache__`（保留 `backend/.venv` 与 `microverse/.godot`——后者含 MCP bridge secret）。
- **涉及**：根目录 `*.log`、`microverse/*.log`、`backend/app/**/__pycache__`。

## 遗留风险备忘
- `sk-REDACTED.txt`：疑似明文 API Key 文件留在项目根目录，建议移入 `.env` 或环境变量并删除该文件，且不要提交到任何仓库。
- 删除 `.git` 后项目无版本控制，如需恢复历史请从远端（GitHub, SSH）重新 clone 或 `git init` 后推送。
