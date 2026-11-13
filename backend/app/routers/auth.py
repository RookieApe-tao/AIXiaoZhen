"""玩家鉴权（/auth）：注册 / 登录 / 本人信息。与 /admin JWT 密钥隔离（§5.7.2）。"""
from fastapi import APIRouter, Body, Depends, HTTPException
from sqlalchemy import exc, select
from sqlalchemy.orm import Session

from .. import crypto, models
from ..auth import create_player_token, get_current_user, hash_password, verify_password
from ..database import get_db
from ..schemas import ByokSettings, ByokSettingsUpdate, PlayerLoginRequest, PlayerRegisterRequest, PlayerTokenResponse, UserOut

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=PlayerTokenResponse, status_code=201)
def register(body: PlayerRegisterRequest, db: Session = Depends(get_db)):
    if not body.username or not body.password:
        raise HTTPException(400, "用户名与密码不能为空")
    try:
        user = models.User(
            username=body.username,
            email=body.email or None,
            password_hash=hash_password(body.password),
            role="player",
            status="active",
        )
        db.add(user)
        db.commit()
        db.refresh(user)
    except exc.IntegrityError:
        db.rollback()
        raise HTTPException(409, "用户名或邮箱已被注册")
    user.token_version += 1
    db.commit()
    token = create_player_token(user.id, user.role, user.token_version)
    return PlayerTokenResponse(
        access_token=token,
        role=user.role,
        user=UserOut.model_validate(user),
    )


@router.post("/login", response_model=PlayerTokenResponse)
def login(body: PlayerLoginRequest, db: Session = Depends(get_db)):
    user = db.scalar(select(models.User).where(models.User.username == body.username))
    if not user or not verify_password(body.password, user.password_hash):
        raise HTTPException(401, "用户名或密码错误")
    user.token_version += 1  # 挤掉旧端：使之前签发的 token 失效
    db.commit()
    token = create_player_token(user.id, user.role, user.token_version)
    return PlayerTokenResponse(
        access_token=token,
        role=user.role,
        user=UserOut.model_validate(user),
    )


@router.get("/me", response_model=UserOut)
def me(user: models.User = Depends(get_current_user)):
    return user


@router.get("/me/byok", response_model=ByokSettings)
def get_my_byok(user: models.User = Depends(get_current_user)):
    # api_key 解密回明文：客户端 BYOK 架构要求客户端拿明文 key 自己发请求；JWT 仅本人可取，加密只为防 DB 脱库
    return ByokSettings(
        api_type=user.byok_api_type,
        model=user.byok_model,
        api_key=crypto.decrypt(user.byok_api_key_enc),
    )


@router.put("/me/byok", response_model=ByokSettings)
def update_my_byok(
    body: ByokSettingsUpdate,
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    if body.api_type is not None:
        user.byok_api_type = body.api_type
    if body.model is not None:
        user.byok_model = body.model
    if body.api_key:  # 非空才更新；空/None 保留原值（前台"留空不改"语义）
        user.byok_api_key_enc = crypto.encrypt(body.api_key)
    db.commit()
    db.refresh(user)
    return ByokSettings(
        api_type=user.byok_api_type,
        model=user.byok_model,
        api_key=crypto.decrypt(user.byok_api_key_enc),
    )


# 玩家 UI 偏好（覆盖管理员默认值；按账号存 settings_json["ui"]）
@router.get("/me/ui_prefs")
def get_my_ui_prefs(user: models.User = Depends(get_current_user)):
    ui = user.settings_json.get("ui") if isinstance(user.settings_json, dict) else None
    return ui or {}


@router.put("/me/ui_prefs")
def update_my_ui_prefs(
    body: dict = Body(...),
    user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    settings = dict(user.settings_json) if isinstance(user.settings_json, dict) else {}
    settings["ui"] = body or {}  # 全量替换 ui 偏好；保留 settings_json 其他键
    user.settings_json = settings
    db.commit()
    return body or {}
