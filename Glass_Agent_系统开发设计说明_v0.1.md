# Glass Agent 系统开发设计说明

**版本：** 0.1（架构基线）  
**日期：** 2026-10-21  
**用途：** 指导多用户 Glass Agent 平台的软件开发；硬件实现另行定义。

## 1. 目标与边界

系统为多个家庭成员和多台眼镜设备提供统一的 Agent 平台。每台设备完成身份认证并绑定到成员；所有事件、记忆、技能和定时任务都必须按家庭、成员、设备及授权范围隔离。平台支持 HTTP 短时交互和 WebSocket 持续会话，并允许 Agent 从长期行为中形成习惯、提出技能改进，必要时生成代码；新技能通过隔离构建、测试和发布后运行，不要求重启 Agent 核心服务。

系统包含独立的管理后台：管理后台用 Spring MVC 实现，用于家庭/成员、设备准入、黑白名单、权限、数据审计、技能版本和运行状态管理。Glass Agent 后端是事件驱动的运行平台，不以传统 MVC 页面应用作为核心架构。

### 1.1 设计原则

1. 身份与授权在服务端验证，设备上报的 `user_id`、`household_id` 不能作为可信身份。
2. 每个请求均从认证主体得到 household/member/device 范围；数据库查询、Hindsight bank、技能权限都执行同一范围校验。
3. Agent 记忆、行为策略、可执行技能和系统权限是不同的数据与生命周期。
4. LLM 生成代码属于不可信代码；任何静态检查或模型生成的测试都不能替代进程/OS 隔离。
5. 在线感知、后台学习、模型推理、技能构建使用独立队列和资源池，媒体拥塞不能阻塞锁车提醒等控制路径。
6. 技能以不可变版本发布，路由可切换、可灰度、可撤回。
7. 未确定的吞吐量通过目标负载与压测得出，不以未经测量的毫秒数字作为架构承诺。

### 1.2 明确不在首期范围

- 自主修改 Agent 核心服务或数据库 schema 并直接上线。
- 生成代码直接在 Gateway/Agent 主 JVM 中运行。
- 不经用户授权推断或执行有显著外部影响的行为。
- 无限保留原始音视频或将所有家庭成员信息默认共享。

## 2. 逻辑架构

```text
眼镜设备
  ├─ HTTP：短时命令、单次媒体上传、查询
  └─ WebSocket：持续会话、控制消息、状态推送、实时音频片段
                         │
               Agent Gateway（Kotlin/JVM）
       设备认证、白/黑名单、会话、限流、事件接入
                         │
          ┌──────────────┴──────────────┐
          │                             │
   Agent Runtime                 Media Ingress/Workers
   意图、策略、技能路由           图像/音频预处理、识别
          │                             │
          ├─ Memory API ─ Hindsight + PostgreSQL（记忆存储）
          ├─ Capability API ─ 定位、通知、商品查询等受控工具
          ├─ Skill Registry ─ 版本、权限、路由、回滚
          └─ Temporal ─ 定时任务、长期/可恢复工作流
                         │
   Kafka 事件流 / PostgreSQL 业务库 / 对象存储 / 模型路由

  独立管理平面：Spring MVC Admin API + 管理 UI
  通过管理 API 访问业务服务；不直接读写 Agent 私有运行表。
```

### 2.1 推荐技术基线

| 领域 | 选型基线 | 说明 |
|---|---|---|
| Agent 核心与 Gateway | Kotlin/JVM、Spring Boot | Kotlin 协程可用于异步流程；WebSocket/HTTP 入口不承担媒体推理 |
| 长连接入口 | Spring WebFlux / Reactor Netty | 适合大量非阻塞会话；事件循环中禁止执行阻塞数据库、图像或模型调用 |
| 管理后台 | Spring MVC | 独立管理平面，用户、设备、策略、审计等常规管理流程 |
| 服务同步通信 | gRPC + Protobuf | 内部类型化 RPC、生成 SDK、接口版本化 |
| 异步事件 | Kafka | 事件持久化、按 key 分区、消费者独立扩缩；通过 Outbox 避免数据库提交与事件发布不一致 |
| 长期任务 | Temporal | 定时提醒、可恢复的多步骤业务流程；不使用内存定时器承担持久任务 |
| 事务数据 | PostgreSQL | 身份、设备、事件索引、授权、技能元数据和审计 |
| 记忆 | Hindsight（经 Memory Service 接入） | retain/recall/reflect；数据按 household/member bank 隔离 |
| 媒体对象 | S3 兼容对象存储 | 保存需要保留的图片/音频/视频；事件队列只传对象引用和元数据 |
| 生成技能执行 | 独立 OCI Worker；Linux 环境采用 gVisor，隔离要求更高时用 microVM | 不在 Agent JVM 内加载不可信代码；镜像按版本不可变 |

