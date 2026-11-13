extends Node2D
# net_proto 主控：开房/加入 + 用 MultiplayerSpawner 在各端复制玩家
# 客户端权威（每 peer 权威自己玩家）——这一步只验证同步管道；混合权威是下一步。

const PORT := 7000
const MAX_CLIENTS := 20
const player_scene := preload("res://player.tscn")

var status_label: Label


func _ready() -> void:
	# MultiplayerSpawner：服务器 spawn 玩家时，自动在各客户端复制同名节点
	var spawner := MultiplayerSpawner.new()
	spawner.name = "Spawner"
	add_child(spawner)  # spawner 与 Players 作为兄弟节点
	spawner.spawn_path = ^"../Players"  # spawner 在 World 下，Players 是其兄弟节点
	spawner.spawn_function = _spawn_player

	_build_ui()

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_ok)
	multiplayer.connection_failed.connect(_on_connected_fail)
	_set_status("点 Host 开房，或填 IP 点 Join")


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var box := VBoxContainer.new()
	box.position = Vector2(20, 20)
	box.custom_minimum_size = Vector2(280, 0)
	canvas.add_child(box)

	var host_btn := Button.new()
	host_btn.text = "Host (开房)"
	host_btn.pressed.connect(_on_host)
	box.add_child(host_btn)

	var row := HBoxContainer.new()
	box.add_child(row)
	var addr_edit := LineEdit.new()
	addr_edit.text = "127.0.0.1"
	addr_edit.custom_minimum_size = Vector2(180, 0)
	row.add_child(addr_edit)
	var join_btn := Button.new()
	join_btn.text = "Join"
	join_btn.pressed.connect(_on_join.bind(addr_edit))
	row.add_child(join_btn)

	status_label = Label.new()
	status_label.custom_minimum_size = Vector2(280, 40)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status_label)


# MultiplayerSpawner 的 spawn_function：服务器与各客户端都会调用，data = peer id
func _spawn_player(data) -> Node:
	var p: CharacterBody2D = player_scene.instantiate()
	p.set_multiplayer_authority(int(data))
	p.name = str(data)
	# 基于 id 的确定性初始位置，避免各端随机分叉（Synchronizer 之后仍会持续同步）
	p.position = Vector2(400 + (int(data) % 10) * 60, 300)
	# 关键：在进树前配好 replication_config，否则 on_replication_start 会报 ERR_UNCONFIGURED
	var cfg := SceneReplicationConfig.new()
	cfg.add_property(".:position")
	p.get_node("Synchronizer").replication_config = cfg
	return p


func add_player(id: int) -> void:
	$Spawner.spawn(id)


func _on_host() -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_CLIENTS)
	if err != OK:
		_set_status("开房失败 %s（端口 %d 被占用?）" % [err, PORT])
		return
	multiplayer.multiplayer_peer = peer
	add_player(1)  # 服务器自己
	_set_status("已开房 (端口 %d)，等别人 Join。你的色块是绿色。" % PORT)


func _on_join(addr_edit: LineEdit) -> void:
	var addr := addr_edit.text.strip_edges()
	if addr.is_empty():
		addr = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(addr, PORT)
	if err != OK:
		_set_status("连接失败 %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	_set_status("连接中 %s:%d ..." % [addr, PORT])


func _on_peer_connected(id: int) -> void:
	_set_status("peer 连接: %d" % id)
	# 只有服务器负责 spawn 新玩家；客户端由 Spawner 自动复制
	if multiplayer.is_server():
		add_player(id)


func _on_peer_disconnected(id: int) -> void:
	_set_status("peer 断开: %d" % id)
	if multiplayer.is_server():
		var p := $Players.get_node_or_null(str(id))
		if p:
			p.queue_free()


func _on_connected_ok() -> void:
	_set_status("已连上服务器。你的色块是绿色，WASD 移动。")


func _on_connected_fail() -> void:
	_set_status("连接失败，检查 IP/端口或对方是否已 Host。")


func _set_status(t: String) -> void:
	if status_label:
		status_label.text = t
	print("[net_proto] ", t)
