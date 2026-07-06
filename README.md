# n8n-develop

为每个客户构建**带中文 UI** 的 n8n Docker 镜像,内置工作流自动导入。

```
[开发机]                              [客户服务器]
本地起 n8n (ghcr.io/deluxebear/n8n:chs)
  └ git checkout -b <user>/<client>-<date>
  └ 在画布上画工作流
  └ ./scripts/sync-from-running.sh --rename    # 自动写入 workflows/<client>-<date>/
  └ ./scripts/build.sh 1.0                     # 客户子目录由分支名自动推断
  └ ./scripts/push.sh  1.0
                          └ docker pull <image>
                          └ docker compose up -d
                          └ 首次启动自动导入工作流
```

## 目录结构

```
n8n-develop/
├── workflows/             导出的工作流 JSON,每个客户分支一个子目录
│   └── <client>-<date>/   ← 由当前 git 分支名后半段推断,如 client_a-20260706
├── images/
│   ├── Dockerfile         FROM ghcr.io/deluxebear/n8n:chs, COPY workflows/<client>-<date>/ -> /workflows
│   └── entrypoint.sh      首次启动时把 /workflows 下的 JSON 导入 n8n 数据库
├── scripts/
│   ├── sync-from-running.sh   一键从运行中的 n8n 容器导出工作流到本地
│   ├── build.sh               docker build(客户子目录由分支名自动推断)
│   └── push.sh                docker push
└── deploy/
    └── docker-compose.yml      客户端 compose 文件
```

**核心约定**:一个 git 分支 = 一个客户。分支命名 `<你的用户名>/<客户名>-<日期>`,例如 `alice/client_a-20260706`。脚本会自动从分支名切掉 `<用户名>/` 前缀,得到 `<客户名>-<日期>` 作为:
- `workflows/` 下的子目录名
- 镜像名的后半段(`n8n-client-a-20260706:1.0`,下划线自动转连字符)

所以脚本不需要你手动传客户名参数,**切到客户分支后直接跑就行**。

## 关于基础镜像

本项目默认使用 **`ghcr.io/deluxebear/n8n:chs`**,这是一个社区维护的 n8n 中文汉化镜像,在官方 n8n 之上叠加了:

- 完整的中文 UI(菜单、设置、侧边栏、节点描述)
- 个人设置里的 Language 切换下拉框
- 创建菜单、数据表 tab 等强制本地化

**代价**:该镜像的 n8n 引擎版本(2.15.0)落后于官方最新版(2.28.x)。需要最新功能/节点时可改用官方镜像 `n8nio/n8n:latest`,但会失去中文 UI。

切换基础镜像:用环境变量 `BASE_N8N_IMAGE` 传给 build 脚本即可,例如:

```bash
BASE_N8N_IMAGE=n8nio/n8n:latest ./scripts/build.sh 1.0
```

Dockerfile / build 脚本会自动跟上,不需要修改任何配置文件。

## 完整工作流

### 步骤 0 — 创建客户分支

分支命名规则:**`<你的用户名>/<客户名>-<YYYYMMDD>`**

例如用户名 `alice`、客户 `client_a`、今天 2026-07-06:

```bash
git checkout master          # 或默认分支
git pull --rebase            # 确保基线最新
git checkout -b alice/client_a-20260706
```

之后所有改动都提交在这个客户分支上,master 永远保持干净作为下一个客户的新建基线。

### 步骤 1 — 本地部署 n8n

第一次运行会拉取汉化镜像(约 600MB),之后会缓存在本地:

```bash
docker run -d --name n8n-dev -p 5678:5678 \
  -v n8n_dev_data:/home/node/.n8n \
  --restart unless-stopped \
  ghcr.io/deluxebear/n8n:chs
```

确认容器跑起来:

```bash
docker ps --filter name=n8n-dev
docker logs n8n-dev | tail -5
```

看到 `n8n is ready` 之类的日志后,浏览器打开 **http://localhost:5678**。

### 步骤 2 — 在工作区画布上画工作流

1. **浏览器打开 http://localhost:5678**
2. 第一次进入会让你**创建 owner 账号**(邮箱+密码,本地开发随便填,例如 `dev@local.com` / `Dev123456`)
3. 进入主界面后,点 **"Add first workflow"** 或左侧 **"+ New workflow"**
4. 在画布上画工作流:
   - 从右侧面板拖节点到画布(或双击画布搜索节点)
   - 拖节点之间的连接线把它们串起来
   - 点每个节点配置参数
5. 在左上角给工作流命名(例如 `daily_report`)
6. 点右上角 **Save**(Ctrl+S)
7. 可以画**多个工作流**,每个独立 Save

> 提示:如果 UI 不是中文,进 Settings → Personal → Language 选「中文」并 Save。

