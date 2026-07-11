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
install_session=true
offline=false
no_native_build=false
skip_shell=false
# Keep the current desktop as a recovery path unless replacement is explicitly
# requested.  More importantly, replacement is deferred until every selected
# source has been fetched, validated and installed successfully.
replace_existing=no
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
用法：./install.sh [选项]

Caelestia Shell 本体始终安装；未指定可选组件时显示交互式选择菜单。

选项：
  --all                    安装全部组件
  --components LIST        安装逗号分隔的可选组件：zh,dock,desktop,launcher
  --with-deps              自动检测并安装缺失依赖（默认）
  --no-deps                不安装缺失的系统依赖
  --no-start               安装后不启动或重启组件
  --no-hyprland            不写任何 Hyprland 集成（包含独立会话）
  --no-session             不安装独立 Villode Hyprland 登录会话
  --offline                仅使用本地缓存，不访问网络
  --no-native-build        不构建 Fork 的原生插件，仅部署 QML
  --skip-shell             不重新部署 Shell（供更新器内部使用）
  --replace-existing       验证并安装成功后，备份并移除现有桌面壳
  --keep-existing          保留检测到的现有桌面壳（默认）
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

if $offline && $with_deps; then
    echo "离线模式不会安装系统依赖；按 --no-deps 继续。"
    with_deps=false
fi

# --no-hyprland is an absolute promise not to create either integration files
# in the user's session or a separate Hyprland session.
if $no_hyprland; then
    install_session=false
fi

if ! $skip_shell &&
   { [[ -f "$state_home/zh.tsv" ]] ||
     [[ -x "$HOME/.local/bin/caelestia-zh-apply" &&
        -f "${XDG_DATA_HOME:-$HOME/.local/share}/caelestia-zh-cn/patches/zh-cn-ui.patch" ]]; } &&
   [[ " ${selected[*]} " != *" zh "* ]]; then
    echo "检测到现有中文化组件，将在刷新 Shell 后自动重新应用。"
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

install_session_dependencies() {
    $install_session || return 0
    $with_deps || return 0
    $offline && return
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm \
            hyprland xdg-desktop-portal xdg-desktop-portal-hyprland \
            xdg-desktop-portal-gtk polkit-gnome pipewire wireplumber \
            networkmanager uwsm foot
    fi
}

install_language_dependencies() {
    [[ " ${selected[*]} " == *" zh "* ]] || return 0
    if command -v patch >/dev/null 2>&1 && command -v rsync >/dev/null 2>&1; then
        return
    fi
    if ! $with_deps || $offline; then
        echo "中文组件需要 patch 和 rsync；请先安装，或使用 --with-deps。" >&2
        return 69
    fi
    if command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm patch rsync
    elif command -v apt >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y patch rsync
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y patch rsync
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y patch rsync
    fi
    command -v patch >/dev/null 2>&1 && command -v rsync >/dev/null 2>&1 || {
        echo "无法安装中文组件所需的 patch 和 rsync。" >&2
        return 69
    }
}

validate_session_terminal() {
    local terminal
    $install_session || return 0
    for terminal in kitty foot alacritty xterm; do
        command -v "$terminal" >/dev/null 2>&1 && return
    done
    echo "独立会话需要终端（推荐 foot）；请安装后重试，或使用 --with-deps。" >&2
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
    fetch_dir="$(mktemp -d "$cache_home/.fetch-$id.XXXXXX")"
    if ! git -C "$fetch_dir" init -q ||
       ! git -C "$fetch_dir" remote add origin "$repo" ||
       ! git -C "$fetch_dir" fetch -q --depth=1 origin "$commit" ||
       ! git -C "$fetch_dir" checkout -q --detach FETCH_HEAD; then
        rm -rf "$fetch_dir"
        echo "无法获取锁定版本：$id ${commit:0:12}" >&2
        return 69
    fi
    rm -rf "$source_dir"
    mv "$fetch_dir" "$source_dir"
    printf '%s\n' "$source_dir"
}

