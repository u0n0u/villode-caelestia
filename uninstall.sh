#!/usr/bin/env bash
set -euo pipefail

state_home="${XDG_STATE_HOME:-$HOME/.local/state}/villode-caelestia"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}/villode-caelestia"
selected=()
purge=false

usage() {
    cat <<'EOF'
用法：villode-caelestia-uninstall [选项]

选项：
  --all                    卸载全部已安装组件
  --components LIST        卸载逗号分隔的组件：shell,zh,dock,desktop,launcher
  --purge                  同时删除组件的用户数据
  -h, --help               显示帮助
EOF
}

add_components() {
    local item
    IFS=',' read -ra items <<< "$1"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        case "$item" in
            shell|zh|dock|desktop|launcher) selected+=("$item") ;;
            *) echo "未知组件：$item" >&2; exit 64 ;;
        esac
    done
}

while (($#)); do
    case "$1" in
        --all) selected=(zh dock desktop launcher shell) ;;
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

if ((${#selected[@]} == 0)); then
    mapfile -t installed < <(find "$state_home" -maxdepth 1 -type f -name '*.tsv' -printf '%f\n' 2>/dev/null | sed 's/\.tsv$//' | sort)
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
    if [[ -z "$answer" || "$answer" == "all" ]]; then
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
    if $purge && [[ "$component" != zh ]]; then
        args+=(--purge)
    fi
    echo "==> 卸载 $component"
    "$script" "${args[@]}"
    rm -rf "$data_home/components/$component"
    rm -f "$state_home/$component.tsv"
done

if ! find "$state_home" -maxdepth 1 -type f -name '*.tsv' -print -quit 2>/dev/null | grep -q .; then
    rm -f "$HOME/.config/hypr/config/villode-suite.lua"
    if [[ -f "$HOME/.config/hypr/hyprland.lua" ]]; then
        sed -i '/Villode desktop suite/Id; /require("config\.villode-suite")/d' \
            "$HOME/.config/hypr/hyprland.lua"
    fi
    rm -rf "$state_home" "$data_home"
    rm -f "$HOME/.local/bin/villode-caelestia-uninstall"
fi

echo "卸载完成。"
