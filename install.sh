#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest="$repo_dir/components.tsv"
cache_home="${XDG_CACHE_HOME:-$HOME/.cache}/villode-caelestia/sources"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}/villode-caelestia"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}/villode-caelestia"
selected=()
with_deps=true
no_start=false
no_hyprland=false
offline=false
no_native_build=false
# A complete Villode installation owns the desktop-shell role. Existing shells
# are backed up and removed by default; --keep-existing is the explicit opt-out.
replace_existing=yes

usage() {
    cat <<'EOF'
用法：./install.sh [选项]

Caelestia Shell 本体始终安装；未指定可选组件时显示交互式选择菜单。

选项：
  --all                    安装全部组件
  --components LIST        安装逗号分隔的可选组件：zh,dock,desktop,launcher
  --with-deps              自动检测并安装缺失依赖（默认）
  --no-deps                不安装缺失的系统依赖
  --no-start               安装后不启动或重启组件
  --no-hyprland            不写入 Hyprland 集成配置
  --offline                仅使用本地缓存，不访问网络
  --no-native-build        不构建 Fork 的原生插件，仅部署 QML
  --replace-existing       备份并移除现有桌面壳（默认）
  --keep-existing          保留检测到的现有桌面壳
  -h, --help               显示帮助
EOF
}

normalise_component() {
    case "$1" in
        shell|core|caelestia) echo shell ;;
        zh|chinese|i18n) echo zh ;;
        dock) echo dock ;;
        desktop|wallpaper) echo desktop ;;
        launcher|launchpad) echo launcher ;;
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
            selected=(zh dock desktop launcher)
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
        --offline)
            offline=true
            ;;
        --no-native-build)
            no_native_build=true
            ;;
        --replace-existing)
            replace_existing=yes
            ;;
        --keep-existing)
            replace_existing=no
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

