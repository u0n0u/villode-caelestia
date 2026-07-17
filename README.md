# Villode Caelestia

基于 [Caelestia Shell](https://github.com/caelestia-dots/shell) 的个人二次开发整合项目。

本仓库提供统一安装入口。Caelestia Shell 本体来自 Villode 的受控 Fork 并始终安装；中文化、Dock、Desktop 和 Launcher 可以自由选择，不会强制捆绑。

**English documentation:** [README.en.md](README.en.md)

## 组件

| 组件 | 作用 | 独立仓库 |
| --- | --- | --- |
| Shell | 固定、测试并由 Villode 跟随适配的 Caelestia 本体 | [caelestia-shell](https://github.com/u0n0u/caelestia-shell) |
| 中文化 | Caelestia Shell 简体中文界面 | [caelestia-zh-cn](https://github.com/u0n0u/caelestia-zh-cn) |
| Dock | macOS 风格 Dock、实时毛玻璃、拖放固定 | [villode-dock](https://github.com/u0n0u/villode-dock) |
| Desktop | 静态图片、视频和 HTML 桌面层 | [villode-desktop](https://github.com/u0n0u/villode-desktop) |
| Launcher | macOS 风格应用启动台，与 Dock 拖放联动 | [villode-launcher](https://github.com/u0n0u/villode-launcher) |
| 指针放大 | Mac 风格晃动定位指针（cursor） | 随 [caelestia-shell](https://github.com/u0n0u/caelestia-shell) 的 `contrib/villode-cursor` 提供 |

安装器通过 `components.tsv` 锁定 Shell 和每个可选组件的提交版本。上游更新不会自动进入安装渠道，必须先同步到 `caelestia-shell` 的 `villode` 分支，完成翻译目录和组合测试后再更新锁定提交。

安装开始时会先获取全部选中组件、检查源码完整性，并验证中文翻译包与锁定的 Shell 是否兼容。只有这些检查和组件安装全部成功后，显式请求的旧桌面替换才会执行；失败的安装不会把组件状态标记成最新。

## 前提

- Hyprland / Wayland
- Git
- Shell 安装器需要 `caelestia-cli`、Quickshell 以及 Caelestia 的运行依赖
- 默认自动检测并补齐依赖，安装系统包时需要 `sudo` 权限
- 独立会话由 UWSM 管理；注销按钮执行 `villode-logout`（先停 Shell 守护，再 `uwsm stop`），有序返回登录管理器
- 无桌面/最小系统也会尽量补齐：`hyprland`、`sddm`、**GTK3/GTK4**、`gtk4-layer-shell`、Qt6、音频与门户
- 日常应用（可按系统已有包智能跳过）：终端（alacritty）、文件管理（thunar）、播放器（mpv）、看图（imv/loupe）、浏览器（优先 google-chrome，否则 firefox）
- 中文：`fcitx5` + 拼音 + 中文字体。Wayland 上**不**设置 `GTK_IM_MODULE`（走 text-input-v3）；`~/.config/uwsm/env` 会 `unset GTK_IM_MODULE` 清掉 user@ 残留；会话里 `dbus-update-activation-environment` 不用 `--all`
- 默认应用写入 `~/.config/caelestia/shell.json` 的 `general.apps`（**仅在缺失或无效时**），并同步 `mimeapps.list`；用户在设置里改过的不会被覆盖
- Super+Return / Dock 等读取 Caelestia「默认应用」中的真实系统命令（不是 villode-* 包装名）
- Arch 系统没有 `yay`/`paru` 时，会自动安装 `base-devel`、`git` 和 `yay-bin`

## 从 TTY / 无桌面安装

适合只有字符终端、尚未装桌面的机器：

```bash
git clone https://github.com/u0n0u/villode-caelestia.git
cd villode-caelestia
./install.sh --all
sudo reboot
# 在 SDDM 选择 Villode Hyprland
```

安装器会检测当前是否在图形会话中：

- **TTY / 无 Wayland**：自动跳过“立即启动 Shell/Dock”（没有合成器会失败），尽量安装并启用 SDDM，结束后提示重启。
- **已在图形会话**：安装后可直接拉起/刷新组件。

## 交互式安装

```bash
git clone https://github.com/u0n0u/villode-caelestia.git
cd villode-caelestia
./install.sh
```

安装器会始终部署锁定的 Villode Caelestia Shell，并显示可选组件菜单。GitHub 较慢时会测速并让你选择镜像。

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

交互式安装检测到现有桌面壳时会询问是否替换（默认保留）；非交互环境不加 `--replace-existing` 时始终保留。

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

## Shell 自动守护

独立会话通过 `villode-caelestia-shell-guard` 拉起 Caelestia Shell，而不是一次性的 `caelestia shell -d`。若 Quickshell 崩溃或退出，守护进程会按退避间隔自动重启，避免桌面只剩 Dock/壁纸、面板消失。

```bash
villode-caelestia-shell-guard status   # 查看守护与 Shell 状态
villode-caelestia-shell-guard restart # 手动重启
villode-caelestia-shell-guard stop    # 停止守护与 Shell（调试用）
```

日志：`~/.local/state/villode-caelestia/shell-guard.log`

## 更新与修复

设置页「Villode 更新」与命令行更新器默认走 GitHub。若访问 GitHub 较慢或不可达，安装器会按顺序尝试镜像（默认 `kkgithub.com`、`ghproxy.net`），并对每次 git 网络操作施加超时；仍失败时检查更新会回退到本地已安装的发布渠道，而不是一直卡住。

安装时（交互）会测速并让你选择更新通道，例如：

```
正在测试 GitHub 访问通道（每个最多 8s）…

  ✓  kkgithub.com（镜像）           0.8s
  ✓  ghproxy.net（代理）            1.3s
  ✓  github.com（直连）             3.0s

请选择之后安装/更新使用的通道：
  a. 自动（按速度排序，失败自动切换）  [推荐]
  1. 仅优先 kkgithub.com（镜像）（0.8s，失败仍尝试其他）
  2. …
```

选择会写入 `~/.local/state/villode-caelestia/install-options`，之后的 `villode-caelestia-update` 会沿用。

```bash
./install.sh --all                      # 非交互：测速后自动选最快优先
./install.sh --github-source kkgithub.com
./install.sh --probe-github             # 强制再测速并选择
./install.sh --skip-github-probe        # 跳过测速，用已保存/默认
```

可选环境变量：

| 变量 | 作用 |
| --- | --- |
| `VILLODE_GITHUB_SOURCE` | `auto` / `github.com` / `kkgithub.com` / `ghproxy.net` … |
| `VILLODE_GITHUB_MIRRORS` | 逗号/空格分隔的镜像列表，默认 `kkgithub.com,ghproxy.net` |
| `VILLODE_PREFER_GITHUB_DIRECT=1` | 优先直连 `github.com`，再试镜像 |
| `VILLODE_GIT_TIMEOUT` | 单次 git 网络操作超时秒数，默认 `12` |
| `VILLODE_PROBE_TIMEOUT` | 测速时每个通道超时秒数，默认 `8` |
| `VILLODE_UPDATE_REMOTE` | 强制指定更新渠道远程 URL |

检查全部组件的真实安装版本：

```bash
villode-caelestia-update --check
```

状态为“有更新”或“需要修复”时，直接执行：

```bash
villode-caelestia-update
```

“需要修复”表示状态记录缺失、文件不完整，或者 Shell 的真实 revision 与记录不一致。更新器会重新部署对应组件并重建可信的版本记录。更新默认只同步已安装的组件；要顺带安装“未安装”状态的可选组件，使用 `villode-caelestia-update --install-missing`。离线安装会默认离线检查；需要恢复在线渠道时可使用 `villode-caelestia-update --online`。

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

可卸载的组件为 `shell,zh,dock,desktop,launcher,cursor`。

默认卸载不会删除组件用户数据。中文化卸载也不会自动删除 `~/.config/quickshell/caelestia`，避免误删用户自行修改的 QML。
部分卸载会按剩余组件重建独立会话的自启动项。全部卸载会移除更新/卸载命令并恢复安装前的注销命令，但会保留 `migration-backups` 和 `desktop-migration.txt`，以便恢复旧桌面。

## 项目边界

- Caelestia 本体由 `u0n0u/caelestia-shell` Fork 完整保存和维护。
- 统一仓库负责编排并锁定版本，不重复复制组件源码。
- 每个组件可独立安装、更新和卸载。
- 完整安装会先安装 Launcher、最后安装并刷新 Dock，确保启动台入口立即显示。
- `Villode Hyprland` 会话使用项目自己的窗口规则、快捷键和自启动，不受旧桌面配置影响。
- 不包含本机配置、缓存、日志、密钥或个人素材。
- Caelestia Shell 的上游代码仍遵循 GPL-3.0-only。

## 许可

统一安装器以 MIT License 发布；被安装组件分别遵循各自仓库中的许可证。
