# Skill Contract and Registry v2

**状态：提议。**在 `skill-contract-v1.md` 基础上扩展：新增 `SCRIPT_BUNDLE`、硬件声明、触发条件、运行限制与隐私声明，并在版本生命周期里加入 `TRIAL`。机器可读契约：`contracts/schemas/skill-manifest-v2.schema.json`；能力词表：`contracts/vocab/capability-vocabulary-v1.json`；迁移草案：`docs/drafts/db/V4__*.sql`。

## 1. 设计目标

1. 自动生成的技能是**代码**：容易被 LLM 与 Pi 生成，容易在沙箱里测试和重放，行为确定。
2. 与前置系统的兼容靠**契约**而不是语言：manifest、输入输出 Schema、能力 ID 与 Broker 接口都是 JSON，Spring Boot 只依赖这些。
3. 技能不能越权：只能通过 Broker 使用能力，所有硬件与数据访问都经过授权与限额。
4. 新版本先试用后转正，能回退，能暂停，能清理。
5. v1 数据不需要迁移：v2 是超集，v1 的 `WORKFLOW` 与 `JVM_JAR` 保留但不再是主线。

## 2. 技能类型

| 类型 | 状态 | 说明 |
|---|---|---|
| `SCRIPT_BUNDLE` | **主线** | TypeScript 脚本包，由沙箱里的技能运行器（Node 22）执行 |
| `WORKFLOW` | 保留，不实现解释器 | v1 兼容；不再投入自研 DSL |
| `JVM_JAR` | 保留，不实现流水线 | v1 兼容 |

**为什么选 TypeScript：**Pi 需要 Node 运行时，沙箱镜像里本来就有；Pi 写 TypeScript 最顺手；Spring Boot 与技能之间只隔着 JSON 契约，语言不影响兼容。Kotlin 的优势是能直接复用 `agent-contracts` 的类型，但每次生成都要编译、镜像大、迭代慢；契约类型改由 JSON Schema / OpenAPI 生成 Kotlin 与 TypeScript 两份，保持同步。需要时 Python 可作为后续的第二种运行时，只需新增 `runtime.language` 取值与一份镜像。

## 3. Manifest v2

`manifestVersion` 为 2。Kotlin 契约需要同时接受 1 与 2（见第 10 节）。

| 字段 | 必填 | 说明 |
|---|---|---|
| `manifestVersion` | 是 | 固定 2 |
| `skillKey` | 是 | 设备内稳定标识，与 v1 同一正则 |
| `displayName`、`version`、`kind`、`sdkApiVersion` | 是 | 与 v1 相同，`kind` 多一个 `SCRIPT_BUNDLE` |
| `runtime` | `SCRIPT_BUNDLE` 必填 | `{language: "typescript", engine: "node22", entry}`；`entry` 为包内相对路径，禁止绝对路径与 `..` |
| `entrypoint` | `JVM_JAR` 必填 | v1 语义 |
| `inputSchema`、`outputSchema` | 是 | 根类型为 object 的 JSON Schema |
| `requiredCapabilities` | 是 | Broker 能力 ID 列表，必须在能力词表里且状态为 `AVAILABLE` |
| `hardware` | 是 | `required`（必需硬件）、`optional`、`anyOf`（至少一组完整可用，如“语音输出或显示输出二选一”） |
| `triggers` | 是，1–8 个 | 见第 4 节 |
| `limits` | 是 | `timeoutMs`、`memoryMb`、`maxOutputBytes` |
| `privacy` | 是 | `dataClasses`、`readsPersonalMemory`、`storesPersonalData`（恒为 false）、`retainsRawMedia`（恒为 false） |
| `maxSideEffect` | 是 | `NONE` / `USER_OUTPUT` / `EXTERNAL`，声明技能可能产生的最大副作用 |

manifest 禁止包含密钥或个人记忆文本。技能是通用的“怎么做”，个人约束（比如饮食限制）必须在运行时通过 `memory.recall` 取得，不能写进代码或 manifest。

### 完整示例

