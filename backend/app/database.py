import os
from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

load_dotenv()  # 加载 backend/.env
# ponytail: 用 127.0.0.1 而非 localhost，避免 IPv6(::1) 解析导致 Docker 端口连接被中断
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql+psycopg2://aixiaozhen:aixiaozhen_dev@127.0.0.1:5432/aixiaozhen")
engine = create_engine(DATABASE_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)


def get_db():
    """FastAPI 依赖：每请求一个 DB session。"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
