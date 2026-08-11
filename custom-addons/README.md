# 你的自定义模块放这里

这个目录已经加入 addons_path（见 deploy/entrypoint.sh），Odoo 启动时会自动扫描。

生成一个新模块的骨架：

    ./odoo-bin scaffold my_crm_ext custom-addons/

不要直接改 `addons/` 里的官方模块——用 `_inherit` 在这里扩展，
升级上游 Odoo 时才不会冲突。
