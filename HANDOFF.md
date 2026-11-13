# HANDOFF：扩充 NPC 言出法随素材（339 个 office_objects sprite）

## 任务目标

把 `microverse/asset/singleObjects/office_objects/` 目录下 **339 个家具 sprite**（`Modern_Office_Singles_32x32_1.png` ~ `_339.png`，Kenney Modern Office 俯视 32px 单体）映射成 NPC 言出法随（place_prefab）可用的素材，让建造工能摆更多家具。

## 当前状态（2026-08-16 已验收）

- **AI 造镇已完成**：「室外小镇」预设 = 纯草坪空地图，两个建造工（建造者阿强/小美）通过 `place_tile`（铺墙/地板/路/树）+ `place_prefab`（放家具）从零建小镇。
- **地图数据化**：建筑布局存 `chunk_json.tiles`（DB），每小镇独立，改预设不影响已有小镇。
- **已映射素材**（很少）：
  - 家具 6 种：`chair`(110)/`back_chair`(106)/`front_chair`(101) 走场景（可坐），`desk`(223)/`coffee_machine`(320)/`plant`(339) 走 sprite。
  - tile 6 名 4 图：`grass`/`tree`/`road`(=wall)/`roof`(=floor)。
  - 其余 330+ 个 sprite 全躺在目录里没映射。

## 加素材要改的地方（关键：4 处同步，漏一处就脱节）

1. **客户端渲染映射** `microverse/script/net/OnlineWorld.gd` → `PREFAB_SPRITES`
   ```gdscript
   "sofa": {"num": 200, "ox": 16, "oy": -32},   # 名字 → sprite 编号 + 底边对齐偏移
   ```
   - `ox/oy`：让 sprite **底边对齐 pos**（脚部对齐消除浮空）。`oy ≈ -(sprite高度/2)`，精确要量 alpha bbox。
   - 已有参照：desk `ox:16 oy:-32`（32×46）、coffee_machine `ox:0 oy:-14`（52×64）、plant `ox:0 oy:-25`（62×50）。
   - 大件（64×96 家具）用 `num` 直接指向对应 PNG；`PREFAB_FALLBACK` 是未知名兜底（现指向 desk 223）。

2. **tile 类型**（若加新地面/装饰）`microverse/script/net/OutdoorTown.gd` → `TILE_TYPES`

3. **prompt 词表（LLM 知道的）** 三处同一文案：
   - `backend/app/config.py` → `prompt_detail_map_edit`（seed 默认值）
   - `microverse/script/net/NetworkNPCBrain.gd` → `FALLBACK_DETAIL_MAP_EDIT`（DB 拉取失败兜底）
   - **DB sysconfig**（运行时实际用的，seed 不覆盖已存在项，改完要脚本 upsert）：
     ```bash
     cd backend && .venv/Scripts/python.exe - << 'EOF'
     from app.database import engine
     from sqlalchemy import text
     with engine.begin() as conn:
         conn.execute(text("UPDATE sysconfig SET value=:v WHERE key='prompt_detail_map_edit'"), {"v": "<新 prompt 全文>"})
     EOF
     ```

## ⚠️ 关键设计决策（先跟用户确认）

**「339 全部放进去」要分清两层：**

| 层 | 放 339 个？ | 成本 |
|----|-----------|------|
| **客户端映射** `PREFAB_SPRITES` | ✅ 可以全放 | **零 token**（纯代码字典）|
| **prompt 词表** `prompt_detail_map_edit` | ❌ 不要全放 | 词表爆长 + LLM 面对 339 个选择会困惑/乱选 |

**建议**：映射表全放（339 个都能渲染），prompt 词表**精选 20~50 个常用家具**（按语义分组：座椅/桌柜/电器/绿植/装饰），其余靠 `<<prefabs>>` 已注入的「附近家具名」让 LLM 按需引用。

## sprite 语义识别方法（本环境关键坑）

- **Read 图片工具对 PNG 返回 `[Unsupported Image]`，看图不可靠** → 用 PIL 像素特征分类：
  ```python
  from PIL import Image
  im = Image.open(f"office_objects/Modern_Office_Singles_32x32_{n}.png").convert("RGBA")
  px = [p for p in im.getdata() if p[3] > 100]   # 不透明像素
  # 绿占比 → 植物；暖棕(r>g>b) → 木家具；灰(r≈g≈b) → 电器/金属；尺寸=alpha bbox
  ```
- 已知参考编号：110=椅子 106=靠背椅 101=前向椅 223=办公桌 320=咖啡机 339=盆栽。
- 大件区：`#190-339` 是家具（#1-189 多为地板/墙 tile）；64×64 是柜/桌（#249/259/290/300 暖棕），52×64 是电器（#317-328）。

## 验证流程

1. 起服务：后端 `.venv/Scripts/python.exe -m uvicorn app.main:app`（端口 8000）+ 客户端 `D:\Godot\Godot_v4.7.1-stable_win64.exe --path E:\AiXiaoZhen\microverse`。
2. 测试账号 `ownA/pwA11111`、`ownB/pwB11111`（BYOK=DeepSeek）。
3. Lobby「生成预设 NPC」→ 建 5 个（含两个建造工）→ 创建「室外小镇」→ 进镇看建造工放新家具。
4. 改完 `.gd` 用 preload 探针 force-parse（主场景 Lobby 不懒加载 NPC 脚本，headless 测不出 parse 错）：
   ```bash
   "D:\Godot\Godot_v4.7.1-stable_win64.exe" --headless --path E:\AiXiaoZhen\microverse --quit-after 2 2>&1 | grep -E "SCRIPT ERROR|Parse Error"
   ```
5. 看日志 `[map] 放置 XX` / tail `E:\AiXiaoZhen\client.log`。

## 关键坑（本轮踩过，别重犯）

- **SQLAlchemy JSONB 浅拷贝**：`chunk = dict(map_row.chunk_json)` 后原地 `tiles.append` 不落库 → 用 `copy.deepcopy`（已修 maps.py）。
- **Kenney roguelike tile 裁切**：16px+1px margin，正确 crop `(cx*17, cy*17)`（+1 偏移会裁进品红边）。
- **改 .gd 用本地 Edit + 精确 tab**，勿用 sed；GDScript 跨 await 必须显式类型。
- 前后端 prompt 词表 3 处不同步 = LLM 说家具名但客户端 fallback 成 desk 图。
