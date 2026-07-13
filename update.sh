#!/usr/bin/env bash
set -euo pipefail

remote="https://github.com/Villode/villode-caelestia.git"
cache_home="${XDG_CACHE_HOME:-$HOME/.cache}/villode-caelestia/update-channel"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}/villode-caelestia"
user_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
data_home="$user_data_home/villode-caelestia"
shell_state_home="${XDG_STATE_HOME:-$HOME/.local/state}/villode-caelestia-shell"
mode=update
network_override=""

acquire_operation_lock() {
    local lock_file="$state_home/operation.lock" rc
    [[ "${VILLODE_OPERATION_LOCK_HELD:-}" == 1 ]] && return 0
    command -v flock >/dev/null 2>&1 || {
        echo "缺少更新器并发保护所需的 flock。" >&2
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
用法：villode-caelestia-update [--check|--check-json] [--online|--offline]

  --check       仅检查，不安装（制表符摘要）
  --check-json  仅检查，输出详细 JSON（供设置页展示）
  --online      本次允许联网（执行安装时会保存在线更新模式）
  --offline     仅使用已缓存的发布渠道和组件源码，绝不联网或安装依赖
EOF
}

while (($#)); do
    case "$1" in
        --check) mode=check ;;
        --check-json) mode=check-json ;;
        --online) network_override=online ;;
        --offline) network_override=offline ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
    shift
done

option_value() {
    local key="$1" default="$2" file="$state_home/install-options" value
    if [[ -f "$file" ]]; then
        value="$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$file")"
    fi
    printf '%s\n' "${value:-$default}"
}

legacy_session_default() {
    if [[ -f "$state_home/session-managed" ||
          -f "$HOME/.config/villode-hyprland/hyprland.conf" ]]; then
        echo yes
    else
        echo no
    fi
}

legacy_hyprland_default() {
    if [[ -f "$state_home/session-managed" ||
          -f "$HOME/.config/villode-hyprland/hyprland.conf" ||
          -f "$HOME/.config/hypr/config/villode-suite.lua" ||
          -f "$HOME/.config/hypr/config/villode-launcher.lua" ]]; then
        echo yes
    else
        echo no
    fi
}

offline_mode="$(option_value offline no)"
case "$network_override" in
    online) offline_mode=no ;;
    offline) offline_mode=yes ;;
esac

validate_channel() {
    local dir="$1"
    [[ -f "$dir/components.tsv" && -x "$dir/install.sh" ]]
}

refresh_channel() {
    local installed_release="$data_home/release"
    if [[ "$offline_mode" == yes ]]; then
        if validate_channel "$cache_home"; then
            channel_dir="$cache_home"
        elif validate_channel "$installed_release"; then
            channel_dir="$installed_release"
        else
            echo "离线模式下没有可用的发布渠道缓存。" >&2
            exit 69
        fi
        return
    fi

    command -v git >/dev/null 2>&1 || {
        echo "检查在线更新需要 git。" >&2
        exit 69
    }
    mkdir -p "$(dirname "$cache_home")"
    if [[ ! -d "$cache_home/.git" ]]; then
        rm -rf "$cache_home"
        git clone -q --filter=blob:none --depth=1 "$remote" "$cache_home"
    else
        git -C "$cache_home" remote set-url origin "$remote"
        git -C "$cache_home" fetch -q --depth=1 origin main
        git -C "$cache_home" reset -q --hard FETCH_HEAD
    fi
    validate_channel "$cache_home" || {
        echo "更新渠道内容不完整，拒绝继续。" >&2
        exit 66
    }
    channel_dir="$cache_home"
}

state_commit() {
    local file="$state_home/$1.tsv"
    if [[ -f "$file" ]]; then
        awk -F '\t' 'NR == 1 { print $2 }' "$file"
    fi
    return 0
}

installed_manifest_commit() {
    local id="$1" manifest="$data_home/components.tsv"
    if [[ -f "$manifest" ]]; then
        awk -F '\t' -v id="$id" '$1 == id { print $3; exit }' "$manifest"
    fi
    return 0
}

