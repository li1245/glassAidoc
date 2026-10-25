# 进化流水线 v1：从需求到试用技能

**状态：提议。**范围：进化作业的触发、可行性预检、Pi Worker 的嵌入方式、多角色生成、验证、试用推送、确认与清理。会话与作业的交互规则见 `session-and-job-model-v1.md`，技能契约见 `skill-contract-v2.md`。

## 1. 原则

1. **Pi 只在慢路径。**它做生成与测试，不上实时热路径。
2. **Runtime 编排，不让 agent 自己编排。**状态机、轮次上限、额度和审计都由 Runtime 掌握。
3. **沙箱里没有密钥，也没有数据库。**需要的一切通过受控网关和 Broker。
4. **生成只组合现有能力。**需要新数据源、新网络访问或新硬件权限的需求，不属于自动进化，由开发者配置或用户授权。
5. **PostgreSQL 是作业与会话标识的事实源。**Hindsight 只存语义记录。

## 2. 触发

| 来源 | 说明 |
|---|---|
| 用户明确要求 | “以后做菜时提示食物成分”“学会做 X” |
| 习惯 | 用户记忆里反复出现的模式，达到阈值后提议“要不要我学会自动做” |
| 未满足需求 | 路由兜底时累积的 `unmet_needs.occurrences` 达到阈值；缺硬件的需求进入 `WAITING_HARDWARE`，硬件变化事件触发重新评估 |

阈值做成配置；习惯类触发先“提议”，用户同意后才开作业。

## 3. 可行性预检

作业登记前，Spring Boot 先让 LLM 把需求拆成结构化结果（所需 Broker 能力、触发场景、输出方式），再用设备硬件档案和能力词表做**确定性匹配**：

| 结论 | 例子 | 处理 |
|---|---|---|
| 能做（`FEASIBLE`） | 摄像头加扬声器或显示 | 登记作业 |
| 降级可做（`DEGRADED`） | 没有扬声器，改用显示输出 | 告知降级方案后登记作业 |
| 做不了 | 要监测血氧但设备没有血氧传感器；或需要 `PLANNED` 状态的数据源 | 立即说明缺什么；写入 `unmet_needs`（`HARDWARE_GAP` 或 `DATA_GAP`），不白跑几分钟的生成 |

预检的 LLM 输出必须经 Schema 校验；失败或低置信度时按“做不了”处理并解释，不猜测。

## 4. 作业状态机

见 `session-and-job-model-v1.md` 第 5 节。作业与技能版本状态并行推进：

| 作业状态 | 技能版本状态 |
|---|---|
| `GENERATING` | 尚未登记 |
| `TESTING` | `CANDIDATE → VALIDATING` |
| `VERIFYING` | `VALIDATING` |
| `READY_FOR_REVIEW` | `VERIFIED → TRIAL`（自动推送，提醒用户） |
| `CONFIRMED` | `ACTIVE` |
| `EXPIRED` | `EXPIRED` |

## 5. 证据包

Runtime 为作业准备并写入工作区（`SPEC.md`、`evidence/`、`catalog/`）的内容：

- 脱敏后的需求文本与验收标准。
- 相关失败事件和用户纠错的**摘要**，不含原始音视频和生物特征数据。
- 该设备可用的能力目录与按设备裁剪的 SDK 类型、dry-run 夹具。
- 进化记忆库里与此类技能相关的教训（经受控网关读取）。

规则：

1. 来自物理世界的文字（OCR、ASR、摄像头）标为不可信数据，放在 `evidence/` 的数据区，**不得出现在指令位**（`SPEC.md` 的要求部分、系统提示）。
2. 个人记忆内容不写入技能、manifest 或 `SPEC.md`；技能在运行时通过 `memory.recall` 取得。
3. `AGENTS.md` 里写作业规则（做什么、不做什么、必须通过的测试、禁用的依赖和调用），让需求在 Pi 压缩上下文后依然存在。

