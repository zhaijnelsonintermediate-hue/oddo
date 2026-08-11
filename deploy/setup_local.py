#!/usr/bin/env python3
"""Set up and run Odoo locally without Docker.

Written for machines where Docker cannot run — a laptop with virtualization
disabled in firmware, or a managed one where it is locked off. It needs only
Python and a PostgreSQL server, neither of which uses virtualization.

    python deploy/setup_local.py

It creates a virtualenv, installs the pinned dependencies, creates the
database, installs CRM into it, and starts the server. Re-running it skips
whatever is already done, so it doubles as the everyday start command.

The environment variables match deploy/entrypoint.sh, so the local setup and
the Railway deployment behave the same way.
"""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IS_WINDOWS = platform.system() == "Windows"


def log(msg: str) -> None:
    print(f"[setup] {msg}", flush=True)


def die(msg: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"\n[setup] 错误: {msg}\n", file=sys.stderr)
    sys.exit(1)


def venv_python(venv: Path) -> Path:
    return venv / ("Scripts/python.exe" if IS_WINDOWS else "bin/python")


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run([str(c) for c in cmd], check=True, **kw)


# ---------------------------------------------------------------------------
# 1. Interpreter
# ---------------------------------------------------------------------------
def check_python() -> None:
    major, minor = sys.version_info[:2]
    # setup.py declares python_requires>=3.10; above 3.12 the pinned wheels
    # in requirements.txt start running out.
    if (major, minor) < (3, 10):
        die(f"需要 Python 3.10 以上，当前是 {major}.{minor}")
    if (major, minor) > (3, 12):
        log(f"警告: Python {major}.{minor} 比 Odoo 18 官方支持的版本新，"
            "部分依赖可能没有预编译包。建议用 3.12。")
    log(f"Python {major}.{minor} on {platform.system()}")


# ---------------------------------------------------------------------------
# 2. Virtualenv + dependencies
# ---------------------------------------------------------------------------
def ensure_venv(venv: Path, skip_deps: bool) -> Path:
    py = venv_python(venv)
    if not py.exists():
        log(f"创建虚拟环境 {venv}")
        run([sys.executable, "-m", "venv", str(venv)])
    else:
        log(f"复用已有虚拟环境 {venv}")

    if skip_deps:
        log("跳过依赖安装 (--skip-deps)")
        return py

    # psycopg2 is the cheapest proof that the install already happened —
    # it is the last thing Odoo needs before it can reach the database.
    probe = subprocess.run(
        [str(py), "-c", "import psycopg2, lxml, PIL, werkzeug"],
        capture_output=True,
    )
    if probe.returncode == 0:
        log("依赖已安装，跳过")
        return py

    log("安装依赖（首次约 3-8 分钟）")
    run([py, "-m", "pip", "install", "--upgrade", "pip", "--quiet"])
    try:
        run([py, "-m", "pip", "install", "-r", str(REPO / "requirements.txt")])
    except subprocess.CalledProcessError:
        die(
            "依赖安装失败。最常见的原因是缺少编译工具。\n"
            "  Windows: 装 Microsoft C++ Build Tools\n"
            "           https://visualstudio.microsoft.com/visual-cpp-build-tools/\n"
            "  Linux:   sudo apt install build-essential libpq-dev libxml2-dev "
            "libxslt1-dev libldap2-dev libsasl2-dev\n"
            "  macOS:   xcode-select --install && brew install postgresql libxml2"
        )
    return py


