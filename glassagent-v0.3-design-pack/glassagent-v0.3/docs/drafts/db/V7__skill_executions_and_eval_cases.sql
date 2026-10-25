-- DRAFT (v0.3): 技能执行记录（试用与评测的信号来源）与带真值的评测用例。
CREATE TABLE skill_executions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL,
    skill_id UUID NOT NULL,
    version INTEGER NOT NULL,
    scene_id UUID REFERENCES agent_scenes(id) ON DELETE SET NULL,
    mode TEXT NOT NULL CHECK (mode IN ('LIVE', 'TRIAL', 'SHADOW', 'REPLAY')),
    outcome TEXT NOT NULL CHECK (outcome IN ('SUCCESS', 'FAILED', 'TIMEOUT', 'SKIPPED_HARDWARE', 'DRY_RUN')),
    started_at TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ,
    latency_ms INTEGER CHECK (latency_ms IS NULL OR latency_ms >= 0),
    hardware_errors TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    feedback TEXT CHECK (feedback IS NULL OR feedback IN ('HELPFUL', 'NOT_HELPFUL', 'DISMISS_FOREVER')),
    feedback_at TIMESTAMPTZ,
    summary JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(summary) = 'object'),
    FOREIGN KEY (skill_id, device_id) REFERENCES agent_skills(id, device_id) ON DELETE CASCADE,
    FOREIGN KEY (skill_id, version) REFERENCES agent_skill_versions(skill_id, version) ON DELETE CASCADE,
    CHECK ((feedback IS NULL) = (feedback_at IS NULL))
);
CREATE INDEX idx_skill_executions_skill ON skill_executions(skill_id, version, started_at DESC);
CREATE INDEX idx_skill_executions_device_time ON skill_executions(device_id, started_at DESC);

CREATE TABLE skill_eval_cases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id UUID NOT NULL,
    skill_id UUID NOT NULL,
    origin TEXT NOT NULL CHECK (origin IN ('USER_CORRECTION', 'TRIAL_FEEDBACK', 'CURATED', 'SYNTHETIC')),
    label TEXT CHECK (label IS NULL OR label IN ('POSITIVE', 'NEGATIVE')),
    input JSONB NOT NULL CHECK (jsonb_typeof(input) = 'object'),
    expected JSONB CHECK (expected IS NULL OR jsonb_typeof(expected) = 'object'),
    fixture_refs JSONB NOT NULL DEFAULT '[]'::JSONB CHECK (jsonb_typeof(fixture_refs) = 'array'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    retain_until TIMESTAMPTZ NOT NULL,
    FOREIGN KEY (skill_id, device_id) REFERENCES agent_skills(id, device_id) ON DELETE CASCADE,
    CHECK (retain_until > created_at)
);
CREATE INDEX idx_skill_eval_cases_skill ON skill_eval_cases(skill_id, created_at DESC);

COMMENT ON TABLE skill_eval_cases IS
    'Sanitized replay cases with ground truth; inputs are personal data and must expire at retain_until.';
COMMENT ON COLUMN skill_executions.summary IS
    'Sanitized outcome summary only; never raw media, raw biometric streams, prompts or secrets.';
