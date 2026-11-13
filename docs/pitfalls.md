# 坑记录

> 规则：遇到问题先读本文件；每次问题解决后，必须把坑（现象/原因/解决）追加到这里。
> 格式：日期 | 现象 | 原因 | 解决 | 涉及文件/命令

---

## 2026-11-13 | 项目副本残留大量日志与 .git 导致目录臃肿
- **现象**：项目根目录散落 17 个 `.log` 文件（backend/client_old1-10/godot/probe 等），microverse 下另有 4 个日志；根目录存在旧 `.git`；`backend/app` 下有 `__pycache__`；存在空的 `temp_mcp/`。
- **原因**：调试脚本把日志重定向到了项目根目录且未加入清理习惯；`.git` 为从旧机器拷贝带来的过期仓库。
- **解决**：删除全部日志、`.git`、`temp_mcp/`、项目自身的 `__pycache__`（保留 `backend/.venv` 与 `microverse/.godot`——后者含 MCP bridge secret）。
- **涉及**：根目录 `*.log`、`microverse/*.log`、`backend/app/**/__pycache__`。

## 2026-11-13 | 首次推送 GitHub：远端非空 + microverse 嵌套 .git
- **现象**：`git push` 被拒（remote contains work that you do not have locally）；microverse/ 自带独立 `.git`，若直接提交会变成无 submodule 元数据的 gitlink。
- **原因**：远端 RookieApe-tao/AIXiaoZhen 已有 2 个早期文档提交；microverse 是上游基线的独立 clone。
- **解决**：删除 `microverse/.git` 并从根 `.gitignore` 移除 `microverse/`（用户确认纳入主仓库，secrets 由 microverse/.gitignore 覆盖）；远端历史用 `git merge origin/main --allow-unrelated-histories -s ours` 合并（保留历史、内容以本地为准）。
- **涉及**：`microverse/.git`、`.gitignore`、git push/merge 命令。

## 遗留风险备忘
- `sk-REDACTED.txt`：疑似明文 API Key 文件留在项目根目录，建议移入 `.env` 或环境变量并删除该文件，且不要提交到任何仓库。
- 删除 `.git` 后项目无版本控制，如需恢复历史请从远端（GitHub, SSH）重新 clone 或 `git init` 后推送。