if ((${#selected[@]} == 0)); then
    if [[ ! -t 0 ]]; then
        echo "非交互环境中请使用 --all 或 --components。" >&2
        exit 64
    fi
    cat <<'EOF'
选择要安装的组件：
  1. Caelestia 简体中文
  2. Villode Dock
  3. Villode Desktop
  4. Villode Launcher
  a. 全部组件
EOF
    read -r -p "输入编号（可用逗号分隔，默认 a）：" answer
    answer="${answer:-a}"
    if [[ "$answer" == "a" || "$answer" == "A" ]]; then
        selected=(zh dock desktop launcher)
    else
        answer="${answer//1/zh}"
        answer="${answer//2/dock}"
        answer="${answer//3/desktop}"
        answer="${answer//4/launcher}"
        add_components "$answer"
    fi
fi

bootstrap_install_tools() {
    local bootstrap_dir

    if ! $with_deps; then
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        if ! command -v git >/dev/null 2>&1 ||
           { ! command -v yay >/dev/null 2>&1 && ! command -v paru >/dev/null 2>&1; }; then
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
    elif ! command -v git >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            sudo apt update
            sudo apt install -y git
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y git
        elif command -v zypper >/dev/null 2>&1; then
            sudo zypper install -y git
        fi
    fi
}

bootstrap_install_tools

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
    local backup_dir package_name path config_file
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
        read -r -p "是否备份并替换为 Villode Caelestia？[Y/n] " answer
        case "${answer:-y}" in
            y|Y|yes|YES) replace_existing=yes ;;
            *) replace_existing=no ;;
        esac
    fi

    if [[ "$replace_existing" == no ]]; then
        echo "保留现有桌面壳；同时运行多个 Shell 可能出现面板、通知和快捷键冲突。"
        return
    fi

    backup_dir="$state_home/migration-backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir/config"
    if [[ -d "$HOME/.config/hypr" ]]; then
        cp -a "$HOME/.config/hypr" "$backup_dir/config/hypr"
    fi
    for path in "${detected_shell_paths[@]}"; do
        cp -a "$path" "$backup_dir/config/"
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

    if [[ -d "$HOME/.config/hypr" ]]; then
        while IFS= read -r -d '' config_file; do
            sed -i -E '/noctalia|noctCall|waybar|hyprpanel|nwg-(panel|dock)|ironbar|(^|[[:space:]])ags([[:space:]]|$)|(^|[[:space:]])eww([[:space:]]|$)/Id' "$config_file"
        done < <(find "$HOME/.config/hypr" -type f \
            \( -name '*.conf' -o -name '*.lua' \) -print0)
    fi

    if command -v pacman >/dev/null 2>&1; then
        removable_packages=()
        for package_name in \
            cachyos-hypr-noctalia cachyos-niri-noctalia \
            noctalia noctalia-shell \
            waybar hyprpanel aylurs-gtk-shell eww \
            nwg-panel nwg-dock nwg-dock-hyprland ironbar; do
            pacman -Q "$package_name" >/dev/null 2>&1 && removable_packages+=("$package_name")
        done
        if ((${#removable_packages[@]})); then
            # Only remove the conflicting shells themselves.  Recursive orphan
            # removal can delete shared Hyprland services such as portals,
            # keyrings and the Dock's file manager.
            sudo pacman -R --noconfirm "${removable_packages[@]}"
        fi
        if pacman -Q noctalia-qs >/dev/null 2>&1; then
            # noctalia-qs conflicts with the standard package while providing
            # quickshell-git to installed dependants. Remove only that provider,
            # then immediately install the standard implementation.
            sudo pacman -Rdd --noconfirm noctalia-qs
            if command -v yay >/dev/null 2>&1; then
                yay -S --needed --noconfirm quickshell-git
            else
                paru -S --needed --noconfirm quickshell-git
            fi
        fi
    fi

    printf 'Desktop shell migration completed at %s\nBackup: %s\n' \
        "$(date --iso-8601=seconds)" "$backup_dir" > "$state_home/desktop-migration.txt"
    echo "旧桌面配置已备份到：$backup_dir"
}

replace_existing_shells

for command_name in git install; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "缺少依赖：$command_name" >&2
        exit 69
    }
done

mkdir -p "$cache_home" "$state_home" "$data_home/components"

manifest_row() {
    awk -F '\t' -v id="$1" '$1 == id { print; found=1; exit } END { if (!found) exit 1 }' "$manifest"
}

fetch_component() {
    local id="$1" repo="$2" commit="$3" source_dir="$cache_home/$id"
    if [[ -d "$source_dir/.git" ]] &&
       [[ "$(git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)" == "$commit" ]]; then
        printf '%s\n' "$source_dir"
        return
    fi
    if $offline; then
        echo "离线缓存缺少组件或版本不匹配：$id" >&2
        return 69
    fi
    rm -rf "$source_dir"
    mkdir -p "$source_dir"
    git -C "$source_dir" init -q
    git -C "$source_dir" remote add origin "$repo"
    git -C "$source_dir" fetch -q --depth=1 origin "$commit"
    git -C "$source_dir" checkout -q --detach FETCH_HEAD
    printf '%s\n' "$source_dir"
}

install_component() {
    local id="$1" row repo commit name source_dir
    row="$(manifest_row "$id")"
    IFS=$'\t' read -r _ repo commit name <<< "$row"
    echo
    echo "==> 安装 $name"
    source_dir="$(fetch_component "$id" "$repo" "$commit")"

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
        dock|desktop|launcher)
            component_args=()
            $with_deps && component_args+=(--with-deps)
            $no_start && component_args+=(--no-start)
            $no_hyprland && component_args+=(--no-hyprland)
            "$source_dir/install.sh" "${component_args[@]}"
            uninstall_source="$source_dir/uninstall.sh"
            ;;
    esac

    install -Dm755 "$uninstall_source" "$data_home/components/$id/uninstall.sh"
    printf '%s\t%s\t%s\n' "$id" "$commit" "$name" > "$state_home/$id.tsv"
}

configure_hyprland_lua_autostart() {
    local hypr_dir="$HOME/.config/hypr"
    local lua_main="$hypr_dir/hyprland.lua"
    local lua_module="$hypr_dir/config/villode-suite.lua"

    $no_hyprland && return
    [[ -f "$lua_main" ]] || return

    mkdir -p "$(dirname "$lua_module")"
    {
        cat <<'EOF'
-- Managed by Villode Caelestia. Hyprland 0.55+ ignores legacy exec-once
-- entries when the active configuration is hyprland.lua.
hl.on("hyprland.start", function()
    hl.exec_cmd("caelestia shell -d")
EOF
        [[ -f "$state_home/desktop.tsv" ]] && \
            echo '    hl.exec_cmd("villode-desktop --daemon")'
        [[ -f "$state_home/dock.tsv" ]] && \
            echo '    hl.exec_cmd("villode-dock --daemon")'
        # Launcher owns its Lua window rules and autostart in its component
        # module, so it is deliberately not started twice here.
        echo 'end)'
    } > "$lua_module"

    if ! grep -Fq 'require("config.villode-suite")' "$lua_main"; then
        printf '\n-- Villode desktop suite\nrequire("config.villode-suite")\n' >> "$lua_main"
    fi
}

if [[ -f "$state_home/zh.tsv" && " ${selected[*]} " != *" zh "* ]]; then
    echo "检测到现有中文化组件，将在刷新 Shell 后自动重新应用。"
    selected+=(zh)
fi

install_component shell

for component in zh desktop launcher dock; do
    if [[ " ${selected[*]} " == *" $component "* ]]; then
        install_component "$component"
    fi
done

configure_hyprland_lua_autostart

install -Dm755 "$repo_dir/uninstall.sh" "$HOME/.local/bin/villode-caelestia-uninstall"
install -Dm644 "$manifest" "$data_home/components.tsv"

if ! $no_start; then
    "$HOME/.local/bin/caelestia" shell -k >/dev/null 2>&1 || true
    # The CLI can leave an older detached Quickshell instance behind after an
    # upgrade. Stop only Caelestia's own instances before starting one fresh
    # process, otherwise duplicate panels keep running and waste resources.
    pkill -u "$UID" -f '^qs -c caelestia([[:space:]]|$)' >/dev/null 2>&1 || true
    "$HOME/.local/bin/caelestia" shell -d >/tmp/villode-caelestia-install.log 2>&1 || {
        echo "组件已安装，但 Caelestia 自动启动失败。" >&2
        echo "日志：/tmp/villode-caelestia-install.log" >&2
        exit 70
    }
    if [[ " ${selected[*]} " == *" dock "* ]]; then
        "$HOME/.local/bin/villode-dock" --reload
    fi
fi

echo
echo "安装完成：shell ${selected[*]}"
echo "统一卸载命令：villode-caelestia-uninstall"