Spring WebFlux 使用少量事件循环线程处理非阻塞 I/O；CPU 密集任务和阻塞库必须隔离到有界工作池或 Worker。背压必须明确采用降速、限量缓冲、丢弃过期数据或拒绝请求等策略。参考：[Spring WebFlux 并发模型](https://docs.spring.io/spring-framework/reference/web/webflux/new-framework.html)。

## 3. 服务边界和通信模式

### 3.1 同步请求

内部服务调用用 gRPC/Protobuf，契约放在独立 `proto` 模块并生成 Kotlin/Java 客户端。gRPC 不承担“全系统所有通信”：它适合短请求/响应和受控能力调用。使用 mTLS 或工作负载身份认证，并在服务端按 household/member/device 做授权；TLS 只保护传输，不代替授权。

### 3.2 异步事件

Kafka 事件使用 Protobuf/Avro 等有版本的 schema。建议按 `household_id` 或 `device_id` 分区，保证单个设备/家庭内事件顺序；消费者必须幂等。事件至少包含：`event_id`、`event_type`、`occurred_at`、`received_at`、`household_id`、`member_id`、`device_id`、`session_id`、`schema_version`、`correlation_id`。

### 3.3 设备传输

- HTTP：设备注册/心跳以外的普通命令、配置查询、单张图片/文件上传。
- WebSocket：持续 Agent 会话、控制与状态推送；协议帧包含类型、序号、会话 ID、时间戳和幂等 ID。
- 图片/音视频大载荷不长期堆在 WebSocket/Gateway 内存；媒体可经 HTTP 流式上传至对象存储，WebSocket/Kafka 只传元数据和引用。
- 若未来需要低延迟实时音视频，单独评估 WebRTC；不把 WebSocket 与实时媒体传输能力等同。

### 3.4 不同处理路径隔离

控制与提醒最高优先级；图像、音频、推理、记忆提炼、进化构建使用各自有界队列/工作池。实时视频通常采用每设备有界缓冲并丢弃过时帧（latest-frame-wins）；需要完整留存时才进入持久化归档路径。音频需维持片段顺序并设置队列上限。队列满时不得无限占用 JVM 堆内存。

## 4. 多家庭、多成员和设备隔离

### 4.1 租户模型

- `household` 是共享资源与管理边界。
- `member` 是个人身份与私人记忆边界。
- `device` 归属一个 household，并绑定一个当前使用 member；绑定变更有审计记录。
- 数据显式标记 `visibility`：`PRIVATE`、`HOUSEHOLD` 或必要的系统级范围。默认私人，不默认向家庭其他成员共享。
- 家庭共享设备也必须在每次会话确认实际用户身份/使用者；设备绑定不是“任何拿到设备的人都等于该成员”。

所有业务表包含 `household_id`；个人数据增加 `member_id`；设备事件增加 `device_id`。每个服务端授权上下文来自已验证凭据，不从请求 JSON 中直接信任租户字段。PostgreSQL 查询使用 household/member 过滤，并优先配置 Row-Level Security 作为纵深防御；应用层仍必须授权，RLS 不取代业务校验。

Hindsight bank 至少按 household 隔离；个人记忆使用每 member 独立 bank 或等价隔离策略；家庭共享记忆单独 bank。Memory Service 负责映射与验证 bank ID，客户端不得自行选择任意 bank。

### 4.2 设备白名单/黑名单状态机

设备状态建议：`PENDING` → `ACTIVE` → `BLOCKED` / `REVOKED`。只有 `ACTIVE` 且在有效家庭绑定下的设备可以建立会话。黑名单命中优先拒绝，并记录原因、操作者、时间和审计事件。设备凭据使用每设备独立密钥或证书，支持轮换、吊销和过期；禁止全家共用一个静态密钥。短期访问令牌包含 device/household/member scope、有效期和权限。

```text
初次配对 → 待批准 → 管理员允许 → 签发设备凭据
被盗/异常 → 立即封禁并撤销凭据 → 断开活动会话 → 拒绝新连接
误封恢复 → 管理员审核 → 重新签发凭据（不恢复旧密钥）
```

白名单是显式准入列表；黑名单是显式拒绝列表。判断顺序：黑名单拒绝 > 状态/凭据验证 > 家庭绑定和成员授权 > 具体能力授权。

## 5. 数据库设计

主业务 PostgreSQL 与 Hindsight 自己管理的记忆库应视作不同 schema/数据库边界。禁止业务代码直接依赖 Hindsight 私有表。Temporal 使用自己的持久化存储配置。媒体二进制放对象存储，数据库只存元数据和引用。

### 5.1 核心实体关系

```text
households 1─N household_members N─1 users
households 1─N devices N─1 members（当前绑定，可为空）
devices 1─N device_sessions 1─N agent_events
agent_events 1─N observations → habit_candidates → habits
skills 1─N skill_versions 1─N skill_executions
skill_versions 1─N skill_capability_grants
所有管理变更 → audit_log
```

### 5.2 表设计（核心字段）

| 表 | 核心字段/约束 |
|---|---|
| `users` | `id UUID PK`、登录主体、状态、`created_at`；个人账号身份，不放设备密钥 |
| `households` | `id UUID PK`、名称、状态、`created_at` |
| `household_members` | `household_id`、`user_id`、`role`、状态、加入/离开时间；唯一 `(household_id,user_id)` |
| `devices` | `id UUID PK`、`household_id`、当前 `member_id`、`device_key_id`、状态、型号、固件版本、`last_seen_at`；索引 `(household_id,status)` |
| `device_credentials` | `id`、`device_id`、凭据摘要/证书指纹、`issued_at`、`expires_at`、`revoked_at`；不存明文密钥 |
| `device_access_rules` | `household_id`、`device_id`、`decision` (`ALLOW`/`DENY`)、原因、有效期、创建者；Deny 优先 |
| `device_sessions` | `id`、tenant/member/device、传输类型、开始/结束时间、状态、连接元数据；索引 `(device_id,started_at DESC)` |
| `agent_events` | UUID、tenant/member/device/session、类型、时间戳、`idempotency_key`、对象引用、schema 版本、处理状态；按时间分区；唯一 `(device_id,idempotency_key)` |
| `media_objects` | UUID、tenant/member/device、对象存储 key、媒体类型、大小、hash、保留截止时间、删除状态；禁止将签名 URL 当永久凭据 |
| `memory_links` | 自有映射表：tenant/member、Hindsight bank ID、visibility、状态；唯一约束保证范围映射 |
| `observations` | tenant/member、来源事件 ID、观察类型、内容/结构化值、置信度、证据数、有效期、状态；敏感字段加密或排除 |
| `habits` | tenant/member、名称、适用条件 JSON、行为效果、证据引用、置信度、状态 (`CANDIDATE/CONFIRMED/PAUSED/REJECTED`)、生效/复核时间 |
| `skills` | UUID、tenant/member 或 shared owner、稳定名称、当前 active version、状态、创建来源 |
| `skill_versions` | skill ID、版本号、manifest、artifact digest、语言/runtime、生成来源、测试报告引用、状态 (`DRAFT/TESTED/CANARY/ACTIVE/RETIRED/REJECTED`)、创建时间；唯一 `(skill_id,version)` |
| `skill_capability_grants` | tenant、skill version、capability 名、资源范围、批准者、有效期；默认无权限 |
| `skill_executions` | tenant/member/device、skill/version、输入/输出摘要、状态、耗时、错误码、correlation ID；敏感 payload 不默认落库 |
| `schedules` | tenant/member、workflow ID、时区、日历规则、目标技能、状态、创建/更新时间；Temporal ID 唯一映射 |
| `audit_log` | actor、tenant、操作、对象、前后值摘要、原因、时间、请求/相关 ID；仅追加，不供普通用户修改 |
| `outbox_events` | event ID、aggregate ID、类型、payload、创建/发送时间、重试次数；与业务事务同库提交 |

### 5.3 关键 SQL 约束示例

```sql
CREATE TABLE devices (
  id UUID PRIMARY KEY,
  household_id UUID NOT NULL REFERENCES households(id),
  member_id UUID NULL,
  status TEXT NOT NULL CHECK (status IN ('PENDING','ACTIVE','BLOCKED','REVOKED')),
  device_key_id TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ
);
CREATE INDEX devices_household_status_idx ON devices(household_id, status);

CREATE TABLE agent_events (
  id UUID PRIMARY KEY,
  household_id UUID NOT NULL,
  member_id UUID,
  device_id UUID NOT NULL REFERENCES devices(id),
  session_id UUID,
  event_type TEXT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL,
  idempotency_key TEXT NOT NULL,
  payload JSONB NOT NULL,
  schema_version INTEGER NOT NULL,
  UNIQUE (device_id, idempotency_key)
);
CREATE INDEX agent_events_scope_time_idx
  ON agent_events(household_id, member_id, occurred_at DESC);
```

生产 DDL 需处理时间分区表的唯一索引规则；上例表达逻辑约束，分区实施时可用 `(event_month, device_id, idempotency_key)` 或独立幂等表实现。所有跨租户外键应包含 tenant key 或经复合约束保证不能把其他 household 的成员/设备错误关联进来。

### 5.4 数据保留与删除

为原始事件、图片、音频、转写、长期记忆分别配置保留策略。原始媒体默认短期保留或不保留；用户可查询、修正、删除自己的记忆。删除成员时执行跨服务删除工作流：撤销凭据、停止定时任务、清理私人对象、清理/匿名化事件、删除对应 Hindsight bank 或成员记忆，并保留合规所需的最小审计记录。

## 6. 行为记忆与自我进化

“种子生现行，现行熏种子”对应受控闭环：

```text
事件 → 观察（observation）→ 习惯候选（habit candidate）
     → 证据/置信度/适用条件评估 → 确认或用户批准
     → 决策策略影响 → 技能/流程候选
     → 沙箱回放评估 → 版本发布
     → 运行结果与纠错再次成为事件
```

- Hindsight 负责经验记忆的 retain/recall/reflect；不可让它直接改身份边界或权限。
- Behavior 服务形成带条件、证据、置信度和复核时间的习惯；单次行为只能是观察。
- Evolution 服务从重复流程或明确请求识别能力缺口，生成技能代码和 manifest。
- 对锁车、定位、通知、家庭共享等有外部影响的能力，技能授权要由用户或家庭管理员批准。
- 新技能只能调用 manifest 明确申请并获批的 Capability API；不能直连主数据库或任意网络。

## 7. 生成代码沙箱和技能发布

```text
需求/行为信号
  → LLM 生成代码 + manifest + 接口版本
  → 临时构建沙箱
  → 依赖锁定、许可证/漏洞扫描、静态检查、编译
  → 单元测试 + SDK 契约测试 + 恶意输入测试
  → 无生产凭据的集成测试 + 历史事件回放
  → 签名 artifact，写 skill_versions
  → 启动隔离 Worker（gVisor 容器；高风险用 microVM）
  → 健康检查与 canary
  → 路由切换；指标异常立即回退
```

运行约束：非 root、只读根文件系统、无特权、默认禁网、无宿主目录挂载、CPU/内存/进程数/临时存储/执行时间上限。能力调用通过 gRPC Capability Broker；Broker 从短期身份凭据推导 tenant scope 并逐次校验 grant。Worker 崩溃不影响 Agent Runtime；超时可终止整个隔离执行单元。

**函数调用顺畅性**：技能内部函数是进程内普通调用；只有跨沙箱边界的系统能力调用才 RPC。SDK 和 Protobuf 契约由平台维护并生成，不要求每个技能作者重造连接、鉴权和序列化。高频细粒度能力应合并为批量/粗粒度 API，避免一个算法循环产生大量 RPC。

## 8. 典型运行流程

### 8.1 设备事件接入

1. 设备使用设备级凭据建立 HTTP/WS 连接。
2. Gateway 验签、检查 credential 未吊销、设备为 ACTIVE、黑名单未命中。
3. 服务端根据 credential 和设备绑定生成不可由客户端覆盖的 `SecurityContext`。
4. 事件校验 schema、大小、速率和幂等 ID；媒体流式进对象存储。
5. 事务写事件/Outbox；发布事件到 Kafka。
6. Agent Runtime 按优先级处理；需要媒体或 LLM 时投递隔离 Worker。
7. 结果通过 WS 推送；离线时按策略保存可恢复通知。

### 8.2 家庭成员隔离

每个查询由服务端构造 `household_id/member_id/device_id` 范围；技能使用家庭共享数据时必须有明确 grant。记忆召回先由 Memory Service 验证 bank scope，再调用 Hindsight。对跨用户 IDOR、伪造 tenant ID、技能跨家庭查询做强制安全测试。

### 8.3 定时提醒

Agent 解析自然语言要求 → 澄清时区/重复规则 → 校验通知权限 → Temporal 创建持久 Schedule → 执行时重新检查用户/设备状态和授权 → 通知 → 记录结果。封禁设备不应无条件删除家庭提醒；任务归属成员，设备只是投递目标。

## 9. 管理后台（Spring MVC）

后台作为独立管理平面，功能包括家庭和成员管理、设备配对审批、允许/封禁/撤销、凭据轮换、技能版本/测试/灰度状态、记忆查看与删除请求、审计检索、健康状态和策略配置。

- 后台调用 Admin API/领域服务，不直接访问 Agent Runtime 内部表。
- 高危操作二次确认并记录操作者、原因和审计记录；设备封禁立即发布撤销事件并断开会话。
- 管理员角色仅在 household 范围内生效；平台运维角色单独授权并审计。
- 后台数据库账号与运行服务账号分离，最小权限。

## 10. 正常开发流程与阶段交付

### 阶段 A：平台基础与租户安全

交付：身份/家庭/成员/设备 schema，配对及白黑名单状态机，设备凭据轮换，HTTP/WS Gateway，SecurityContext，审计与租户隔离集成测试。

### 阶段 B：实时 Agent 运行路径

交付：事件契约、幂等接收、Kafka Outbox/消费者、媒体对象存储引用、控制/媒体队列隔离、模型路由、Capability API。

### 阶段 C：记忆与行为闭环

交付：Hindsight Memory Service、多 bank scope 映射、事件→观察→习惯候选、用户确认/编辑/删除、证据追踪与复核机制。

### 阶段 D：长期流程和技能系统

交付：Temporal adapter、schedule 管理、Skill Registry/manifest/SDK、技能版本和 capability grant、已有技能 Worker。

### 阶段 E：代码生成与隔离发布

交付：临时构建环境、沙箱执行、契约/回放评估、签名 artifact、Worker 发布、canary、回滚、审计。

### 阶段 F：容量与可靠性

交付：目标负载说明、媒体与 WS 并发压测、数据库/Kafka/Temporal 故障演练、备份恢复演练、成本与保留策略。

各阶段在同一个目标架构下逐步交付；服务契约、租户模型、事件模型、skill manifest 和权限模型先稳定，避免后期推倒重做。

## 11. 测试设计

### 11.1 单元测试

- 设备状态机、黑名单优先级、凭据过期/撤销。
- tenant/member 权限决策、技能 capability grant。
- 行为证据合并、置信度更新、候选→确认状态迁移。
- 幂等、重试、事件 schema 兼容、习惯适用条件。
- skill manifest 校验、版本比较和回滚决策。

### 11.2 集成测试

- PostgreSQL migration、复合租户约束、RLS 策略。
- Kafka Outbox、重复投递、消费者重放和顺序保证。
- Hindsight bank scope 映射、召回无跨成员泄漏、删除行为。
- Temporal schedule 创建、修改、取消、时区、重试和 worker 重启恢复。
- Capability Broker 鉴权、超时、限流、熔断和 mTLS。

### 11.3 契约测试

- Protobuf 兼容性与跨版本客户端/服务端。
- Skill SDK 输入输出 schema、错误码、超时和取消语义。
- Worker manifest 与实际请求 capability 一致；未授权调用必须拒绝。
- HTTP/WS 事件协议兼容；旧设备 schema 的升级/降级策略。

### 11.4 隔离与安全测试

- 恶意技能尝试读宿主文件、环境变量、云凭据、其他 household 数据。
- 任意外网连接、端口扫描、DNS 隧道、子进程、fork bomb、内存/CPU/磁盘耗尽。
- 沙箱逃逸回归用例；镜像签名和依赖供应链检查。
- 伪造 `household_id/member_id/device_id`、重放设备令牌、撤销后复用。
- WebSocket 会话劫持、过期凭据、跨设备绑定、黑名单后既有会话断开。
- 对家庭成员私人记忆的访问控制、导出、删除和审计。

### 11.5 技能质量测试

- 构建、单元、属性/模糊测试。
- Capability API 契约测试和模拟依赖集成测试。
- 以历史事件做确定性回放，比较旧版/新版成功率、错误动作、延迟、成本及用户纠正率。
- 金丝雀流量、健康检查、自动停止发布和一键回滚。
- LLM 生成的测试仅是一项证据，不作为发布的唯一准入条件。

### 11.6 性能和容量测试

在硬件/真实负载目标确定后执行，并记录 p50/p95/p99、错误率、丢帧率、队列深度、堆/直接内存、GC、GPU 利用率、每 household 资源公平性。分别压测：

- 活跃 WebSocket 连接、重连风暴和慢客户端。
- HTTP 图片上传并发、尺寸上限、对象存储慢响应。
- 音频片段吞吐和端到端实时延迟。
- 视频帧积压策略与实时提醒优先级。
- Kafka consumer 延迟、Hindsight 写入/召回和 PostgreSQL 热点。
- 技能 Worker 启动时间、并发隔离、超时清理与滚动版本切换。

验收阈值在负载模型确定后写入版本化 SLO；不提前宣称固定毫秒级数字。

### 11.7 故障与恢复测试

- Gateway/Runtime/Worker 滚动重启，活动 WebSocket 重连。
- Kafka 暂不可用、重复事件、消费者崩溃与重放。
- PostgreSQL failover、连接池耗尽、迁移回滚和备份恢复。
- Temporal Worker 停机后 schedule 恢复。
- Hindsight 不可用时在线行为的降级策略（不把未保存事实假装成已记忆）。
- Skill Worker 超时/崩溃时终止隔离环境、切回上版且主系统继续服务。

## 12. 可观测性与运维要求

所有请求与异步流程贯穿 `trace_id/correlation_id`；日志按 tenant/device 记录最小必要元数据，不记录明文凭据或默认记录原始媒体。核心指标包括：活动会话数、认证拒绝原因、消息速率、队列深度/最老年龄、丢帧数、媒体处理耗时、LLM 超时、记忆写入/召回耗时、技能版本错误率、沙箱资源使用和跨租户授权拒绝数。

设备密钥、模型密钥和数据库凭据存入密钥管理系统，不写入固件公共配置、LLM prompt、日志或生成技能环境。事件和 memory 的导出/删除要有可追踪的异步操作状态。

## 13. 关键架构决策记录（ADR 摘要）

1. **主语言：Kotlin/JVM。** Python 作为可选 AI/数据 Worker，不替换主平台。
2. **非 MVC Agent 核心。** 使用事件驱动 Agent Runtime；管理后台独立采用 Spring MVC。
3. **传输分工。** 设备 HTTP/WS；内部同步 gRPC；异步 Kafka；长时任务 Temporal。
4. **多租户默认私人。** household/member/device 三层授权，家庭共享必须显式标注。
5. **生成代码独立执行。** 临时构建沙箱与版本化 Worker；不使用主 JVM 热加载作为安全扩展机制。
6. **记忆服务隔离。** Hindsight 经 Memory Service 使用；PG 保存业务事实和审计，不依赖 Hindsight 私有 schema。
7. **资源隔离。** 控制、媒体、LLM、记忆整理和技能构建分别限流、排队、扩容。

## 14. 参考

- [Spring WebFlux concurrency model and backpressure](https://docs.spring.io/spring-framework/reference/web/webflux/new-framework.html)
- [gRPC performance practices](https://grpc.io/docs/guides/performance/)
- [gRPC authentication](https://grpc.io/docs/guides/auth/)
- [Temporal Python SDK and workflow concepts](https://docs.temporal.io/develop/python)
- [Hindsight retain/recall/reflect](https://docs.hindsight.vectorize.io/cloud/reflect/)
- [Oracle Java Security Manager status](https://docs.oracle.com/en/java/javase/26/security/security-developer-guide.pdf)
- [gVisor architecture](https://gvisor.dev/docs/architecture_guide/intro/)
- [Firecracker microVM](https://firecracker-microvm.github.io/)

