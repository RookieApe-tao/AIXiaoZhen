-- AI小镇 · 数据库 Schema（游戏核心 + 管理后台）
-- PostgreSQL 15+ + pgvector ｜ 主键 bigint ｜ 时间 timestamptz ｜ 软删除
-- 决策：embedding 管理员统一配（vector(1024)）；建角色先玩后审（characters.is_active 默认 TRUE）

CREATE EXTENSION IF NOT EXISTS vector;

-- ============================ 游戏核心 ============================

CREATE TABLE users (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username VARCHAR(64) NOT NULL UNIQUE,
    email VARCHAR(255) UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(32) NOT NULL DEFAULT 'player',      -- player/creator/resident/observer
    status VARCHAR(32) NOT NULL DEFAULT 'active',    -- active/banned
    byok_api_type VARCHAR(32),                       -- BYOK 提供商（APIConfig provider 名：Ollama/OpenAI/DeepSeek/...）
    byok_model VARCHAR(128),                         -- BYOK 模型名（如 deepseek-chat）
    byok_api_key_enc BYTEA,                          -- AES-256 加密的玩家 BYOK api_key（脱库保护；GET 解密返回本人）
    token_version INTEGER NOT NULL DEFAULT 0,        -- 单端登录：登录 ++ 使旧 token 失效（挤掉旧端）
    settings_json JSONB NOT NULL DEFAULT '{}',
    banned_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_users_role   ON users(role)   WHERE deleted_at IS NULL;
CREATE INDEX idx_users_status ON users(status) WHERE deleted_at IS NULL;

CREATE TABLE towns (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    creator_id BIGINT NOT NULL REFERENCES users(id),
    name VARCHAR(128) NOT NULL,
    config_json JSONB NOT NULL DEFAULT '{}',
    weather VARCHAR(64) NOT NULL DEFAULT 'clear',
    time_scale REAL NOT NULL DEFAULT 1.0,
    status VARCHAR(32) NOT NULL DEFAULT 'active',    -- active/paused/destroyed
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_towns_creator ON towns(creator_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_towns_status  ON towns(status)     WHERE deleted_at IS NULL;

CREATE TABLE characters (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id BIGINT NOT NULL REFERENCES users(id),
    town_id BIGINT REFERENCES towns(id),
    name VARCHAR(64) NOT NULL,
    appearance_json JSONB NOT NULL DEFAULT '{}',
    personality_json JSONB NOT NULL DEFAULT '{}',
    background TEXT,
    system_prompt TEXT,
    core_memories_json JSONB NOT NULL DEFAULT '[]',
    review_status VARCHAR(32) NOT NULL DEFAULT 'pending',  -- pending/approved/rejected/edited
    is_active BOOLEAN NOT NULL DEFAULT TRUE,               -- 先玩后审：默认立即可用
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_characters_owner  ON characters(owner_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_characters_town   ON characters(town_id)  WHERE deleted_at IS NULL;
CREATE INDEX idx_characters_review ON characters(review_status) WHERE deleted_at IS NULL;

CREATE TABLE map_data (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    town_id BIGINT NOT NULL REFERENCES towns(id),
    chunk_json JSONB NOT NULL DEFAULT '{}',
    prefabs_json JSONB NOT NULL DEFAULT '[]',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_mapdata_town ON map_data(town_id);

CREATE TABLE chat_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    town_id BIGINT REFERENCES towns(id),
    speaker_id BIGINT REFERENCES characters(id),
    listener_id BIGINT REFERENCES characters(id),
    content TEXT NOT NULL,
    ai_score REAL,                  -- AI 审查可疑度 0-1（运行时审查挂钩）
    is_flagged BOOLEAN NOT NULL DEFAULT FALSE,  -- 敏感词/AI 命中
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_chatlogs_town     ON chat_logs(town_id, created_at);
CREATE INDEX idx_chatlogs_flagged  ON chat_logs(is_flagged) WHERE is_flagged;
CREATE INDEX idx_chatlogs_speaker  ON chat_logs(speaker_id);

CREATE TABLE memory_vectors (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    character_id BIGINT NOT NULL REFERENCES characters(id),
    content TEXT NOT NULL,
    embedding vector(1024) NOT NULL,            -- 管理员统一 embedding 模型维度
    memory_type VARCHAR(32) NOT NULL DEFAULT 'personal',  -- personal/interaction/task/emotion/event
    importance SMALLINT NOT NULL DEFAULT 3,     -- 1-10
    emotion_weight REAL NOT NULL DEFAULT 1.0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_memory_character ON memory_vectors(character_id);
-- ponytail: ivfflat lists=100 适配 ~10万条量级；记忆上百万后重建调 lists 或换 HNSW
CREATE INDEX idx_memory_embedding ON memory_vectors
    USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ============================ 管理后台（§5.8）============================

CREATE TABLE admins (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username VARCHAR(64) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(32) NOT NULL DEFAULT 'reviewer',   -- super/reviewer
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE prompt_reviews (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type VARCHAR(32) NOT NULL,         -- system_prompt/chat_output
    target_id BIGINT NOT NULL,         -- characters.id 或 chat_logs.id
    target_type VARCHAR(32) NOT NULL,  -- character/chat
    content TEXT NOT NULL,
    ai_score REAL,                     -- AI 审查可疑度 0-1
    ai_tags_json JSONB NOT NULL DEFAULT '[]',   -- AI 打的违规标签
    status VARCHAR(32) NOT NULL DEFAULT 'pending',  -- pending/approved/rejected/edited
    reviewer_id BIGINT REFERENCES admins(id),
    reviewed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_reviews_status      ON prompt_reviews(status, created_at);
CREATE INDEX idx_reviews_type_target ON prompt_reviews(type, target_id);

CREATE TABLE audit_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    admin_id BIGINT NOT NULL REFERENCES admins(id),
    action VARCHAR(64) NOT NULL,       -- ban_user/edit_character/reset_memory/...
    target_type VARCHAR(32) NOT NULL,
    target_id BIGINT,
    before_json JSONB,
    after_json JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- 仅追加：应用层禁止 UPDATE/DELETE；数据量大后按 created_at 分区
CREATE INDEX idx_audit_admin  ON audit_logs(admin_id, created_at);
CREATE INDEX idx_audit_target ON audit_logs(target_type, target_id);

CREATE TABLE sensitive_words (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    word VARCHAR(128) NOT NULL,
    category VARCHAR(64),              -- 政治/色情/暴力/广告...
    level SMALLINT NOT NULL DEFAULT 1, -- 1-3 严重度
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_sensitive_enabled ON sensitive_words(word) WHERE enabled;

CREATE TABLE sysconfig (
    key VARCHAR(128) PRIMARY KEY,                    -- 配置项主键（默认值定义在后端 app/config.py，启动自动 seed）
    value TEXT,
    value_type VARCHAR(32) NOT NULL DEFAULT 'string',  -- string/int/float/bool/json
    category VARCHAR(64),
    description TEXT,
    encrypted BOOLEAN NOT NULL DEFAULT FALSE,        -- TRUE 时 value 为 AES-256 加密串
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
