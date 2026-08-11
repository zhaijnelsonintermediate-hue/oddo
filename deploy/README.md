# 在 Railway 上部署 Odoo 18 CRM

## 为什么不是 Vercel

Vercel 跑无状态 serverless 函数，Odoo 是有状态的常驻进程。冲突是架构级的，不是配置能绕过的：

| 阻塞项 | Odoo 需要 | Vercel 提供 |
| --- | --- | --- |
| 体积 | 内核 101M + web 80M + mail 40M + crm 11M，加 Python 依赖约 300–400M | Python 函数包上限 250MB（解压后） |
| 启动 | 每次启动加载 registry，几十秒 | 函数超时 60s（Hobby）/ 300s（Pro），且每次冷启动重来 |
| 附件存储 | 持久磁盘上的 filestore | 只有临时 `/tmp`，实例间不共享 |
| 实时推送 | chatter / 活动提醒靠 websocket 长连接 | Python runtime 不支持长连接 |
| 定时任务 | `ir.cron` 常驻 worker（线索自动分配、活动到期提醒） | 无常驻进程 |
| 数据库连接 | 连接池假设进程长生命周期 | 函数并发造成连接风暴 |

Railway 提供容器 + 持久卷 + 托管 Postgres，这三样正好是上面缺的。

## 部署步骤

### 1. 建项目并挂 Postgres

在 [railway.app](https://railway.app) 新建 Project → **Deploy from GitHub repo** → 选
`zhaijnelsonintermediate-hue/oddo`，分支 `claude/odoo-open-source-system-da1r23`。

Railway 会自动发现根目录的 `Dockerfile` 和 `railway.json`，不需要额外配置构建。

然后在同一个 Project 里 **New → Database → Add PostgreSQL**。

### 2. 把数据库连给 Odoo 服务

进 Odoo 服务的 **Variables**，添加一个引用变量：

```
DATABASE_URL = ${{Postgres.DATABASE_URL}}
```

`PORT` 由 Railway 自动注入，不要手动设。

### 3. 挂持久卷

Odoo 服务 → **Settings → Volumes → Add Volume**，挂载路径填：

```
/var/lib/odoo
```

**这一步不能省。** 附件、邮件附件、会话都存在这里，不挂卷的话每次重新部署全部丢失。

### 4. 设置管理员密码

```
ODOO_ADMIN_PASSWORD  = 你的强密码
ODOO_MASTER_PASSWORD = 另一个强密码
```

`ODOO_ADMIN_PASSWORD` 是 `admin` 用户的登录密码。**不设的话首次初始化后 admin 密码是默认的 `admin`，部署即裸奔。**
`ODOO_MASTER_PASSWORD` 是数据库管理器的主密码。

### 5. 部署

首次部署会跑数据库初始化（装 base + crm 及其依赖），大约 3–8 分钟。`railway.json`
里健康检查超时设成了 600 秒就是为了容纳这段时间。

完成后在 **Settings → Networking → Generate Domain** 生成一个 `*.up.railway.app`
域名，打开即是登录页，用 `admin` + 你设的 `ODOO_ADMIN_PASSWORD` 登录。

要绑自己的域名，同一页 **Custom Domain** 里填域名，Railway 会给一条 CNAME 记录，
到你的 DNS 服务商那边加上即可，证书 Railway 自动签发。`proxy_mode = True` 已经配好，
Odoo 会正确识别 Railway 转发过来的 `X-Forwarded-Proto`，不会出现 https 页面里混进
http 链接的问题。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DATABASE_URL` | — | **必填**，Railway Postgres 引用变量。也可改用 `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`/`PGDATABASE` |
| `PORT` | `8069` | Railway 自动注入 |
| `ODOO_ADMIN_PASSWORD` | — | admin 登录密码。**强烈建议设置** |
| `ODOO_MASTER_PASSWORD` | 每次启动随机生成 | 数据库管理器主密码 |
| `ODOO_INIT_MODULES` | `crm` | 首次初始化安装的模块，逗号分隔。如 `crm,sale_management,project` |
| `ODOO_UPDATE_MODULES` | 空 | 每次启动升级这些模块。改了模块的 XML/CSV 后用它生效 |
| `ODOO_LOAD_LANGUAGE` | 空 | 初始化时加载的语言包，中文填 `zh_CN` |
| `ODOO_WITH_DEMO` | `0` | 设 `1` 装演示数据。生产环境保持 `0` |
| `ODOO_LIST_DB` | `False` | 是否暴露数据库管理器。生产环境保持 `False` |
| `ODOO_WORKERS` | `0` | **不要改**，见下方说明 |
| `ODOO_MAX_CRON_THREADS` | `2` | 定时任务线程数 |
| `ODOO_DB_MAXCONN` | `32` | 数据库连接池上限 |
| `ODOO_DB_SSLMODE` | `prefer` | Railway 内网连接用 `prefer` 即可 |
| `ODOO_LIMIT_TIME_CPU` | `300` | 单请求 CPU 秒数上限 |
| `ODOO_LIMIT_TIME_REAL` | `600` | 单请求墙钟秒数上限 |
| `ODOO_LOG_LEVEL` | `info` | 调试时设 `debug` |

## 几个必须知道的约束

**`ODOO_WORKERS` 必须是 0。** 多进程（prefork）模式下 Odoo 把 websocket 放在第二个
端口（`gevent_port`，默认 8072）上服务，而 Railway 每个服务只暴露一个端口 —— 改成
多进程会让 CRM 的 chatter 和活动提醒静默失效。线程模式在同一端口内处理 websocket
升级（`odoo/service/server.py:141`），所以单端口平台上它才是对的选择。

**`numReplicas` 必须是 1。** filestore 在单个卷上，Railway 的卷只能挂给一个实例。
要横向扩容得先把 filestore 换成 S3 兼容存储。

**代码改了怎么生效。** 改 Python 代码重新部署即可；改了模块的 XML 视图、CSV 权限等
数据文件，需要设 `ODOO_UPDATE_MODULES=你的模块名` 触发一次模块升级。

## 本地开发

```bash
docker compose up --build
```

起来之后三个地址都能用，账号 `admin` / `admin123`：

| 地址 | 说明 |
| --- | --- |
| <http://odoo.localhost> | **推荐**。`*.localhost` 在 Chrome / Firefox / Safari 里自动解析到 127.0.0.1（RFC 6761），不用改 hosts |
| <http://localhost> | 同一个反向代理，走 80 端口 |
| <http://localhost:8069> | 直连 Odoo，绕过代理。调试代理问题时用 |

想用自定义域名（比如 `crm.local`），在 hosts 文件里加一行即可，代理是按端口匹配的，不挑 Host：

```
127.0.0.1 crm.local
```

macOS / Linux 改 `/etc/hosts`，Windows 改 `C:\Windows\System32\drivers\etc\hosts`。

**80 端口被占用的话**，把 `docker-compose.yml` 里 proxy 服务的 `"80:80"` 改成 `"8080:80"`，
然后访问 <http://odoo.localhost:8080>。

源码目录是 bind mount 的，改了代码重启容器即可，不用重新构建镜像。

生成自定义模块骨架：

```bash
./odoo-bin scaffold my_crm_ext custom-addons/
```

不要直接改 `addons/` 下的官方模块 —— 用 `_inherit` 在 `custom-addons/` 里扩展，
升级上游 Odoo 时才不会冲突。

## 成本参考

Odoo 空载常驻内存约 400–600MB，装了 CRM 后建议至少 1GB。Railway 按用量计费，
Odoo 服务 + Postgres + 卷，轻量使用大致每月 10–20 美元。
