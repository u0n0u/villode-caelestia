#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest="$repo_dir/components.tsv"
cache_home="${XDG_CACHE_HOME:-$HOME/.cache}/villode-caelestia/sources"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}/villode-caelestia"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}/villode-caelestia"
# shellcheck source=lib/git-net.sh
if [[ -f "$repo_dir/lib/git-net.sh" ]]; then
    # shellcheck disable=SC1091
    source "$repo_dir/lib/git-net.sh"
elif [[ -f "$data_home/release/lib/git-net.sh" ]]; then
    # Channel tree may lag; prefer the already-deployed helper.
    # shellcheck disable=SC1091
    source "$data_home/release/lib/git-net.sh"
else
    echo "缺少 lib/git-net.sh，无法处理 GitHub 访问回退。" >&2
    exit 69
fi
# Keep the restart log out of the shared, predictable /tmp namespace.
install_log="$state_home/install.log"
selected=()
with_deps=true
no_start=false
no_hyprland=false
install_session=true
offline=false
no_native_build=false
skip_shell=false
reapply_zh=true
# github_source_choice: empty=decide later; auto/key=fixed; probe=run speed test
github_source_choice=""
skip_github_probe=false
# Keep the current desktop as a recovery path unless replacement is explicitly
# requested.  More importantly, replacement is deferred until every selected
# source has been fetched, validated and installed successfully.
# Empty means no explicit choice: interactive runs ask, others keep.
replace_existing=""
declare -A source_dirs component_commits component_names
stage_dir=""

acquire_operation_lock() {
    local lock_file="$state_home/operation.lock" rc
    [[ "${VILLODE_OPERATION_LOCK_HELD:-}" == 1 ]] && return 0
    command -v flock >/dev/null 2>&1 || {
        echo "缺少安装器并发保护所需的 flock。" >&2
        exit 69
    }
    install -d -m700 "$state_home"
    : > "$lock_file"
    chmod 600 "$lock_file"
    if flock --exclusive --nonblock --close --conflict-exit-code 75 \
        "$lock_file" env VILLODE_OPERATION_LOCK_HELD=1 "$0" "$@"; then
        exit 0
    else
        rc=$?
    fi
    [[ "$rc" == 75 ]] && echo "另一个 Villode 安装、更新或卸载操作正在进行。" >&2
    exit "$rc"
}

acquire_operation_lock "$@"

usage() {
    cat <<'EOF'
用法 / Usage：./install.sh [选项]

始终安装锁定的 Caelestia Shell；未指定可选组件时显示交互菜单。
Always installs the pinned Caelestia Shell; shows a menu for optional components when none are given.

适合已有桌面，也适合纯 TTY / 无桌面机器（会装 Hyprland + SDDM 等，结束后重启进 Villode Hyprland）。
Works from an existing desktop or from a bare TTY (pulls Hyprland + SDDM, then reboot into Villode Hyprland).

选项 / Options：
  --all                    安装全部组件 / install all optional components
  --components LIST        可选：zh,dock,desktop,launcher,cursor
  --with-deps              自动安装缺失系统依赖（默认）/ auto-install missing packages (default)
  --no-deps                不装系统包 / do not install system packages
  --no-start               安装后不启动组件 / deploy only, do not launch apps
  --no-hyprland            不写任何 Hyprland 集成 / no Hyprland integration at all
  --no-session             不装独立 Villode 登录会话 / no dedicated login session
  --offline                仅本地缓存 / local cache only
  --no-native-build        不构建原生插件 / skip native plugin build
  --skip-shell             不重装 Shell（更新器内部）/ skip shell redeploy (updater)
  --no-reapply-zh          刷新 Shell 时不重装中文化 / do not reapply zh on shell refresh
  --replace-existing       成功后替换旧桌面壳 / replace existing desktop shells after success
  --keep-existing          保留旧桌面壳 / keep existing desktop shells
  --github-source KEY      更新通道 / channel: auto|github.com|kkgithub.com|ghproxy.net|...
  --probe-github           测速并选择通道 / speed-test mirrors then choose
  --skip-github-probe      跳过测速 / skip mirror probe
  -h, --help               显示帮助 / show this help

TTY 示例 / TTY example：
  ./install.sh --all && sudo reboot
  # then pick "Villode Hyprland" in SDDM
EOF
}

# True when we are not inside a running Wayland/X11 graphical session
# (plain TTY, SSH without display, early boot, etc.).
is_graphical_session() {
    [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]] && return 0
    case "${XDG_SESSION_TYPE:-}" in
        wayland|x11|mir) return 0 ;;
    esac
    return 1
}

# On TTY / headless: do not try to start Shell/Dock (no compositor yet).
# Still install the login session + DM so the user can reboot into the desktop.
adapt_for_tty_install() {
    if is_graphical_session; then
        return 0
    fi
    echo
    echo "检测到当前为 TTY / 无图形会话（no Wayland/X11 display）。"
    echo "Detected TTY or non-graphical session."
    if ! $no_start; then
        no_start=true
        echo "→ 自动使用 --no-start：安装完成后不会在此启动 Shell/Dock。"
        echo "→ Auto --no-start: will not launch Shell/Dock here (no compositor)."
    fi
    if $install_session; then
        echo "→ 将安装独立 Villode Hyprland 会话与登录管理器（如 SDDM）。"
        echo "→ Will install Villode Hyprland session + display manager (e.g. SDDM)."
        echo "→ 完成后请执行：sudo reboot ，在登录界面选择 “Villode Hyprland”。"
        echo "→ When finished: sudo reboot , then select “Villode Hyprland” at the greeter."
    else
        echo "→ 已指定 --no-session：不会创建登录会话。若需要图形登录，请去掉该选项重装。"
        echo "→ --no-session set: no login session. Re-run without it for a greeter entry."
    fi
    echo
}

print_install_summary() {
    echo
    if $skip_shell; then
        echo "安装完成 / Done：${selected[*]}"
    else
        echo "安装完成 / Done：shell ${selected[*]}"
    fi
    echo "卸载 / Uninstall：villode-caelestia-uninstall"
    echo "更新 / Update：  villode-caelestia-update"
    if $install_session && ! $no_hyprland; then
        echo
        echo "登录会话 / Login session：Villode Hyprland"
        echo "  配置 / config：~/.config/villode-hyprland/hyprland.conf"
        if ! is_graphical_session; then
            echo
            echo "你当前在 TTY。请重启后进入图形会话："
            echo "You are on a TTY. Reboot into the graphical session:"
            echo "  sudo reboot"
            echo "  → SDDM / greeter → “Villode Hyprland”"
            if command -v systemctl >/dev/null 2>&1; then
                if systemctl is-enabled sddm.service >/dev/null 2>&1; then
                    echo "  SDDM：已启用 / enabled"
                else
                    echo "  提示：若无登录界面，可执行：sudo systemctl enable --now sddm"
                    echo "  Tip: if no greeter, run: sudo systemctl enable --now sddm"
                fi
            fi
        else
            echo "  注销会话后在登录管理器中选择 “Villode Hyprland”。"
            echo "  Log out and select “Villode Hyprland” in your display manager."
        fi
    fi
    if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/caelestia/shell.json" ]]; then
        echo
        echo "默认应用已按系统已装软件识别（设置里可改，重装不会覆盖你的选择）。"
        echo "Default apps detected from installed software (Settings override is kept)."
    fi
    echo
}

normalise_component() {
    case "$1" in
        shell|core|caelestia) echo shell ;;
        zh|chinese|i18n) echo zh ;;
        dock) echo dock ;;
        desktop|wallpaper) echo desktop ;;
        launcher|launchpad) echo launcher ;;
        cursor|pointer|shake) echo cursor ;;
        *) return 1 ;;
    esac
}

add_components() {
    local raw item component
    raw="$1"
    IFS=',' read -ra items <<< "$raw"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        [[ -n "$item" ]] || continue
        if ! component="$(normalise_component "$item")"; then
            echo "未知组件：$item" >&2
            exit 64
        fi
        if [[ " ${selected[*]} " != *" $component "* ]]; then
            selected+=("$component")
        fi
    done
}

