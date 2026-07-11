#!/usr/bin/env bash
set -euo pipefail

remote="https://github.com/Villode/villode-caelestia.git"
cache_home="${XDG_CACHE_HOME:-$HOME/.cache}/villode-caelestia/update-channel"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}/villode-caelestia"
mode=update

if [[ "${1:-}" == "--check" ]]; then
    mode=check
elif [[ $# -gt 0 ]]; then
    echo "用法：villode-caelestia-update [--check]" >&2
    exit 64
fi

refresh_channel() {
    mkdir -p "$(dirname "$cache_home")"
    if [[ ! -d "$cache_home/.git" ]]; then
        rm -rf "$cache_home"
        git clone -q --filter=blob:none --depth=1 "$remote" "$cache_home"
    else
        git -C "$cache_home" remote set-url origin "$remote"
        git -C "$cache_home" fetch -q --depth=1 origin main
        git -C "$cache_home" reset -q --hard FETCH_HEAD
    fi
}

installed_commit() {
    local file="$state_home/$1.tsv"
    [[ -f "$file" ]] && awk -F '\t' 'NR == 1 { print $2 }' "$file"
}

refresh_channel
manifest="$cache_home/components.tsv"
outdated=()

while IFS=$'\t' read -r id _repo latest name; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    installed="$(installed_commit "$id")"
    if [[ -z "$installed" ]]; then
        status="未安装"
    elif [[ "$installed" == "$latest" ]]; then
        status="已是最新"
    else
        status="有更新"
        outdated+=("$id")
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$name" "${installed:0:7}" "${latest:0:7}" "$status"
done < "$manifest"

if [[ "$mode" == check ]]; then
    exit 0
fi

if ((${#outdated[@]} == 0)); then
    echo
    echo "所有 Villode 组件都已是最新版本。"
    exit 0
fi

optional=()
for id in "${outdated[@]}"; do
    [[ "$id" != shell ]] && optional+=("$id")
done

args=(--keep-existing)
if [[ " ${outdated[*]} " != *" shell "* ]]; then
    args+=(--skip-shell)
fi
if ((${#optional[@]})); then
    components="$(IFS=,; echo "${optional[*]}")"
    args+=(--components "$components")
elif [[ " ${outdated[*]} " == *" shell "* ]]; then
    args+=(--components shell)
fi

echo
echo "即将同步 ${#outdated[@]} 个 Villode 组件：${outdated[*]}"
echo "更新源：$remote"
echo

if [[ " ${outdated[*]} " != *" shell "* ]] && ! grep -q -- '--skip-shell' "$cache_home/install.sh"; then
    data_home="${XDG_DATA_HOME:-$HOME/.local/share}/villode-caelestia"
    mkdir -p "$state_home" "$data_home/components"

    for id in "${optional[@]}"; do
        IFS=$'\t' read -r _ repo commit name < <(awk -F '\t' -v id="$id" '$1 == id { print; exit }' "$manifest")
        source_dir="$cache_home/components/$id"

        echo "==> 更新 $name"
        rm -rf "$source_dir"
        git clone -q --filter=blob:none "$repo" "$source_dir"
        git -C "$source_dir" checkout -q "$commit"
        "$source_dir/install.sh" --with-deps
        install -Dm755 "$source_dir/uninstall.sh" "$data_home/components/$id/uninstall.sh"
        printf '%s\t%s\t%s\n' "$id" "$commit" "$name" > "$state_home/$id.tsv"
    done
else
    "$cache_home/install.sh" "${args[@]}"
fi
