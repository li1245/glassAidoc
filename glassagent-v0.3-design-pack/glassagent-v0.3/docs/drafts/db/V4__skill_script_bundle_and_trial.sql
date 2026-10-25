-- DRAFT (v0.3): 先评审再放入 agent-runtime/src/main/resources/db/migration/。
-- 目的：为注册表增加 SCRIPT_BUNDLE 技能类型、TRIAL/EXPIRED 版本状态，以及“试用版本”指针。
-- 不变量：V3 的内容不可变触发器不受影响（新增列都属于可变的生命周期元数据）。

-- 1) 技能类型：加入 SCRIPT_BUNDLE（TypeScript 脚本包，由沙箱里的技能运行器执行）。
ALTER TABLE agent_skill_versions DROP CONSTRAINT agent_skill_versions_kind_check;
ALTER TABLE agent_skill_versions
    ADD CONSTRAINT agent_skill_versions_kind_check
    CHECK (kind IN ('WORKFLOW', 'JVM_JAR', 'SCRIPT_BUNDLE'));

-- 2) 载荷约束：SCRIPT_BUNDLE 与 JVM_JAR 一样，只引用不可变制品并要求小写 SHA-256。
ALTER TABLE agent_skill_versions DROP CONSTRAINT agent_skill_versions_check;
ALTER TABLE agent_skill_versions
    ADD CONSTRAINT agent_skill_versions_payload_check
    CHECK (
        (kind = 'WORKFLOW' AND workflow_definition IS NOT NULL
            AND jsonb_typeof(workflow_definition) = 'object'
            AND artifact_uri IS NULL AND artifact_sha256 IS NULL)
        OR
        (kind IN ('JVM_JAR', 'SCRIPT_BUNDLE') AND workflow_definition IS NULL
            AND artifact_uri IS NOT NULL AND length(artifact_uri) BETWEEN 1 AND 2048
            AND artifact_sha256 IS NOT NULL AND artifact_sha256 ~ '^[0-9a-f]{64}$')
    );

-- 3) 版本状态：VERIFIED -> TRIAL（自动推送试用）-> ACTIVE（用户确认）；未确认到期为 EXPIRED。
ALTER TABLE agent_skill_versions DROP CONSTRAINT agent_skill_versions_state_check;
ALTER TABLE agent_skill_versions
    ADD CONSTRAINT agent_skill_versions_state_check
    CHECK (state IN ('CANDIDATE', 'VALIDATING', 'VERIFIED', 'TRIAL', 'ACTIVE',
                     'REJECTED', 'SUPERSEDED', 'EXPIRED'));

ALTER TABLE agent_skill_versions
    ADD COLUMN trial_started_at TIMESTAMPTZ,
    ADD COLUMN trial_expires_at TIMESTAMPTZ,
    ADD COLUMN confirmed_at TIMESTAMPTZ;

ALTER TABLE agent_skill_versions
    ADD CONSTRAINT agent_skill_versions_trial_window_check
    CHECK (state <> 'TRIAL'
           OR (trial_started_at IS NOT NULL AND trial_expires_at IS NOT NULL
               AND trial_expires_at > trial_started_at));

-- 4) 试用指针：active_version 始终是“已确认、可回退的版本”；trial_version 是正在试用的候选。
ALTER TABLE agent_skills ADD COLUMN trial_version INTEGER;

ALTER TABLE agent_skills
    ADD CONSTRAINT fk_agent_skills_trial_version
    FOREIGN KEY (id, trial_version)
    REFERENCES agent_skill_versions(skill_id, version)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE agent_skills
    ADD CONSTRAINT ck_agent_skills_trial_distinct
    CHECK (trial_version IS NULL OR active_version IS NULL OR trial_version <> active_version);

COMMENT ON COLUMN agent_skills.trial_version IS
    'Version under user trial; routed only inside its declared triggers with guardrails. NULL when no trial.';
COMMENT ON COLUMN agent_skill_versions.trial_expires_at IS
    'Unconfirmed trials expire (default 7 days); expiry pauses the skill if it has no confirmed active version.';
