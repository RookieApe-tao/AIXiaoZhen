extends Node2D
class_name OutdoorTown
# 「数据驱动地图」：本场景只铺草地底 + 全图 navmesh。建筑/路/墙/树全部来自 chunk_json.tiles
# （预设 seed 时存 tiles 数据，创建小镇深拷贝，进镇时重放）。AI 言出法随的 place_tile 也走 set_tile 追加。
# 联机房间感知走后端 _room_index，本场景不建 RoomArea；墙纯视觉，移动碰撞 = navmesh 轮廓。

const TILE := 32
const SHEET := "res://asset/maps/exteriors/outdoor_atlas.png"

# outdoor_atlas.png（4×1，32px，Kenney roguelike-modern-city 裁切拼合，品红已清）
const GRASS := Vector2i(0, 0)   # 草地（绿）
const TREE := Vector2i(1, 0)    # 树（装饰）
const ROAD := Vector2i(2, 0)    # 路/墙（灰铺装）
const ROOF := Vector2i(3, 0)    # 屋顶/室内地板（红棕）

# tile_type（后端 place_tile 的语义名）→ atlas 坐标。AI 建造用的词汇表。
const TILE_TYPES := {
	"grass": GRASS,
	"tree": TREE,
	"road": ROAD,
	"wall": ROAD,   # 墙与路同灰
	"floor": ROOF,  # 地板与屋顶同红棕
	"roof": ROOF,
}


func _ready() -> void:
	_build_tiles()
	_build_navmesh()


func _build_tiles() -> void:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	var src := TileSetAtlasSource.new()
	src.texture = load(SHEET)
	src.texture_region_size = Vector2i(TILE, TILE)
	# 运行时设 texture 不会自动切片，须显式 create_tile（否则 set_cell 静默不渲染 → 黑图）
	for at in [GRASS, TREE, ROAD, ROOF]:
		src.create_tile(at)
	ts.add_source(src, 0)
	var layer := TileMapLayer.new()
	layer.name = "Tiles"
	layer.tile_set = ts
	add_child(layer)

	# 草地底（36×22 格 = 1152×704），建筑/路/墙由 chunk_json.tiles 进镇时重放铺上
	for x in range(36):
		for y in range(22):
			layer.set_cell(Vector2i(x, y), 0, GRASS)
	print("[outdoor-town] grass placed=", layer.get_used_cells().size())


# AI 建造 tile：tile_type（grass/tree/road/wall/floor/roof）→ set_cell。pos 是 tile 网格坐标。
# 供 OnlineWorld 处理 place_tile 调用；未知类型静默忽略（不崩）。
func set_tile(tile_type: String, pos: Vector2i) -> void:
	var at = TILE_TYPES.get(tile_type.to_lower())
	if at == null:
		return
	var layer = get_node_or_null("Tiles")
	if layer == null:
		return
	layer.set_cell(pos, 0, at)


# 删除 tile：改回草地。pos 是 tile 网格坐标。
func remove_tile(pos: Vector2i) -> void:
	var layer = get_node_or_null("Tiles")
	if layer == null:
		return
	layer.set_cell(pos, 0, GRASS)


# 非草地 tile（建造内容：路/墙/地板/树）的像素 bounding box。空返回 null。
# OnlineWorld 开局相机居中用。
func get_built_rect() -> Rect2:
	var layer = get_node_or_null("Tiles")
	if layer == null:
		return Rect2()
	var min_v := Vector2i(INF, INF)
	var max_v := Vector2i(-INF, -INF)
	for at in [TREE, ROAD, ROOF]:
		for cell in layer.get_used_cells_by_id(0, at):
			min_v = min_v.min(cell)
			max_v = max_v.max(cell)
	if min_v.x == INF:
		return Rect2()
	# 格坐标→像素：扩半格到 tile 边缘
	return Rect2(Vector2(min_v) * TILE, Vector2(max_v - min_v + Vector2i.ONE) * TILE)


func _build_navmesh() -> void:
	var nav := NavigationRegion2D.new()
	nav.name = "NavigationRegion2D"
	var poly := NavigationPolygon.new()
	# 全图可走（36×22 格 = 1152×704）。建筑墙纯视觉，NPC 可穿过——2D 俯视下墙是装饰，
	# 用户要求全图都能走，故不挖墙洞（ponytail: 要墙碰撞时再加 hole outline）。
	var outline := PackedVector2Array([
		Vector2(0, 0), Vector2(1152, 0), Vector2(1152, 704), Vector2(0, 704),
	])
	poly.add_outline(outline)
	poly.make_polygons_from_outlines()
	print("[outdoor-town] navmesh polygons=", poly.get_polygon_count())
	nav.navigation_polygon = poly
	add_child(nav)
