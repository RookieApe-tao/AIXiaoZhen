extends Node
# 音频管理器 autoload：BGM 循环 + UI 音效（Kenney CC0 素材 asset/audio/）。
# 纯客户端本地：静音/音量落 user://audio.json，不联网。BYOK 无后端音频依赖。

var _bgm: AudioStreamPlayer
var _sfx_pool: Array[AudioStreamPlayer] = []
var _cache: Dictionary = {}
var bgm_muted := false
var sfx_muted := false

const BGM_PATH := "res://asset/audio/bgm.ogg"
const SFX_OPEN := "res://asset/audio/ui/click1.ogg"
const SFX_CLOSE := "res://asset/audio/ui/switch1.ogg"


func _ready() -> void:
	_bgm = AudioStreamPlayer.new()
	_bgm.bus = "Master"
	_bgm.volume_db = -14.0   # BGM 压低，不盖过对话/气泡
	add_child(_bgm)
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_sfx_pool.append(p)
	_load_state()


func _load(path: String) -> AudioStream:
	if not _cache.has(path):
		_cache[path] = load(path)
	return _cache[path]


func play_bgm() -> void:
	var s := _load(BGM_PATH)
	if s == null or (_bgm.stream == s and _bgm.playing):
		return
	if s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true   # 长循环 BGM，无缝 loop
	_bgm.stream = s
	if not bgm_muted:
		_bgm.play()
		print("[audio] BGM 已播放（循环）%s" % BGM_PATH)


func stop_bgm() -> void:
	_bgm.stop()


func play_open() -> void:
	_play_sfx(SFX_OPEN)


func play_close() -> void:
	_play_sfx(SFX_CLOSE)


func _play_sfx(path: String) -> void:
	if sfx_muted:
		return
	var s := _load(path)
	if s == null:
		return
	for p in _sfx_pool:
		if not p.playing:
			p.stream = s
			p.play()
			return


func toggle_bgm_muted() -> void:
	bgm_muted = not bgm_muted
	if bgm_muted:
		_bgm.stop()
	elif _bgm.stream != null:
		_bgm.play()
	_save_state()


func toggle_sfx_muted() -> void:
	sfx_muted = not sfx_muted
	_save_state()


func _load_state() -> void:
	if not FileAccess.file_exists(_state_path()):
		return
	var f := FileAccess.open(_state_path(), FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if data is Dictionary:
		bgm_muted = bool(data.get("bgm_muted", false))
		sfx_muted = bool(data.get("sfx_muted", false))


func _save_state() -> void:
	var f := FileAccess.open(_state_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"bgm_muted": bgm_muted, "sfx_muted": sfx_muted}))
	f.close()


func _state_path() -> String:
	return "user://audio.json"
