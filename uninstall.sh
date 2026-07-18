#!/usr/bin/env bash
set -euo pipefail

state_home="${XDG_STATE_HOME:-$HOME/.local/state}/villode-caelestia"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}/villode-caelestia"
selected=()
purge=false

acquire_operation_lock() {
    local lock_file="$state_home/operation.lock" rc
    [[ "${VILLODE_OPERATION_LOCK_HELD:-}" == 1 ]] && return 0
    command -v flock >/dev/null 2>&1 || {
        echo "缺少卸载器并发保护所需的 flock。" >&2
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
用法：villode-caelestia-uninstall [选项]

选项：
  --all                    卸载全部已安装组件
  --components LIST        卸载逗号分隔的组件：shell,zh,dock,desktop,launcher,cursor
  --purge                  同时删除组件的用户数据（不删除桌面迁移备份）
  -h, --help               显示帮助
EOF
}

add_components() {
    local item
    IFS=',' read -ra items <<< "$1"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        case "$item" in
            shell|zh|dock|desktop|launcher|cursor)
                [[ " ${selected[*]} " == *" $item "* ]] || selected+=("$item")
                ;;
            *) echo "未知组件：$item" >&2; exit 64 ;;
        esac
    done
}

while (($#)); do
    case "$1" in
        --all) selected=(zh dock desktop launcher cursor shell) ;;
        --components)
            [[ $# -ge 2 ]] || { echo "--components 缺少参数" >&2; exit 64; }
            add_components "$2"
            shift
            ;;
        --components=*) add_components "${1#*=}" ;;
        --purge) purge=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知选项：$1" >&2; usage >&2; exit 64 ;;
    esac
    shift
done

installed_components() {
    local id
    for id in shell zh dock desktop launcher cursor; do
        [[ -f "$state_home/$id.tsv" ]] && printf '%s\n' "$id"
    done
}

