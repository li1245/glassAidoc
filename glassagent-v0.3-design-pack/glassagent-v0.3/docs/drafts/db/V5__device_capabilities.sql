-- DRAFT (v0.3): 设备硬件能力注册表。设备只声明“有什么”；授权状态由服务端和用户决定。
CREATE TABLE device_capabilities (
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    capability_id TEXT NOT NULL
        CHECK (length(capability_id) BETWEEN 3 AND 64
               AND capability_id ~ '^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$'),
    presence TEXT NOT NULL CHECK (presence IN ('PRESENT', 'ABSENT', 'UNKNOWN')),
    source TEXT NOT NULL DEFAULT 'BUILTIN' CHECK (source IN ('BUILTIN', 'ACCESSORY', 'EMULATED')),
    limits JSONB NOT NULL DEFAULT '{}'::JSONB CHECK (jsonb_typeof(limits) = 'object'),
    privacy_class TEXT NOT NULL CHECK (privacy_class IN ('NORMAL', 'MEDIA', 'BIOMETRIC')),
    permission TEXT NOT NULL DEFAULT 'ASK' CHECK (permission IN ('GRANTED', 'DENIED', 'ASK')),
    permission_updated_at TIMESTAMPTZ,
    reported_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (device_id, capability_id)
);

CREATE INDEX idx_device_capabilities_lookup
    ON device_capabilities(capability_id, presence, permission);

COMMENT ON TABLE device_capabilities IS
    'Static hardware profile per device. Live state (online, battery, busy) is kept in memory, not here.';
COMMENT ON COLUMN device_capabilities.permission IS
    'Server/user-controlled. BIOMETRIC and MEDIA classes are never auto-granted by skill generation or trials.';
COMMENT ON COLUMN device_capabilities.limits IS
    'Reported constraints such as resolution, frame rate, sample rate, power class; sanitized and size-limited.';
