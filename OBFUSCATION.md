# 自动化混淆流水线（Obfuscate Worker）

本仓库是 [`cmliu/edgetunnel`](https://github.com/cmliu/edgetunnel) 的 fork。上游代码里带特征码自保，但
Cloudflare 仍会按 `_worker.js` 的代码特征做识别。本仓库在原有「自动同步上游」之外，**再加一条自动化流水线**：

> `main` 上的 `_worker.js` 一变化（上游同步或手动改动）→ 自动用 [javascript-obfuscator](https://github.com/javascript-obfuscator/javascript-obfuscator) 混淆
> → 通过行为等价冒烟测试 → 发布到 **`deploy`** 分支；Cloudflare 连接 `deploy` 分支完成部署。

> 说明：本文件是 fork 自己新增的文档，**不修改上游的 `README.md`**——上游 README 改动频繁，
> 避免给 `sync.yml` 的自动合并制造冲突。

## 分支模型

| 分支 | 内容 | 用途 |
| --- | --- | --- |
| `main` | 上游原始代码（`_worker.js` 未混淆，含上游的伪装注释） | 只用于跟随上游；**不要拿它部署** |
| `deploy` | 混淆后的 `_worker.js` + `wrangler.toml` + `.obfuscate-meta.json` | **Cloudflare 部署分支**，由流水线独占管理 |

`deploy` 分支每次发布都是**单个孤儿提交 + force-push**，内容只有 CF 部署需要的三个文件：

- `_worker.js`：混淆后的 Worker 入口（名字与 `wrangler.toml` 的 `main` 保持一致）
- `wrangler.toml`：从 `main` 原样复制（`name` / `main` / `compatibility_date` / `keep_vars`）
- `.obfuscate-meta.json`：本次产物来源（源指纹、源提交、上游版本号、随机种子、生成时间）

> ⚠️ **不要手改 `deploy` 分支**：任何手写提交都会在下一次发布时被 force-push 覆盖。
> 要改配置请改 `main` 上的 `obfuscate.config.json`。

## 流水线（`.github/workflows/obfuscate-worker.yml`）

**触发**

- `workflow_run`：`Upstream Sync` 成功完成后自动跟进。*（`sync.yml` 用 `GITHUB_TOKEN` 推送，
  GitHub 不会为它触发其它 workflow 的 `push` 事件，所以必须用 `workflow_run` 串联。）*
- `push` 到 `main`，且改动涉及 `_worker.js` / `wrangler.toml` / 混淆配置 / 脚本 / 本流水线本身
- `workflow_dispatch` 手动触发，可选参数：
  - `seed`：指定随机种子（留空则随机；相同种子产物可复现）
  - `force`：源文件没变也强制重新混淆

**步骤**

1. 检出 `main`，算「源指纹」= `sha256(_worker.js + obfuscate.config.json)`
2. 与 `deploy` 分支里 `.obfuscate-meta.json` 的 `source_sha256` 比对，**一致且非 force 则直接跳过**
   （所以每天跑同步、上游没更新时不会产生无意义提交）
3. 安装 pin 住版本的 `javascript-obfuscator` 与 `wrangler`
4. 混淆：`scripts/obfuscate-worker.sh _worker.js <输出> <seed>`
5. **行为等价冒烟测试**：`scripts/worker-smoke-test.sh` 用本地 workerd 分别拉起原始版与混淆版，
   对 9 个端点发同样的请求，比较状态码 / 体积 / 内容哈希；**不一致就失败，不发布**
6. 组装部署产物并 force-push 到 `deploy`

任务摘要（Actions 运行页的 Summary）里会带上本次上游版本、源指纹、种子与体积。

## 混淆配置（`obfuscate.config.json`）

关键取舍（都经过本地实测验证）：

| 配置 | 值 | 原因 |
| --- | --- | --- |
| `target` | `browser-no-eval` | Cloudflare Workers 运行时禁止 `eval` / `new Function` |
| `stringArray` + `stringArrayEncoding: base64` | 开 | 字符串常量（域名、路径、协议名等特征）进入数组并 base64 存储 |
| `stringArrayThreshold` | `1` | 所有可入组的字符串都入组，不留明文（对象属性名不在此列，见下） |
| `splitStrings` | 开 | 再把长字符串切碎 |
| `identifierNamesGenerator` | `hexadecimal` | 标识符十六进制化 |
| `renameGlobals` | **开** | 模块顶层的函数/变量名一并改名。上游代码顶层有大量**中文函数名**（如 `特征码字典`、`数据转Uint8Array`、`拼接字节数据`），关掉的话它们会原样留在产物里成为强特征（实测残留 428 处） |
| `renameProperties` | **关** | 属性名是配置 JSON 与外部管理面板/订阅客户端的**契约**，改名会破坏兼容；`env.KV`、请求头等也依赖属性名 |
| `selfDefending` / `debugProtection` | **关** | 兼容性优先，避免与 CF 运行时/压缩冲突 |
| `controlFlowFlattening` / `deadCodeInjection` | **关** | 兼容性与运行时性能优先 |

默认效果：5.14MB 源文件（其中 4.8MB 是上游的希伯来文伪装注释）→ **约 422KB 纯混淆代码**；
混淆耗时约 2 秒。按需求，产物**只保留混淆代码**，上游那段伪装注释会被丢弃。

### 混淆覆盖情况（实测，对照产物）

| 特征类别 | 旧配置（`renameGlobals: false`） | 现配置 |
| --- | --- | --- |
| 中文标识符（函数/变量名） | 428 处 | **9 处**（且全是对象解构键/属性名） |
| 明文字符串（含中文） | 340 处 | **229 处**，全部是**对象属性名** |
| `export default` 入口 | 保留 | 保留 |

**故意保留的部分**：对象属性名（`'协议'`、`'加密方式'`、`'名称'`…）不会被改名，因为它们出现在
worker 与外部管理面板 / 订阅客户端之间的 JSON 结构里，改名会让后台面板和客户端配置读不出来。
这是配置侧的安全边界——想进一步隐藏属性名就得改上游代码（把配置契约改成不含语义的名字），
不建议在流水线里做。

> 如果 CF 仍能识别，可在 `obfuscate.config.json` 里逐项加码后重新运行流水线（每次都要靠冒烟测试兜底）：
> `controlFlowFlattening: true` → `deadCodeInjection: true` → `identifierNamesGenerator: "mangled-shuffled"`
> → `stringArrayEncoding: ["rc4"]` → 调 `stringArrayWrappersCount`。也可以只换 `seed` 让每次部署的产物都不同。

## Cloudflare 侧配置（连接 GitHub 自动部署）

在 Cloudflare 控制台把 Worker/Pages 项目的 Git 集成指向本仓库的 **`deploy`** 分支：

- **Workers（Workers Builds）**：`Settings → Build → Git 集成`，仓库选本 fork，**生产分支填 `deploy`**；
  仓库根已有 `wrangler.toml`（`main = "_worker.js"`），部署命令用默认的 `npx wrangler deploy` 即可
- **Pages**：`Settings → Builds & deployments`，生产分支选 `deploy`；Pages 会自动取仓库根的 `_worker.js`

两者都是「推分支 → 自动构建部署」。`sync.yml`/本流水线推 `main` 不会触发部署，**只有 `deploy` 分支被推送时才部署**。

## 本地复现

```bash
# 依赖（版本与流水线保持一致）
npm i --no-save javascript-obfuscator@5.9.0 wrangler@4.149.0

# 混淆（第 3 个参数是 seed，省略则随机）
OBFUSCATOR_BIN=./node_modules/.bin/javascript-obfuscator \
  bash scripts/obfuscate-worker.sh _worker.js /tmp/obfuscated-worker.js 123456

# 行为等价冒烟测试（需 wrangler，本地起 workerd，约 10 秒）
WRANGLER_BIN=./node_modules/.bin/wrangler \
  bash scripts/worker-smoke-test.sh _worker.js /tmp/obfuscated-worker.js
```

冒烟测试断言的是「两个版本行为一致」，不是绝对正确；两个版本都依赖同一个外部页面站点，
外部不可用时两边一起失败，等价性结论依然成立。

## 回滚 / 排障

- **部署回滚**：Cloudflare 侧直接回滚到上一个已部署版本（Workers 的 Versions / Pages 的 Deployments）
- **重建某个版本**：Actions 里 `workflow_dispatch` 勾 `force`，或用 `seed` 指定种子重跑
- **流水线卡在冒烟测试**：说明这次混淆会改变行为，`deploy` 分支不会被更新（旧版本继续在线）。
  用 `SMOKE_KEEP=1` 本地跑一次冒烟，工作目录里保留了 `*/summary.txt` 对比与 `wrangler.log` 日志
- **上游冲突**：`sync.yml` 走 `git pull --no-rebase`，冲突时它会失败并要求手动 Sync Fork；
  本流水线新增的文件都是上游没有的新文件，不会加剧冲突

## 工具版本

流水线 pin 住 `javascript-obfuscator@5.9.0` 与 `wrangler@4.149.0`（见 workflow 里的 `env`）。
升级时改这两个变量，并**重跑一次 `force` 验证冒烟测试通过**再合入。
