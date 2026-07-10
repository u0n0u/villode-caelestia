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

## 前提

- Hyprland / Wayland
- Git
- Shell 安装器需要 `caelestia-cli`、Quickshell 以及 Caelestia 的运行依赖
- 默认自动检测并补齐依赖，安装系统包时需要 `sudo` 权限

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

## 项目边界

- Caelestia 本体由 `Villode/caelestia-shell` Fork 完整保存和维护。
- 统一仓库负责编排并锁定版本，不重复复制组件源码。
- 每个组件可独立安装、更新和卸载。
- 不包含本机配置、缓存、日志、密钥或个人素材。
- Caelestia Shell 的上游代码仍遵循 GPL-3.0-only。

## 许可

统一安装器以 MIT License 发布；被安装组件分别遵循各自仓库中的许可证。
