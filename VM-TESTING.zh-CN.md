# 虚拟机全新安装测试

本流程用于在 CachyOS/Arch Hyprland 虚拟机中验证“自动接管旧桌面 + Villode 全套安装”。建议先创建虚拟机快照。

## 1. 确认命令在虚拟机内执行

```bash
hostnamectl
systemd-detect-virt
echo "$XDG_CURRENT_DESKTOP"
```

`systemd-detect-virt` 应输出 `kvm`，桌面应包含 `Hyprland`。

## 2. 记录安装前环境

```bash
pacman -Qq | grep -Ei 'noctalia|waybar|hyprpanel|ags|eww|nwg|ironbar|quickshell|caelestia' || true
ps -eo pid,cmd | grep -Ei 'noctalia|waybar|hyprpanel|ags|eww|nwg|ironbar' | grep -v grep || true
```

## 3. 安装

```bash
git clone https://github.com/u0n0u/villode-caelestia.git
cd villode-caelestia
./install.sh --all
```

安装器默认会自动备份、停止并卸载检测到的冲突桌面壳。它不使用递归孤儿依赖清理，不应删除文件管理器、钥匙环、GVFS 或桌面门户。

## 4. 注销并进入独立会话

安装完成后注销当前会话，在 SDDM 会话选择器中选择 `Villode Hyprland` 再登录。
该会话必须使用 `~/.config/villode-hyprland/hyprland.conf`，不应加载 `~/.config/hypr`。

```bash
pgrep -af 'start-villode-hyprland|Hyprland.*villode-hyprland'
```

## 5. 可选：验收旧桌面清理

先在 `Villode Hyprland` 会话确认界面和输入正常，然后在终端执行：

```bash
cd ~/villode-caelestia
./install.sh --all --replace-existing
```

```bash
pacman -Qq | grep -Ei '^((cachyos-.*-)?noctalia|waybar|hyprpanel|aylurs-gtk-shell|eww|nwg-(panel|dock|dock-hyprland)|ironbar)$' || true
ps -eo pid,cmd | grep -Ei 'noctalia|waybar|hyprpanel|ags|eww|nwg|ironbar' | grep -v grep || true
cat ~/.local/state/villode-caelestia/desktop-migration.txt
```

前两条不应输出旧桌面包或进程；第三条会显示备份目录。

## 6. 验收 Villode 组件

```bash
pgrep -af 'qs -c caelestia|villode-(desktop|launcher|dock)'
```

应看到 Caelestia、Desktop、Launcher 和 Dock，且 Caelestia 只有一个 `qs -c caelestia` 实例。

## 7. 验收启动台弹窗

点击 Dock 中的启动台图标。它应该以居中、900×600 的浮动窗口出现，不应分割或挤压已有窗口。

```bash
hyprctl clients -j | jq '.[] | select(.class == "local.villode.launcher") | {class,title,floating,size,at}'
```

期望 `floating` 为 `true`，`size` 接近 `[900,600]`。

## 8. 保留旧桌面的对照测试

如果只想测试安装而不卸载原桌面，显式执行：

```bash
./install.sh --all --keep-existing
```

此模式可能产生面板和快捷键重叠，不作为全套安装的通过标准。
