# dsh-upgrade-notes

> 个人实测记录，非官方文档，与 DeepSeek 无关联，不构成官方迁移指引。
> Personal field notes. Unofficial, unaffiliated with DeepSeek, and not official migration guidance.

把 `0.1.0-rc.7 → 0.1.0-rc.8 → 0.1.1-rc.1 → 0.1.1-rc.2` 的升级链（加一次降级读取、一跳 alpha 前瞻）在 macOS 和 Linux CI 上各实跑一遍的原始记录。每一跳用五个探针判定：服务启动 / 工作区注册表 / 会话列表 / 会话历史可读 / 用户配置存活；原始日志全部入仓，CI 可重跑。

**结论先行：**

- **已测的升级路径本身没坏。** shipped 默认（JSONL）存储上，三跳升级 + 一次降级读取，macOS 与 Linux 各 20 项判定全绿，会话历史事件数两侧逐项一致（均 69）。
- **真正会拦住人的是安装阶段。** 默认 Node 堆的机器上，npm 解依赖树内存触顶（Mark-Compact 停在 ~2015.6MB 后 `exit 134`）；内存更大的机器上同一命令毫无异常。CI 把「默认堆复现崩溃 → 社区 workaround 装成功」两步保留在同一次 run 里。
- **存储不兼容的准确边界比 release note 字面更细。** SQLite 后端是 opt-in；schema 常量编译在 provider 插件里，跟插件走、不跟 harness 走——只升 harness 不会撞，升插件才会撞（四幕实测见下）。

**English TL;DR** — Re-runnable field notes of upgrading DSH across rc tags on macOS + Linux CI. The tested upgrade chain itself holds: 20/20 probes green per platform on the shipped JSONL path, downgrade read included. The real blocker is install-time: npm dependency resolution tops out the default V8 old-space heap (`exit 134`) on ~2GB-heap machines while bigger machines sail through — the CI run keeps both the crash repro and the community workaround. SQLite storage incompatibility is opt-in and travels with the plugin, not the harness.

## 升级矩阵 / Upgrade matrix

macOS（本地实跑，`summary.json` 机器判定）：

| hop | platform | server boots | workspace registry | session listed | session log readable | user settings honored |
|---|---|---|---|---|---|---|
| `0.1.0-rc.7->0.1.0-rc.8` | macos | ✅ | ✅ | ✅ | ✅ | ✅ |
| `chain-0.1.0-rc.8->0.1.1-rc.1` | macos | ✅ | ✅ | ✅ | ✅ | ✅ |
| `chain-0.1.1-rc.1->0.1.1-rc.2` | macos | ✅ | ✅ | ✅ | ✅ | ✅ |
| `chain-0.1.1-rc.2->0.1.0-rc.7`（降级读取） | macos | ✅ | ✅ | ✅ | ✅ | ✅ |
| `chain-0.1.1-rc.2->0.1.2-alpha.2` | macos | ✅ | ❌* | ❌* | ❌* | ❌* |

Linux（GitHub Actions run `33071234071`，本仓 Actions 页可查）：四跳同矩阵**全 ✅（20/20）**，`history_events` 与 macOS 逐项一致；同一 run 内含 OOM 复现步骤（默认堆 `exit 134`）与 workaround 安装步骤。

\* **alpha.2 行注记：四个 ❌ 是旧 API 探针失效，不是数据损失。** `0.1.2-alpha.2` 引入了 API 鉴权（token/cookie）与 API 层重构（路径 `.`→`/`、typert 化请求信封），本仓的 rc 世代探针拿不到响应；rc.7 世代造的会话数据在 alpha.2 的 UI 中完整渲染，用户配置原样生效。顺带：这套探针由此成了第一个被 alpha.2 重构击中的外部消费者——AGENTS.md 的 pre-release 立场（首个正式 tag 前不做兼容承诺）落在我们自己身上的现身说法。

## 安装阶段实测 / Install-time findings