if ((${#selected[@]} == 0)); then
    mapfile -t installed < <(installed_components)
    if ((${#installed[@]} == 0)); then
        echo "没有记录到已安装的 Villode Caelestia 组件。"
        exit 0
    fi
    if [[ ! -t 0 ]]; then
        echo "非交互环境中请使用 --all 或 --components。" >&2
        exit 64
    fi
    echo "已安装组件：${installed[*]}"
    read -r -p "输入要卸载的组件（逗号分隔，默认全部）：" answer
    if [[ -z "$answer" || "$answer" == all ]]; then
        selected=("${installed[@]}")
    else
        add_components "$answer"
    fi
fi

for component in "${selected[@]}"; do
    script="$data_home/components/$component/uninstall.sh"
    if [[ ! -x "$script" ]]; then
        echo "跳过未安装或缺少卸载器的组件：$component"
        continue
    fi
    args=()
    # zh keeps user QML edits; cursor's uninstaller always removes its own
    # config/data/state and takes no flags.
    if $purge && [[ "$component" != zh && "$component" != cursor ]]; then
        args+=(--purge)
    fi
    echo "==> 卸载 $component"
    "$script" "${args[@]}"
    rm -rf "$data_home/components/$component"
    rm -f "$state_home/$component.tsv"
done

component_installed() {
    [[ -f "$state_home/$1.tsv" ]]
}

any_component_installed() {
    local id
    for id in shell zh dock desktop launcher cursor; do
        component_installed "$id" && return 0
    done
    return 1
}

any_session_component_installed() {
    local id
    for id in shell dock desktop launcher; do
        component_installed "$id" && return 0
    done
    return 1
}

render_managed_session() {
    local target="$HOME/.config/villode-hyprland/hyprland.conf"
    local template="$data_home/release/session/villode-hyprland.conf" tmp
    local have_shell=0 have_desktop=0 have_launcher=0 have_dock=0
    [[ -f "$template" ]] || template="$target"
    [[ -f "$template" ]] || return 0
    component_installed shell && have_shell=1
    component_installed desktop && have_desktop=1
    component_installed launcher && have_launcher=1
    component_installed dock && have_dock=1
    mkdir -p "$(dirname "$target")"
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
    ' "$template" > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$target"
}

restore_session_logout() {
    local config="$HOME/.config/caelestia/shell.json"
    local backup="$state_home/logout-backup.json"
    [[ -f "$backup" ]] || return 0
    command -v python3 >/dev/null 2>&1 || {
        echo "缺少 python3，注销命令备份保留在：$backup" >&2
        return 0
    }
    if python3 - "$config" "$backup" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
backup = Path(sys.argv[2])
try:
    saved = json.loads(backup.read_text())
    data = json.loads(path.read_text()) if path.exists() else {}
except (OSError, json.JSONDecodeError) as error:
    print(f"无法恢复注销命令：{error}", file=sys.stderr)
    raise SystemExit(1)
if not isinstance(data, dict):
    print(f"无法恢复注销命令：{path} 顶层不是 JSON 对象", file=sys.stderr)
    raise SystemExit(1)
session = data.get("session")
if not isinstance(session, dict):
    session = {}
    data["session"] = session
commands = session.get("commands")
if not isinstance(commands, dict):
    commands = {}
    session["commands"] = commands
managed = {("uwsm", "stop"), ("villode-logout",)}
current = commands.get("logout")
current_key = tuple(current) if isinstance(current, list) else None
if current_key not in managed:
    # The user changed or removed the value after installation. Their newer
    # choice wins; only values still owned by Villode are restored.
    raise SystemExit(0)
if saved.get("present"):
    commands["logout"] = saved.get("value")
else:
    commands.pop("logout", None)
temp = path.with_name(path.name + f".tmp-{os.getpid()}")
temp.parent.mkdir(parents=True, exist_ok=True)
temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
temp.replace(path)
PY
    then
        rm -f "$backup"
    fi
}

refresh_managed_session() {
    [[ -f "$state_home/session-managed" ]] || return 0
    if any_session_component_installed; then
        render_managed_session
        return
    fi
    rm -rf "$HOME/.config/villode-hyprland"
    sudo rm -f /usr/local/bin/start-villode-hyprland \
        /usr/local/bin/villode-hyprland-compositor \
        /usr/local/share/wayland-sessions/villode-hyprland.desktop
    restore_session_logout
    rm -f "$state_home/session-managed"
}

adopt_legacy_managed_session() {
    local target="$HOME/.config/villode-hyprland/hyprland.conf"
    [[ -f "$state_home/session-managed" ]] && return 0
    if [[ -f "$target" ]] && grep -Fxq '# Villode Hyprland session' "$target"; then
        : > "$state_home/session-managed"
    fi
}

refresh_lua_integration() {
    local lua_main="$HOME/.config/hypr/hyprland.lua"
    local lua_module="$HOME/.config/hypr/config/villode-suite.lua" tmp
    [[ -f "$lua_module" ]] || return 0
    if ! component_installed shell && ! component_installed desktop && ! component_installed dock; then
        rm -f "$lua_module"
        if [[ -f "$lua_main" ]]; then
            sed -i '/Villode desktop suite/Id; /require("config\.villode-suite")/d' "$lua_main"
        fi
        return
    fi
    tmp="$(mktemp "${lua_module}.XXXXXX")"
    {
        echo '-- Managed by Villode Caelestia.'
        echo 'hl.on("hyprland.start", function()'
        component_installed shell && echo '    hl.exec_cmd("villode-caelestia-shell-guard --daemon")'
        component_installed desktop && echo '    hl.exec_cmd("villode-desktop --daemon")'
        component_installed dock && echo '    hl.exec_cmd("villode-dock --daemon")'
        echo 'end)'
    } > "$tmp"
    mv "$tmp" "$lua_module"
}

adopt_legacy_managed_session
refresh_managed_session
refresh_lua_integration

if ! any_component_installed; then
    # Integration metadata can be removed, but migration backups deliberately
    # stay in state_home so an ordinary uninstall never destroys recovery data.
    restore_session_logout
    rm -rf "$data_home"
    rm -f "$state_home/install-options"
    # Stop shell supervisor before removing it.
    if [[ -x "$HOME/.local/bin/villode-caelestia-shell-guard" ]]; then
        "$HOME/.local/bin/villode-caelestia-shell-guard" stop >/dev/null 2>&1 || true
    fi
    pkill -f 'villode-screenshot-editor --daemon' >/dev/null 2>&1 || true
    rm -f "$HOME/.local/bin/villode-caelestia-uninstall" \
        "$HOME/.local/bin/villode-caelestia-update" \
        "$HOME/.local/bin/villode-caelestia-shell-guard" \
        "$HOME/.local/bin/villode-logout" \
        "$HOME/.local/bin/villode-system-update" \
        "$HOME/.local/bin/villode-datetime" \
        "$HOME/.local/bin/villode-terminal" \
        "$HOME/.local/bin/villode-explorer" \
        "$HOME/.local/bin/villode-screenshot-editor" \
        "$HOME/.local/bin/caelestia-gtk-sync"
    # Only remove swappy if it is our PATH shim, never a real package binary.
    if [[ -f "$HOME/.local/bin/swappy" ]] &&
       grep -q 'Villode screenshot editor (swappy-compatible shim)' \
           "$HOME/.local/bin/swappy" 2>/dev/null; then
        rm -f "$HOME/.local/bin/swappy"
    fi
    # The outer flock process still owns the unlinked inode until this script
    # exits, so removing the pathname here cannot release protection early.
    rm -f "$state_home/operation.lock"
    rmdir "$state_home" 2>/dev/null || true
fi

echo "卸载完成。"