while (($#)); do
    case "$1" in
        --all)
            selected=(zh dock desktop launcher cursor)
            ;;
        --components)
            [[ $# -ge 2 ]] || { echo "--components 缺少参数" >&2; exit 64; }
            add_components "$2"
            shift
            ;;
        --components=*)
            add_components "${1#*=}"
            ;;
        --with-deps)
            with_deps=true
            ;;
        --no-deps)
            with_deps=false
            ;;
        --no-start)
            no_start=true
            ;;
        --no-hyprland)
            no_hyprland=true
            ;;
        --no-session)
            install_session=false
            ;;
        --offline)
            offline=true
            ;;
        --no-native-build)
            no_native_build=true
            ;;
        --skip-shell)
            skip_shell=true
            ;;
        --no-reapply-zh)
            reapply_zh=false
            ;;
        --replace-existing)
            replace_existing=yes
            ;;
        --keep-existing)
            replace_existing=no
            ;;
        --github-source)
            [[ $# -ge 2 ]] || { echo "--github-source 缺少参数" >&2; exit 64; }
            github_source_choice="$2"
            shift
            ;;
        --github-source=*)
            github_source_choice="${1#*=}"
            ;;
        --probe-github)
            github_source_choice=probe
            ;;
        --skip-github-probe)
            skip_github_probe=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知选项：$1" >&2
            usage >&2
            exit 64
            ;;
    esac
    shift
done

# No explicit --replace-existing/--keep-existing: ask in interactive runs so
# the detected-shell prompt can actually fire; keep silently everywhere else.
if [[ -z "$replace_existing" ]]; then
    if [[ -t 0 ]]; then
        replace_existing=ask
    else
        replace_existing=no
    fi
fi

