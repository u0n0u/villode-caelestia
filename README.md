# Villode Caelestia

基于 [Caelestia Shell](https://github.com/caelestia-dots/shell) 的个人二次开发整合项目。

本仓库提供统一安装入口。Caelestia Shell 本体来自 Villode 的受控 Fork 并始终安装；中文化、Dock、Desktop 和 Launcher 可以自由选择，不会强制捆绑。

## 组件

| 组件 | 作用 | 独立仓库 |
| --- | --- | --- |
| Shell | 固定、测试并由 Villode 跟随适配的 Caelestia 本体 | [caelestia-shell](https://github.com/Villode/caelestia-shell) |
| 中文化 | Caelestia Shell 简体中文界面 | [caelestia-zh-cn](https://github.com/Villode/caelestia-zh-cn) |
| Dock | macOS 风格 Dock、实时毛玻璃、拖放固定 | [villode-dock](https://github.com/Villode/villode-dock) |
| Desktop | 静态图片、视频和 HTML 桌面层 | [villode-desktop](https://github.com/Villode/villode-desktop) |
| Launcher | macOS 风格应用启动台，与 Dock 拖放联动 | [villode-launcher](https://github.com/Villode/villode-launcher) |

安装器通过 `components.tsv` 锁定 Shell 和每个可选组件的提交版本。上游更新不会自动进入安装渠道，必须先同步到 `caelestia-shell` 的 `villode` 分支，完成中文补丁和组合测试后再更新锁定提交。

安装开始时会先获取全部选中组件、检查源码完整性，并验证中文组件能否干净应用到锁定的 Shell。只有这些检查和组件安装全部成功后，显式请求的旧桌面替换才会执行；失败的安装不会把组件状态标记成最新。

## 前提

- Hyprland / Wayland
- Git
- Shell 安装器需要 `caelestia-cli`、Quickshell 以及 Caelestia 的运行依赖
- 默认自动检测并补齐依赖，安装系统包时需要 `sudo` 权限
- 独立会话由 UWSM 管理，Caelestia 的注销按钮会执行 `uwsm stop` 有序返回登录管理器
- Arch 上自动补齐独立会话依赖时会安装 `foot`，用于 Super+Return 和终端内更新流程
- Arch 系统没有 `yay`/`paru` 时，会自动安装 `base-devel`、`git` 和 `yay-bin`

## 交互式安装

```bash
git clone https://github.com/Villode/villode-caelestia.git
cd villode-caelestia
./install.sh
```

安装器会始终部署锁定的 Villode Caelestia Shell，并显示可选组件菜单。

## 一键安装全部组件

```bash
./install.sh --all
```

完整安装会创建独立的 `Villode Hyprland` 登录会话和
`~/.config/villode-hyprland` 配置目录，不读取用户现有的 Noctalia/CachyOS Hyprland 配置。
首次安装默认保留旧会话作为救援入口；注销后在 SDDM 中选择 `Villode Hyprland`。

确认独立会话正常后，可以自动识别并替换 Noctalia、Waybar、HyprPanel、AGS、Eww、Nwg Panel/Dock 和 Ironbar：

```bash
./install.sh --all --replace-existing
```

替换流程会先备份相关用户配置和 Hyprland 配置，再停止旧 Shell、仅移除冲突软件包。
作为 Quickshell 提供者的 `noctalia-qs` 会保留，避免更新中断时留下不可用的 Shell。备份位置会记录在
`~/.local/state/villode-caelestia/desktop-migration.txt`。

默认行为等同于：

```bash
./install.sh --all --keep-existing
```

如果不需要独立登录会话，仅安装组件：

```bash
./install.sh --all --no-session
```

只安装指定组件：

```bash
./install.sh --components zh,dock,launcher
```

如果只想检查现有环境、不允许安装器补充系统依赖：

```bash
./install.sh --all --no-deps
```

只部署文件，不启动程序，也不修改 Hyprland 配置：

```bash
./install.sh --all --no-start --no-hyprland
```

调试时可以跳过原生插件构建，继续使用系统已有插件：

```bash
./install.sh --components shell --no-native-build --no-start
```

已经下载过对应版本后，可以离线安装：

```bash
./install.sh --all --offline
```

离线模式只使用已锁定且版本完全匹配的本地缓存，不会访问网络，也不会安装系统依赖。安装器会保存依赖、启动、Hyprland、独立会话、原生构建和离线模式，后续更新会复用这些选择。`--no-hyprland` 同时禁止写入用户会话和独立 Villode 会话的 Hyprland 集成。

## 更新与修复

检查全部组件的真实安装版本：

```bash
villode-caelestia-update --check
```

状态为“有更新”或“需要修复”时，直接执行：

```bash
villode-caelestia-update
```

“需要修复”表示状态记录缺失、文件不完整，或者 Shell 的真实 revision 与记录不一致。更新器会重新部署对应组件并重建可信的版本记录。离线安装会默认离线检查；需要恢复在线渠道时可使用 `villode-caelestia-update --online`。

虚拟机从旧桌面到纯净 Villode 环境的完整测试步骤见
[`VM-TESTING.zh-CN.md`](VM-TESTING.zh-CN.md)。

## 卸载

交互式选择：

```bash
villode-caelestia-uninstall
```

卸载全部组件：

```bash
villode-caelestia-uninstall --all
```

卸载指定组件并清理它们的用户数据：

```bash
villode-caelestia-uninstall --components dock,launcher --purge
```

默认卸载不会删除组件用户数据。中文化卸载也不会自动删除 `~/.config/quickshell/caelestia`，避免误删用户自行修改的 QML。
部分卸载会按剩余组件重建独立会话的自启动项。全部卸载会移除更新/卸载命令并恢复安装前的注销命令，但会保留 `migration-backups` 和 `desktop-migration.txt`，以便恢复旧桌面。

## 项目边界

- Caelestia 本体由 `Villode/caelestia-shell` Fork 完整保存和维护。
- 统一仓库负责编排并锁定版本，不重复复制组件源码。
- 每个组件可独立安装、更新和卸载。
- 完整安装会先安装 Launcher、最后安装并刷新 Dock，确保启动台入口立即显示。
- `Villode Hyprland` 会话使用项目自己的窗口规则、快捷键和自启动，不受旧桌面配置影响。
- 不包含本机配置、缓存、日志、密钥或个人素材。
- Caelestia Shell 的上游代码仍遵循 GPL-3.0-only。

## 许可

统一安装器以 MIT License 发布；被安装组件分别遵循各自仓库中的许可证。