| 现象 | 实测 | 出处 |
|---|---|---|
| npm 安装 OOM | ubuntu runner（7GB RAM）+ 默认堆：`FATAL ERROR: Ineffective mark-compacts near heap limit`，Mark-Compact ~2015.6MB，npm `exit 134`（SIGABRT）；修法 = `NODE_OPTIONS=--max-old-space-size=4096`。macOS 侧同命令峰值 RSS 2.9-3.5GB 却无事——V8 默认堆上限随可用内存放大，「同命令不同机器结果相反」的机制在这 | CI run 33071234071；`logs/macos/install-*.log`（`/usr/bin/time -l` 原始数据） |
| npx 冷缓存 | `npx @deepseek-ai/dsh@latest --version` 冷缓存 **905 秒**、峰值 RSS 3.54GB（macOS arm64，直连 npmjs），只为打印一个版本号 | `logs/macos/npx-cold-timing.log` |
| Node 版本边界 | Node 16.20.2：boot 立死于 `node:util` 无 `parseEnv`（Node 21.7+ API），报错只字不提版本；Node 22.18.0（低于声明下限一个 patch）：boot、建会话、落盘全部正常，下限的具体触发点未复现到（如实标注）。engines 下限声明位于仓库根 `package.json`；发布到 npm 的包内我没有找到 engines 字段（核验：`dsh` / `dsh-base` / `dsh-host-apiproxy`），npm 安装时不会因 Node 版本给出警告 | `logs/macos/node-16-boot.log`、`node-22.18-*.log` |

## 会话存储：拒绝而非迁移 / Storage: rejected, not migrated

AGENTS.md 写明 pre-release 阶段不做兼容承诺（`SESSION_FORMAT_VERSION` 保持 0）。SQLite 对照组四幕把这个立场翻译成用户可感的形状：

1. rc.7 + SQLite 插件（opt-in）造库（schema 15）→ 正常
2. **只升 harness** 到 rc.8、插件钉在 rc.7 → **正常读**（schema 常量编译在插件内）
3. **升插件**到 rc.8（库还是 15）→ 整树启动失败：`session database ... has schema version 15, incompatible with this build (17)`；插件降回 rc.7 → 立即救活
4. rc.8 造 schema-17 库 → 全套升 alpha.2 → 同型拒绝（17 vs 20）——下一次 schema 变更已在 alpha 频道排队

shipped 默认的 JSONL 路径不受影响（即矩阵全绿那条路）。日志：`logs/macos/sqlite-*`。

## 源码定位 / Source anchors

| 条目 | 定位（均按 tag 核验） |
|---|---|
| 会话格式版本 | `packages/core/session/src/types.ts:56`（`SESSION_FORMAT_VERSION = 0`，含 alpha.2） |
| 双向拒绝文案 | `packages/session/session-persistence/src/coordinator.ts:78-80`；语义见 `docs/subsystems/persistence.md:94` |
| SQLite schema 常量 | `packages/session/session-persistence-sqlite/src/schema.ts`（rc.7=15 / rc.8=17 / alpha.2=20） |
| 安装内存扇出 | `apps/cli/package.json` 60+ 直接 workspace 依赖；发布包无 lockfile 传导，npm/npx 每次全量解树 |
| Node API 用点 | `dsh-app-boot` 首行 import `parseEnv`（21.7+）；`packages/host/apiproxy/src/fetch/client.ts:315-316`（`AbortSignal.timeout` 17.3+ / `.any` 20.3+） |
| 插件钉版机制 | `$DSH_HOME/profiles/web/package.json`（`dsh plugin add @ver` 精确钉版，不带 `^`） |

## 重跑 / Reproduce

- `fixtures/install-tag.sh <ver>`：按版本隔离前缀安装，`/usr/bin/time -l` 记录 npm 峰值内存
- `fixtures/make-fixture.sh <ver> <port>`：起服务→建工作区→建会话→发 prompt→落盘快照，全程 tee 日志
- `fixtures/upgrade-hop.sh`：还原快照→新版启动同一 home→五问探针→`summary.json` 机器可判
- `.github/workflows/upgrade-matrix.yml`：Linux 全链 CI（零密钥——升级实跑不需要 LLM）
- fixture 生成不需要真实密钥：LLM 端点配置为任意 OpenAI 兼容的本地替身（`apiKeyEnv` 环境变量注入，配置文件里不落密钥）

**诚实边界**（未覆盖，如实标注）：npx 缓存路径上的升级、`dsh` 自升级命令本身、装有第三方插件的 profile 层（`profiles/node_modules` 默认为空，SQLite 四幕是目前唯一的插件跨版样本）。
