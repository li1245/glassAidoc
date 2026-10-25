# Glass Agent 文档索引（v0.3）

建议阅读顺序：

1. `architecture/system-design-v0.3.md`：总览与决策，其余文档的入口。
2. `architecture/session-and-job-model-v1.md`：连接、场景、任务、作业，如何不被阻塞。
3. `architecture/evolution-pipeline-v1.md`：从需求到试用技能；Pi 如何嵌入。
4. `architecture/skill-contract-v2.md`：技能契约与注册表状态。
5. `architecture/hardware-capability-model-v1.md`：硬件能力与可行性预检。
6. `architecture/device-protocol-v1.md`：设备通道协议与入网。
7. `architecture/security-threat-model-v1.md`：威胁与缓解。
8. `adr/decision-log.md`：决策与待确认项。
9. `roadmap/milestones-v0.3.md`：里程碑、验收、第一批任务。
10. `operations/v0.3-open-items.md`：待验证与未验证事项。

v0.2 文档（`system-design-v0.2.md`、`skill-contract-v1.md`）保留；与 v0.3 冲突之处以 v0.3 为准，v0.2 中的身份边界、模块化单体与 Hindsight 边界原则继续有效。

契约与迁移草案：

- `contracts/`：JSON Schema、能力词表、示例与 `validate.py`。
- `docs/drafts/db/`：V4–V7 迁移草案与 `verify_v4_v7.sql`。