## 6. Pi Worker 的嵌入

### 6.1 为什么是 RPC 子进程，不是进程内 SDK

Pi 是 Node.js / TypeScript 程序（需要 Node 22.19 或更高），不是 JVM 库，不能作为 Spring Bean。它有四种运行方式；其中 RPC 模式通过 stdin/stdout 收发 JSON Lines，官方定位就是语言无关的集成、进程隔离和自定义界面；SDK 是把 Pi 嵌进 Node 或 Bun 进程的进程内集成，官方说明要隔离请用 CLI 集成。

不采用进程内 SDK 的理由：

- Pi 默认以启动账号的权限运行，不逐次询问；进程内意味着它的 `bash`、`write` 等工具与 Runtime 同权限，一次提示注入就可能触及设备密钥、数据库凭据和其他设备的数据。
- 无法按作业做资源配额和崩溃隔离，一个会话把事件循环卡住会让所有设备的实时音频抖动。
- Pi 发布频繁（1.0 于 2026-10-01 发布，补丁版本很密），SDK 接口变化会直接打到主程序；RPC 契约面更窄（这是判断，不是官方保证），Worker 镜像可以独立灰度升级。
- 所有设备的会话放在同一进程里，缺陷可能串数据；每作业一进程是构造性的隔离。

如果将来想把 Runtime 也换成 TypeScript，也应该是“两个进程”：Runtime 加沙箱里的 Worker，Worker 内部可以用 SDK，但不能把 Pi 放进业务进程。注意 SDK 方式默认不加载 Codemode 与 MCP，需要自己把对应扩展加入 `extensionFactories`。

### 6.2 沙箱镜像

- 固定 Node 与 Pi 版本，预装在镜像里；**运行时不执行 `pi install`，不安装第三方包**。
- 安装依赖使用 `--ignore-scripts`；依赖清单与镜像经扫描和审计。
- 预装自己的 TypeScript 扩展 `glass-broker`：把受控能力注册成 Pi 工具，经 Unix 套接字回调 Runtime。
- 关闭遥测（`PI_TELEMETRY=0`），使用 `--offline` 禁止自动联网。
- 项目是 ESM，不要用 CommonJS。

### 6.3 启动与 RPC 客户端

Runtime 为每个作业启动一个容器，执行类似：

```text
pi --mode rpc --session-dir /work/sessions/<jobId> --name job-<jobId> [--tools <角色允许的工具>]
```

Kotlin 侧 RPC 客户端的职责：

1. 启动后调用 `get_state`，把 `sessionId`、`sessionFile` 与会话名写入 `evolution_jobs`；用 `set_session_name` 或 `--name` 命名为 `job-<jobId>`。
2. 发送需求，消费事件流；以 `agent_settled` 判断一轮真正结束。
3. `steer` 在 agent 运行中排队、在当前这轮工具调用结束后送达；`follow_up` 在 agent 结束后送达；`abort` 用于取消。
4. 周期调用 `get_session_stats` 监控上下文占用；需要时 `compact`，也可 `set_auto_compaction`。
5. 用 `get_entries`（带 `since` 游标）读取完整历史用于审计，客户端重启后也能续读。
6. 处理子进程启动失败、意外退出、取消与超时。stderr 只是诊断信息，不要当协议解析。
7. 读取 stdout 只按 LF 切分，不使用把 U+2028 当换行的读取器。

### 6.4 回调通道

```text
沙箱容器（--network none，只有回环）
  Pi ──LLM 请求──► 回环端口 ──小型转发器──► 挂载的 Unix 套接字 ──► Runtime 受控网关
  glass-broker 扩展 ──HTTP over UDS────────────────────────────► Runtime Broker / 记忆代理
```

