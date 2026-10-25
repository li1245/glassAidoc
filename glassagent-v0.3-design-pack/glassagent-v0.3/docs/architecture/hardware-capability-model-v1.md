# 硬件能力模型 v1

**状态：提议。**回答：技能能做什么取决于设备有什么；生成技能时怎么知道设备有没有摄像头、麦克风、扬声器、显示、心率、血氧；怎么组合；怎么保证隐私与安全。机器可读词表：`contracts/vocab/capability-vocabulary-v1.json`；表结构：`docs/drafts/db/V5__device_capabilities.sql`。

## 1. 原则

1. **技能永远不直接碰硬件。**所有硬件访问都经过 Broker。
2. **设备只声明事实。**有无、来源、限制；授权状态与隐私等级由服务端和用户决定。
3. **先判断可行，再决定要不要生成。**
4. **生成时只看得到本设备能用的能力。**用类型约束而不是提示词约束。
5. **新硬件权限永不自动授予，生物特征数据单独授权。**

## 2. 能力档案

设备连接时发送 `capability.report`，服务端校验后写入 `device_capabilities`：

| 字段 | 说明 |
|---|---|
| `capability_id` | 硬件能力 ID，见第 3 节词表 |
| `presence` | `PRESENT` / `ABSENT` / `UNKNOWN` |
| `source` | `BUILTIN`（内置）/ `ACCESSORY`（外接配件，如蓝牙心率设备）/ `EMULATED`（模拟，如手机的单行文本区模拟 HUD） |
| `limits` | 设备上报的限制：分辨率、帧率、采样率、功耗等级等，大小受限并脱敏 |
| `privacy_class` | `NORMAL` / `MEDIA` / `BIOMETRIC`，**由服务端根据词表写入** |
| `permission` | `GRANTED` / `DENIED` / `ASK`，默认 `ASK`，由服务端和用户决定 |

静态清单落库；在线状态、电量、占用情况只放内存，由心跳更新。`devices.profile` 继续保存型号、固件等非能力元数据。

## 3. 词表

硬件能力（设备档案里的 ID）：

| ID | 隐私等级 | 说明 |
|---|---|---|
| `camera.photo` | MEDIA | 拍摄静态照片 |
| `camera.video` | MEDIA | 持续低帧率取帧或录像 |
| `mic.input` | MEDIA | 麦克风语音输入 |
| `speaker.output` | NORMAL | 扬声器或骨传导语音输出 |
| `display.hud` | NORMAL | 抬头显示文本输出 |
| `sensor.heart_rate` | BIOMETRIC | 心率 |
| `sensor.spo2` | BIOMETRIC | 血氧饱和度 |
| `sensor.imu` | NORMAL | 惯性传感器 |
| `power.battery` | NORMAL | 电量与充电状态 |

Broker 能力（技能调用的 ID）每个都声明所需硬件、副作用等级和 dry-run 行为，例如：

| Broker 能力 | 所需硬件 | 副作用 |
|---|---|---|
| `device.camera.capture_photo` | `camera.photo` | NONE |
| `device.camera.sample_frames` | `camera.video` | NONE |
| `device.audio.listen` | `mic.input` | NONE |
| `device.audio.speak` | `speaker.output` | USER_OUTPUT |
| `device.display.show` | `display.hud` | USER_OUTPUT |
| `device.notify.user` | 语音输出或显示任一可用 | USER_OUTPUT |
| `device.sensor.read_heart_rate` / `read_spo2` | `sensor.heart_rate` / `sensor.spo2` | NONE |
| `model.llm.chat`、`model.vision.describe` | 无 | NONE |
| `memory.recall` | 无 | NONE（只读，返回内容不可信） |
| `data.food_composition` | 无 | NONE，**状态 `PLANNED`，尚未接入** |

**组合能力**由 Broker 能力组合而成，例如“做菜时提示食物成分”＝摄像头拍照 + 视觉模型 + 记忆召回 + 语音或显示任一输出；“做菜时压力提示”＝心率 + 语音或显示输出。组合的硬件需求在 manifest 的 `hardware` 里用 `required` 与 `anyOf` 表达。

## 4. 可行性预检

用户提出新需求时，先把需求拆成所需 Broker 能力，再用确定性规则匹配设备档案，三种结论：

| 结论 | 条件 | 处理 |
|---|---|---|
| 能做 | 所需硬件均 `PRESENT`，且能力均为 `AVAILABLE` | 登记作业 |
| 降级可做 | “任一”需求只满足一部分，或可选硬件缺失 | 告知降级方案后登记作业 |
| 做不了 | 必需硬件缺失，或需要 `PLANNED` 能力，或权限被拒 | 立即说明缺什么，写入 `unmet_needs`（`HARDWARE_GAP` / `DATA_GAP`） |

被搁置的需求在 `capability.changed`（例如用户连上了外接心率设备）时重新评估，满足条件即转为作业。

“食物含有什么成分”需要可靠的数据来源。能力目录里只有视觉识别和 LLM 时，技能只能给出低置信度的推断，必须在输出里标注；接入食品成分库这类外部数据源属于新增能力，需要配置网络与凭据，是开发者的工作，不是自动进化。