# ---------------------------------------------------------------------------
# 3. Database
# ---------------------------------------------------------------------------
def ensure_database(py: Path, cfg: dict) -> bool:
    """Create the database if absent. Returns True when it still needs Odoo's
    schema installed."""
    script = r"""
import sys, psycopg2
from psycopg2 import sql
host, port, user, password, dbname = sys.argv[1:6]
try:
    admin = psycopg2.connect(host=host, port=port, user=user,
                             password=password, dbname="postgres")
except psycopg2.OperationalError as exc:
    print("CONNFAIL:" + str(exc).strip().splitlines()[0]); sys.exit(3)
admin.autocommit = True
with admin.cursor() as cur:
    cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (dbname,))
    if not cur.fetchone():
        cur.execute(sql.SQL("CREATE DATABASE {}").format(sql.Identifier(dbname)))
        print("CREATED"); sys.exit(0)
admin.close()

# The database exists — has Odoo already been installed into it?
conn = psycopg2.connect(host=host, port=port, user=user,
                        password=password, dbname=dbname)
with conn.cursor() as cur:
    cur.execute("SELECT to_regclass('public.ir_module_module') IS NOT NULL")
    print("INSTALLED" if cur.fetchone()[0] else "EMPTY")
"""
    proc = subprocess.run(
        [str(py), "-c", script, cfg["host"], cfg["port"],
         cfg["user"], cfg["password"], cfg["dbname"]],
        capture_output=True, text=True,
    )
    out = (proc.stdout or "").strip()

    if out.startswith("CONNFAIL:"):
        die(
            f"连不上 PostgreSQL ({cfg['user']}@{cfg['host']}:{cfg['port']})\n"
            f"  {out[len('CONNFAIL:'):]}\n\n"
            "检查：\n"
            "  1. PostgreSQL 装了吗？Windows 下载: https://www.postgresql.org/download/windows/\n"
            "  2. 服务在跑吗？Windows 里 services.msc 找 postgresql-x64-*\n"
            "  3. 密码对吗？用 --db-password 或环境变量 PGPASSWORD 指定"
        )
    if proc.returncode != 0 and not out:
        die(f"数据库检查失败:\n{proc.stderr}")

    if out == "CREATED":
        log(f"已创建数据库 {cfg['dbname']}")
        return True
    if out == "EMPTY":
        log(f"数据库 {cfg['dbname']} 存在但还是空的")
        return True
    log(f"数据库 {cfg['dbname']} 已初始化")
    return False


# ---------------------------------------------------------------------------
# 4. Config file
# ---------------------------------------------------------------------------
def write_config(cfg: dict, data_dir: Path, conf_path: Path) -> None:
    custom = REPO / "custom-addons"
    custom.mkdir(exist_ok=True)
    addons = ",".join(str(p) for p in (custom, REPO / "odoo/addons", REPO / "addons"))

    conf_path.write_text(
        "[options]\n"
        f"admin_passwd = {cfg['master_password']}\n"
        f"db_host = {cfg['host']}\n"
        f"db_port = {cfg['port']}\n"
        f"db_user = {cfg['user']}\n"
        f"db_password = {cfg['password']}\n"
        f"db_name = {cfg['dbname']}\n"
        f"dbfilter = ^{cfg['dbname']}$\n"
        "list_db = False\n"
        f"addons_path = {addons}\n"
        f"data_dir = {data_dir}\n"
        "http_interface = 127.0.0.1\n"
        f"http_port = {cfg['port_http']}\n"
        # Threaded mode: gevent is excluded on Windows in requirements.txt, and
        # it is what serves the CRM chatter websocket in-process anyway.
        "workers = 0\n"
        "max_cron_threads = 2\n"
        "limit_time_real = 600\n",
        encoding="utf-8",
    )
    conf_path.chmod(0o600)
    log(f"已写入配置 {conf_path}")


# ---------------------------------------------------------------------------
# 5. Install + run
# ---------------------------------------------------------------------------
def install_modules(py: Path, conf: Path, cfg: dict, modules: str, demo: bool) -> None:
    log(f"初始化数据库并安装: {modules}（约 3-8 分钟，请耐心等）")
    cmd = [py, str(REPO / "odoo-bin"), "-c", str(conf), "-d", cfg["dbname"],
           "-i", modules, "--stop-after-init", "--no-http"]
    if not demo:
        cmd.append("--without-demo=all")
    if cfg["language"]:
        cmd.append(f"--load-language={cfg['language']}")
    run(cmd)

    if cfg["admin_password"]:
        log("设置 admin 密码")
        code = (
            "import os\n"
            "admin = env.ref('base.user_admin')\n"
            "admin.password = os.environ['ODOO_ADMIN_PASSWORD']\n"
            "env.cr.commit()\n"
        )
        env = {**os.environ, "ODOO_ADMIN_PASSWORD": cfg["admin_password"]}
        run([py, str(REPO / "odoo-bin"), "shell", "-c", str(conf),
             "-d", cfg["dbname"], "--no-http", "--log-level=warn"],
            input=code, text=True, env=env)
    else:
        log("警告: 未设置 --admin-password，admin 密码是默认的 'admin'")