component_evidence() {
    case "$1" in
        shell)
            [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/caelestia/.villode-managed" ]]
            ;;
        zh)
            [[ -x "$HOME/.local/bin/caelestia-zh-apply" &&
               -f "$user_data_home/caelestia-zh-cn/patches/zh-cn-ui.patch" ]] &&
                "$HOME/.local/bin/caelestia-zh-apply" --check 2>/dev/null |
                grep -q '已经应用'
            ;;
        dock) [[ -x "$HOME/.local/bin/villode-dock" ]] ;;
        desktop) [[ -x "$HOME/.local/bin/villode-desktop" ]] ;;
        launcher) [[ -x "$HOME/.local/bin/villode-launcher" ]] ;;
        *) return 1 ;;
    esac
}

# Sets: installed, repair_needed, component_present.
resolve_installed() {
    local id="$1" recorded="" actual="" marker="" fallback="" managed_revision=""
    installed=""
    repair_needed=false
    component_present=false
    recorded="$(state_commit "$id")"

    if [[ "$id" == shell ]]; then
        marker="$shell_state_home/revision"
    else
        marker="$data_home/components/$id/revision"
    fi
    [[ -f "$marker" ]] && actual="$(sed -n '1p' "$marker")"

    if [[ "$id" == shell ]]; then
        managed_revision="$(awk -F ': *' '$1 == "Revision" { print $2; exit }' \
            "${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/caelestia/.villode-managed" \
            2>/dev/null || true)"
    fi

    evidence_present=false
    if component_evidence "$id"; then
        evidence_present=true
    fi
    if $evidence_present || [[ -n "$actual" ]]; then
        component_present=true
    fi
    if [[ -n "$actual" ]]; then
        installed="$actual"
        if [[ -z "$recorded" || "$recorded" != "$actual" ]] || ! $evidence_present; then
            repair_needed=true
        fi
        if [[ "$id" == shell && "$managed_revision" != "$actual" ]]; then
            repair_needed=true
        fi
    elif $component_present; then
        fallback="${recorded:-$(installed_manifest_commit "$id")}"
        installed="$fallback"
        # Legacy installs did not have an independently verifiable component
        # revision. Reinstall once to establish one.
        repair_needed=true
    elif [[ -n "$recorded" ]]; then
        installed="$recorded"
        component_present=true
        repair_needed=true
    fi
}

component_source_dir() {
    local id="$1"
    local candidates=(
        "${XDG_CACHE_HOME:-$HOME/.cache}/villode-caelestia/sources/$id"
        "$data_home/components/$id"
        "$cache_home/components/$id"
    )
    local dir
    for dir in "${candidates[@]}"; do
        if [[ -d "$dir/.git" || -d "$dir" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    return 1
}

# Prints "ISO8601|subject" for a commit, or empty.
git_commit_meta() {
    local repo="$1" commit="$2"
    [[ -n "$repo" && -n "$commit" && -d "$repo/.git" ]] || return 0
    if git -C "$repo" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        git -C "$repo" log -1 --format='%cI|%s' "$commit" 2>/dev/null || true
    fi
    return 0
}

# Prints up to 12 subject lines of commits in (from, to].
git_changelog_lines() {
    local repo="$1" from="$2" to="$3"
    [[ -n "$repo" && -n "$to" && -d "$repo/.git" ]] || return 0
    if [[ -n "$from" ]] && git -C "$repo" cat-file -e "${from}^{commit}" 2>/dev/null &&
       git -C "$repo" cat-file -e "${to}^{commit}" 2>/dev/null; then
        git -C "$repo" log --format='%s' --no-merges "${from}..${to}" 2>/dev/null | head -n 12 || true
    elif git -C "$repo" cat-file -e "${to}^{commit}" 2>/dev/null; then
        git -C "$repo" log -1 --format='%s' "$to" 2>/dev/null || true
    fi
    return 0
}

state_mtime_iso() {
    local file="$state_home/$1.tsv"
    if [[ -f "$file" ]]; then
        date -d "@$(stat -c '%Y' "$file")" --iso-8601=seconds 2>/dev/null ||
            date -r "$(stat -c '%Y' "$file")" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true
    fi
    return 0
}

refresh_channel
manifest="$channel_dir/components.tsv"
actionable=()
# JSON rows collected as tab-separated payload for python encoder
json_rows_file="$(mktemp)"
trap 'rm -f "$json_rows_file"' EXIT

while IFS=$'\t' read -r id repo latest name; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    resolve_installed "$id"
    if ! $component_present; then
        status="未安装"
    elif [[ "$installed" != "$latest" ]]; then
        status="有更新"
        actionable+=("$id")
    elif $repair_needed; then
        status="需要修复"
        actionable+=("$id")
    else
        status="已是最新"
    fi
    if [[ "$mode" != check-json ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$name" "${installed:0:7}" "${latest:0:7}" "$status"
    fi

    if [[ "$mode" == check-json ]]; then
        src_dir="$(component_source_dir "$id" || true)"
        installed_meta="$(git_commit_meta "$src_dir" "$installed")"
        latest_meta="$(git_commit_meta "$src_dir" "$latest")"
        installed_at="${installed_meta%%|*}"
        installed_subject=""
        if [[ "$installed_meta" == *"|"* ]]; then
            installed_subject="${installed_meta#*|}"
        fi
        latest_at="${latest_meta%%|*}"
        latest_subject=""
        if [[ "$latest_meta" == *"|"* ]]; then
            latest_subject="${latest_meta#*|}"
        fi
        # Prefer commit author date; fall back to local install state mtime.
        if [[ -z "$installed_at" ]]; then
            installed_at="$(state_mtime_iso "$id")"
        fi
        changes=""
        if [[ "$status" == "有更新" || "$status" == "需要修复" ]]; then
            changes="$(git_changelog_lines "$src_dir" "$installed" "$latest" | paste -sd '|' -)"
        elif [[ -n "$latest_subject" ]]; then
            changes="$latest_subject"
        elif [[ -n "$installed_subject" ]]; then
            changes="$installed_subject"
        fi
        # row: id name installed_short latest_short status installed_full latest_full installed_at latest_at changes_pipe
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$name" "${installed:0:7}" "${latest:0:7}" "$status" \
            "${installed:-}" "${latest:-}" "${installed_at:-}" "${latest_at:-}" "${changes:-}" \
            >> "$json_rows_file"
    fi
done < "$manifest"

if [[ "$mode" == check ]]; then
    exit 0
fi

if [[ "$mode" == check-json ]]; then
    python3 - "$json_rows_file" <<'PY'
import json, sys
from datetime import datetime, timezone

path = sys.argv[1]
components = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        while len(parts) < 10:
            parts.append("")
        (cid, name, inst_s, lat_s, status, inst_f, lat_f, inst_at, lat_at, changes) = parts[:10]
        change_list = [c for c in changes.split("|") if c.strip()] if changes else []
        components.append({
            "id": cid,
            "name": name,
            "installed": inst_s or "—",
            "latest": lat_s or "—",
            "installedFull": inst_f or "",
            "latestFull": lat_f or "",
            "status": status,
            "installedAt": inst_at or "",
            "releasedAt": lat_at or "",
            "changes": change_list,
        })

out = {
    "checkedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
    "components": components,
    "updateCount": sum(1 for c in components if c["status"] in ("有更新", "需要修复")),
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
    exit 0
fi

if ((${#actionable[@]} == 0)); then
    echo
    echo "所有 Villode 组件都已是最新版本。"
    exit 0
fi

optional=()
for id in "${actionable[@]}"; do
    [[ "$id" != shell ]] && optional+=("$id")
done

args=(--keep-existing)
if [[ " ${actionable[*]} " != *" shell "* ]] &&
   grep -q -- '--skip-shell' "$channel_dir/install.sh"; then
    args+=(--skip-shell)
fi
if ((${#optional[@]})); then
    components="$(IFS=,; echo "${optional[*]}")"
    args+=(--components "$components")
else
    args+=(--components shell)
fi

if [[ "$offline_mode" == yes ]]; then
    args+=(--offline --no-deps)
else
    # Older installations have no options file. Use conservative defaults so
    # a component update cannot unexpectedly install system packages.
    case "$(option_value dependencies without)" in
        without) args+=(--no-deps) ;;
        *) args+=(--with-deps) ;;
    esac
fi
[[ "$(option_value start yes)" == no ]] && args+=(--no-start)
if [[ "$(option_value hyprland "$(legacy_hyprland_default)")" == no ]]; then
    args+=(--no-hyprland)
elif [[ "$(option_value session "$(legacy_session_default)")" == no ]]; then
    args+=(--no-session)
fi
[[ "$(option_value native_build yes)" == no ]] && args+=(--no-native-build)

echo
echo "即将同步 ${#actionable[@]} 个 Villode 组件：${actionable[*]}"
if [[ "$offline_mode" == yes ]]; then
    echo "更新源：本地缓存（离线）"
else
    echo "更新源：$remote"
fi
echo

"$channel_dir/install.sh" "${args[@]}"
