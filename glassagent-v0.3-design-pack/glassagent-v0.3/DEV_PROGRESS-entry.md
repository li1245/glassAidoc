### 2026-10-25 — v0.3 设计基线（草案）

- 引入 Pi 作为沙箱内的进化引擎（RPC 子进程，不进程内嵌入）；内置实时功能保留在 Spring Boot。
- 技能类型新增 `SCRIPT_BUNDLE`（TypeScript），版本状态新增 `TRIAL`、`EXPIRED`；`WORKFLOW` 与 `JVM_JAR` 保留但不再作为主线。
- 新增设计文档：设备协议、硬件能力模型、技能契约 v2、会话与作业模型、进化流水线、安全威胁模型、决策记录、里程碑。
- 新增契约：设备信封 Schema、SkillManifest v2 Schema、能力词表，配套示例与 `contracts/validate.py`（已运行通过）。
- 新增迁移草案 V4–V7（放在 `docs/drafts/db/`，评审后再放入 `db/migration/`）；在本地 PostgreSQL 16 上对 V1–V3 基线执行成功，`verify_v4_v7.sql` 18 项断言通过；PostgreSQL 18 上待复跑。
- 未改动 Runtime 源码；Kotlin 契约变更仅为文字说明，未编译。
- 下一步：评审 `adr/decision-log.md` 的待确认项，进入 M0（契约冻结）与 M1（设备网关与手机端）。
