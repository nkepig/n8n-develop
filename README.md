# n8n-develop

为每个客户构建**带中文 UI + 企业版功能**的 n8n Docker 镜像,内置工作流自动导入。

```
[开发机]                              [客户服务器]
本地起 n8n (ghcr.io/deluxebear/n8n:chs)
  └ git checkout -b <user>/<client>
  └ 在画布上画工作流
  └ ./scripts/sync-from-running.sh
  └ ./scripts/build.sh 1.0
  └ ./scripts/push.sh
                          └ docker pull <image>
                          └ docker compose up -d
                          └ 首次启动自动导入工作流
```

## 核心约定

一个 git 分支 = 一个客户。分支命名 `<用户名>/<客户名>`,例如 `alice/client_a`。脚本自动从分支名推断客户子目录,**切到客户分支后直接跑,不传参数**。

## 目录结构

```
n8n-develop/
├── workflows/<client>/      导出的工作流 JSON(按客户分子目录)
├── images/
│   ├── Dockerfile           FROM ghcr.io/deluxebear/n8n:chs
│   └── entrypoint.sh        首次启动自动导入 /workflows
├── scripts/
│   ├── sync-from-running.sh  从 n8n-dev 容器导出工作流
│   ├── build.sh              docker buildx build(amd64)
│   └── push.sh               docker push
└── deploy/docker-compose.yml 客户端 compose
```

## 基础镜像

`ghcr.io/deluxebear/n8n:chs` — 社区维护的中文汉化 + 企业版 mock,跟进官方最新版本(当前 `2.28.7-chs`)。

**三个 env 必须设**(已烫进 Dockerfile 和 docker-compose.yml):


| Env                   | 值             | 作用                     |
| --------------------- | ------------- | ---------------------- |
| `N8N_DEFAULT_LOCALE`  | `zh-CN`       | 中文 UI                  |
| `N8N_ENTERPRISE_MOCK` | `true`        | 企业版功能(SSO/LDAP/RBAC 等) |
| `NODE_ENV`            | `development` | enterprise mock 生效前提   |


## 步骤

### 1. 起本地 n8n

```bash
docker run -d --name n8n-dev -p 5678:5678 \
  -e N8N_DEFAULT_LOCALE=zh-CN \
  -e N8N_ENTERPRISE_MOCK=true \
  -e NODE_ENV=development \
  -e N8N_SECURE_COOKIE=false \
  -v n8n_dev_data:/home/node/.n8n \
  --restart unless-stopped \
  ghcr.io/deluxebear/n8n:chs
```