if ((${#selected[@]} == 0)); then
    if [[ ! -t 0 ]]; then
        echo "非交互环境中请使用 --all 或 --components。" >&2
        echo "Non-interactive: pass --all or --components." >&2
        exit 64
    fi
    cat <<'EOF'
选择要安装的组件 / Choose optional components：
  1. Caelestia 简体中文 / Simplified Chinese
  2. Villode Dock
  3. Villode Desktop
  4. Villode Launcher
  5. Villode 指针放大 / cursor shake-to-find
  a. 全部 / all
EOF
    read -r -p "输入编号（逗号分隔，默认 a）/ numbers (default a): " answer
    answer="${answer:-a}"
    if [[ "$answer" == "a" || "$answer" == "A" ]]; then
        selected=(zh dock desktop launcher cursor)
    else
        answer="${answer//1/zh}"
        answer="${answer//2/dock}"
        answer="${answer//3/desktop}"
        answer="${answer//4/launcher}"
        answer="${answer//5/cursor}"
        add_components "$answer"
    fi
fi

if $offline && $with_deps; then
    echo "离线模式不会安装系统依赖；按 --no-deps 继续。"
    with_deps=false
fi

# TTY / no display: skip live start, guide user to reboot into SDDM.
adapt_for_tty_install

# Resolve GitHub access channel (speed test + user choice). Offline skips probe
# but still records an explicit --github-source for later online updates.
configure_github_source() {
    local saved_source saved_mirrors saved_prefer
    if $offline; then
        if [[ -n "$github_source_choice" &&
              "$github_source_choice" != probe &&
              "$github_source_choice" != auto &&
              "$github_source_choice" != offline ]]; then
            villode_apply_github_source "$github_source_choice"
        else
            villode_apply_github_source "${VILLODE_GITHUB_SOURCE:-auto}"
        fi
        return 0
    fi
    if $skip_github_probe && [[ -z "$github_source_choice" || "$github_source_choice" == auto ]]; then
        saved_source="$(awk -F= '$1=="github_source"{print substr($0,index($0,"=")+1);exit}' \
            "$state_home/install-options" 2>/dev/null || true)"
        saved_mirrors="$(awk -F= '$1=="github_mirrors"{print substr($0,index($0,"=")+1);exit}' \
            "$state_home/install-options" 2>/dev/null || true)"
        saved_prefer="$(awk -F= '$1=="github_prefer_direct"{print substr($0,index($0,"=")+1);exit}' \
            "$state_home/install-options" 2>/dev/null || true)"
        if [[ -n "$saved_source" ]]; then
            [[ -n "$saved_mirrors" ]] && export VILLODE_GITHUB_MIRRORS="$saved_mirrors"
            [[ -n "$saved_prefer" ]] && export VILLODE_PREFER_GITHUB_DIRECT="$saved_prefer"
            villode_apply_github_source "$saved_source"
            echo "沿用已保存的更新通道：$(villode_source_label "$saved_source")"
            return 0
        fi
        export VILLODE_SKIP_PROBE=1
        villode_select_github_source
        return 0
    fi
    if [[ -n "$github_source_choice" &&
          "$github_source_choice" != probe &&
          "$github_source_choice" != auto ]]; then
        export VILLODE_GITHUB_SOURCE_FORCE="$github_source_choice"
        villode_select_github_source
        return 0
    fi
    # probe / auto / default:
    # - interactive + default → probe then menu
    # - auto or non-interactive → probe then auto-pick fastest
    if [[ "$github_source_choice" == auto || ( -z "$github_source_choice" && ! -t 0 ) ]]; then
        export VILLODE_GITHUB_SOURCE_FORCE=auto
    else
        unset VILLODE_GITHUB_SOURCE_FORCE 2>/dev/null || true
    fi
    unset VILLODE_SKIP_PROBE 2>/dev/null || true
    villode_select_github_source
}
configure_github_source

# --no-hyprland is an absolute promise not to create either integration files
# in the user's session or a separate Hyprland session.
if $no_hyprland; then
    install_session=false
fi

if $reapply_zh && ! $skip_shell &&
   { [[ -f "$state_home/zh.tsv" ]] ||
     [[ -x "$HOME/.local/bin/caelestia-zh-apply" &&
        -f "${XDG_DATA_HOME:-$HOME/.local/share}/caelestia-zh-cn/i18n/qml_zh_CN.qm" ]]; } &&
   [[ " ${selected[*]} " != *" zh "* ]]; then
    echo "检测到现有中文翻译包，将在刷新 Shell 后自动重新安装。"
    selected+=(zh)
fi

ensure_fetch_tools() {
    command -v install >/dev/null 2>&1 || {
        echo "缺少依赖：install" >&2
        exit 69
    }
    command -v git >/dev/null 2>&1 && return
    if $offline || ! $with_deps; then
        echo "缺少依赖：git" >&2
        exit 69
    fi
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm git
    elif command -v apt >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y git
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y git
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y git
    fi
    command -v git >/dev/null 2>&1 || {
        echo "无法安装安装器必需的 git。" >&2
        exit 69
    }
}

bootstrap_build_tools() {
    local bootstrap_dir

    if $skip_shell || ! $with_deps || $offline; then
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
            sudo pacman -S --needed --noconfirm base-devel git
        fi
        if ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; then
            echo "未检测到 yay 或 paru，正在安装 yay-bin……"
            bootstrap_dir="$(mktemp -d)"
            git clone --depth=1 https://aur.archlinux.org/yay-bin.git "$bootstrap_dir/yay-bin"
            (
                cd "$bootstrap_dir/yay-bin"
                makepkg -si --needed --noconfirm
            )
            rm -rf "$bootstrap_dir"
        fi
    fi
}

# Install packages from official repos when available; skip unknown names.
pacman_install_available() {
    local pkg available=()
    (($#)) || return 0
    command -v pacman >/dev/null 2>&1 || return 1
    for pkg in "$@"; do
        if pacman -Si "$pkg" >/dev/null 2>&1 || pacman -Q "$pkg" >/dev/null 2>&1; then
            available+=("$pkg")
        else
            echo "跳过不可用软件包：$pkg"
        fi
    done
    ((${#available[@]})) || return 0
    sudo pacman -S --needed --noconfirm "${available[@]}"
}

# AUR helper install (yay/paru). Best-effort; never hard-fail the whole install.
aur_install_available() {
    local helper pkg
    (($#)) || return 0
    if command -v yay >/dev/null 2>&1; then
        helper=yay
    elif command -v paru >/dev/null 2>&1; then
        helper=paru
    else
        echo "未找到 yay/paru，跳过 AUR 包：$*"
        return 0
    fi
    for pkg in "$@"; do
        if pacman -Q "$pkg" >/dev/null 2>&1; then
            continue
        fi
        echo "通过 $helper 安装：$pkg"
        "$helper" -S --needed --noconfirm "$pkg" || \
            echo "警告：安装 $pkg 失败，可稍后手动安装。" >&2
    done
}

install_session_dependencies() {
    # --skip-shell is used by the updater for an already installed suite.
    # Session prerequisites were handled by the original full installation;
    # a Dock/Launcher/Desktop/translation-only update must not prompt for sudo.
    $skip_shell && return 0
    $install_session || return 0
    $with_deps || return 0
    $offline && return
    if command -v pacman >/dev/null 2>&1; then
        # Compositor + portals + audio + network + session manager.
        # GTK4 stack is required by Dock/Desktop (user-reported hard dependency).
        pacman_install_available \
            hyprland xdg-desktop-portal xdg-desktop-portal-hyprland \
            xdg-desktop-portal-gtk polkit-gnome pipewire wireplumber \
            networkmanager uwsm \
            gtk3 gtk4 gtk4-layer-shell gtk-layer-shell \
            libadwaita adwaita-icon-theme hicolor-icon-theme papirus-icon-theme \
            qt6-base qt6-declarative qt6-svg qt6-wayland \
            python python-gobject python-cairo \
            sddm
        # Daily apps: terminal, file manager, media, images, browser.
        # Prefer repo packages; Chrome may need AUR.
        pacman_install_available \
            alacritty thunar mpv imv loupe \
            xdg-utils shared-mime-info
        # Browser: try google-chrome via AUR if missing; else firefox.
        if ! command -v google-chrome-stable >/dev/null 2>&1 && \
           ! command -v google-chrome >/dev/null 2>&1 && \
           ! command -v chromium >/dev/null 2>&1; then
            if pacman -Si firefox >/dev/null 2>&1; then
                pacman_install_available firefox
            fi
            aur_install_available google-chrome
        fi
        # Enable display manager when we installed/have sddm and none is active.
        ensure_display_manager
    fi
}

ensure_display_manager() {
    local unit
    $offline && return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    # Already have an enabled DM?
    for unit in sddm.service gdm.service lightdm.service ly.service greetd.service; do
        if systemctl is-enabled "$unit" >/dev/null 2>&1; then
            echo "登录管理器已启用：$unit"
            return 0
        fi
    done
    if systemctl list-unit-files sddm.service >/dev/null 2>&1 || \
       pacman -Q sddm >/dev/null 2>&1; then
        echo "正在启用 SDDM 登录管理器……"
        sudo systemctl enable sddm.service 2>/dev/null || true
        # Do not start now if already in a graphical session (would disrupt user).
        if [[ "${XDG_SESSION_TYPE:-}" != wayland && "${XDG_SESSION_TYPE:-}" != x11 ]]; then
            sudo systemctl start sddm.service 2>/dev/null || true
        fi
    fi
}

install_language_dependencies() {
    # Always ensure python/flock for zh; also set up Chinese IME for the suite.
    if ! command -v python3 >/dev/null 2>&1 || ! command -v flock >/dev/null 2>&1; then
        if ! $with_deps || $offline; then
            if [[ " ${selected[*]} " == *" zh "* ]]; then
                echo "中文组件需要 python3 和 flock；请先安装，或使用 --with-deps。" >&2
                return 69
            fi
        else
            if command -v pacman >/dev/null 2>&1; then
                sudo pacman -S --needed --noconfirm python util-linux
            elif command -v apt >/dev/null 2>&1; then
                sudo apt update
                sudo apt install -y python3 util-linux
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y python3 util-linux
            elif command -v zypper >/dev/null 2>&1; then
                sudo zypper install -y python3 util-linux
            fi
        fi
    fi
    if [[ " ${selected[*]} " == *" zh "* ]] || $install_session; then
        if $with_deps && ! $offline && command -v pacman >/dev/null 2>&1; then
            # Chinese input method stack (Wayland-friendly).
            pacman_install_available \
                fcitx5 fcitx5-chinese-addons fcitx5-gtk fcitx5-qt \
                fcitx5-configtool fcitx5-material-color \
                noto-fonts-cjk wqy-zenhei wqy-microhei
            configure_chinese_input
        fi
    fi
    if [[ " ${selected[*]} " == *" zh "* ]]; then
        command -v python3 >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
            echo "无法安装中文组件所需的 python3 和 flock。" >&2
            return 69
        }
    fi
}

configure_chinese_input() {
    local env_dir conf profile_dir uwsm_dir
    env_dir="$HOME/.config/environment.d"
    conf="$env_dir/90-villode-fcitx5.conf"
    mkdir -p "$env_dir"
    # On Wayland, do NOT set GTK_IM_MODULE — let GTK use the Wayland IM protocol
    # (text-input-v3) via fcitx5. See: https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland
    cat > "$conf" <<'EOF'
# Managed by Villode Caelestia — Chinese input (fcitx5)
# GTK_IM_MODULE intentionally unset on Wayland (use text-input-v3 frontend)
QT_IM_MODULE=fcitx
QT_IM_MODULES=wayland;fcitx;ibus
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
EOF
    # UWSM prepare-env sources these; `unset` clears a stale GTK_IM_MODULE left in
    # the long-lived user@ manager after a previous session that set it.
    uwsm_dir="$HOME/.config/uwsm"
    mkdir -p "$uwsm_dir"
    cat > "$uwsm_dir/env" <<'EOF'
# Managed by Villode — Fcitx5 on Wayland
# See: https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland
unset GTK_IM_MODULE
EOF
    cat > "$uwsm_dir/env-hyprland" <<'EOF'
# Managed by Villode — Fcitx5 on Wayland (Hyprland)
unset GTK_IM_MODULE
EOF
    # Minimal fcitx5 profile so pinyin is available out of the box.
    profile_dir="$HOME/.config/fcitx5"
    mkdir -p "$profile_dir/conf"
    if [[ ! -f "$profile_dir/profile" ]]; then
        cat > "$profile_dir/profile" <<'EOF'
[Groups/0]
# Group Name
Name=Default
# Layout
Default Layout=us
# Default Input Method
DefaultIM=pinyin

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=pinyin
# Layout
Layout=

[GroupOrder]
0=Default
EOF
    fi
    # Ensure pinyin addon config exists
    if [[ ! -f "$profile_dir/conf/pinyin.conf" ]]; then
        cat > "$profile_dir/conf/pinyin.conf" <<'EOF'
# Managed by Villode — defaults for fcitx5-chinese-addons pinyin
EOF
    fi
    echo "已配置中文输入法环境（fcitx5）；注销重新登录后生效。"
}

validate_session_terminal() {
    local terminal
    $install_session || return 0
    for terminal in alacritty kitty foot wezterm gnome-terminal konsole xfce4-terminal xterm; do
        command -v "$terminal" >/dev/null 2>&1 && return
    done
    echo "独立会话需要终端（推荐 Alacritty）；请安装后重试，或使用 --with-deps。" >&2
    return 69
}

detect_existing_shells() {
    detected_shell_packages=()
    detected_shell_paths=()
    local package_name path

    if command -v pacman >/dev/null 2>&1; then
        for package_name in \
            cachyos-hypr-noctalia cachyos-niri-noctalia \
            noctalia noctalia-shell noctalia-qs \
            waybar hyprpanel aylurs-gtk-shell eww \
            nwg-panel nwg-dock nwg-dock-hyprland ironbar; do
            if pacman -Q "$package_name" >/dev/null 2>&1; then
                detected_shell_packages+=("$package_name")
            fi
        done
    fi

    for path in \
        "$HOME/.config/noctalia" \
        "$HOME/.config/quickshell/noctalia" \
        "$HOME/.config/quickshell/noctalia-shell" \
        "$HOME/.config/waybar" \
        "$HOME/.config/ags" \
        "$HOME/.config/hyprpanel" \
        "$HOME/.config/eww" \
        "$HOME/.config/nwg-panel" \
        "$HOME/.config/nwg-dock-hyprland" \
        "$HOME/.config/ironbar"; do
        if [[ -e "$path" ]]; then
            detected_shell_paths+=("$path")
        fi
    done
    return 0
}

replace_existing_shells() {
    local backup_dir backup_target package_name path config_file
    local -a removable_packages=()
    detect_existing_shells
    if ((${#detected_shell_packages[@]} == 0 && ${#detected_shell_paths[@]} == 0)); then
        echo "未检测到冲突的桌面壳。"
        return
    fi

    echo "检测到现有桌面壳："
    ((${#detected_shell_packages[@]})) && printf '  软件包：%s\n' "${detected_shell_packages[*]}"
    ((${#detected_shell_paths[@]})) && printf '  配置：%s\n' "${detected_shell_paths[*]}"

    if [[ "$replace_existing" == ask ]]; then
        if [[ ! -t 0 ]]; then
            echo "非交互环境请使用 --replace-existing 或 --keep-existing。" >&2
            exit 64
        fi
        read -r -p "是否备份并替换为 Villode Caelestia？[y/N] " answer
        case "$answer" in
            y|Y|yes|YES) replace_existing=yes ;;
            *) replace_existing=no ;;
        esac
    fi

    if [[ "$replace_existing" == no ]]; then
        echo "保留现有桌面壳；同时运行多个 Shell 可能出现面板、通知和快捷键冲突。"
        return
    fi

    backup_dir="$state_home/migration-backups/$(date +%Y%m%d-%H%M%S-%N)"
    mkdir -p "$backup_dir/home/.config"
    if [[ -d "$HOME/.config/hypr" ]]; then
        cp -a "$HOME/.config/hypr" "$backup_dir/home/.config/hypr"
    fi
    for path in "${detected_shell_paths[@]}"; do
        backup_target="$backup_dir/home/${path#"$HOME"/}"
        mkdir -p "$(dirname "$backup_target")"
        cp -a "$path" "$backup_target"
    done

    # Package-manager operations happen while the original configuration is
    # still present. pacman itself is transactional; if it fails, set -e stops
    # here and the user's desktop files have not been removed.
    if command -v pacman >/dev/null 2>&1; then
        for package_name in \
            cachyos-hypr-noctalia cachyos-niri-noctalia \
            noctalia noctalia-shell \
            waybar hyprpanel aylurs-gtk-shell eww \
            nwg-panel nwg-dock nwg-dock-hyprland ironbar; do
            pacman -Q "$package_name" >/dev/null 2>&1 && removable_packages+=("$package_name")
        done
        if ((${#removable_packages[@]})); then
            # Only remove the conflicting shells themselves. Recursive orphan
            # removal can delete shared portals, keyrings or file managers.
            sudo pacman -R --noconfirm "${removable_packages[@]}"
        fi
        if pacman -Q noctalia-qs >/dev/null 2>&1; then
            # This package provides Quickshell and is not itself a running
            # desktop shell. Keeping the provider avoids a remove-then-download
            # gap that could leave the user without Quickshell when offline.
            echo "保留 Quickshell 提供者 noctalia-qs。"
        fi
    fi

    if [[ -d "$HOME/.config/hypr" ]]; then
        # noctCall covers Noctalia IPC helper variables ($noctCall) seen in
        # preset configs; lines that never occur simply do not match.
        while IFS= read -r -d '' config_file; do
            sed -i -E '/noctalia|noctCall|waybar|hyprpanel|nwg-(panel|dock)|ironbar|(^|[[:space:]])ags([[:space:]]|$)|(^|[[:space:]])eww([[:space:]]|$)/Id' "$config_file"
        done < <(find "$HOME/.config/hypr" -type f \
            \( -name '*.conf' -o -name '*.lua' \) -print0)
    fi

    for path in "${detected_shell_paths[@]}"; do
        rm -rf "$path"
    done

    qs -c noctalia-shell kill >/dev/null 2>&1 || true
    qs -c noctalia kill >/dev/null 2>&1 || true
    pkill -x noctalia >/dev/null 2>&1 || true
    pkill -x waybar >/dev/null 2>&1 || true
    pkill -x hyprpanel >/dev/null 2>&1 || true
    pkill -x nwg-panel >/dev/null 2>&1 || true
    pkill -x nwg-dock >/dev/null 2>&1 || true
    pkill -x nwg-dock-hyprland >/dev/null 2>&1 || true
    pkill -x ironbar >/dev/null 2>&1 || true

    printf 'Desktop shell migration completed at %s\nBackup: %s\n' \
        "$(date --iso-8601=seconds)" "$backup_dir" > "$state_home/desktop-migration.txt"
    echo "旧桌面配置已备份到：$backup_dir"
}

manifest_row() {
    awk -F '\t' -v id="$1" '$1 == id { print; found=1; exit } END { if (!found) exit 1 }' "$manifest"
}

fetch_component() {
    local id="$1" repo="$2" commit="$3" source_dir="$cache_home/$id" fetch_dir
    if [[ -d "$source_dir/.git" ]] &&
       [[ "$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)" == "$commit" ]]; then
        printf '%s\n' "$source_dir"
        return
    fi
    if $offline; then
        echo "离线缓存缺少组件或版本不匹配：$id" >&2
        return 69
    fi
    mkdir -p "$cache_home"
    fetch_dir="$(mktemp -d "$cache_home/.fetch-$id.XXXXXX")"
    if ! git -C "$fetch_dir" init -q; then
        rm -rf "$fetch_dir"
        echo "无法初始化组件缓存：$id" >&2
        return 69
    fi
    villode_git_env
    if ! villode_git_fetch_ref "$fetch_dir" "$repo" "$commit" ||
       ! git -C "$fetch_dir" checkout -q --detach FETCH_HEAD; then
        rm -rf "$fetch_dir"
        echo "无法获取锁定版本：$id ${commit:0:12}（GitHub/镜像均失败或超时）" >&2
        return 69
    fi
    rm -rf "$source_dir"
    mv "$fetch_dir" "$source_dir"
    printf '%s\n' "$source_dir"
}

validate_component_source() {
    local id="$1" source_dir="${source_dirs[$1]}" required required_path
    case "$id" in
        shell)
            required=(install-villode.sh uninstall-villode.sh shell.qml UPSTREAM_VERSION assets components i18n modules services utils)
            ;;
        zh)
            required=(install.sh uninstall.sh bin/caelestia-zh-apply i18n/qml_zh_CN.qm i18n/qml_zh_CN.ts i18n/zh_CN.json)
            ;;
        cursor)
            # Source is caelestia-shell (same repo pin as shell)
            required=(contrib/villode-cursor/install.sh contrib/villode-cursor/villode-cursor-shake)
            ;;
        dock|desktop|launcher)
            required=(install.sh uninstall.sh)
            ;;
    esac
    for required_path in "${required[@]}"; do
        [[ -e "$source_dir/$required_path" ]] || {
            echo "组件源码不完整：$id 缺少 $required_path" >&2
            return 66
        }
    done
    case "$id" in
        shell) bash -n "$source_dir/install-villode.sh" "$source_dir/uninstall-villode.sh" ;;
        cursor)
            bash -n "$source_dir/contrib/villode-cursor/install.sh" \
                "$source_dir/contrib/villode-cursor/uninstall.sh"
            ;;
        *) bash -n "$source_dir/install.sh" "$source_dir/uninstall.sh" ;;
    esac
}

prefetch_component() {
    local id="$1" row repo commit name source_dir
    row="$(manifest_row "$id")"
    IFS=$'\t' read -r _ repo commit name <<< "$row"
    source_dir="$(fetch_component "$id" "$repo" "$commit")"
    source_dirs["$id"]="$source_dir"
    component_commits["$id"]="$commit"
    component_names["$id"]="$name"
    validate_component_source "$id"
}

preflight_zh_compatibility() {
    local zh_source="${source_dirs[zh]}" shell_source
    local checker="$zh_source/bin/caelestia-zh-apply"

    if [[ -n "${source_dirs[shell]:-}" ]]; then
        shell_source="${source_dirs[shell]}"
    else
        shell_source="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/caelestia"
    fi
    [[ -f "$shell_source/shell.qml" ]] || {
        echo "无法验证中文组件：没有可用的 Caelestia Shell 源码。" >&2
        return 66
    }

    CAELESTIA_TRANSLATION_FILE="$zh_source/i18n/qml_zh_CN.qm" \
        "$checker" --check --source "$shell_source"
}

prepare_sources() {
    local id
    ensure_fetch_tools
    mkdir -p "$cache_home" "$state_home" "$data_home"

    if ! $skip_shell; then
        prefetch_component shell
    fi
    for id in zh desktop launcher dock cursor; do
        if [[ " ${selected[*]} " == *" $id "* ]]; then
            prefetch_component "$id"
        fi
    done
    if [[ -n "${source_dirs[zh]:-}" ]]; then
        preflight_zh_compatibility
    fi
    echo "全部锁定源码已获取并通过安装前检查。"
}

stage_component_state() {
    local id="$1" uninstall_source="$2" component_dir="$stage_dir/$id"
    mkdir -p "$component_dir"
    install -m755 "$uninstall_source" "$component_dir/uninstall.sh"
    printf '%s\n' "${component_commits[$id]}" > "$component_dir/revision"
    printf '%s\t%s\t%s\n' \
        "$id" "${component_commits[$id]}" "${component_names[$id]}" > "$stage_dir/$id.tsv"
}

install_component() {
    local id="$1" source_dir="${source_dirs[$1]}" uninstall_source
    echo
    echo "==> 安装 ${component_names[$id]}"

    case "$id" in
        shell)
            shell_args=(--no-restart)
            $with_deps && shell_args+=(--with-deps)
            $no_native_build && shell_args+=(--no-native-build)
            "$source_dir/install-villode.sh" "${shell_args[@]}"
            uninstall_source="$source_dir/uninstall-villode.sh"
            ;;
        zh)
            "$source_dir/install.sh" --no-apply
            "$HOME/.local/bin/caelestia-zh-apply" --no-restart
            uninstall_source="$source_dir/uninstall.sh"
            ;;
        cursor)
            cursor_args=()
            $no_start && cursor_args+=(--no-start)
            $no_hyprland && cursor_args+=(--no-hyprland)
            bash "$source_dir/contrib/villode-cursor/install.sh" "${cursor_args[@]}"
            uninstall_source="$source_dir/contrib/villode-cursor/uninstall.sh"
            ;;
        dock|desktop|launcher)
            component_args=()
            $with_deps && component_args+=(--with-deps)
            $no_start && component_args+=(--no-start)
            if $no_hyprland || $install_session; then
                component_args+=(--no-hyprland)
            fi
            "$source_dir/install.sh" "${component_args[@]}"
            uninstall_source="$source_dir/uninstall.sh"
            ;;
    esac
    stage_component_state "$id" "$uninstall_source"
}

configure_hyprland_lua_autostart() {
    local hypr_dir="$HOME/.config/hypr"
    local lua_main="$hypr_dir/hyprland.lua"
    local lua_module="$hypr_dir/config/villode-suite.lua"

    $no_hyprland && return
    $install_session && return
    [[ -f "$lua_main" ]] || return 0

    mkdir -p "$(dirname "$lua_module")"
    {
        cat <<'EOF'
-- Managed by Villode Caelestia. Hyprland 0.55+ ignores legacy exec-once
-- entries when the active configuration is hyprland.lua.
hl.on("hyprland.start", function()
EOF
        component_available shell && \
            echo '    hl.exec_cmd("villode-caelestia-shell-guard --daemon")'
        component_available desktop && \
            echo '    hl.exec_cmd("villode-desktop --daemon")'
        component_available dock && \
            echo '    hl.exec_cmd("villode-dock --daemon")'
        # Launcher owns its Lua window rules and autostart in its component
        # module, so it is deliberately not started twice here.
        echo 'end)'
    } > "$lua_module"

    if ! grep -Fq 'require("config.villode-suite")' "$lua_main"; then
        printf '\n-- Villode desktop suite\nrequire("config.villode-suite")\n' >> "$lua_main"
    fi
}

component_available() {
    [[ -f "$stage_dir/$1.tsv" || -f "$state_home/$1.tsv" ]]
}

any_session_component_available() {
    local id
    for id in shell desktop launcher dock; do
        component_available "$id" && return 0
    done
    return 1
}

render_session_config() {
    local target="$1" tmp
    local have_shell=0 have_desktop=0 have_launcher=0 have_dock=0
    component_available shell && have_shell=1
    component_available desktop && have_desktop=1
    component_available launcher && have_launcher=1
    component_available dock && have_dock=1
    tmp="$(mktemp "${target}.XXXXXX")"
    awk \
        -v shell="$have_shell" \
        -v desktop="$have_desktop" \
        -v launcher="$have_launcher" \
        -v dock="$have_dock" '
        /exec-once = villode-caelestia-shell-guard/ && !shell { next }
        /exec-once = caelestia shell -d/ && !shell { next }
        /exec-once = villode-desktop --daemon/ && !desktop { next }
        /exec-once = villode-launcher --daemon/ && !launcher { next }
        /exec-once = villode-dock --daemon/ && !dock { next }
        { print }
    ' "$repo_dir/session/villode-hyprland.conf" > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$target"
}

set_session_logout() {
    local config="$HOME/.config/caelestia/shell.json"
    local backup="$state_home/logout-backup.json"
    local legacy_managed="${1:-no}"
    command -v python3 >/dev/null 2>&1 || {
        echo "缺少 python3，无法安全设置独立会话注销命令。" >&2
        return 69
    }
    python3 - "$config" "$backup" "$legacy_managed" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
backup = Path(sys.argv[2])
legacy_managed = sys.argv[3] == "yes"
try:
    data = json.loads(path.read_text()) if path.exists() else {}
except (OSError, json.JSONDecodeError) as error:
    print(f"无法读取 {path}，未覆盖注销命令：{error}", file=sys.stderr)
    raise SystemExit(0)
if not isinstance(data, dict):
    print(f"{path} 顶层不是 JSON 对象，未覆盖注销命令。", file=sys.stderr)
    raise SystemExit(0)
session = data.get("session")
if not isinstance(session, dict):
    session = {}
    data["session"] = session
commands = session.get("commands", {})
if not isinstance(commands, dict):
    commands = {}
    session["commands"] = commands
if not backup.exists():
    backup.parent.mkdir(parents=True, exist_ok=True)
    # Treat previous Villode-managed values as not user-owned.
    managed = {
        ("uwsm", "stop"),
        ("villode-logout",),
    }
    current = commands.get("logout")
    if legacy_managed and (
        (isinstance(current, list) and tuple(current) in managed)
        or current in (["uwsm", "stop"], ["villode-logout"])
    ):
        # Older Villode installers wrote this value without preserving the
        # prior setting. Removing it on uninstall restores Caelestia's default.
        saved = {"present": False, "value": None}
    else:
        saved = {"present": "logout" in commands, "value": commands.get("logout")}
    temp = backup.with_name(backup.name + f".tmp-{os.getpid()}")
    temp.write_text(json.dumps(saved, ensure_ascii=False) + "\n")
    temp.replace(backup)
# villode-logout stops the shell guard then runs `uwsm stop` so SDDM returns.
commands["logout"] = ["villode-logout"]
path.parent.mkdir(parents=True, exist_ok=True)
temp = path.with_name(path.name + f".tmp-{os.getpid()}")
temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
temp.replace(path)
PY
}

# Detect system apps and write Caelestia defaults only when missing/broken.
# User-chosen values in shell.json are never overwritten.
configure_default_apps() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - <<'PY'
import json
import os
import shutil
from pathlib import Path

path = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "caelestia" / "shell.json"
try:
    data = json.loads(path.read_text()) if path.exists() else {}
except (OSError, json.JSONDecodeError):
    data = {}
if not isinstance(data, dict):
    data = {}

def first_cmd(names):
    for name in names:
        if shutil.which(name):
            return [name]
    return None

def is_broken(value, wrappers=(), key=""):
    if value in (None, [], ""):
        return True
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list) or not value:
        return True
    head = value[0]
    # Missing binary or known-bad defaults / wrappers used as "apps"
    if head in wrappers:
        return True
    if head in ("foot", "thunar") and not shutil.which(head):
        return True
    # Temporary xdg-open home fallback is replaced when a real FM appears.
    if key == "explorer" and head == "xdg-open":
        return True
    if not shutil.which(head) and head not in ("xdg-open",):
        return True
    return False

general = data.setdefault("general", {})
if not isinstance(general, dict):
    general = {}
    data["general"] = general
apps = general.setdefault("apps", {})
if not isinstance(apps, dict):
    apps = {}
    general["apps"] = apps

# Prefer real system binaries. Order = preference when multiple exist.
candidates = {
    "terminal": (
        "alacritty", "kitty", "foot", "wezterm", "gnome-terminal",
        "konsole", "xfce4-terminal", "xterm",
    ),
    "explorer": (
        "nautilus", "dolphin", "thunar", "nemo", "pcmanfm", "caja", "cosmic-files",
    ),
    "browser": (
        "google-chrome-stable", "google-chrome", "chromium",
        "brave", "brave-browser", "microsoft-edge-stable",
        "firefox", "firefox-developer-edition",
    ),
    "playback": (
        "mpv", "vlc", "celluloid", "totem",
    ),
    "audio": (
        "pavucontrol", "pavucontrol-qt", "qpwgraph", "helvum",
    ),
}
wrappers = {
    "terminal": ("villode-terminal",),
    "explorer": ("villode-explorer",),
    "browser": (),
    "playback": (),
    "audio": (),
}

chosen = {}
for key, names in candidates.items():
    cur = apps.get(key)
    if not is_broken(cur, wrappers.get(key, ()), key=key):
        chosen[key] = cur if isinstance(cur, list) else [cur]
        continue
    found = first_cmd(names)
    if found:
        apps[key] = found
        chosen[key] = found
    elif key == "explorer" and shutil.which("xdg-open"):
        apps[key] = ["xdg-open", str(Path.home())]
        chosen[key] = apps[key]

path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_name(path.name + f".tmp-{os.getpid()}")
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
tmp.replace(path)

# mimeapps.list — only fill missing associations
mime = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "mimeapps.list"
desktop_map = {
    "alacritty": "Alacritty.desktop",
    "kitty": "kitty.desktop",
    "foot": "foot.desktop",
    "nautilus": "org.gnome.Nautilus.desktop",
    "dolphin": "org.kde.dolphin.desktop",
    "thunar": "thunar.desktop",
    "nemo": "nemo.desktop",
    "pcmanfm": "pcmanfm.desktop",
    "google-chrome-stable": "google-chrome.desktop",
    "google-chrome": "google-chrome.desktop",
    "chromium": "chromium.desktop",
    "firefox": "firefox.desktop",
    "mpv": "mpv.desktop",
    "vlc": "vlc.desktop",
    "imv": "imv.desktop",
    "loupe": "org.gnome.Loupe.desktop",
    "eog": "org.gnome.eog.desktop",
    "gwenview": "org.kde.gwenview.desktop",
}

def desk(cmd_list):
    if not cmd_list:
        return None
    return desktop_map.get(cmd_list[0])

# Image viewer is not a Caelestia apps key; still set mime defaults.
image_cmd = first_cmd(("imv", "loupe", "eog", "gwenview", "feh", "sxiv"))
associations = {
    "inode/directory": desk(chosen.get("explorer")),
    "text/html": desk(chosen.get("browser")),
    "x-scheme-handler/http": desk(chosen.get("browser")),
    "x-scheme-handler/https": desk(chosen.get("browser")),
    "video/mp4": desk(chosen.get("playback")),
    "video/x-matroska": desk(chosen.get("playback")),
    "audio/mpeg": desk(chosen.get("playback")),
    "image/png": desk(image_cmd) if image_cmd else None,
    "image/jpeg": desk(image_cmd) if image_cmd else None,
    "image/webp": desk(image_cmd) if image_cmd else None,
    "image/gif": desk(image_cmd) if image_cmd else None,
}
associations = {k: v for k, v in associations.items() if v}

existing = {}
section = None
if mime.exists():
    for line in mime.read_text().splitlines():
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            existing.setdefault(section, {})
            continue
        if section and "=" in line and not line.strip().startswith("#"):
            k, _, v = line.partition("=")
            existing.setdefault(section, {})[k.strip()] = v.strip()

default = existing.setdefault("Default Applications", {})
added = existing.setdefault("Added Associations", {})
changed = False
for mime_type, desktop in associations.items():
    if mime_type not in default:
        default[mime_type] = desktop
        changed = True
    if mime_type not in added:
        added[mime_type] = desktop + ";"
        changed = True

if changed or not mime.exists():
    mime.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for section_name in ("Default Applications", "Added Associations"):
        lines.append(f"[{section_name}]")
        for k, v in sorted(existing.get(section_name, {}).items()):
            lines.append(f"{k}={v}")
        lines.append("")
    mime.write_text("\n".join(lines))

print("默认应用：")
for key in ("terminal", "explorer", "browser", "playback", "audio"):
    val = apps.get(key)
    if val:
        print(f"  {key}: {' '.join(val) if isinstance(val, list) else val}")
if image_cmd:
    print(f"  image: {' '.join(image_cmd)}")
PY
}

install_villode_session() {
    local session_config="$HOME/.config/villode-hyprland/hyprland.conf" legacy_managed=no
    # A component-only updater run does not change the installed component
    # set, so the existing independent session needs neither root writes nor
    # logout-command changes.
    $skip_shell && return 0
    $install_session || return 0
    any_session_component_available || return 0

    if [[ -f "$session_config" && ! -f "$state_home/session-managed" ]]; then
        legacy_managed=yes
    fi
    mkdir -p "$(dirname "$session_config")"
    render_session_config "$session_config"
    sudo install -Dm755 "$repo_dir/session/start-villode-hyprland" \
        /usr/local/bin/start-villode-hyprland
    sudo install -Dm755 "$repo_dir/session/villode-hyprland-compositor" \
        /usr/local/bin/villode-hyprland-compositor
    sudo install -Dm644 "$repo_dir/session/villode-hyprland.desktop" \
        /usr/local/share/wayland-sessions/villode-hyprland.desktop

    # Remove integration written by older releases. The dedicated session must
    # not depend on, or modify, the user's original Hyprland/Noctalia session.
    rm -f "$HOME/.config/hypr/config/villode-suite.lua" \
        "$HOME/.config/hypr/config/villode-launcher.lua"
    if [[ -f "$HOME/.config/hypr/hyprland.lua" ]]; then
        sed -i '/Villode desktop suite/Id; /Villode Launcher/Id; /require("config\.villode-suite")/d; /require("config\.villode-launcher")/d' \
            "$HOME/.config/hypr/hyprland.lua"
    fi

    set_session_logout "$legacy_managed"
    : > "$state_home/session-managed"
}

write_install_options() {
    local tmp
    tmp="$(mktemp "$state_home/.install-options.XXXXXX")"
    {
        $with_deps && echo 'dependencies=with' || echo 'dependencies=without'
        $no_start && echo 'start=no' || echo 'start=yes'
        $no_hyprland && echo 'hyprland=no' || echo 'hyprland=yes'
        $install_session && echo 'session=yes' || echo 'session=no'
        $offline && echo 'offline=yes' || echo 'offline=no'
        $no_native_build && echo 'native_build=no' || echo 'native_build=yes'
        echo "github_source=${VILLODE_GITHUB_SOURCE:-auto}"
        echo "github_mirrors=${VILLODE_GITHUB_MIRRORS:-kkgithub.com,ghproxy.net}"
        echo "github_prefer_direct=${VILLODE_PREFER_GITHUB_DIRECT:-0}"
    } > "$tmp"
    mv "$tmp" "$state_home/install-options"
}

install_release_files() {
    local release_dir="$data_home/release"
    if [[ "$repo_dir" != "$release_dir" ]]; then
        install -Dm755 "$repo_dir/install.sh" "$release_dir/install.sh"
        install -Dm755 "$repo_dir/uninstall.sh" "$release_dir/uninstall.sh"
        install -Dm755 "$repo_dir/update.sh" "$release_dir/update.sh"
        install -Dm644 "$manifest" "$release_dir/components.tsv"
        if [[ -f "$repo_dir/lib/git-net.sh" ]]; then
            install -Dm644 "$repo_dir/lib/git-net.sh" "$release_dir/lib/git-net.sh"
        fi
        for file in villode-hyprland.conf start-villode-hyprland \
            villode-hyprland-compositor villode-hyprland.desktop \
            villode-terminal villode-explorer villode-caelestia-shell-guard \
            villode-logout villode-system-update villode-datetime \
            villode-screenshot-editor swappy-villode caelestia-gtk-sync; do
            [[ -f "$repo_dir/session/$file" ]] || continue
            install -Dm644 "$repo_dir/session/$file" "$release_dir/session/$file"
        done
        chmod 755 "$release_dir/session/start-villode-hyprland" \
            "$release_dir/session/villode-hyprland-compositor" \
            "$release_dir/session/villode-terminal" \
            "$release_dir/session/villode-explorer" \
            "$release_dir/session/villode-caelestia-shell-guard" \
            2>/dev/null || true
        [[ -f "$release_dir/session/villode-logout" ]] && \
            chmod 755 "$release_dir/session/villode-logout"
        [[ -f "$release_dir/session/villode-system-update" ]] && \
            chmod 755 "$release_dir/session/villode-system-update"
        [[ -f "$release_dir/session/villode-datetime" ]] && \
            chmod 755 "$release_dir/session/villode-datetime"
        [[ -f "$release_dir/session/villode-screenshot-editor" ]] && \
            chmod 755 "$release_dir/session/villode-screenshot-editor"
        [[ -f "$release_dir/session/swappy-villode" ]] && \
            chmod 755 "$release_dir/session/swappy-villode"
        [[ -f "$release_dir/session/caelestia-gtk-sync" ]] && \
            chmod 755 "$release_dir/session/caelestia-gtk-sync"
    fi

    install -Dm755 "$repo_dir/uninstall.sh" "$HOME/.local/bin/villode-caelestia-uninstall"
    install -Dm755 "$repo_dir/update.sh" "$HOME/.local/bin/villode-caelestia-update"
    if [[ -f "$repo_dir/session/villode-caelestia-shell-guard" ]]; then
        install -Dm755 "$repo_dir/session/villode-caelestia-shell-guard" \
            "$HOME/.local/bin/villode-caelestia-shell-guard"
    fi
    if [[ -f "$repo_dir/session/villode-logout" ]]; then
        install -Dm755 "$repo_dir/session/villode-logout" \
            "$HOME/.local/bin/villode-logout"
    fi
    if [[ -f "$repo_dir/session/villode-system-update" ]]; then
        install -Dm755 "$repo_dir/session/villode-system-update" \
            "$HOME/.local/bin/villode-system-update"
    fi
    if [[ -f "$repo_dir/session/villode-datetime" ]]; then
        install -Dm755 "$repo_dir/session/villode-datetime" \
            "$HOME/.local/bin/villode-datetime"
    fi
    if [[ -f "$repo_dir/session/villode-screenshot-editor" ]]; then
        install -Dm755 "$repo_dir/session/villode-screenshot-editor" \
            "$HOME/.local/bin/villode-screenshot-editor"
    fi
    if [[ -f "$repo_dir/session/swappy-villode" ]]; then
        install -Dm755 "$repo_dir/session/swappy-villode" \
            "$HOME/.local/bin/swappy"
    fi
    if [[ -f "$repo_dir/session/caelestia-gtk-sync" ]]; then
        install -Dm755 "$repo_dir/session/caelestia-gtk-sync" \
            "$HOME/.local/bin/caelestia-gtk-sync"
        # Apply current scheme to GTK immediately after install.
        "$HOME/.local/bin/caelestia-gtk-sync" >/dev/null 2>&1 || true
    fi
    if [[ -f "$repo_dir/lib/git-net.sh" ]]; then
        # PATH-installed update.sh lives outside the release tree; keep the
        # helper under XDG data so resolve_git_net_lib always finds it.
        install -Dm644 "$repo_dir/lib/git-net.sh" "$data_home/release/lib/git-net.sh"
        install -Dm644 "$repo_dir/lib/git-net.sh" "$data_home/lib/git-net.sh"
    fi
    install -Dm755 "$repo_dir/session/villode-terminal" "$HOME/.local/bin/villode-terminal"
    install -Dm755 "$repo_dir/session/villode-explorer" "$HOME/.local/bin/villode-explorer"
    install -Dm644 "$manifest" "$data_home/components.tsv"
}

publish_component_states() {
    local id next_dir old_dir state_tmp
    mkdir -p "$data_home/components"
    for id in shell zh desktop launcher dock cursor; do
        [[ -f "$stage_dir/$id.tsv" ]] || continue
        next_dir="$(mktemp -d "$data_home/components/.$id.next.XXXXXX")"
        old_dir="$data_home/components/.$id.old.$$"
        install -m755 "$stage_dir/$id/uninstall.sh" "$next_dir/uninstall.sh"
        install -m644 "$stage_dir/$id/revision" "$next_dir/revision"
        if [[ -e "$data_home/components/$id" ]]; then
            mv "$data_home/components/$id" "$old_dir"
        fi
        if mv "$next_dir" "$data_home/components/$id"; then
            rm -rf "$old_dir"
        else
            [[ -e "$old_dir" ]] && mv "$old_dir" "$data_home/components/$id"
            return 1
        fi

        state_tmp="$(mktemp "$state_home/.$id.tsv.XXXXXX")"
        install -m644 "$stage_dir/$id.tsv" "$state_tmp"
        mv "$state_tmp" "$state_home/$id.tsv"
    done
}

caelestia_cli() {
    if [[ -x "$HOME/.local/bin/caelestia" ]]; then
        printf '%s\n' "$HOME/.local/bin/caelestia"
    else
        printf '%s\n' caelestia
    fi
}

quickshell_cli() {
    # Prefer the Villode qs wrapper so process naming matches the installed
    # runtime. Fall back to PATH when the wrapper is not present yet.
    if [[ -x "$HOME/.local/lib/caelestia/bin/qs" ]]; then
        printf '%s\n' "$HOME/.local/lib/caelestia/bin/qs"
    elif command -v qs >/dev/null 2>&1; then
        command -v qs
    else
        return 1
    fi
}

# True when a live Caelestia Quickshell process is present. Dead instance
# runtime dirs under $XDG_RUNTIME_DIR/quickshell must not count.
caelestia_shell_is_running() {
    local qs out pid cmdline
    if qs="$(quickshell_cli 2>/dev/null)"; then
        out="$("$qs" -c caelestia list --json --any-display 2>/dev/null || true)"
        if [[ "$out" == \[* && "$out" != "[]" ]] && grep -q '"pid"[[:space:]]*:' <<<"$out"; then
            return 0
        fi
    fi

    # The qs wrapper re-execs to /usr/bin/quickshell, so the live process name
    # is usually "quickshell", not "qs -c caelestia".
    while IFS= read -r pid; do
        [[ -r "/proc/$pid/cmdline" ]] || continue
        cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
        if [[ "$cmdline" == *'-c caelestia'* ||
              "$cmdline" == *'--config caelestia'* ||
              "$cmdline" == *'/quickshell/caelestia'* ]]; then
            return 0
        fi
    done < <(pgrep -u "$UID" -x quickshell 2>/dev/null || true)
    while IFS= read -r pid; do
        [[ -r "/proc/$pid/cmdline" ]] || continue
        cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
        if [[ "$cmdline" == *'-c caelestia'* ||
              "$cmdline" == *'--config caelestia'* ]]; then
            return 0
        fi
    done < <(pgrep -u "$UID" -x qs 2>/dev/null || true)
    return 1
}

stop_caelestia_shell() {
    local qs deadline pid cmdline
    local guard="$HOME/.local/bin/villode-caelestia-shell-guard"

    # Pause supervisor first so it does not race a restart while we kill shell.
    if [[ -x "$guard" ]]; then
        # Only stop the guard process, not permanently disable across restarts:
        # create disable briefly via guard stop, then leave binaries in place.
        "$guard" stop >/dev/null 2>&1 || true
    fi

    "$(caelestia_cli)" shell -k >/dev/null 2>&1 || true
    if qs="$(quickshell_cli 2>/dev/null)"; then
        # Kill every display-scoped instance for this config. "kill" targets one
        # instance per invocation, so also try newest after the default oldest.
        "$qs" -c caelestia kill --any-display >/dev/null 2>&1 || true
        "$qs" -c caelestia kill --any-display --newest >/dev/null 2>&1 || true
    fi

    # Match both the pre-reexec qs launcher and the final quickshell binary.
    pkill -u "$UID" -f '(^|/)qs[[:space:]]+-c[[:space:]]*caelestia([[:space:]]|$)'         >/dev/null 2>&1 || true
    pkill -u "$UID" -f '(^|/)quickshell[[:space:]].*-c[[:space:]]*caelestia([[:space:]]|$)'         >/dev/null 2>&1 || true
    pkill -u "$UID" -f '(^|/)quickshell[[:space:]].*/quickshell/caelestia'         >/dev/null 2>&1 || true

    deadline=$((SECONDS + 5))
    while caelestia_shell_is_running && (( SECONDS < deadline )); do
        if (( SECONDS + 2 >= deadline )); then
            while IFS= read -r pid; do
                [[ -r "/proc/$pid/cmdline" ]] || continue
                cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
                if [[ "$cmdline" == *'-c caelestia'* ||
                      "$cmdline" == *'--config caelestia'* ||
                      "$cmdline" == *'/quickshell/caelestia'* ]]; then
                    kill -9 "$pid" >/dev/null 2>&1 || true
                fi
            done < <(pgrep -u "$UID" -x quickshell 2>/dev/null || true; \
                     pgrep -u "$UID" -x qs 2>/dev/null || true)
        fi
        sleep 0.1
    done

    ! caelestia_shell_is_running
}

# Stop any previous instance, start a detached shell, and verify a live process
# actually remains. Prefer the shell guard so post-install life also auto-restarts.
# Quickshell's -n/--no-duplicate path can exit 0 with "already running" while the
# old process is still shutting down.
restart_caelestia_shell() {
    local log="${1:-$install_log}" attempt out rc=0 deadline attempt_log
    local guard="$HOME/.local/bin/villode-caelestia-shell-guard"

    : >"$log"
    # repo_dir is set in the full installer; extracted helper unit tests may omit it.
    if [[ ! -x "$guard" && -n "${repo_dir:-}" &&
          -f "$repo_dir/session/villode-caelestia-shell-guard" ]]; then
        install -Dm755 "$repo_dir/session/villode-caelestia-shell-guard" "$guard"
    fi

    for attempt in 1 2 3; do
        stop_caelestia_shell || true
        if [[ -x "$guard" ]]; then
            "$guard" stop >/dev/null 2>&1 || true
        fi
        rc=0
        attempt_log="$(mktemp)"
        {
            if [[ -x "$guard" ]]; then
                printf 'restart attempt %s: launching shell guard --daemon\n' "$attempt"
                LANG="${LANG:-zh_CN.UTF-8}" LC_ALL="${LC_ALL:-$LANG}" \
                    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
                    QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}" \
                    "$guard" --daemon
            else
                printf 'restart attempt %s: launching caelestia shell -d\n' "$attempt"
                LANG="${LANG:-zh_CN.UTF-8}" LC_ALL="${LC_ALL:-$LANG}" \
                    "$(caelestia_cli)" shell -d
            fi
        } >"$attempt_log" 2>&1 || rc=$?
        cat "$attempt_log" >>"$log"
        out="$(cat "$attempt_log" 2>/dev/null || true)"
        rm -f "$attempt_log"

        if grep -Fq 'An instance of this configuration is already running.' <<<"$out"; then
            printf 'restart attempt %s: start reported an existing instance; retrying\n' \
                "$attempt" >>"$log"
            sleep 0.2
            continue
        fi
        if (( rc != 0 )); then
            printf 'restart attempt %s: start exited %s\n' \
                "$attempt" "$rc" >>"$log"
            sleep 0.2
            continue
        fi

        deadline=$((SECONDS + 6))
        while ! caelestia_shell_is_running && (( SECONDS < deadline )); do
            sleep 0.1
        done
        if caelestia_shell_is_running; then
            printf 'restart attempt %s: shell is running\n' "$attempt" >>"$log"
            return 0
        fi
        printf 'restart attempt %s: start returned success but no live shell process\n' \
            "$attempt" >>"$log"
        sleep 0.2
    done
    return 1
}

prepare_sources
bootstrap_build_tools
install_session_dependencies
install_language_dependencies
validate_session_terminal

stage_dir="$(mktemp -d "$state_home/.install-stage.XXXXXX")"
cleanup_stage() {
    [[ -n "$stage_dir" ]] && rm -rf "$stage_dir"
}
trap cleanup_stage EXIT

if ! $skip_shell; then
    install_component shell
    # Cursor shake-to-find ships with Shell sources; register it as its own
    # component so the updates page can show install/repair status.
    if grep -q $'^cursor\t' "$manifest" 2>/dev/null; then
        source_dirs[cursor]="${source_dirs[shell]}"
        component_commits[cursor]="${component_commits[shell]}"
        component_names[cursor]="$(awk -F '\t' '$1 == "cursor" { print $4; exit }' "$manifest")"
        [[ -n "${component_names[cursor]}" ]] || component_names[cursor]="Villode 指针放大"
        install_component cursor
    fi
fi

for component in zh desktop launcher dock cursor; do
    # Skip if already installed above as part of shell
    if [[ "$component" == cursor ]] && ! $skip_shell && grep -q $'^cursor\t' "$manifest" 2>/dev/null; then
        continue
    fi
    if [[ " ${selected[*]} " == *" $component "* ]]; then
        install_component "$component"
    fi
done

# Replacement is intentionally the last potentially destructive migration
# step. At this point every selected installer and the zh/Shell combination
# have already succeeded.
replace_existing_shells
configure_hyprland_lua_autostart
install_villode_session
install_release_files
# After packages are on PATH: detect system apps and write Caelestia defaults
# without overwriting user choices in shell.json.
configure_default_apps
write_install_options
publish_component_states

if ! $no_start; then
    # Update/install often runs from inside the shell settings UI. The old
    # process may still be exiting while the new start races with -n, so stop,
    # start and verify with retries instead of a single fire-and-forget launch.
    # On TTY, adapt_for_tty_install already forced no_start=true.
    restart_caelestia_shell "$install_log" || {
        echo "组件已安装，但 Caelestia 自动启动失败。" >&2
        echo "Components installed, but Caelestia failed to start." >&2
        echo "日志 / log：$install_log" >&2
        if ! is_graphical_session; then
            echo "当前无图形会话：请重启后从 SDDM 进入 Villode Hyprland。" >&2
            echo "No graphical session: reboot and select Villode Hyprland in SDDM." >&2
            # Do not fail the whole install on TTY — files and session are ready.
        else
            exit 70
        fi
    }
    if [[ " ${selected[*]} " == *" dock "* ]] && [[ -x "$HOME/.local/bin/villode-dock" ]]; then
        "$HOME/.local/bin/villode-dock" --reload 2>/dev/null || true
    fi
fi

print_install_summary
