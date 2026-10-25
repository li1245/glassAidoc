-- DRAFT (v0.3): 场景、进化作业、作业审计、未满足需求（含缺硬件搁置）。
-- 作业与 Pi 会话 ID 以 PostgreSQL 为准；Hindsight 只存语义记录并以 job:<id> 标签引用。

CREATE TABLE agent_scenes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_]*$' AND length(kind) <= 40),
    state TEXT NOT NULL DEFAULT 'OPEN' CHECK (state IN ('OPEN', 'CLOSED')),
    opened_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_activity_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at TIMESTAMPTZ,
    summary_retained_at TIMESTAMPTZ,
    CHECK ((state = 'CLOSED') = (closed_at IS NOT NULL))
);
CREATE INDEX idx_agent_scenes_open ON agent_scenes(device_id, last_activity_at DESC) WHERE state = 'OPEN';

CREATE TABLE evolution_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    origin_scene_id UUID REFERENCES agent_scenes(id) ON DELETE SET NULL,
    skill_key VARCHAR(63) NOT NULL
        CHECK (length(skill_key) BETWEEN 2 AND 63 AND skill_key ~ '^[a-z][a-z0-9]*(-[a-z0-9]+)*$'),
    title TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    requirement_digest CHAR(64) NOT NULL CHECK (requirement_digest ~ '^[0-9a-f]{64}$'),
    feasibility TEXT NOT NULL CHECK (feasibility IN ('FEASIBLE', 'DEGRADED')),
    state TEXT NOT NULL DEFAULT 'QUEUED'
        CHECK (state IN ('QUEUED', 'GENERATING', 'TESTING', 'VERIFYING', 'READY_FOR_REVIEW',
                         'CONFIRMED', 'CLEANING', 'CLEANED', 'FAILED', 'ABANDONED', 'EXPIRED')),
    round INTEGER NOT NULL DEFAULT 0 CHECK (round >= 0),
    candidate_skill_id UUID,
    candidate_version INTEGER,
    pi_session_id TEXT,
    pi_session_file TEXT,
    pi_session_name TEXT,
    workspace_ref TEXT,
    lease_owner TEXT,
    lease_until TIMESTAMPTZ,
    token_budget BIGINT NOT NULL CHECK (token_budget > 0),
    tokens_used BIGINT NOT NULL DEFAULT 0 CHECK (tokens_used >= 0),
    review_notified_at TIMESTAMPTZ,
    confirmed_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    cleanup_due_at TIMESTAMPTZ,
    failure_code TEXT CHECK (failure_code IS NULL OR failure_code ~ '^[A-Z][A-Z0-9_]*$'),
    failure_detail JSONB CHECK (failure_detail IS NULL OR jsonb_typeof(failure_detail) = 'object'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (candidate_skill_id, candidate_version)
        REFERENCES agent_skill_versions(skill_id, version),
    CHECK ((candidate_skill_id IS NULL) = (candidate_version IS NULL)),
    CHECK (state <> 'READY_FOR_REVIEW' OR candidate_skill_id IS NOT NULL),
    CHECK (lease_owner IS NULL OR lease_until IS NOT NULL)
);
CREATE INDEX idx_evolution_jobs_device_state ON evolution_jobs(device_id, state, created_at DESC);
CREATE INDEX idx_evolution_jobs_lease ON evolution_jobs(lease_until)
    WHERE state IN ('QUEUED', 'GENERATING', 'TESTING', 'VERIFYING');
CREATE INDEX idx_evolution_jobs_expiry ON evolution_jobs(expires_at)
    WHERE state = 'READY_FOR_REVIEW';
CREATE INDEX idx_evolution_jobs_cleanup ON evolution_jobs(cleanup_due_at)
    WHERE state IN ('CONFIRMED', 'CLEANING', 'FAILED', 'ABANDONED', 'EXPIRED');

-- 追加式审计：只存脱敏摘要，不存提示词原文和个人记忆内容。
CREATE TABLE evolution_job_events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_id UUID NOT NULL REFERENCES evolution_jobs(id) ON DELETE CASCADE,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    kind TEXT NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_.]*$' AND length(kind) <= 64),
    detail JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(detail) = 'object')
);
CREATE INDEX idx_evolution_job_events_job ON evolution_job_events(job_id, id);

-- 未满足需求：反复出现会触发进化；缺硬件的需求进入搁置，硬件变化后重新评估。
CREATE TABLE unmet_needs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    need_key TEXT NOT NULL CHECK (length(need_key) BETWEEN 1 AND 160),
    kind TEXT NOT NULL CHECK (kind IN ('NO_SKILL', 'HARDWARE_GAP', 'DATA_GAP')),
    summary TEXT NOT NULL CHECK (length(summary) BETWEEN 1 AND 500),
    required_capabilities TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    status TEXT NOT NULL DEFAULT 'OPEN'
        CHECK (status IN ('OPEN', 'WAITING_HARDWARE', 'CONVERTED', 'DISMISSED')),
    occurrences INTEGER NOT NULL DEFAULT 1 CHECK (occurrences > 0),
    job_id UUID REFERENCES evolution_jobs(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (device_id, need_key)
);
CREATE INDEX idx_unmet_needs_status ON unmet_needs(device_id, status);

COMMENT ON TABLE evolution_jobs IS
    'Source of truth for generation jobs and their Pi session identifiers; cleanup and recovery never depend on Hindsight recall.';
COMMENT ON COLUMN evolution_jobs.requirement_digest IS
    'SHA-256 of the requirement/spec text; the text itself lives in the job workspace, not in this table.';
COMMENT ON COLUMN evolution_jobs.lease_owner IS
    'Runtime instance currently driving the job; expired leases let another instance resume it.';