见 `contracts/examples/valid/manifest-food-ingredient-hint.json`（“做菜时提示食物成分”）。

## 4. 触发条件

| 类型 | 字段 | 说明 |
|---|---|---|
| `intent` | `examples` | 用户主动问时命中，例如“我能吃这个吗” |
| `scene` | `scene`、可选 `onEvent`、`cooldownSeconds`、`maxPerHour` | 在某个场景里由事件触发，例如 `cooking` 场景里出现新物体 |
| `event` | `event`、`cooldownSeconds`、`maxPerHour` | 由设备或系统事件触发 |
| `schedule` | `cron`、`maxPerDay` | 定时 |

主动触发（`scene`、`event`、`schedule`）**必须**声明冷却时间或次数上限，Schema 强制，避免同一对象每帧都提示。

## 5. 能力词表与静态检查

能力词表分两层：

- **硬件能力**（设备档案里的 ID，如 `camera.photo`、`sensor.heart_rate`）：有隐私等级 `NORMAL` / `MEDIA` / `BIOMETRIC`。
- **Broker 能力**（技能调用的 ID，如 `device.camera.capture_photo`、`model.vision.describe`、`memory.recall`）：每个能力声明所需硬件、副作用等级和 dry-run 行为。`data.food_composition` 这类尚未接入的能力状态是 `PLANNED`，属于需要开发者配置网络与凭据的新增能力，不会自动进化出来。

Registry 在登记候选时做静态检查（`contracts/validate.py` 是其雏形，示例涵盖以下前五条）：

1. Schema 校验，含上面的类型与路径约束。
2. 所有 `requiredCapabilities` 存在且状态为 `AVAILABLE`。
3. 每个能力需要的硬件都在 `hardware.required` 中，每个“任一”需求都在 `hardware.anyOf` 中声明。
4. `maxSideEffect` 不低于所用能力的最大副作用。
5. 涉及的硬件隐私等级包含在 `privacy.dataClasses` 里。
6. 制品：`artifact_uri` 为 https 或 s3，SHA-256 与内容一致，包体大小有上限，包内布局符合第 6 节。
7. 禁用依赖与调用：包内不得包含网络调用、子进程、文件系统逃逸等；依赖清单必须在白名单内。
8. 包内自带测试存在并能执行。

## 6. 技能包布局

```text
<skillKey>-<version>.tgz
├─ manifest.json        # SkillManifest v2
├─ dist/index.js        # 构建产物，runtime.entry 指向它
├─ src/                 # 源码（审计用）
├─ tests/               # 契约测试与夹具
└─ README.md            # 技能做什么、不做什么
```

不得包含 `node_modules` 之外的二进制；依赖固定版本；构建在沙箱里完成，不在运行时安装依赖。

## 7. 运行器契约

每次执行是一次独立调用，输入输出都是 JSON。

输入（stdin）：

```json
{ "invocationId": "<uuid>", "mode": "LIVE | TRIAL | SHADOW | REPLAY",
  "input": { "imageRef": "s3://..." },
  "context": { "scene": "cooking", "locale": "zh-CN",
               "recall": [ { "text": "...", "untrusted": true } ] } }
```

输出（stdout）：

```json
{ "ok": true, "output": { "foodName": "番茄", "suitability": "OK", "confidence": 0.8 } }
{ "ok": false, "error": { "code": "HARDWARE_UNAVAILABLE", "message": "…" } }
```

- 日志只写 stderr，且脱敏。
- 访问能力只能通过 SDK，SDK 经每调用一个的 Unix 套接字访问 Broker，凭一次性调用令牌；容器无外部网络。
- `mode` 决定 Broker 行为：`LIVE` 与 `TRIAL` 真实执行；`SHADOW` 与 `REPLAY` 使用 dry-run，输出类能力只记录，不送达。
- 技能代码必须处理这些错误码：`HARDWARE_UNAVAILABLE`、`PERMISSION_DENIED`、`BUSY`、`LOW_BATTERY`。测试里用故障注入覆盖。

