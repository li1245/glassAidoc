# 设备通道协议 v1

**状态：提议。**范围：设备（手机参考实现、命令行模拟器、未来自研眼镜）与 Glass Agent Runtime 之间的入网、会话、控制消息、音频与图像传输。机器可读契约见 `contracts/schemas/device-envelope-v1.schema.json`，示例与校验脚本见 `contracts/`。

## 1. 设计原则

1. **新鲜度优先。**实时场景里“旧数据”比“丢数据”更糟：图像只保留最新帧，音频小帧流式，控制消息可靠有序。
2. **身份只来自传输层。**`device_id` 从 mTLS 证书映射得到，消息里不携带也不接受 `device_id`。
3. **设备只声明事实，不声明权限。**能力清单只含有无、来源、限制；授权状态与隐私等级由服务端决定。
4. **设备不盲从服务端。**采集指示、时长上限、物理静音由设备端自己强制。
5. **与硬件无关。**协议不假设蓝牙、手机或具体芯片；入网方式可替换，运行期协议不变。
6. **可测试。**同一套一致性测试同时约束命令行模拟器、手机 App 和未来硬件。

## 2. 传输

| 连接 | 路径 | 内容 | 说明 |
|---|---|---|---|
| primary | `wss://<host>/ws/v1/device` | 控制消息（文本帧 JSON）+ 音频二进制帧 | 优先级高，低延迟 |
| bulk | `wss://<host>/ws/v1/device/bulk` | 图像帧、较大的二进制数据 | 与 primary 使用同一会话 ID，独立拥塞，避免图像拖慢音频 |

- TLS 1.3，客户端证书（mTLS）。设备端固定服务端 CA。
- 单条 TCP 上的队头阻塞用“双连接”规避。以后若实测抖动不满足，再评估 QUIC 或 WebRTC，信封与消息类型不变。
- 大媒体（拍照原图、会议录音）优先上传到对象存储，消息里只带 `mediaRef`，不在 JSON 里放 Base64。

## 3. 入网

v0.2 的前提是“设备是唯一身份边界，不建立用户模型”，所以入网令牌由**管理员接口**签发，而不是由某个用户账号签发。开发期用命令行，之后可以换成管理端。

### 3.1 流程

```text
管理员接口          手机 App（只是搬运工）            设备                  Runtime
    │ 1. 签发入网令牌 ───────────────────────────────────────────────────────►│
    │◄──────── 令牌、deviceId、CA 固定信息、接入地址、过期时间 ───────────────│
    │ 2. 令牌以二维码展示 ─► 设备扫码（或蓝牙配对后接收）                      │
    │                         3. 设备联网，向入网接口发 CSR + 令牌 ───────────►│
    │                         4. 校验令牌（单次、未过期、绑定 PENDING 设备）   │
    │                         ◄──────────── 设备证书与证书链 ──────────────────│
    │                         5. 以 mTLS 建立 primary/bulk，发 hello           │
```

- 令牌**单次使用、几分钟过期**，库里只存 SHA-256 摘要。沿用 `device_credentials`：`token_sha256`、`scopes = {enrollment:complete}`、`expires_at`；完成后立即吊销，并插入证书凭据（`certificate_sha256`）。
- 设备密钥在设备上生成（有安全芯片就放进芯片），私钥不出设备；**CSR 不经手机**。手机只搬运令牌与网络凭据。
- 手机阶段：二维码扫描即可。现成硬件没有自研蓝牙入网栈时同样适用。
- 自研硬件阶段：蓝牙配对作为带外通道，必须使用 LE Secure Connections，配合二维码带外校验或数字比对；**不接受 Just Works**；配对窗口由设备上的物理动作开启。

### 3.2 HTTP 接口

| 接口 | 认证 | 作用 |
|---|---|---|
| `POST /api/v1/admin/enrollments` | 管理员凭据（mTLS） | 创建 `PENDING` 设备，返回 `{deviceId, enrollmentToken, expiresAt, caPin, endpoints}` |
| `POST /api/v1/enrollment/complete` | 无客户端证书，TLS 校验服务端；请求体里带入网令牌 | 提交 `{csrPem, deviceModel, firmware, attestation?}`，返回 `{certificatePem, chainPem, deviceId}`，设备状态转为 `ACTIVE` |

- 入网接口限速，失败有审计；令牌错误不透露具体原因。
- 证书续期直接在已建立的 mTLS 通道上完成，不再需要手机。
- 更换网络需要再次近距离配对或扫码；丢失设备在服务端吊销证书。
- 设备恢复出厂后重新入网，必须重新由管理员签发令牌（防止转手劫持）。

