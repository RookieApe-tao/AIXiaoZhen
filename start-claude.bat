@echo off
REM 切换到本 bat 所在目录（%~dp0 带末尾反斜杠）
cd /d "%~dp0"
REM 在新的 PowerShell 窗口中启动 Claude Code，并透传额外参数
start "Claude Code" powershell -NoExit -Command "claude --dangerously-skip-permissions %*"