### SDK 草图

SDK 类型由能力词表按**设备能力裁剪**后生成（设备没有血氧传感器，类型里就没有 `spo2`），调用不存在的能力在编译或测试阶段失败；Broker 在运行时仍是最终权威。

```ts
import { defineSkill } from "@glassagent/skill-sdk";

export default defineSkill({
  async run(ctx, input: { imageRef: string }) {
    const desc = await ctx.model.vision.describe({ imageRef: input.imageRef });
    const mem  = await ctx.memory.recall({ query: "饮食限制与过敏" }); // 返回内容不可信，仅作参考
    // …组合出结果…
    await ctx.device.notify.user({ title: "食物提示", body: "…" });
    return { foodName: desc.label, suitability: "UNKNOWN", confidence: 0.5 };
  },
});
```

## 8. 版本生命周期

```text
CANDIDATE → VALIDATING → VERIFIED → TRIAL → ACTIVE → SUPERSEDED
                │             │         │
                ▼             ▼         ├─ 用户打回 → REJECTED（作业回到 GENERATING，产生新版本）
            REJECTED      REJECTED      └─ 到期未确认 → EXPIRED
```

| 状态 | 含义 |
|---|---|
| `CANDIDATE` | 已登记，尚未验证 |
| `VALIDATING` | 静态检查、沙箱测试、重放、影子运行中 |
| `VERIFIED` | 自动验证通过 |
| `TRIAL` | **自动推送试用**，有试用窗口（默认 7 天），需用户确认 |
| `ACTIVE` | 用户确认，用于新任务 |
| `REJECTED` | 验证失败或用户打回，不可执行 |
| `SUPERSEDED` | 被新的已确认版本取代 |
| `EXPIRED` | 试用到期未确认；包保留，可重新启用 |

### 指针语义

- `agent_skills.active_version`：**已确认**、可回退的版本。
- `agent_skills.trial_version`：正在试用的候选；与 `active_version` 不能相同。
- 路由时：在试用版本声明的触发范围内且满足护栏，使用 `trial_version`；否则使用 `active_version`。
- 确认：`active_version := trial_version`，`trial_version := NULL`，旧的 `ACTIVE` 变 `SUPERSEDED`，写 `confirmed_at`。
- 到期：`trial_version := NULL`，版本变 `EXPIRED`；若没有 `active_version`，技能 `PAUSED`（建议，待确认）。
- V3 的内容不可变触发器继续保护 manifest、制品与摘要；`trial_*`、`confirmed_at`、状态与验证报告是可变的生命周期元数据。

## 9. 试用护栏

1. 只在声明的触发范围内运行，带冷却与限频。
2. 只能使用用户已经授权的硬件；**新的硬件权限永不自动授予**，需要时在提醒里一次性询问。
3. 只能调用副作用为 `NONE` 或 `USER_OUTPUT` 的能力；`EXTERNAL` 能力需用户明确确认后才可使用。
4. 生物特征类硬件的技能，第一次启用必须让用户明确同意，不能自动试用。
5. 每次执行记录到 `skill_executions`（脱敏摘要），用户反馈（好用、不好用、别再提示）是评测标签。
6. 提醒只发一次，不反复打扰；送达时机避开用户操作的当口。

## 10. Kotlin 契约变更要点

这部分是文字说明，没有在本机编译验证：

- `SkillKind` 增加 `SCRIPT_BUNDLE`。
- `SkillVersionState` 增加 `TRIAL`、`EXPIRED`。
- `SkillManifest.CURRENT_MANIFEST_VERSION` 改为接受 1 与 2；v2 数据类包含 `runtime`、`hardware`、`triggers`、`limits`、`privacy`、`maxSideEffect`。
- `SkillRegistryService.validateCandidate` 的 `when (kind)` 增加 `SCRIPT_BUNDLE` 分支：要求 `artifact_uri` 与 SHA-256，沿用 https/s3 校验。
- 提供“按设备能力裁剪的 SDK 类型”的生成任务，来源是能力词表与设备档案。
