# GlassAgent v0.3 设计包

内容：设计文档、契约（JSON Schema、能力词表、示例）、迁移草案与验证脚本。**没有改动你的源码。**

## 目录

```text
docs/                      放进仓库的 docs/（与现有 docs/architecture 合并）
  README.md                文档索引
  architecture/            v0.3 设计文档（7 份）
  adr/decision-log.md      决策记录与待确认项
  roadmap/milestones-v0.3.md
  operations/v0.3-open-items.md
  drafts/db/               V4–V7 迁移草案 + verify_v4_v7.sql
contracts/                 放进仓库根目录
  schemas/                 设备信封、SkillManifest v2、能力词表的 JSON Schema
  vocab/                   能力词表
  examples/                valid / invalid / semantic-invalid 示例
  validate.py              校验脚本
DEV_PROGRESS-entry.md      可粘贴到 DEV_PROGRESS.md 的记录
```

## 使用

1. 把 `docs/` 与 `contracts/` 合并进仓库根目录。
2. 校验契约：`pip install jsonschema && python3 contracts/validate.py`
3. 评审后，把 `docs/drafts/db/V4..V7*.sql` 放入 `agent-runtime/src/main/resources/db/migration/`。放入前先在 PostgreSQL 18 上验证：

   ```text
   psql -v ON_ERROR_STOP=1 -f V1..V7（依序）
   psql -v ON_ERROR_STOP=1 -f docs/drafts/db/verify_v4_v7.sql   # 在事务里运行并回滚
   ```
4. 先读 `docs/architecture/system-design-v0.3.md`，再看 `docs/adr/decision-log.md` 里的待确认项。

## 已验证与未验证

- 已验证：V4–V7 在 PostgreSQL 16 上对 V1–V3 基线依序执行成功，18 项断言全部通过；契约校验脚本运行通过。
- 未验证：Kotlin 契约变更与 Runtime 代码（未编译）；Pi 的实际行为（依据官方文档核对）；手机与硬件章节（未实测）。