## 5. 生成时的约束

- 给 Pi 的 TypeScript SDK 按**设备能力裁剪**生成：没有血氧传感器的设备，类型里就没有 `spo2`，调用它会在编译或测试时失败，Pi 会自己修正。
- Broker 在运行时仍是最终权威：每次调用都会再校验有无、授权与状态。
- 沙箱测试用模拟后端：输入类用夹具（照片、音频片段、心率血氧曲线），输出类用 dry-run；`contracts/vocab` 里每个能力的 `dryRun` 字段定义行为。故障注入覆盖硬件离线、权限被拒、设备忙、电量低。

## 6. Broker 的运行时职责

每次硬件调用，Broker 依次：

1. **校验**：设备有这项能力、已授权、当前可用。
2. **隐私**：摄像头与麦克风必须点亮可见指示；限制单次时长与频率；原始音视频默认不落库，只保留衍生结果；技能拿到的是媒体引用，不是原始数据。
3. **资源仲裁**：摄像头、麦克风会被多个调用方争用（实时视觉翻译与一个技能同时要摄像头）。规则：区分独占与共享；内置实时功能优先于技能；冲突时技能让路并收到 `BUSY`。
4. **功耗与发热配额**：持续视频类能力限额；`LOW_BATTERY` 时拒绝高耗能调用。
5. **统一错误码**：`HARDWARE_UNAVAILABLE`、`PERMISSION_DENIED`、`BUSY`、`LOW_BATTERY`。
6. **审计**：记录能力 ID、调用方技能版本、结果状态，不记录原始数据。

## 7. 生物特征（心率、血氧）

1. 授权独立于摄像头和麦克风，用户单独同意；不在技能试用时自动授予。
2. 记忆里只存摘要和趋势，不存原始连续数据。
3. 输出不做诊断，措辞用提示而不是结论；阈值提醒带“仅供参考”类说明。
4. 戒指等消费级传感器的数据只用于提示，不作医疗依据；社区逆向的蓝牙协议可能随固件更新失效，产品化时换成有官方 SDK 的传感器。
5. 涉及生物特征的技能，第一次启用必须让用户明确同意，不能自动试用。
6. 日志与评测用例里不得出现原始生物特征序列；评测用例有保留期限（`retain_until`）。

## 8. 手机参考设备档案

手机阶段的档案（待实测确认）：

| 能力 | presence | source | 备注 |
|---|---|---|---|
| `camera.photo` | PRESENT | BUILTIN | |
| `camera.video` | PRESENT | BUILTIN | 低帧率取帧，最新帧优先 |
| `mic.input` | PRESENT | BUILTIN | 16 kHz 单声道 |
| `speaker.output` | PRESENT | BUILTIN | |
| `display.hud` | PRESENT | EMULATED | 单行文本区，每行不超过 32 字符，模拟将来的 HUD |
| `sensor.heart_rate` | 可开关 | EMULATED 或 ACCESSORY | 手动注入曲线，或接蓝牙戒指 |
| `sensor.spo2` | 可开关 | EMULATED 或 ACCESSORY | 同上 |
| `sensor.imu` | PRESENT | BUILTIN | |
| `power.battery` | PRESENT | BUILTIN | |

手机客户端提供“拔掉硬件”开关面板，用来验证“能做、降级可做、做不了”三种结论。显示被限制为单行短文本，避免做出只有手机屏幕才能用的功能。

## 9. 对自研硬件的反向需求（草案）

自研眼镜还没有设计，下面是本系统对硬件的要求，供选型与设计时对照，具体指标待你和硬件方向确定：

1. **自己联网**：Wi‑Fi，是否带蜂窝视场景定；入网后不依赖手机。
2. **安全存储**：安全芯片或可信执行环境存设备私钥，支持密钥证明；证书可更新、可吊销。
3. **隐私硬件**：采集指示灯、物理静音或隐私开关，且这些由设备固件强制，不受服务端命令影响。
4. **音视频**：摄像头需足够清晰以做 OCR（菜单、配料表）；麦克风最好有降噪，厨房噪声下可用；扬声器或骨传导需在噪声环境下听得清。
5. **显示**：至少能显示短文本；单色可以接受。
6. **配件接入**：蓝牙中心角色，能连接心率、血氧配件；能力清单里标明 `ACCESSORY`。
7. **电量与热**：向服务端上报电量；固件有高耗能命令的拒绝逻辑；连续取帧的发热需要在选型时验证。
8. **OTA 与恢复**：固件可升级；恢复出厂必须清除密钥，并要求重新入网。
9. **兼容协议**：实现 `device-protocol-v1.md` 并通过一致性测试；入网支持二维码，可选蓝牙配对（LE Secure Connections，禁止 Just Works）。

## 10. 待确认

- 手机阶段 Android Keystore 是否由硬件支持，是否能做密钥证明。
- 心率血氧外接设备的选型与对应的开放协议。
- 自研硬件的网络方案（仅 Wi‑Fi，还是加蜂窝）。
