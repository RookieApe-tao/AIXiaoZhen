extends Node
# 跨场景会话状态 autoload。WebSocket 中继模式下所有客户端连后台，按 town_id 分组。

var is_host: bool = false           # pid==1 时为 true（由后台分配）
var pid: int = 0                    # 后台 WebSocket 分配的 peer id（1=房主）
var jwt: String = ""               # 玩家 JWT
var my_username: String = ""       # 玩家用户名（返回大厅时显示 welcome）
var character_id: int = 0
var character_name: String = "player"
var character_background: String = ""   # 旧方案（纯文本背景）
var character_persona: Dictionary = {}  # 结构化五字段人设（personality_json）
var npc_list: Array = []           # 用户带入房间的 NPC 角色
var controlling_npc: bool = false
var controlled_npc_name: String = ""
var api_base: String = "http://127.0.0.1:8000"
var kicked_reason: String = ""    # 单端登录被挤掉的原因
var lobby_message: String = ""    # 回大厅后弹窗显示
var chat_max_rounds: int = 8
var room_chat_max_rounds: int = 0
var room_max_npcs: int = 20
var npc_initial_items: Array = []  # 小镇默认 NPC 初始物品（进镇 spawn 时补给空物品栏的 own NPC）
var room_id: int = 0               # ponytail: 废弃
var town_id: int = 0
# 导演模式：房主权威推进，WS 写入，NPC 大脑 _world_context 只读注入（零 HTTP，热路径安全）
var game_clock_min: int = -1          # 游戏时钟（分钟，-1=未收到房主时钟）
var weather: String = "clear"
var time_scale: float = 1.0
var world_background: String = ""
var company_info: String = ""
var social_rules: String = ""
var active_events: Dictionary = {}    # {id: {kind, text}} 生效中事件（WS 增量维护，deactivate 按 id 移除）
var prompt_templates: Dictionary = {}  # NPC prompt 模板（/config/public 拉取，后台可改；缺失时 brain 用 FALLBACK）
var ui_config: Dictionary = {}  # UI 调参（生效值 = 默认值合并玩家覆盖）
var ui_defaults: Dictionary = {}  # 管理员默认值（/config/public）
var ui_prefs: Dictionary = {}  # 玩家自己的覆盖（/auth/me/ui_prefs，按账号；优先于默认值）
var my_user_id: int = 0

# Token 消耗统计（纯客户端本地：BYOK 直连 provider，后端看不到，客户端从响应 usage 累计）
# 每角色可配不同 provider/BYOK 账户 → 除全局合计外按角色分桶（跨 provider 单价不同，不宜直接相加）
var total_prompt_tokens := 0
var total_completion_tokens := 0
var token_usage: Dictionary = {}   # 角色名 → {provider, prompt_tokens, completion_tokens}
var _token_usage_loaded := false

# UI 调参 FALLBACK（与 backend config.py 默认值保持一致）
const FALLBACK_UI_FONT_SIZE := 24
const FALLBACK_BUBBLE_DURATION_SEC := 5.0
const FALLBACK_BUBBLE_FONT_SIZE := 12
const FALLBACK_SHOW_INTENT_LABEL := true


static func str_or(val, default: String = "") -> String:
	if val == null: return default
	if typeof(val) == TYPE_STRING: return val
	return str(val)


static func int_or(val, default: int = 0) -> int:
	if val == null: return default
	if typeof(val) == TYPE_INT or typeof(val) == TYPE_FLOAT: return int(val)
	if typeof(val) == TYPE_STRING and val.is_valid_int(): return int(val)
	return default


static func float_or(val, default: float) -> float:
	if val == null: return default
	if typeof(val) == TYPE_FLOAT or typeof(val) == TYPE_INT: return float(val)
	if typeof(val) == TYPE_STRING and val.is_valid_float(): return float(val)
	return default


static func bool_or(val, default: bool) -> bool:
	if val == null: return default
	if typeof(val) == TYPE_BOOL: return val
	if typeof(val) == TYPE_STRING: return val.to_lower() == "true"
	return default


# Token 消耗累计（每次 AI 响应后调用；落 user:// 本地文件，纯客户端统计）
# key=角色名（空=非 BYOK 请求，如 embedding，不落分桶）；provider=该角色的 api_type
func add_token_usage(key: String, provider: String, prompt_tokens: int, completion_tokens: int) -> void:
	if not _token_usage_loaded:
		_load_token_usage()
		_token_usage_loaded = true
	if prompt_tokens <= 0 and completion_tokens <= 0:
		return
	total_prompt_tokens += prompt_tokens
	total_completion_tokens += completion_tokens
	if not key.is_empty():
		var entry: Dictionary = token_usage.get(key, {"provider": provider, "prompt_tokens": 0, "completion_tokens": 0})
		entry["provider"] = provider
		entry["prompt_tokens"] = int(entry.get("prompt_tokens", 0)) + prompt_tokens
		entry["completion_tokens"] = int(entry.get("completion_tokens", 0)) + completion_tokens
		token_usage[key] = entry
	_save_token_usage()


func _load_token_usage() -> void:
	if not FileAccess.file_exists(_token_usage_path()):
		return
	var f := FileAccess.open(_token_usage_path(), FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary:
		total_prompt_tokens = int(data.get("prompt_tokens", 0))
		total_completion_tokens = int(data.get("completion_tokens", 0))
		if data.get("by_character") is Dictionary:
			token_usage = data["by_character"]


func _save_token_usage() -> void:
	var f := FileAccess.open(_token_usage_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"prompt_tokens": total_prompt_tokens, "completion_tokens": total_completion_tokens, "by_character": token_usage}))
	f.close()


func _token_usage_path() -> String:
	# ponytail: 按账号分文件（多账号同机不串），未登录 my_user_id=0 落共享占位
	return "user://token_usage_%d.json" % my_user_id


func rebuild_ui_config() -> void:
	# 生效值 = 默认值 ← 玩家覆盖（玩家优先）→ ui_config，再应用
	ui_config.clear()
	for k in ui_defaults:
		ui_config[k] = ui_defaults[k]
	for k in ui_prefs:
		ui_config[k] = ui_prefs[k]
	apply_ui_config()


func apply_ui_config() -> void:
	# UI 字号应用到项目默认主题（mutate 共享主题实例 → 全场 Control 生效）
	var t := load("res://asset/ui/theme/MainTheme.tres") as Theme
	if is_instance_valid(t):
		t.default_font_size = int_or(ui_config.get("ui_font_size", null), FALLBACK_UI_FONT_SIZE)