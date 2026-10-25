-- 在已应用 V1..V7 的空库上运行：每条断言失败会抛错。用法：psql -v ON_ERROR_STOP=1 -f verify_v4_v7.sql
BEGIN;
CREATE TEMP TABLE _r(name text, ok boolean);

DO $$
DECLARE d1 uuid; d2 uuid; s uuid; s2 uuid; j uuid; ok boolean;
BEGIN
  INSERT INTO devices(name) VALUES ('phone-dev') RETURNING id INTO d1;
  INSERT INTO devices(name) VALUES ('phone-other') RETURNING id INTO d2;
  INSERT INTO agent_skills(device_id, skill_key) VALUES (d1, 'food-check') RETURNING id INTO s;
  INSERT INTO agent_skills(device_id, skill_key) VALUES (d2, 'other-skill') RETURNING id INTO s2;

  -- 1) SCRIPT_BUNDLE 正常登记
  INSERT INTO agent_skill_versions(skill_id, version, kind, manifest, artifact_uri, artifact_sha256, source)
  VALUES (s, 1, 'SCRIPT_BUNDLE', '{}'::jsonb, 's3://skills/d1/food-check/1.tgz', repeat('a',64), 'LEARNED');
  INSERT INTO _r VALUES ('script bundle registers', true);

  -- 2) SCRIPT_BUNDLE 缺 artifact 必须失败
  BEGIN
    INSERT INTO agent_skill_versions(skill_id, version, kind, manifest, source)
    VALUES (s, 2, 'SCRIPT_BUNDLE', '{}'::jsonb, 'LEARNED');
    INSERT INTO _r VALUES ('script bundle without artifact rejected', false);
  EXCEPTION WHEN check_violation THEN INSERT INTO _r VALUES ('script bundle without artifact rejected', true); END;

  -- 3) 非法 sha 必须失败
  BEGIN
    INSERT INTO agent_skill_versions(skill_id, version, kind, manifest, artifact_uri, artifact_sha256, source)
    VALUES (s, 2, 'SCRIPT_BUNDLE', '{}'::jsonb, 's3://x', repeat('G',64), 'LEARNED');
    INSERT INTO _r VALUES ('bad sha rejected', false);
  EXCEPTION WHEN check_violation THEN INSERT INTO _r VALUES ('bad sha rejected', true); END;

  -- 4) 旧类型仍可用
  INSERT INTO agent_skill_versions(skill_id, version, kind, manifest, workflow_definition, source)
  VALUES (s, 3, 'WORKFLOW', '{}'::jsonb, '{"nodes":[]}'::jsonb, 'SYSTEM');
  INSERT INTO _r VALUES ('workflow still registers', true);

  -- 5) TRIAL 需要窗口
  BEGIN
    UPDATE agent_skill_versions SET state='TRIAL' WHERE skill_id=s AND version=1;
    INSERT INTO _r VALUES ('trial without window rejected', false);
  EXCEPTION WHEN check_violation THEN INSERT INTO _r VALUES ('trial without window rejected', true); END;

  UPDATE agent_skill_versions
     SET state='TRIAL', trial_started_at=now(), trial_expires_at=now()+interval '7 days'
   WHERE skill_id=s AND version=1;
  INSERT INTO _r VALUES ('trial with window ok (mutable lifecycle columns)', true);

  -- 6) 试用指针 + 与 active 不同
  UPDATE agent_skills SET trial_version=1 WHERE id=s;
  INSERT INTO _r VALUES ('trial pointer set', true);
  BEGIN
    UPDATE agent_skills SET active_version=1 WHERE id=s;
    INSERT INTO _r VALUES ('trial==active rejected', false);
  EXCEPTION WHEN check_violation THEN INSERT INTO _r VALUES ('trial==active rejected', true); END;

  -- 7) V3 不可变触发器仍然生效
  BEGIN
    UPDATE agent_skill_versions SET artifact_uri='s3://evil' WHERE skill_id=s AND version=1;
    INSERT INTO _r VALUES ('content immutability still enforced', false);
  EXCEPTION WHEN check_violation THEN INSERT INTO _r VALUES ('content immutability still enforced', true); END;

  -- 8) 确认：active=1, trial 清空
  UPDATE agent_skills SET active_version=1, trial_version=NULL WHERE id=s;
  UPDATE agent_skill_versions SET state='ACTIVE', confirmed_at=now() WHERE skill_id=s AND version=1;
  INSERT INTO _r VALUES ('confirm path ok', true);

  -- 9) 设备能力
  INSERT INTO device_capabilities(device_id, capability_id, presence, privacy_class)
  VALUES (d1, 'camera.photo', 'PRESENT', 'MEDIA'), (d1, 'sensor.heart_rate', 'PRESENT', 'BIOMETRIC');
  INSERT INTO _r VALUES ('capabilities insert', true);
  BEGIN
    INSERT INTO device_capabilities(device_id, capability_id, presence, privacy_class)
    VALUES (d1, 'Camera', 'PRESENT', 'MEDIA');
    INSERT INTO _r VALUES ('bad capability id rejected', false);
  EXCEPTION WHEN check_violation THEN INSERT INTO _r VALUES ('bad capability id rejected', true); END;
  SELECT permission = 'ASK' INTO ok FROM device_capabilities WHERE device_id=d1 AND capability_id='sensor.heart_rate';
  INSERT INTO _r VALUES ('biometric defaults to ASK (never auto-granted)', ok);

  -- 10) 作业
  BEGIN
    INSERT INTO evolution_jobs(device_id, skill_key, title, requirement_digest, feasibility, state, token_budget)
    VALUES (d1, 'food-check', 't', repeat('b',64), 'FEASIBLE', 'READY_FOR_REVIEW', 1000);
    INSERT INTO _r VALUES ('review without candidate rejected', false);
  EXCEPTION WHEN check_violation THEN INSERT INTO _r VALUES ('review without candidate rejected', true); END;

  INSERT INTO evolution_jobs(device_id, skill_key, title, requirement_digest, feasibility, token_budget,
                             candidate_skill_id, candidate_version, state, expires_at)
  VALUES (d1, 'food-check', '做菜时提示食物成分', repeat('b',64), 'FEASIBLE', 200000, s, 1, 'READY_FOR_REVIEW', now()+interval '7 days')
  RETURNING id INTO j;
  INSERT INTO evolution_job_events(job_id, kind, detail) VALUES (j, 'state.changed', '{"to":"READY_FOR_REVIEW"}');
  INSERT INTO _r VALUES ('job with candidate ok', true);

  BEGIN
    INSERT INTO evolution_jobs(device_id, skill_key, title, requirement_digest, feasibility, token_budget,
                               candidate_skill_id, candidate_version)
    VALUES (d1, 'food-check', 't', repeat('b',64), 'FEASIBLE', 1, s, 99);
    INSERT INTO _r VALUES ('dangling candidate version rejected', false);
  EXCEPTION WHEN foreign_key_violation THEN INSERT INTO _r VALUES ('dangling candidate version rejected', true); END;

  -- 11) 执行记录：跨设备外键必须被拒
  INSERT INTO skill_executions(device_id, skill_id, version, mode, outcome, started_at)
  VALUES (d1, s, 1, 'TRIAL', 'SUCCESS', now());
  BEGIN
    INSERT INTO skill_executions(device_id, skill_id, version, mode, outcome, started_at)
    VALUES (d2, s, 1, 'TRIAL', 'SUCCESS', now());
    INSERT INTO _r VALUES ('cross-device execution rejected', false);
  EXCEPTION WHEN foreign_key_violation THEN INSERT INTO _r VALUES ('cross-device execution rejected', true); END;

  -- 12) 评测用例必须有保留期限
  BEGIN
    INSERT INTO skill_eval_cases(device_id, skill_id, origin, input, retain_until)
    VALUES (d1, s, 'USER_CORRECTION', '{}'::jsonb, now() - interval '1 day');
    INSERT INTO _r VALUES ('expired eval case rejected', false);
  EXCEPTION WHEN check_violation THEN INSERT INTO _r VALUES ('expired eval case rejected', true); END;
END $$;

SELECT name, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS result FROM _r;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM _r WHERE NOT ok) THEN RAISE EXCEPTION 'verification failed'; END IF; END $$;
ROLLBACK;