- 每作业一个套接字，路径即作业身份；再加作业级短期令牌（绑定设备、作业、允许的能力、有效期、token 额度）。
- 沙箱没有任何对外网络，也不监听端口。Pi 的模型提供方通过 `models.json` 配置为自定义 OpenAI 兼容地址；若不能直接使用 Unix 套接字，则在容器内用一个极小的 TCP→UDS 转发器监听回环。**这一点需要原型验证。**
- 受控网关持有 LLM 密钥，按作业计量 token 与时长，超额即中止，并写审计。
- 同机部署无需在沙箱与 Runtime 之间再加 TLS；Worker 将来搬到别的主机时再换成 mTLS。

### 6.5 角色与工具范围

Pi 支持用 `--tools` 限定工具集，例如 `pi --tools read,grep,find,ls` 得到一个只读会话。各角色的工具与工作区权限：

| 角色 | 工具 | 工作区 |
|---|---|---|
| 规格员 | `read` 等只读 + 写 `SPEC.md` | 作业工作区 |
| 实现者 | `read`、`write`、`edit`、`bash` | 独立的候选目录（读写） |
| 测试作者 | 只读规格与契约 + 写 `tests/` | 只能看到 `SPEC.md` 与契约，**看不到实现** |
| 审查者 | `read`、`grep`、`find`、`ls` | 候选目录只读挂载 |

`--tools` 在 RPC 模式下的行为需要原型确认。

### 6.6 容器与资源限制

非 root、只读根文件系统、可写的只有作业工作区；限制 CPU、内存、进程数与墙钟时间；seccomp；每作业独立工作区卷。**产品化前必须把隔离强度升级到 gVisor 或 microVM**，因为 Pi 会运行 LLM 写出的 bash，容器共享宿主内核。

## 7. 生成流水线

默认**单路**：一个实现者，加独立的测试作者和只读审查者；**先单路，测试失败再并行第二个候选**，节省成本。多候选（best-of-N）只用于复杂技能或失败后的重试。

```text
规格员（SPEC.md） ─┬─► 实现者 A（候选一）
                  ├─► 实现者 B（候选二，失败后才启动）
                  └─► 测试作者（只读规格，写 tests/）
                          │
                  Runtime 评测：跑测试，选优
                          │
                       审查者（只读）：越权调用、硬编码个人信息、可疑依赖
                          │
                  通过 → 打包、登记候选
                  不通过 → 回到实现者（同会话 follow_up，带失败信息；轮次有上限）
```

- 角色之间不直接对话，只通过工作区文件与 Runtime 状态机交接。
- 每个候选一份目录副本，合并只经 Runtime，避免互相覆盖文件。
- 作业内并发上限默认 3 个会话；每个作业的 token 额度由网关分配给各角色，超额停止。
- **多 agent 是否优于单 agent，必须用评测集做对照**（成功率、耗时、token 成本），再决定默认策略；没有数据之前不要假设它更好。
- 不安装第三方子 agent 扩展：它们是第三方代码，会进入沙箱的信任范围，且编排权在 agent 手里。

## 8. 验证

1. **静态检查**：Schema、能力、硬件、副作用、隐私、制品、禁用依赖和调用（见 `skill-contract-v2.md` 第 5 节）。
2. **沙箱测试**：全新容器、禁网，运行技能自带测试，含故障注入（硬件离线、权限被拒、设备忙、电量低）。
3. **重放评测**：对历史用例，能力走 dry-run，与当前版本对比。
4. **影子运行**：在真实任务上并行跑候选，不产生副作用。输入类硬件只使用正常任务里**已经产生的数据**，影子运行自己不触发拍照或录音。
5. **试用**：真实世界的验证交给用户试用期；用户的反馈是真值标签。

任何一步失败都不允许推送试用；失败原因（脱敏）写入 `validation_report` 与作业事件。

## 9. 登记、推送与确认

