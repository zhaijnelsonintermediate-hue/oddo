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

> **先说计费。** Railway 没有长期免费额度，新账号有一笔试用额度，用完需要绑卡上
> Hobby 计划（$5/月起，按实际用量计费）。Odoo + Postgres + 卷轻量使用大致每月
> 10–20 美元。走这条路之前先知道这件事。

### 1. 建项目

在 [railway.app](https://railway.app) 用 GitHub 账号登录 → **New Project** →
**Deploy from GitHub repo**。

首次会让你授权 Railway 访问 GitHub 仓库。如果列表里找不到 `oddo`，点
**Configure GitHub App**，在 GitHub 的授权页面把这个仓库勾上再回来。

选中 `zhaijnelsonintermediate-hue/oddo` 之后 Railway 会立刻开始构建。

### 2. 换成正确的分支

**默认分支上没有部署配置，第一次构建一定会失败，这是正常的。**

进 Odoo 服务 → **Settings → Source → Branch**，改成：

```
claude/odoo-open-source-system-da1r23
```

改完 Railway 会自动重新构建。它会发现根目录的 `Dockerfile` 和 `railway.json`，
构建方式不用另外配。

### 3. 加 Postgres

同一个 Project 里 **New → Database → Add PostgreSQL**。

### 4. 把数据库连给 Odoo 服务

进 Odoo 服务的 **Variables**，添加一个引用变量：

```
DATABASE_URL = ${{Postgres.DATABASE_URL}}
```

注意值要原样填 `${{Postgres.DATABASE_URL}}` —— 这是 Railway 的引用语法，
它会在部署时替换成真实连接串。不要去 Postgres 服务里复制那串明文地址过来，
那样密码轮换后就失效了。如果你的数据库服务不叫 `Postgres`，把前半段换成实际名字。

`PORT` 由 Railway 自动注入，不要手动设。

### 5. 挂持久卷

Odoo 服务 → **Settings → Volumes → Add Volume**，挂载路径填：

```
/var/lib/odoo
```

**这一步不能省。** 附件、邮件附件、会话都存在这里，不挂卷的话每次重新部署全部丢失。

### 6. 设置密码和语言

继续在 **Variables** 里加：

```
ODOO_ADMIN_PASSWORD  = 你的强密码
ODOO_MASTER_PASSWORD = 另一个强密码
ODOO_LOAD_LANGUAGE   = zh_CN
```

`ODOO_ADMIN_PASSWORD` 是 `admin` 用户的登录密码。**不设的话首次初始化后 admin
密码是默认的 `admin`，域名一生成就是裸奔状态。**
`ODOO_MASTER_PASSWORD` 是数据库管理器的主密码。
`ODOO_LOAD_LANGUAGE=zh_CN` 让初始化时把中文语言包一起装上。

只是想先试用、看看功能长什么样，再加一个：

```
ODOO_WITH_DEMO = 1
```

会带一批演示线索和客户，空管道没什么可看的。**但这批数据之后清不干净** ——
真要转生产得删库重来，所以确定要正式用的话就别加这条。

### 7. 部署

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

### 不用 Docker 跑（虚拟化开不了时走这条）

Docker Desktop 报 **Virtualization support not detected** 时，说明 CPU 虚拟化在
固件里关着，或者这台机器被 IT 策略锁了。先花 30 秒确认是哪种：

任务管理器（`Ctrl+Shift+Esc`）→ **性能** → **CPU** → 看「虚拟化」这一项。

- **已禁用** → 重启进 BIOS 打开 `Intel VT-x` / `AMD SVM Mode`，两分钟的事，之后
  用上面的 Docker 方案，那条路更省心。
- **已启用但 Docker 仍报错** → 管理员 PowerShell 跑 `wsl --install`，重启。
- **公司电脑、改不了，或者是虚拟机** → 用下面这条原生方案，完全绕开虚拟化。

Odoo 在 Windows 上原生跑其实比 Linux 更省事：`requirements.txt` 把
`python-ldap`、`gevent`、`greenlet` 这几个需要编译的都排除了
（`sys_platform != 'win32'`），剩下的基本都有现成的 wheel。少了 gevent 意味着
只能跑线程模式，而这正好是我们要的模式。

**1. 装 Python 3.12** — <https://www.python.org/downloads/>
安装第一屏**务必勾上 `Add python.exe to PATH`**。

**2. 装 PostgreSQL** — <https://www.postgresql.org/download/windows/>
安装过程中会让你给 `postgres` 用户设密码，**记下来**，下一步要用。其余一路默认。

**3. 拿代码**

```powershell
cd $HOME\Desktop
git clone --depth 1 -b claude/odoo-open-source-system-da1r23 https://github.com/zhaijnelsonintermediate-hue/oddo.git
cd oddo
```

**4. 一条命令装好并启动**

```powershell
python deploy\setup_local.py --demo
```

脚本会问你 PostgreSQL 的密码（第 2 步设的那个），然后自动建虚拟环境、装依赖、
建库、装 CRM、启动服务。**首次约 10-15 分钟。**

`--demo` 会带上演示数据。想要干净的库就去掉这个参数。

**5. 打开** <http://localhost:8069>，账号 `admin`，密码 `admin123`。

之后每次启动只要再跑一遍同一条命令，脚本会跳过已经做完的步骤，几秒就起来。

| 参数 | 作用 |
| --- | --- |
| `--demo` | 装演示数据 |
| `--admin-password 你的密码` | 改 admin 登录密码（默认 `admin123`） |
| `--db-name 别的名字` | 换数据库名（默认 `odoo_crm`） |
| `--http-port 8070` | 换端口 |
| `--modules crm,sale_management` | 多装几个模块 |
| `--setup-only` | 只安装不启动 |

**依赖装到一半报编译错误**，装一下 Microsoft C++ Build Tools 再重跑：
<https://visualstudio.microsoft.com/visual-cpp-build-tools/>

**PDF 报表需要额外装 wkhtmltopdf**（CRM 本身用不到，可以先跳过）：
<https://wkhtmltopdf.org/downloads.html>，要装 `0.12.6` 那个打过补丁的版本。

### 从零开始（Windows，用 Docker）

**1. 装 Docker Desktop。** 从 <https://www.docker.com/products/docker-desktop/>
下载安装，按提示重启。装完启动它，等托盘的鲸鱼图标不再转动。验证：

```powershell
docker --version
docker compose version
```

两条都有版本号输出才算好了。报 `docker: command not found` 或
`Cannot connect to the Docker daemon` 就是 Docker Desktop 没启动。

**2. 拿代码。** 完整历史有 1 GB 以上，用浅克隆快很多：

```powershell
git clone --depth 1 -b claude/odoo-open-source-system-da1r23 https://github.com/zhaijnelsonintermediate-hue/oddo.git
cd oddo
```

没装 git 就去仓库页面选对分支后 **Code → Download ZIP**，解压后进入该目录。

**3. 起服务。**

```powershell
docker compose up --build
```

首次要拉基础镜像、编译 Python 依赖、初始化数据库，**约 10–20 分钟**，取决于网速。
中途大量输出是正常的。

**4. 等这一行出现**，才算真的起来了：

```
odoo-1  | ... INFO ? odoo.service.server: HTTP service (werkzeug) running on
```

**5. 打开** <http://odoo.localhost>，用 `admin` / `admin123` 登录。

**6. 停止**：终端里按 `Ctrl+C`。彻底清掉容器用 `docker compose down`；
连数据库一起清掉重来用 `docker compose down -v`（会删光数据，慎用）。

> PowerShell 里设环境变量的写法和 Linux 不同，`PROXY_PORT=8080 docker compose up`
> **在 PowerShell 里不生效**。要改端口，在仓库根目录建一个 `.env` 文件写上
> `PROXY_PORT=8080`，这个写法所有系统通用。

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

### 80 端口被占用

Windows 上 80 端口经常被 IIS、`World Wide Web Publishing Service` 或 HTTP.sys
预留占着。这时 Caddy 起不来，浏览器报 `ERR_CONNECTION_REFUSED`（注意这个错误码
说明域名解析是好的，只是没人监听）。先查是谁占了：

```powershell
netstat -ano | findstr :80          # Windows
sudo lsof -i :80                    # macOS / Linux
```

换个端口即可，不用改文件：

```bash
PROXY_PORT=8080 docker compose up
```

或在仓库根目录建个 `.env` 写上 `PROXY_PORT=8080`，然后访问
<http://odoo.localhost:8080>。

### 排查顺序

代理层出问题时按这个顺序看：

```bash
docker compose ps            # 三个服务是否都是 running
docker compose logs proxy    # Caddy 有没有起来、绑没绑上端口
docker compose logs odoo     # Odoo 是否已经 "Modules loaded"
curl http://localhost:8069/web/health   # 绕过代理直连，返回 {"status": "pass"} 说明 Odoo 本身没问题
```

最后一条能直接区分是代理的问题还是 Odoo 的问题。

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