### 步骤 3 — 执行 sync 脚本导出工作流

**前提:你已经切到客户分支(步骤 0)**。脚本会从当前 git 分支自动推断客户子目录,不需要传任何参数。

```bash
./scripts/sync-from-running.sh --rename
```

**做什么**:

- 连进 `n8n-dev` 容器
- 跑 `n8n export:workflow --backup`,把所有工作流逐个导出成 JSON
- 从当前 git 分支名切掉 `<user>/` 前缀,得到 `<client>-<date>`(如 `client_a-20260706`)
- 复制到 `workflows/<client>-<date>/`(目录不存在会自动创建)
- 加 `--rename` 后文件名变成 `<工作流名>__<id>.json`,更可读

验证一下:

```bash
ls workflows/
# client_a-20260706/

ls workflows/client_a-20260706/
# daily_report__abc123.json  sync_data__def456.json  ...
```

**这个脚本是覆盖式的**——同 id 的旧文件会被新版本覆盖,所以可以反复修改工作流、反复同步。

常用变体:

```bash
# 默认:从当前分支推断客户目录,n8n-dev 容器,可读文件名
./scripts/sync-from-running.sh --rename

# 指定容器名(如果你起的容器不叫 n8n-dev)
./scripts/sync-from-running.sh --container my-n8n --rename

# 强制覆盖客户目录(不依赖 git 分支)
./scripts/sync-from-running.sh --client client_a-20260706 --rename
```

### 步骤 4 — 本地构建客户镜像

```bash
./scripts/build.sh 1.0
```

**前提:已切到客户分支**。脚本从分支名推断客户子目录,不需要传客户名。

构建过程中:

- 以仓库根目录为 build context
- `FROM ghcr.io/deluxebear/n8n:chs`
- `COPY workflows/<client>-<date>/ -> /workflows/`
- 把 `images/entrypoint.sh` 烤进去作为启动脚本
- 镜像名:`n8n-<client>-<date>:<tag>`,下划线自动转连字符,例如 `n8n-client-a-20260706:1.0`

验证镜像:

```bash
docker images | grep n8n-client
# n8n-client-a-20260706   1.0   ...   ...
```

可选 — 本地起镜像确认工作流自动导入:

```bash
# 生成 bcrypt 密码 hash(密码自己定,比如 client_a_2024)
docker run --rm httpd:2.4 htpasswd -nbBC 12 '' 'client_a_2024' \
  | tr -d ':\n' | sed 's/^\$2y\$/\$2b\$/'

# 起镜像
docker run -d --name n8n-client-test -p 5680:5678 \
  -e N8N_INSTANCE_OWNER_MANAGED_BY_ENV=true \
  -e N8N_INSTANCE_OWNER_EMAIL=admin@client.local \
  -e N8N_INSTANCE_OWNER_PASSWORD_HASH='$2b$12$xxxxx...' \
  -v n8n_client_test_data:/home/node/.n8n \
  n8n-client-a-20260706:1.0
docker logs -f n8n-client-test
# 应能看到 [entrypoint] Import complete.

# 浏览器开 http://localhost:5680 用上面邮箱+原密码登录,工作流已就绪

# 验证完清理
docker stop n8n-client-test && docker rm n8n-client-test
docker volume rm n8n_client_test_data
```

### 步骤 5 — 推送镜像到 registry(可选)

如果客户要远程拉取:

```bash
REGISTRY=registry.example.com/your-namespace ./scripts/push.sh 1.0
```

输出 `registry.example.com/your-namespace/n8n-client-a-20260706:1.0`。客户子目录同样从分支名自动推断。

### 步骤 6 — Commit + Push 分支

所有工作流改动都在客户分支上,**不要直接 push 到 master**:

```bash
git status                                       # 看哪些文件变了
git add workflows/client_a-20260706/
git commit -m "feat(client_a): 同步工作流 v1.0

- daily_report
- sync_data
- notify_user"
git push -u origin alice/client_a-20260706
```

后续在该客户分支上继续修改工作流:

```bash
# 改完工作流后:
./scripts/sync-from-running.sh --rename
git add workflows/client_a-20260706/
git commit -m "feat(client_a): 增加订单同步工作流"
git push
./scripts/build.sh 1.1     # 客户镜像版本 +1
REGISTRY=... ./scripts/push.sh 1.1
```

### 步骤 7 — 客户部署

给客户两份文件:`deploy/docker-compose.yml` + 一个填好的 `.env`:

```bash
# 客户的 .env
N8N_IMAGE=registry.example.com/your-namespace/n8n-client-a-20260706:1.0
OWNER_EMAIL=admin@client.com
OWNER_PASSWORD_HASH='$2b$12$xxxxx...'    # 客户自己生成,密码不传给你
OWNER_FIRST_NAME=Admin
OWNER_LAST_NAME=ClientA
N8N_EDITOR_BASE_URL=https://n8n.client.com   # 如有域名
N8N_WEBHOOK_URL=https://n8n.client.com
```

客户那边:

```bash
docker compose up -d
# 首次启动 entrypoint:建 owner → 导入 /workflows → 写 marker → 重启
# 浏览器 http://<host>:5678 用 OWNER_EMAIL + 原密码登录,工作流已就绪
```

## 客户后续升级工作流

```bash
# 你的开发机
# 1. 切回客户分支,在 n8n-dev 容器里改工作流,Save
git checkout alice/client_a-20260706
# 2. sync
./scripts/sync-from-running.sh --rename
# 3. commit + push
git add workflows/client_a-20260706/ && git commit -m "feat(client_a): v1.2" && git push
# 4. build + push 镜像
./scripts/build.sh 1.2
REGISTRY=... ./scripts/push.sh 1.2

# 客户那边
# 5. 改 .env 里 N8N_IMAGE 标签为 1.2
# 6. ⚠️ 必须删数据卷才会重新导入:
docker compose pull
docker compose down -v       # ⚠️ 会丢客户在 UI 里自己改的工作流
docker compose up -d
```

**重要**:客户在 UI 里自己改的工作流会被覆盖。生产环境的工作流编辑应该回到你这边做,再走一遍 build/push 流程,不要让客户直接在 UI 上改。

## 命令速查

| 场景 | 命令 |
|---|---|
| 起本地 n8n | `docker run -d --name n8n-dev -p 5678:5678 -v n8n_dev_data:/home/node/.n8n --restart unless-stopped ghcr.io/deluxebear/n8n:chs` |
| 看日志 | `docker logs -f n8n-dev` |
| 停/删容器 | `docker stop n8n-dev && docker rm n8n-dev` |
| 清空数据重来 | `docker volume rm n8n_dev_data` |
| 新建客户分支 | `git checkout -b <user>/<client>-<YYYYMMDD>` |
| 导出工作流 | `./scripts/sync-from-running.sh --rename` |
| 构建镜像 | `./scripts/build.sh 1.0` |
| 推送镜像 | `REGISTRY=... ./scripts/push.sh 1.0` |
| 生成密码 hash | `docker run --rm httpd:2.4 htpasswd -nbBC 12 '' 'PWD' \| tr -d ':\n' \| sed 's/^\$2y\$/\$2b\$/'` |

## FAQ

### Q: 为什么不直接用官方镜像 `n8nio/n8n`?
A: 官方镜像没有打包中文 locale 文件(`zh-CN.json` 在源码里有 543K 翻译,但官方 build 没把它打进 editor-ui bundle),并且没有 Language 切换下拉框。要让 UI 显示中文,只能用社区汉化镜像 `ghcr.io/deluxebear/n8n:chs`,或者自己从 n8n 源码 fork 重新编译(成本远高于本项目)。

### Q: 这个项目依赖 n8n 源码吗?
A: **不依赖**。本项目只是 `FROM` 一个已经编译好的 n8n 镜像,把工作流 JSON 烤进去。工作流 JSON 是"数据",n8n 镜像是"程序",两者解耦。n8n 官方或汉化作者更新镜像后,你只需要用 `BASE_N8N_IMAGE=...` 重新 build,不需要 merge 任何源码。

### Q: 客户升级 = 简单 pull 镜像就行?
A: 不是。entrypoint 用 marker 文件检测是否已导入过,所以单纯 `docker compose pull && up -d` 不会重新导入工作流。客户升级的标准动作是 `docker compose pull && docker compose down -v && docker compose up -d`(注意 `-v` 会删数据卷,丢客户在 UI 里自己改的工作流)。

### Q: chs 镜像里的 n8n 是不是旧版?
A: 是。`ghcr.io/deluxebear/n8n:chs` 当前的 n8n 引擎版本是 2.15.0,而官方最新是 2.28.x。汉化功能以落后版本为代价。需要最新节点/功能时可改用 `BASE_N8N_IMAGE=n8nio/n8n:latest ./scripts/build.sh 1.0`,但失去中文 UI。

### Q: 为什么脚本不需要传客户名?
A: 因为分支命名规则是 `<user>/<client>-<date>`,脚本从 `git rev-parse --abbrev-ref HEAD` 拿到分支名,切掉 `<user>/` 前缀就得到 `<client>-<date>`,直接用作 `workflows/` 子目录名和镜像名后半段。一个分支 = 一个客户,不需要每次手敲客户名。如果你不在客户分支上(比如在 master),脚本会报错提示先 `git checkout -b`。