def serve(py: Path, conf: Path, cfg: dict) -> None:
    url = f"http://localhost:{cfg['port_http']}"
    print()
    log("=" * 58)
    log(f"启动 Odoo — 浏览器打开  {url}")
    log(f"  账号: admin")
    log(f"  密码: {cfg['admin_password'] or 'admin'}")
    log("停止: 在这个窗口按 Ctrl+C")
    log("=" * 58)
    print()
    os.execv(str(py), [str(py), str(REPO / "odoo-bin"),
                       "-c", str(conf), "-d", cfg["dbname"]])


# ---------------------------------------------------------------------------
def main() -> None:
    p = argparse.ArgumentParser(
        description="不用 Docker，在本机安装并启动 Odoo 18 CRM")
    p.add_argument("--db-host", default=os.environ.get("PGHOST", "localhost"))
    p.add_argument("--db-port", default=os.environ.get("PGPORT", "5432"))
    p.add_argument("--db-user", default=os.environ.get("PGUSER", "postgres"))
    p.add_argument("--db-password", default=os.environ.get("PGPASSWORD"))
    p.add_argument("--db-name", default=os.environ.get("ODOO_DB", "odoo_crm"))
    p.add_argument("--http-port", default=os.environ.get("PORT", "8069"))
    p.add_argument("--admin-password",
                   default=os.environ.get("ODOO_ADMIN_PASSWORD", "admin123"))
    p.add_argument("--master-password",
                   default=os.environ.get("ODOO_MASTER_PASSWORD", "local-master"))
    p.add_argument("--modules", default=os.environ.get("ODOO_INIT_MODULES", "crm"))
    p.add_argument("--language", default=os.environ.get("ODOO_LOAD_LANGUAGE", "zh_CN"))
    p.add_argument("--demo", action="store_true", default=False,
                   help="装演示数据（想先看看功能长什么样就加上）")
    p.add_argument("--venv", default=str(REPO / ".venv"))
    p.add_argument("--skip-deps", action="store_true")
    p.add_argument("--setup-only", action="store_true", help="装完不启动")
    args = p.parse_args()

    if args.db_password is None:
        import getpass
        args.db_password = getpass.getpass(
            f"PostgreSQL 用户 {args.db_user} 的密码: ")

    cfg = {
        "host": args.db_host, "port": args.db_port, "user": args.db_user,
        "password": args.db_password, "dbname": args.db_name,
        "port_http": args.http_port, "admin_password": args.admin_password,
        "master_password": args.master_password, "language": args.language,
    }

    check_python()
    if not (REPO / "odoo-bin").exists():
        die(f"在 {REPO} 里找不到 odoo-bin，脚本位置不对？")

    py = ensure_venv(Path(args.venv), args.skip_deps)
    needs_install = ensure_database(py, cfg)

    data_dir = REPO / ".odoo-data"
    data_dir.mkdir(exist_ok=True)
    conf = REPO / ".odoo.conf"
    write_config(cfg, data_dir, conf)

    if needs_install:
        install_modules(py, conf, cfg, args.modules, args.demo)
    else:
        log("已初始化过，直接启动")

    if args.setup_only:
        log("--setup-only：安装完成，未启动")
        return
    serve(py, conf, cfg)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        die(f"命令执行失败（退出码 {exc.returncode}）: {' '.join(map(str, exc.cmd))}")
    except KeyboardInterrupt:
        print("\n[setup] 已中断")
