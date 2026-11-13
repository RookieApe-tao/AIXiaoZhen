"""AES-256-GCM 对称加密：玩家 BYOK api_key 落库加密（防 DB 脱库）。
密钥从 AIXIAOZHEN_BYOK_AES_KEY（32 字节 base64）取；未配则用 dev 固定密钥并告警（生产必须配置）。
"""
import base64
import hashlib
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

_DEV_KEY_WARNED = False


def _load_key() -> bytes:
    """返回 32 字节 AES 密钥。env 配 base64(32B)；未配 → dev 固定 + 告警一次。"""
    global _DEV_KEY_WARNED
    raw = os.getenv("AIXIAOZHEN_BYOK_AES_KEY", "").strip()
    if raw:
        key = base64.b64decode(raw)
        if len(key) != 32:
            raise RuntimeError("AIXIAOZHEN_BYOK_AES_KEY 必须是 32 字节的 base64")
        return key
    if not _DEV_KEY_WARNED:
        print("[crypto] 警告：未配 AIXIAOZHEN_BYOK_AES_KEY，用 dev 固定密钥（生产必须配置）")
        _DEV_KEY_WARNED = True
    # ponytail: dev 固定密钥（代码内），仅 dev 可接受；生产靠 env 注入
    return hashlib.sha256(b"aixiaozhen-dev-byok-key-CHANGE-ME").digest()


def encrypt(plain: str) -> bytes:
    """AES-256-GCM：返回 nonce(12B) + 密文。"""
    if not plain:
        return b""
    nonce = os.urandom(12)
    ct = AESGCM(_load_key()).encrypt(nonce, plain.encode("utf-8"), None)
    return nonce + ct


def decrypt(blob: bytes | None) -> str:
    if not blob:
        return ""
    nonce, ct = blob[:12], blob[12:]
    return AESGCM(_load_key()).decrypt(nonce, ct, None).decode("utf-8")