validate_component_source() {
    local id="$1" source_dir="${source_dirs[$1]}" required
    case "$id" in
        shell)
            required=(install-villode.sh uninstall-villode.sh shell.qml UPSTREAM_VERSION assets components modules services utils)
            ;;
        zh)
            required=(install.sh uninstall.sh bin/caelestia-zh-apply patches/zh-cn-ui.patch)
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
    local zh_source="${source_dirs[zh]}" shell_source help_text
    local checker="$zh_source/bin/caelestia-zh-apply"
    local patch_file="$zh_source/patches/zh-cn-ui.patch"

    if [[ -n "${source_dirs[shell]:-}" ]]; then
        shell_source="${source_dirs[shell]}"
    else
        shell_source="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/caelestia"
    fi
    [[ -f "$shell_source/shell.qml" ]] || {
        echo "无法验证中文组件：没有可用的 Caelestia Shell 源码。" >&2
        return 66
    }

    help_text="$($checker --help 2>&1 || true)"
    if command -v patch >/dev/null 2>&1 &&
       grep -q -- '--check' <<< "$help_text" && grep -q -- '--source' <<< "$help_text"; then
        CAELESTIA_PATCH_FILE="$patch_file" \
            "$checker" --check --source "$shell_source"
        return
    fi

    # Compatibility fallback for older language packages. git-apply performs a
    # complete dry run and does not require the system `patch` command.
    if git -C "$shell_source" apply --check "$patch_file" >/dev/null 2>&1 ||
       git -C "$shell_source" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
        return
    fi
    echo "中文组件与锁定的 Shell 版本不兼容；未对系统进行任何更改。" >&2
    return 65
}

prepare_sources() {
    local id
    ensure_fetch_tools
    mkdir -p "$cache_home" "$state_home" "$data_home"

    if ! $skip_shell; then
        prefetch_component shell
    fi
    for id in zh desktop launcher dock; do
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
            echo '    hl.exec_cmd("caelestia shell -d")'
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
    if legacy_managed and commands.get("logout") == ["uwsm", "stop"]:
        # Older Villode installers wrote this value without preserving the
        # prior setting. Removing it on uninstall restores Caelestia's default.
        saved = {"present": False, "value": None}
    else:
        saved = {"present": "logout" in commands, "value": commands.get("logout")}
    temp = backup.with_name(backup.name + f".tmp-{os.getpid()}")
    temp.write_text(json.dumps(saved, ensure_ascii=False) + "\n")
    temp.replace(backup)
commands["logout"] = ["uwsm", "stop"]
path.parent.mkdir(parents=True, exist_ok=True)
temp = path.with_name(path.name + f".tmp-{os.getpid()}")
temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
temp.replace(path)
PY
}

install_villode_session() {
    local session_config="$HOME/.config/villode-hyprland/hyprland.conf" legacy_managed=no
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
        for file in villode-hyprland.conf start-villode-hyprland \
            villode-hyprland-compositor villode-hyprland.desktop; do
            install -Dm644 "$repo_dir/session/$file" "$release_dir/session/$file"
        done
        chmod 755 "$release_dir/session/start-villode-hyprland" \
            "$release_dir/session/villode-hyprland-compositor"
    fi

    install -Dm755 "$repo_dir/uninstall.sh" "$HOME/.local/bin/villode-caelestia-uninstall"
    install -Dm755 "$repo_dir/update.sh" "$HOME/.local/bin/villode-caelestia-update"
    install -Dm644 "$manifest" "$data_home/components.tsv"
}

publish_component_states() {
    local id next_dir old_dir state_tmp
    mkdir -p "$data_home/components"
    for id in shell zh desktop launcher dock; do
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
fi

for component in zh desktop launcher dock; do
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
write_install_options
publish_component_states

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
if $skip_shell; then
    echo "安装完成：${selected[*]}"
else
    echo "安装完成：shell ${selected[*]}"
fi
echo "统一卸载命令：villode-caelestia-uninstall"
echo "检查与更新命令：villode-caelestia-update"
