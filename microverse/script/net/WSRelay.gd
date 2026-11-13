extends Node
class_name WSRelay
# WebSocket 中继客户端：连接到后台 /ws/town/{town_id}?token=JWT
# 替代 ENetMultiplayerPeer，所有实时消息通过后台转发。

signal connected(p_pid: int)
signal disconnected()
signal message_received(msg: Dictionary)

var _ws: WebSocketPeer
var _connected: bool = false


func connect_to_town(town_id: int, jwt: String) -> void:
	if _ws:
		_ws.close()
	_ws = WebSocketPeer.new()
	var ws_url = GameSession.api_base.replace("http://", "ws://") + "/ws/town/%d?token=%s" % [town_id, jwt]
	var err = _ws.connect_to_url(ws_url)
	if err != OK:
		push_error("[ws] connect_to_url failed: %d, url=%s" % [err, ws_url])
		return
	print("[ws] connecting to town=%d ..." % town_id)


func send(msg: Dictionary) -> void:
	if not _connected:
		return
	var text = JSON.stringify(msg)
	_ws.send_text(text)

func send_to(pid: int, msg: Dictionary) -> void:
	if not _connected:
		return
	msg["to_pid"] = pid
	var text = JSON.stringify(msg)
	_ws.send_text(text)


func close() -> void:
	_connected = false
	if _ws:
		_ws.close()
		_ws = null


func _process(_delta):
	if not _ws:
		return
	_ws.poll()
	var state = _ws.get_ready_state()
	match state:
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				# pid 会在 peer_join 消息里收到
		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				disconnected.emit()
				print("[ws] connection closed")
			return
		WebSocketPeer.STATE_CONNECTING:
			return  # still waiting
	# 收消息
	while _ws.get_available_packet_count() > 0:
		var pkt = _ws.get_packet()
		if pkt == null:
			continue
		var data = pkt.get_string_from_utf8()
		var msg = JSON.parse_string(data)
		if typeof(msg) != TYPE_DICTIONARY:
			continue
		var t = msg.get("t", "")
		if t == "peer_join" and msg.get("pid") != null:
			if GameSession.pid == 0:
				# 自己的第一条 peer_join：初始化 pid/host
				GameSession.pid = msg["pid"]
				GameSession.is_host = msg.get("host", false)
				print("[ws] peer_join pid=%d host=%s (自己)" % [GameSession.pid, GameSession.is_host])
				connected.emit(GameSession.pid)
			else:
				# 别人的 peer_join：转发给 OnlineWorld 处理
				message_received.emit(msg)
		else:
			message_received.emit(msg)
