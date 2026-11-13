"""业务接口鉴权：bcrypt 密码 + JWT + 依赖。
admins 表为业务接口鉴权用（§5.8.3：管理后台主账号走 Directus 的 directus_users）。"""
import os
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session

from .database import get_db
from . import models

# 直接用 bcrypt，不经 passlib（passlib 1.7.4 与 bcrypt 5.x 不兼容）

# ponytail: dev 默认密钥；生产必须由 env 注入强随机值
_JWT_SECRET = os.getenv("AIXIAOZHEN_JWT_SECRET", "aixiaozhen-dev-jwt-secret-CHANGE-ME")
_JWT_ALG = "HS256"

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/admin/login")

# 玩家鉴权（与 admin 密钥隔离，§5.7.2）
_PLAYER_JWT_SECRET = os.getenv("AIXIAOZHEN_PLAYER_JWT_SECRET", "aixiaozhen-dev-player-jwt-secret-CHANGE-ME")
player_oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")


def hash_password(pw: str) -> str:
    return bcrypt.hashpw(pw.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(pw: str, pw_hash: str) -> bool:
    try:
        return bcrypt.checkpw(pw.encode("utf-8"), pw_hash.encode("utf-8"))
    except (ValueError, TypeError):
        return False


def create_access_token(admin_id: int, role: str, ttl_minutes: int = 120) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(admin_id),
        "role": role,
        "iat": now,
        "exp": now + timedelta(minutes=ttl_minutes),
    }
    return jwt.encode(payload, _JWT_SECRET, algorithm=_JWT_ALG)


def _decode(token: str) -> dict:
    try:
        return jwt.decode(token, _JWT_SECRET, algorithms=[_JWT_ALG])
    except jwt.PyJWTError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="无效或过期 token")


def create_player_token(user_id: int, role: str, token_version: int = 0, ttl_minutes: int = 1440) -> str:
    """玩家 token（默认 24h）。token_version 用于单端登录：登录 ++ 使旧 token 失效。"""
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "role": role,
        "tv": token_version,
        "iat": now,
        "exp": now + timedelta(minutes=ttl_minutes),
    }
    return jwt.encode(payload, _PLAYER_JWT_SECRET, algorithm=_JWT_ALG)


def _decode_player(token: str) -> dict:
    try:
        return jwt.decode(token, _PLAYER_JWT_SECRET, algorithms=[_JWT_ALG])
    except jwt.PyJWTError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="无效或过期 token")


def get_current_admin(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> models.Admin:
    payload = _decode(token)
    try:
        admin_id = int(payload.get("sub", 0))
    except (TypeError, ValueError):
        admin_id = 0
    admin = db.get(models.Admin, admin_id)
    if not admin:
        raise HTTPException(status_code=401, detail="管理员不存在")
    return admin


def require_role(*roles: str):
    """依赖工厂：校验 admin.role ∈ roles，否则 403。"""
    def _dep(admin: models.Admin = Depends(get_current_admin)) -> models.Admin:
        if admin.role not in roles:
            raise HTTPException(status_code=403, detail="权限不足")
        return admin
    return _dep


def get_current_user(
    token: str = Depends(player_oauth2_scheme),
    db: Session = Depends(get_db),
) -> models.User:
    """玩家 JWT → User。与 get_current_admin 不同密钥、不同表。"""
    payload = _decode_player(token)
    try:
        user_id = int(payload.get("sub", 0))
    except (TypeError, ValueError):
        user_id = 0
    user = db.get(models.User, user_id)
    if not user:
        raise HTTPException(status_code=401, detail="用户不存在")
    # 单端登录：JWT 的 tv 必须等于当前 token_version，否则已被别处登录挤掉
    if int(payload.get("tv", -1)) != user.token_version:
        raise HTTPException(status_code=401, detail="账号在别处登录，请重新登录")
    # 封禁生效：管理员封禁后 user.status=banned，即使 token 仍在也拒绝（封禁时 ++token_version 使旧端被踢）
    if user.status == "banned":
        raise HTTPException(status_code=403, detail="账号已被封禁")
    return user