## 4. 会话

1. 设备建立 primary，发送 `hello`（支持的协议版本范围、型号、固件，可带续连令牌与最后收到的服务端序号）。
2. 服务端回 `hello.ack`：会话 ID、服务端时间、协商版本、心跳间隔、限制（单条控制消息、单帧大小、最大帧率）、是否接受续连。
3. 设备建立 bulk，携带同一会话 ID。
4. 设备发送 `capability.report`；之后硬件变化发送 `capability.changed`。
5. 正常运行；心跳 `ping`/`pong`。

断线重连：续连令牌短期有效，成功则从最后序号继续；失败则新建会话，未确认的命令按幂等键重试。

## 5. 控制消息信封

文本帧，JSON，字段与约束见 Schema。

```json
{ "v": 1, "type": "cmd.capture_photo", "id": "<uuid>", "seq": 7, "ts": 1790000001000,
  "payload": { "captureId": "<uuid>", "maxEdge": 1280, "quality": 80,
               "purpose": "food-identify", "indicatorRequired": true } }
```

| 字段 | 说明 |
|---|---|
| `v` | 协议版本，当前 1 |
| `type` | 消息类型，闭集，未知类型直接拒绝 |
| `id` | 消息 UUID，用于幂等和 `ack` |
| `seq` | 每个连接方向单调递增，用于检测丢失与重放 |
| `ts` | 发送方 epoch 毫秒；服务端允许有限时间窗，超窗拒绝 |
| `corr` | 关联的请求消息 `id` |
| `payload` | 按 `type` 校验的对象 |

### 5.1 消息类型

| 方向 | 类型 | 作用 |
|---|---|---|
| 设备 → 服务端 | `hello`、`ping` | 握手、心跳 |
| | `capability.report`、`capability.changed` | 硬件能力清单与变化 |
| | `audio.begin`、`audio.end` | 话语边界，音频数据在二进制帧 |
| | `photo.result` | 拍照结果：`mediaRef` 或 bulk 帧序号二选一 |
| | `sensor.sample` | 心率、血氧采样批 |
| | `feedback` | 对试用技能的反馈：好用、不好用、别再提示 |
| | `event` | 通用事件，映射到 `agent_events`（带幂等键） |
| | `ack`、`error` | 应答与错误 |
| 服务端 → 设备 | `hello.ack`、`pong` | 握手应答、心跳 |
| | `cmd.capture_photo`、`cmd.listen`、`cmd.stop`、`cmd.subscribe_sensor`、`cmd.config` | 采集与配置命令 |
| | `out.display` | 在 HUD 显示最多 3 行、每行不超过 32 字符 |
| | `out.speak` | 语音输出元数据，音频在二进制帧 |
| | `out.notify` | 带送达策略的通知（试用提醒、技能就绪、缺硬件说明等） |
| 双向 | `ack`、`error` | |

`cmd.capture_photo` 与 `cmd.listen` 必须带 `indicatorRequired: true`（Schema 强制），设备端也要自己点亮采集指示。

## 6. 二进制帧

用于音频与图像。每帧头部固定 13 字节，之后是载荷：

```text
┌────────┬──────────────┬─────────────────────┬──────────┐
│ 通道 1B│ 序号 4B (BE) │ 时间戳 8B (BE, ms)  │ 载荷 …   │
└────────┴──────────────┴─────────────────────┴──────────┘
```

| 通道 | 方向 | 内容 | 所在连接 |
|---|---|---|---|
| `0x01` | 设备 → 服务端 | 音频（PCM s16le 或 Opus，单声道，20 ms 分帧） | primary |
| `0x02` | 服务端 → 设备 | TTS 音频 | primary |
| `0x03` | 设备 → 服务端 | 图像帧（JPEG） | bulk |
| `0x04` | 保留 | 传感器二进制批 | |

- 序号按通道独立递增。音频通道缺帧由服务端抖动缓冲处理；图像通道不要求连续。
- 开发期局域网先发 PCM，不压缩，减少变量；稳定后换 Opus。
- 载荷大小受 `hello.ack` 的限制约束，超限返回 `PAYLOAD_TOO_LARGE`。

## 7. 流控与丢弃策略

| 数据 | 策略 |
|---|---|
| 控制消息 | 可靠、有序、按序号检测缺失；命令有超时与幂等重试 |
| 音频上行 | 有序；积压超过阈值时丢最旧的帧并产生一次可观测事件，不无限排队 |
| 图像帧 | **最新帧优先**：上传积压就丢旧帧；帧率不超过服务端下发的 `maxFps` |
| TTS 下行 | 可被打断（`interruptible`）；用户插话时服务端发 `cmd.stop` |
| 传感器 | 批量发送，带时间戳与可选质量值；断线期间设备可缓存有限条，恢复后补发 |

