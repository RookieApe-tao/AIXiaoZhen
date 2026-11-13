extends RefCounted

# 新手教程卡片：仿 ConfirmBox 静态入口 + 实例方法持状态（GDScript lambda 按值捕获，
# 步数索引 i 不能靠 lambda 递增——CLAUDE.md lambda 坑①，写普通方法）。
# 两段式——Lobby 弹 ①②（讲大厅 UI），进镇后弹 ③④⑤⑥（讲世界内操作）。
# 无遮罩不拦点击：操作类教程要边看边在身后的世界里试。
# 用法：Tutorial.show(self, "lobby") / Tutorial.show(self, "town")
# 首次触发在 Lobby._show_lobby / OnlineWorld._on_ws_connected（看 tutorial_*_done 标志）；
# 重复入口：Lobby「？」按钮 / OnlineWorld 系统 tab「新手教程」。

const LOBBY_STEPS := [
	{"title": "① 账号与角色", "text": "「角色管理」新建你的居民：姓名、性格、说话风格、职务。「AI 设置」里填好 API Key，居民才会思考和说话（不会配看群里的《内测玩家指南》）。"},
	{"title": "② 小镇", "text": "左侧选一个小镇看详情，「进入小镇」会带上你勾选的居民一起入住。没有合适的就「新建小镇」。"},
]
const TOWN_STEPS := [
	{"title": "③ 上帝视角", "text": "你是这个镇的观察者：WASD 移动镜头，滚轮缩放，按住右键拖拽平移，空格回到选中居民身边。"},
	{"title": "④ 交互", "text": "左键点居民=选中（看它的面板）；点空地=指挥选中的居民走过去；B=附身控制它走路；按住 T 点另一个居民=强制他们对话；C=切换自己的居民；Tab=看在线玩家。"},
	{"title": "⑤ 面板", "text": "底部横排是功能区：设置 / 角色 / 状态 / 玩法 / 系统。点组标题展开具体功能，面板从右侧滑出（同时只开一个）。"},
	{"title": "⑥ 导演模式", "text": "你是房主：底部「导演」tab 可改天气、时间流速、世界观、发新闻——全镇居民都会感知到并做出反应。"},
]

static func show(parent: Node, segment: String) -> void:
	var t := new()
	# RefCounted 局部实例出作用域即释放——按钮连的是实例方法，实例没了就是死键。
	# _open 里 layer.set_meta 挂住本对象，layer 释放时自动一并释放。
	t._steps = LOBBY_STEPS if segment == "lobby" else TOWN_STEPS.duplicate()
	if segment == "town" and not GameSession.is_host:
		t._steps.remove_at(3)   # 非房主无导演 tab，剔除第 ⑥ 步（计数自动变 /5）
	t._key = "tutorial_%s_done" % segment
	t._open(parent)

var _steps: Array = []
var _key := ""
var _i := 0
var _layer: CanvasLayer
var _panel: Panel
var _margin: MarginContainer
var _title_l: Label
var _body: Label
var _next_b: Button

func _open(parent: Node) -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 100
	_layer.set_meta("tutorial", self)   # 挂住 RefCounted 本体，layer queue_free 时一并释放
	parent.add_child(_layer)

	var panel := Panel.new()
	_panel = panel
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(520, 240)
	# 定宽 520 居中，高度由 _draw 按文案实测自适应（防长文案/大字号溢出边框）
	panel.offset_left = -260.0
	panel.offset_right = 260.0
	panel.offset_top = -240.0
	panel.offset_bottom = 0.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP   # 点卡片本身不放行到世界（吞点击误指挥）
	_layer.add_child(panel)

	_margin = MarginContainer.new()
	_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_margin.add_theme_constant_override("margin_left", 20)
	_margin.add_theme_constant_override("margin_top", 16)
	_margin.add_theme_constant_override("margin_right", 20)
	_margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(_margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	_margin.add_child(vb)

	_title_l = Label.new()
	_title_l.add_theme_font_size_override("font_size", maxi(9, GameSession.int_or(GameSession.ui_config.get("ui_font_size", null), GameSession.FALLBACK_UI_FONT_SIZE) + 4))
	vb.add_child(_title_l)
	vb.add_child(HSeparator.new())

	_body = Label.new()
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(0, 64)
	vb.add_child(_body)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)
	var skip_b := Button.new()
	skip_b.text = "跳过教程"
	skip_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skip_b.pressed.connect(_close)
	row.add_child(skip_b)
	_next_b = Button.new()
	_next_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_next_b.pressed.connect(_on_next)
	row.add_child(_next_b)

	_draw()

func _on_next() -> void:
	if _i < _steps.size() - 1:
		_i += 1
		_draw()
	else:
		_close()

func _close() -> void:
	var s := SettingsManager.get_settings()
	s[_key] = true   # 完成/跳过统一写标志（幂等，帮助重开再写无害）
	SettingsManager.update_settings(s)
	_layer.queue_free()

func _draw() -> void:
	_title_l.text = "%s（%d/%d）" % [_steps[_i]["title"], _i + 1, _steps.size()]
	_body.text = _steps[_i]["text"]
	_next_b.text = "下一步" if _i < _steps.size() - 1 else "完成"
	# 高度自适应：按换行后正文的实际高度撑 Panel（定宽 520 居中偏上，防溢出边框）
	var avail_w := _panel.size.x - 40.0   # 左右 margin 20+20
	var fs := _body.get_theme_font_size("font_size")
	var text_h := _body.get_theme_font("font").get_multiline_string_size(
		_body.text, HORIZONTAL_ALIGNMENT_LEFT, avail_w, fs).y
	_body.custom_minimum_size = Vector2(0, maxf(64.0, text_h))
	await RenderingServer.frame_post_draw   # 等 Container 重算最小尺寸
	if _layer == null or not is_instance_valid(_layer):
		return
	var h := maxf(240.0, _margin.get_minimum_size().y)   # 最小尺寸=内容实高（size 是被面板撑开的 240）
	_panel.offset_top = -120.0 - h / 2.0
	_panel.offset_bottom = -120.0 + h / 2.0