浏览器开 [http://localhost:5678,设](http://localhost:5678,设) owner 账号(邮箱+密码自己定)。

### 2. 创建客户分支

```bash
git checkout -b <你的用户名>/<客户名>
# 例如: git checkout -b alice/client_a
```

### 3. 画工作流

浏览器 [http://localhost:5678](http://localhost:5678) → 画工作流 → 左上角工作流命名（个人/xxx）。

### 4. 导出工作流

```bash
./scripts/sync-from-running.sh
```

从 `n8n-dev` 容器导出所有工作流到 `workflows/<client>/`,每个工作流一个 `<标题>.json`。

### 5. 构建镜像

```bash
./scripts/build.sh 1.0
# 产出本地镜像: n8n-xiaoming:1.0
```

用 `docker buildx build --platform linux/amd64 --load` 构建(客户服务器通常是 amd64)。

### 6. 推送镜像

首次推 Docker Hub 需先登录(只需一次):

```bash
docker login
```

然后直接 push:

```bash
./scripts/push.sh
# 自动从 docker login 状态读取用户名,retag 成 <用户名>/n8n-xiaoming:1.0 并 push
# 例如: dazey/n8n-xiaoming:1.0
```

push.sh 会自动从 `~/.docker/config.json` 或 macOS keychain 读取你 `docker login` 时输入的用户名,不需要再传 `REGISTRY`。

### 7. Commit

```bash
git add workflows/<client>/
git commit -m "feat(<client>): 同步工作流 v1.0"
git push -u origin <你的用户名>/<客户名>
```

### 8. 客户部署

**方式 A: docker run(推荐,简单)**

```bash
docker run -d --name n8n -p 5678:5678 \
  -e N8N_SECURE_COOKIE=false \
  -v n8n_data:/home/node/.n8n \
  --restart unless-stopped \
  <你的DockerHub用户名>/n8n-<client>:1.0
# 例如: dazey/n8n-xiaoming:1.0
```

> 其他 env(`N8N_DEFAULT_LOCALE` / `N8N_ENTERPRISE_MOCK` / `NODE_ENV` / `N8N_BUILTIN_WORKFLOWS_DIR`)已经烫进镜像,不需要再传。

**方式 B: docker compose**

修改 `deploy/docker-compose.yml` 里的 `image:` 改成你的镜像名,然后:

```bash
docker compose up -d
```

**首次部署后:**

1. 浏览器开 `http://<服务器IP>:5678`
2. 完成 owner 账号创建(邮箱+密码自己定)
3. **提交后 entrypoint 会自动检测到 setup 完成,导入 /workflows 下的工作流,然后重启 n8n**
4. 刷新页面,登录,工作流已就绪

> ⚠️ 工作流导入发生在 setup 完成**之后**,请先在浏览器走完 setup 向导,再回来看工作流列表。

## 客户升级

```bash
# 开发机:改工作流 → sync → commit → build + push
./scripts/sync-from-running.sh
git add workflows/<client>/ && git commit -m "v1.1" && git push
./scripts/build.sh 1.1
./scripts/push.sh
```

客户那边(⚠️ **必须删数据卷**才会重新导入,否则 marker 文件会让 entrypoint 跳过导入):

```bash
# docker run 方式
docker stop n8n && docker rm n8n
docker volume rm n8n_data
docker pull <用户名>/n8n-<client>:1.1
docker run -d --name n8n -p 5678:5678 \
  -e N8N_SECURE_COOKIE=false \
  -v n8n_data:/home/node/.n8n \
  --restart unless-stopped \
  <用户名>/n8n-<client>:1.1

# 或 docker compose 方式
docker compose pull
docker compose down -v
docker compose up -d
```

⚠️ `down -v` / `volume rm` 会删客户在 UI 里改的工作流。工作流编辑应该回到你这边做。

## 命令速查


| 场景            | 命令                                                                                                                                                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 起本地 n8n       | `docker run -d --name n8n-dev -p 5678:5678 -e N8N_DEFAULT_LOCALE=zh-CN -e N8N_ENTERPRISE_MOCK=true -e NODE_ENV=development -e N8N_SECURE_COOKIE=false -v n8n_dev_data:/home/node/.n8n --restart unless-stopped ghcr.io/deluxebear/n8n:chs` |
| 看日志           | `docker logs -f n8n-dev`                                                                                                                                                                                                                   |
| 新建客户分支        | `git checkout -b <user>/<client>`                                                                                                                                                                                                          |
| 导出工作流         | `./scripts/sync-from-running.sh`                                                                                                                                                                                                           |
| 构建镜像          | `./scripts/build.sh 1.0`                                                                                                                                                                                                                   |
| 推送镜像          | `./scripts/push.sh`(自动读 docker login 的用户名)                                                                                                                                                                                                 |
| Docker Hub 登录 | `docker login`                                                                                                                                                                                                                             |


## FAQ

### Q: 忘了 n8n-dev 的密码怎么办?

删掉 `n8n_dev_data` volume 重启即可(⚠️ 会丢容器里所有工作流,确保已 sync):

```bash
docker stop n8n-dev && docker rm n8n-dev
docker volume rm n8n_dev_data
# 然后重跑步骤 1
```

### Q: 构建镜像需要先 docker login 吗?

Build 不需要。只有 push 到 Docker Hub 才需要,首次执行 `docker login` 输入用户名和密码/Token 即可。

### Q: 为什么用 `--platform linux/amd64`?

开发机是 Apple Silicon(arm64),客户服务器通常是 amd64。buildx 跨平台构建出 amd64 镜像,`--load` 加载到本地 docker。

### Q: 客户升级 = 简单 pull 镜像就行?

不是。entrypoint 用 marker 文件检测是否已导入过,单纯 `pull && up -d` 不会重新导入。必须 `down -v` 删数据卷再 `up -d`。

### Q: 客户部署后看不到工作流?

工作流导入发生在 **owner setup 完成之后**。流程是:
1. 启动容器 → entrypoint 后台起 n8n,等待 setup
2. 浏览器开 `http://<host>:5678` → 填邮箱密码 → 提交
3. entrypoint 检测到 setup 完成 → 自动 `n8n import:workflow` → 写 marker → 重启 n8n
4. 刷新页面登录,工作流就出现了

如果你还没在浏览器走完 setup 向导,工作流不会导入。如果走完了还是没有,可能是 volume 里有旧 marker 文件——删掉 volume 重来:
```bash
docker stop n8n && docker rm n8n
docker volume rm n8n_data
# 然后重新 docker run
```

### Q: 为什么脚本不需要传客户名?

脚本从 `git rev-parse --abbrev-ref HEAD` 拿分支名,切掉 `<user>/` 前缀得到 `<client>`,直接用作 workflows 子目录名和镜像名后半段。在 master/main 上跑会报错。

### Q: 报错 "secure cookie" / Safari 打不开?

n8n 默认要求 HTTPS 才能登录。本项目在镜像和 docker-compose 里默认设了 `N8N_SECURE_COOKIE=false`,允许 HTTP 访问。如果你在 TLS 反向代理后面部署,把这个改回 `true`。

### Q: chs 镜像是不是旧版?

不是。`ghcr.io/deluxebear/n8n:chs` 跟进官方最新版本。需要固定版本用 `:2.28.7-chs` 这类显式 tag。# n8n-develop