每个设备、每条通道有有界队列与速率限制；超过限制返回 `RATE_LIMITED` 并附 `retryAfterMs`。

## 8. 错误码

`HARDWARE_UNAVAILABLE`、`PERMISSION_DENIED`、`BUSY`、`LOW_BATTERY`、`RATE_LIMITED`、`INVALID_MESSAGE`、`UNSUPPORTED_VERSION`、`PAYLOAD_TOO_LARGE`、`UNAUTHENTICATED`、`INTERNAL`。`error` 消息带 `retryable` 与可选 `retryAfterMs`，`message` 不超过 200 字符且不含内部细节。

## 9. 设备端强制策略

以下规则由设备端自己执行，服务端的命令不能越过：

1. 摄像头或麦克风采集时必须点亮可见指示，不允许静默采集。
2. 单次采集时长与频率有设备端上限。
3. 物理静音或隐私开关优先于一切命令；生效时对相应命令返回 `PERMISSION_DENIED`。
4. 电量低时拒绝高耗能命令，返回 `LOW_BATTERY`。
5. 原始音视频默认不在设备上持久化。

## 10. 安全要点

- mTLS，设备端固定 CA；证书可撤销，吊销后服务端立刻断开该设备的连接。
- 服务端对每条消息做 Schema 校验、大小限制、速率限制和序号与时间窗检查；校验失败只记录摘要，不记录载荷原文。
- 设备通道出现的文字内容（OCR、ASR 等）一律视为不可信数据。
- 离线缓存的事件如果由中转设备带回，需用设备私钥签名，防止伪造与重放（手机直连阶段暂不需要）。
- 日志不记录原始媒体与生物特征数据，只记录元数据与哈希。

## 11. 一致性测试清单

三种实现（命令行模拟器、手机 App、未来硬件）都必须通过：

1. 入网：令牌单次有效、过期失效、重复使用失败；完成后状态转为 `ACTIVE`。
2. 握手：版本协商、限制下发、续连成功与失败两条路径。
3. 能力上报：包含 `permission` 或 `privacyClass` 字段的上报被拒绝。
4. 命令：缺少 `indicatorRequired` 的采集命令被拒绝；设备静音时返回 `PERMISSION_DENIED`。
5. 流控：图像积压时只保留最新帧；音频积压触发丢帧事件。
6. 错误：每个错误码至少一条触发用例。
7. 安全：伪造 `device_id`、未知类型、超大载荷、时间窗外消息全部被拒绝。

## 12. 命令行模拟器与时间线脚本

先做命令行模拟器，读取时间线脚本，按时间向服务端发送数据，也是后续“评测回放”的数据来源。

```yaml
name: ask-food-identify
device:
  profile: phone-reference            # 引用硬件能力档案
  removeCapabilities: []              # 填 sensor.heart_rate 等可模拟“拔掉硬件”
steps:
  - at: 0s    send: hello
  - at: 0.1s  send: capability.report
  - at: 2s    audio: fixtures/audio/what-is-this.wav
  - at: 3s    photo: fixtures/photos/tomato.jpg
  - at: 5s    expect: { type: out.display, containsAny: ["番茄", "tomato"], timeout: 5s }
  - at: 6s    sensor: { sensor: heart_rate, curve: fixtures/sensors/hr-cooking.csv }
```

夹具放在文件夹里（照片、WAV、心率曲线）；同一脚本可在 CI 中无人值守运行。

## 13. 手机参考实现要点（安卓）

- 入网：扫二维码取令牌，证书放进 Android Keystore。开发构建只信任单独的开发 CA，不关闭证书校验，也不把开发 CA 带进正式构建。
- 采集：前台服务，在 App 处于前台时由用户启动；麦克风 16 kHz 单声道、20 ms 分帧；摄像头 1–2 帧每秒，长边缩到约 1280 的 JPEG。
- 轻量处理只包括编码、缩放、抽帧、端点检测、隐私开关与采集指示；识别、翻译、LLM、TTS、记忆召回全部在服务端，否则功能搬不到算力有限的眼镜上。
- 输出：文本区限制字数模拟 HUD；TTS 音频块直接播放。
- 调试：提供“拔掉硬件”开关面板（摄像头、扬声器、心率等），用于验证可行性预检的三种结论。
