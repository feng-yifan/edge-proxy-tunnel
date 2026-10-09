# edge-proxy-tunnel 部署说明（Cloudflare Workers）

> 本文件由 `main` 分支的 `DEPLOY.md` 自动同步到本分支，**请勿直接在本分支修改**——`deploy`
> 分支由 GitHub Actions 流水线独占（每次发布都是单个孤儿提交 + force-push，手写提交会被覆盖）。

## 本分支是什么

`deploy` 分支由 `.github/workflows/obfuscate-worker.yml` 生成，只含三个文件：

| 文件 | 说明 |
| --- | --- |
| `_worker.js` | 经混淆的 Worker 入口（约 422KB）。源文件在 `main`，未混淆 |
| `wrangler.toml` | 部署配置（`main = "_worker.js"`、`name`、`compatibility_date`、`keep_vars = true`） |
| `.obfuscate-meta.json` | 产物来源（源提交、源指纹、混淆器版本、随机种子） |

## 为什么不要用 `main` 分支部署

`main` 跟随上游 `cmliu/edgetunnel` 每日同步，其中的 `_worker.js` 是**未混淆的原始代码**。
Cloudflare 会按代码特征识别这类 Worker 并**下发滥用报告（abuse report）**，Worker 可能被限流或封停。

所以：**CF 的生产分支必须是 `deploy`**，且首次接入时不要让它先按 `main` 构建。

## 部署步骤（Cloudflare Workers + Git 集成）

要点：**先用 Hello World 模板把 Worker 建出来，再连仓库**——这样创建流程不会拿 `main` 去构建。

1. **先部署一个默认模板**
   控制台 → `Workers & Pages` → `Create` → 选 **Start with Hello World** → 部署。
   （此时 Worker 与仓库无关，不会有任何特征识别风险，可先访问它的 `*.workers.dev` 地址确认是 Hello World。）
2. **在设置里接入 Git 仓库**
   进入这个 Worker → `Settings`（设置）→ `Build`（构建）→ `Connect` / `Git Repository` →
   选择本仓库 `feng-yifan/edge-proxy-tunnel`。
   - 若这一步要求填分支，先填 `main` 也无妨，下一步立刻改掉。
   - **Build command 留空**；**Deploy command 保持默认**（`npx wrangler deploy`），仓库根已有 `wrangler.toml`。
   - ⚠️ `wrangler.toml` 的 `name`（当前 `v20251104`）决定 `wrangler deploy` 部署到哪个 Worker：
     请让这个 Worker 的名字与之一致（不一致时 CF 会按配置里的名字部署到另一个 Worker，
     自定义域/绑定也不会跟着走）。
3. **把生产分支改为 `deploy`**
   `Settings` → `Build` → `Branch control` / `Production branch` 改为 **`deploy`**。
   改完手动触发一次部署（`Deployments → Retry deployment` / `Create deployment`），
   确认构建的是 `deploy` 分支的提交而不是 `main`。
4. **补齐运行时配置**（与分支无关，做一次即可；`keep_vars = true` 保证后续重建不丢变量）
   - 变量：`Settings → Variables and Secrets` 添加 `ADMIN` = 你的管理员密码
   - 绑定：`Settings → Bindings` 添加 **KV 命名空间**，变量名必须是 `KV`
   - 触发器：`Settings → Domains & Routes → Add custom domain` 绑定你的域名
     （⚠️ `*.workers.dev` 域名在部分内网被 DNS 污染，建议用自定义域）
5. **验证**
   - `https://<你的域名>/admin` 能打开登录页
   - 登录后能看到配置面板；订阅地址 `https://<你的域名>/sub?token=<面板里的订阅 token>&clash` 能拉到 clash 配置

## 后续更新

- 上游每日同步到 `main` → 流水线自动混淆 → **仅当源文件变化时**才 force-push 到 `deploy` → CF 自动构建部署
- 想强制换一次混淆指纹（重新随机种子并重发一次）：仓库 `Actions` → `Obfuscate Worker` → `Run workflow` → 勾 `force`
- 要改混淆强度 / 部署内容：改 `main` 上的 `obfuscate.config.json` 或本文件（`DEPLOY.md`），推送后流水线自动生效
- 排障与回滚：见 `main` 上的 `OBFUSCATION.md`；CF 侧也可用 `Deployments` 回滚到上一个版本
