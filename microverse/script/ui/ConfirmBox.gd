extends RefCounted

# 通用二次确认框：主题化 Panel（ConfirmationDialog 是独立 Window 不吃项目主题，黑底蓝字丑）。
# 用法（调用方 const ConfirmBox := preload(...) 后）：
#   ConfirmBox.show_confirm(self, "标题", "正文", "确定", "取消", func(): ...)

static func show_confirm(parent: Node, title: String, text: String,
		ok_text: String = "确定", cancel_text: String = "取消",
		on_ok: Callable = Callable(), size := Vector2(500, 260)) -> void:
	# 挂独立 CanvasLayer：parent 是 Node2D 场景（如 OnlineWorld 带 Camera2D）时，
	# Control 子节点跟世界坐标走会被相机移偏；独立 layer 永远屏幕居中。
	var layer := CanvasLayer.new()
	layer.layer = 100   # 盖住游戏 HUD/面板
	parent.add_child(layer)
	# 半透明遮罩（拦点击，视觉聚焦）
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(dim)

	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = size
	panel.offset_left = -size.x / 2.0
	panel.offset_top = -size.y / 2.0
	panel.offset_right = size.x / 2.0
	panel.offset_bottom = size.y / 2.0
	layer.add_child(panel)

	var close_all := func() -> void:
		layer.queue_free()   # 整层一起释放

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	margin.add_child(vb)

	var title_l := Label.new()
	title_l.text = title
	title_l.add_theme_font_size_override("font_size", maxi(9, GameSession.int_or(GameSession.ui_config.get("ui_font_size", null), GameSession.FALLBACK_UI_FONT_SIZE) + 4))
	vb.add_child(title_l)
	vb.add_child(HSeparator.new())

	var body := Label.new()
	body.text = text
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(0, 44)   # 两行正文保底，短文案也留足按钮空间
	vb.add_child(body)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	vb.add_child(row)
	var cancel_b := Button.new()
	cancel_b.text = cancel_text
	cancel_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_b.pressed.connect(close_all)
	row.add_child(cancel_b)
	var ok_b := Button.new()
	ok_b.text = ok_text
	ok_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok_b.pressed.connect(func() -> void:
		close_all.call()
		if on_ok.is_valid():
			on_ok.call()
	)
	row.add_child(ok_b)