- 验证通过后，**Runtime 从沙箱拉取技能包**，校验 SHA-256，登记为不可变版本，状态推进到 `TRIAL`，写入 `trial_version`，并通知路由等模块刷新。Worker 不能直接写入业务模块。
- 提醒用户试用：`out.notify`，只发一次，送达时机按场景选择。
- 用户确认 → `ACTIVE`，作业 `CONFIRMED`，进入清理。
- 用户打回或给出新要求 → 同一个 Pi 会话 `follow_up` 继续，产生新版本，旧版本 `REJECTED`。
- 一周未确认 → 版本 `EXPIRED`，作业 `EXPIRED`；若技能没有已确认版本则暂停（建议，待确认）。

## 10. 清理流水线

每步幂等、可重试，状态记录在作业表与作业事件里：

1. 把有价值的教训写入进化记忆库（经受控网关）。
2. 确认技能包已作为不可变版本登记在注册表。
3. 删除 Pi 会话文件与工作区。会话记录里可能带有用户的饮食、健康约束等个人信息，不应长期保留。
4. 在 PG 里只保留作业记录、技能摘要和脱敏后的验证报告。

**孤儿扫描**：定期对比会话目录与作业表；目录里有、作业表里没有的会话直接清理，终态作业超过 `cleanup_due_at` 的强制清理。清理从不依赖 Hindsight 的 recall 结果。

## 11. 失败与恢复

- Runtime 通过租约驱动作业；重启后扫描租约过期的活跃作业并续跑（Pi 会话是文件，可恢复）。
- Pi 自带的 Durable 是实验特性，**不依赖它**；持久化靠 PG 状态与会话文件。
- 失败分类（脱敏）：`BUDGET_EXCEEDED`、`TIMEOUT`、`VALIDATION_FAILED`、`SANDBOX_VIOLATION`、`WORKER_CRASHED`；每种有重试策略与最大次数。
- 作业取消：`abort`，随后进入清理。

## 12. 进化记忆库

- 与用户记忆库分离，按设备独立，视为用户私有数据；bank 名由服务端用设备 ID 映射（例如 `evo-<deviceId>`），Worker 无权选择。
- 内容是生成过程中的教训：某类代码的测试失败原因、能力的坑、验证与用户反馈的结论。
- 读写只通过受控网关；与 Pi 相关的 Hindsight 集成社区已有（例如 `pi-hindsight`），但第三方 npm 包属于代码执行，建议锁版本并审计，或像 oh-my-pi 那样自己写只用必要接口的极简客户端；两种做法都要由网关锁定 bank。
- 用户可查看、导出、删除；设备删除时一并清除。
- 默认不跨用户共享；将来如果做公共技能模板，必须另做脱敏，不能从私有库直接取。

## 13. 待原型验证

1. Pi 模型提供方能否经容器内回环转发到 Unix 套接字。
2. RPC 模式下 `--tools` 是否按预期限权。
3. 需求从对话钉到文件后，Pi 自动压缩前后行为是否一致。
4. 同一作业多个 Pi 会话的资源占用与墙钟时间。
5. gVisor 或 microVM 在目标主机上的可用性与开销。
6. `agent_settled` 与 `steer`、`follow_up` 在长任务中的时序。

## 14. 资料（2026-10-25 核对）

- Pi RPC 模式：https://pi.dev/docs/latest/rpc ；RPC 命令：https://pi.dev/docs/latest/rpc-commands ；SDK：https://pi.dev/docs/latest/sdk
- Pi 1.0 综述（Node 22.19、遥测与离线、权限与容器建议）：https://www.eesel.ai/es/blog/pi-coding-agent-explicado
- `--tools` 只读会话：https://composio.dev/blog/pi-agent-vs-claude-code
- Pi 与 Hindsight：https://hindsight.vectorize.io/blog/2026/06/08/oh-my-pi-hindsight-memory

Pi 迭代很快，以上以你安装的版本的官方文档为准，每次升级前重新核对本节涉及的命令与行为。
