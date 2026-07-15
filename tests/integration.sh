#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_line() {
    local output="$1" id="$2" expected="$3"
    awk -F '\t' -v id="$id" -v expected="$expected" \
        '$1 == id && NF == 5 && $5 == expected { found=1 } END { exit !found }' \
        <<< "$output" || fail "$id 应为 $expected"
}

test_update_repairs_real_revision() {
    local root="$work/update" output
    mkdir -p "$root/home/.local/bin" \
        "$root/config/quickshell/caelestia" \
        "$root/state/villode-caelestia" \
        "$root/state/villode-caelestia-shell" \
        "$root/data/villode-caelestia/release" \
        "$root/data/villode-caelestia/components/dock"
    install -m755 "$repo_dir/install.sh" "$root/data/villode-caelestia/release/install.sh"
    printf '%s\n' \
        $'# id\trepository\tcommit\tname' \
        $'shell\thttps://invalid/shell\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tShell' \
        $'zh\thttps://invalid/zh\t1111111111111111111111111111111111111111\tZh' \
        $'dock\thttps://invalid/dock\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tDock' \
        $'desktop\thttps://invalid/desktop\t2222222222222222222222222222222222222222\tDesktop' \
        $'launcher\thttps://invalid/launcher\t3333333333333333333333333333333333333333\tLauncher' \
        > "$root/data/villode-caelestia/release/components.tsv"
    printf '%s\n' 'offline=yes' > "$root/state/villode-caelestia/install-options"
    printf '%s\t%s\t%s\n' shell aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa Shell \
        > "$root/state/villode-caelestia/shell.tsv"
    printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        > "$root/state/villode-caelestia-shell/revision"
    printf '%s\n' 'Revision: dddddddddddddddddddddddddddddddddddddddd' \
        > "$root/config/quickshell/caelestia/.villode-managed"
    printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
        > "$root/data/villode-caelestia/components/dock/revision"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/home/.local/bin/villode-dock"
    chmod +x "$root/home/.local/bin/villode-dock"

    output="$(
        HOME="$root/home" \
        XDG_CONFIG_HOME="$root/config" \
        XDG_STATE_HOME="$root/state" \
        XDG_DATA_HOME="$root/data" \
        XDG_CACHE_HOME="$root/cache" \
            "$repo_dir/update.sh" --check
    )"
    assert_line "$output" shell '需要修复'
    assert_line "$output" dock '需要修复'
    assert_line "$output" desktop '未安装'
}

test_offline_no_hyprland_installs_successfully() {
    local root="$work/success" channel cache shell_source shell_commit
    channel="$root/channel"
    cache="$root/cache/villode-caelestia/sources"
    shell_source="$cache/shell"
    mkdir -p "$channel/session" "$shell_source" "$root/home" "$root/state" "$root/data"
    install -m755 "$repo_dir/install.sh" "$channel/install.sh"
    install -m755 "$repo_dir/uninstall.sh" "$channel/uninstall.sh"
    install -m755 "$repo_dir/update.sh" "$channel/update.sh"
    cp -a "$repo_dir/session/." "$channel/session/"

    git -C "$shell_source" init -q
    mkdir -p "$shell_source"/{assets,components,i18n,modules,services,utils}
    printf '%s\n' qm > "$shell_source/i18n/qml_zh_CN.qm"
    printf '%s\n' 'Item {}' > "$shell_source/shell.qml"
    printf '%s\n' v1 > "$shell_source/UPSTREAM_VERSION"
    cat > "$shell_source/install-villode.sh" <<'SH'
#!/usr/bin/env bash
set -e
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/caelestia"
printf 'Revision: %s\n' "$(git rev-parse HEAD)" \
  > "${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/caelestia/.villode-managed"
touch "$HOME/shell-installed"
SH
    printf '#!/usr/bin/env bash\nexit 0\n' > "$shell_source/uninstall-villode.sh"
    chmod +x "$shell_source/install-villode.sh" "$shell_source/uninstall-villode.sh"
    git -C "$shell_source" add .
    git -C "$shell_source" -c user.name=test -c user.email=test@example.invalid \
        commit -qm shell
    shell_commit="$(git -C "$shell_source" rev-parse HEAD)"
    printf '# id\trepository\tcommit\tname\n' > "$channel/components.tsv"
    printf 'shell\thttps://invalid/shell\t%s\tShell\n' "$shell_commit" \
        >> "$channel/components.tsv"

    HOME="$root/home" XDG_CONFIG_HOME="$root/config" \
    XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
    XDG_CACHE_HOME="$root/cache" \
        "$channel/install.sh" --components shell --offline --no-deps \
        --no-start --no-hyprland --no-native-build --keep-existing >/dev/null
    [[ -e "$root/home/shell-installed" ]] || fail '离线无 Hyprland 安装未执行 Shell'
    [[ -f "$root/state/villode-caelestia/shell.tsv" ]] || fail '成功安装未发布 Shell 状态'
}

test_operation_lock_rejects_concurrent_update() {
    local root="$work/operation-lock" lock holder rc=0 held=false
    lock="$root/state/villode-caelestia/operation.lock"
    mkdir -p "$(dirname "$lock")"
    flock "$lock" sleep 1 &
    holder=$!
    for _ in {1..50}; do
        if ! flock --nonblock "$lock" true; then
            held=true
            break
        fi
        sleep 0.01
    done
    $held || fail '测试进程未取得操作锁'
    HOME="$root/home" XDG_STATE_HOME="$root/state" \
    XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache" \
        "$repo_dir/update.sh" --check >/dev/null 2>&1 || rc=$?
    wait "$holder"
    [[ "$rc" == 75 ]] || fail "并发更新应返回 75，实际为 $rc"
}

test_update_reuses_install_options() {
    local root="$work/options" args_file
    mkdir -p "$root/home/.local/bin" "$root/state/villode-caelestia" \
        "$root/data/villode-caelestia/release" \
        "$root/data/villode-caelestia/components/dock"
    args_file="$root/install-args"
    printf '#!/usr/bin/env bash\n# supports --skip-shell\nprintf "%%s\\n" "$@" > "%s"\n' "$args_file" \
        > "$root/data/villode-caelestia/release/install.sh"
    chmod +x "$root/data/villode-caelestia/release/install.sh"
    printf '%s\n' \
        $'# id\trepository\tcommit\tname' \
        $'dock\thttps://invalid/dock\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tDock' \
        > "$root/data/villode-caelestia/release/components.tsv"
    printf '%s\n' \
        'offline=yes' 'dependencies=with' 'start=no' 'hyprland=no' \
        'session=yes' 'native_build=no' \
        > "$root/state/villode-caelestia/install-options"
    printf '%s\t%s\t%s\n' dock aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa Dock \
        > "$root/state/villode-caelestia/dock.tsv"
    printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        > "$root/data/villode-caelestia/components/dock/revision"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/home/.local/bin/villode-dock"
    chmod +x "$root/home/.local/bin/villode-dock"

    HOME="$root/home" XDG_STATE_HOME="$root/state" \
    XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache" \
        "$repo_dir/update.sh" >/dev/null
    for expected in --skip-shell --components dock --offline --no-deps \
        --no-start --no-hyprland --no-native-build; do
        grep -Fxq -- "$expected" "$args_file" || fail "更新未复用选项：$expected"
    done
}

test_preflight_failure_preserves_existing_desktop() {
    local root="$work/preflight" channel cache shell_source zh_source shell_commit zh_commit rc
    root="$work/preflight"
    channel="$root/channel"
    cache="$root/cache/villode-caelestia/sources"
    shell_source="$cache/shell"
    zh_source="$cache/zh"
    mkdir -p "$channel" "$shell_source" "$zh_source" \
        "$root/home/.config/waybar" "$root/state" "$root/data"
    install -m755 "$repo_dir/install.sh" "$channel/install.sh"

    git -C "$shell_source" init -q
    mkdir -p "$shell_source"/{assets,components,i18n,modules,services,utils}
    printf '%s\n' qm > "$shell_source/i18n/qml_zh_CN.qm"
    printf '%s\n' 'Item { property string text: "hello" }' > "$shell_source/shell.qml"
    printf '%s\n' v1 > "$shell_source/UPSTREAM_VERSION"
    printf '#!/usr/bin/env bash\ntouch "$HOME/shell-installed"\n' \
        > "$shell_source/install-villode.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$shell_source/uninstall-villode.sh"
    chmod +x "$shell_source/install-villode.sh" "$shell_source/uninstall-villode.sh"
    git -C "$shell_source" add .
    git -C "$shell_source" -c user.name=test -c user.email=test@example.invalid \
        commit -qm shell
    shell_commit="$(git -C "$shell_source" rev-parse HEAD)"

    git -C "$zh_source" init -q
    mkdir -p "$zh_source/bin" "$zh_source/i18n"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$zh_source/install.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$zh_source/uninstall.sh"
    printf '#!/usr/bin/env bash\n[[ -f "${4:-}/services/UiLanguage.qml" ]] || exit 65\n' \
        > "$zh_source/bin/caelestia-zh-apply"
    printf '%s\n' qm > "$zh_source/i18n/qml_zh_CN.qm"
    printf '%s\n' ts > "$zh_source/i18n/qml_zh_CN.ts"
    printf '%s\n' '{}' > "$zh_source/i18n/zh_CN.json"
    chmod +x "$zh_source/install.sh" "$zh_source/uninstall.sh" \
        "$zh_source/bin/caelestia-zh-apply"
    git -C "$zh_source" add .
    git -C "$zh_source" -c user.name=test -c user.email=test@example.invalid \
        commit -qm zh
    zh_commit="$(git -C "$zh_source" rev-parse HEAD)"

    printf '# id\trepository\tcommit\tname\n' > "$channel/components.tsv"
    printf 'shell\thttps://invalid/shell\t%s\tShell\n' "$shell_commit" \
        >> "$channel/components.tsv"
    printf 'zh\thttps://invalid/zh\t%s\tZh\n' "$zh_commit" \
        >> "$channel/components.tsv"
    printf '%s\n' old > "$root/home/.config/waybar/config"

    rc=0
    HOME="$root/home" \
    XDG_STATE_HOME="$root/state" \
    XDG_DATA_HOME="$root/data" \
    XDG_CACHE_HOME="$root/cache" \
        "$channel/install.sh" --components zh --offline --no-start \
        --no-hyprland --replace-existing >/dev/null 2>&1 || rc=$?
    [[ "$rc" == 65 ]] || fail "不兼容预检退出码应为 65，实际为 $rc"
    [[ -f "$root/home/.config/waybar/config" ]] || fail '预检失败后旧桌面被删除'
    [[ ! -e "$root/home/shell-installed" ]] || fail '预检失败后仍执行了组件安装'
    if find "$root/state/villode-caelestia" -name '*.tsv' -print -quit 2>/dev/null | grep -q .; then
        fail '预检失败后写入了组件状态'
    fi
}

test_partial_uninstall_rebuilds_session() {
    local root="$work/uninstall" state data home fake
    root="$work/uninstall"
    home="$root/home"
    state="$root/state/villode-caelestia"
    data="$root/data/villode-caelestia"
    fake="$root/fake-bin"
    mkdir -p "$home/.local/bin" "$home/.config/caelestia" \
        "$home/.config/villode-hyprland" "$state/migration-backups/keep" \
        "$data/release/session" "$fake"
    install -m644 "$repo_dir/session/villode-hyprland.conf" \
        "$data/release/session/villode-hyprland.conf"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/sudo"
    chmod +x "$fake/sudo"
    for id in shell dock; do
        mkdir -p "$data/components/$id"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$data/components/$id/uninstall.sh"
        chmod +x "$data/components/$id/uninstall.sh"
        printf '%s\t%s\t%s\n' "$id" deadbeef "$id" > "$state/$id.tsv"
    done
    : > "$state/session-managed"
    printf '%s\n' '{"present":true,"value":["loginctl","terminate-user"]}' \
        > "$state/logout-backup.json"
    printf '%s\n' '{"session":{"commands":{"logout":["uwsm","stop"]}}}' \
        > "$home/.config/caelestia/shell.json"
    printf '%s\n' keep > "$state/migration-backups/keep/sentinel"
    : > "$home/.local/bin/villode-caelestia-update"
    : > "$home/.local/bin/villode-caelestia-uninstall"

    HOME="$home" XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
        PATH="$fake:$PATH" "$repo_dir/uninstall.sh" --components dock
    grep -q 'exec-once = caelestia shell -d' \
        "$home/.config/villode-hyprland/hyprland.conf" || fail 'Shell 自启动被误删'
    if grep -q 'exec-once = villode-dock --daemon' \
        "$home/.config/villode-hyprland/hyprland.conf"; then
        fail 'Dock 自启动未按部分卸载移除'
    fi

    HOME="$home" XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
        PATH="$fake:$PATH" "$repo_dir/uninstall.sh" --components shell
    [[ -f "$state/migration-backups/keep/sentinel" ]] || fail '迁移备份被删除'
    [[ ! -e "$home/.local/bin/villode-caelestia-update" ]] || fail '更新命令未清理'
    python3 - "$home/.config/caelestia/shell.json" <<'PY' || fail '注销命令未恢复'
import json
import sys
assert json.load(open(sys.argv[1]))["session"]["commands"]["logout"] == ["loginctl", "terminate-user"]
PY
}

test_full_uninstall_removes_cursor() {
    local root state data home fake
    root="$work/uninstall-cursor"
    home="$root/home"
    state="$root/state/villode-caelestia"
    data="$root/data/villode-caelestia"
    fake="$root/fake-bin"
    mkdir -p "$home/.local/bin" "$state" "$fake"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/sudo"
    chmod +x "$fake/sudo"
    mkdir -p "$data/components/shell"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$data/components/shell/uninstall.sh"
    chmod +x "$data/components/shell/uninstall.sh"
    printf '%s\t%s\t%s\n' shell deadbeef Shell > "$state/shell.tsv"
    mkdir -p "$data/components/cursor"
    # Mirror the real cursor uninstaller: it removes the shake binary itself.
    printf '#!/usr/bin/env bash\nrm -f "$HOME/.local/bin/villode-cursor-shake"\n' \
        > "$data/components/cursor/uninstall.sh"
    chmod +x "$data/components/cursor/uninstall.sh"
    printf '%s\t%s\t%s\n' cursor deadbeef Cursor > "$state/cursor.tsv"
    : > "$home/.local/bin/villode-cursor-shake"
    chmod +x "$home/.local/bin/villode-cursor-shake"

    HOME="$home" XDG_STATE_HOME="$root/state" XDG_DATA_HOME="$root/data" \
        PATH="$fake:$PATH" "$repo_dir/uninstall.sh" --all
    [[ ! -e "$home/.local/bin/villode-cursor-shake" ]] || fail 'cursor 未随 --all 卸载'
    [[ ! -f "$state/cursor.tsv" ]] || fail 'cursor 状态记录残留'
    [[ ! -e "$data" ]] || fail '全量卸载后数据目录残留'
    [[ ! -e "$state" ]] || fail '全量卸载后状态目录残留'
}

test_update_skips_missing_components_by_default() {
    local root="$work/update-missing" args_file output
    mkdir -p "$root/home/.local/bin" "$root/state/villode-caelestia" \
        "$root/data/villode-caelestia/release" \
        "$root/data/villode-caelestia/components/dock"
    args_file="$root/install-args"
    printf '#!/usr/bin/env bash\n# supports --skip-shell\nprintf "%%s\\n" "$@" > "%s"\n' "$args_file" \
        > "$root/data/villode-caelestia/release/install.sh"
    chmod +x "$root/data/villode-caelestia/release/install.sh"
    printf '%s\n' \
        $'# id\trepository\tcommit\tname' \
        $'dock\thttps://invalid/dock\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tDock' \
        $'desktop\thttps://invalid/desktop\t2222222222222222222222222222222222222222\tDesktop' \
        > "$root/data/villode-caelestia/release/components.tsv"
    printf '%s\n' 'offline=yes' > "$root/state/villode-caelestia/install-options"
    printf '%s\t%s\t%s\n' dock bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb Dock \
        > "$root/state/villode-caelestia/dock.tsv"
    printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
        > "$root/data/villode-caelestia/components/dock/revision"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/home/.local/bin/villode-dock"
    chmod +x "$root/home/.local/bin/villode-dock"

    output="$(
        HOME="$root/home" XDG_STATE_HOME="$root/state" \
        XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache" \
            "$repo_dir/update.sh"
    )"
    [[ ! -e "$args_file" ]] || fail '默认更新不应安装未安装组件'
    grep -q 'install-missing' <<< "$output" || fail '默认更新未提示 --install-missing'

    HOME="$root/home" XDG_STATE_HOME="$root/state" \
    XDG_DATA_HOME="$root/data" XDG_CACHE_HOME="$root/cache" \
        "$repo_dir/update.sh" --install-missing >/dev/null
    [[ -f "$args_file" ]] || fail '--install-missing 未执行安装'
    grep -Fxq -- '--components' "$args_file" || fail '--install-missing 未传递组件参数'
    grep -Fxq -- 'desktop' "$args_file" || fail '--install-missing 未安装缺失组件'
    grep -Fxq -- '--skip-shell' "$args_file" || fail '--install-missing 不应重装 Shell'
}

test_restart_shell_retries_already_running() {
    local root="$work/restart-shell" fake log pid_file
    root="$work/restart-shell"
    fake="$root/fake-bin"
    log="$root/install.log"
    pid_file="$root/fake-shell.pid"
    mkdir -p "$fake" "$root/home/.local/bin" "$root/home/.local/lib/caelestia/bin" "$root/state"

    # Extract only the restart helpers from install.sh so we can unit-test the
    # already-running race without running a full component install.
    # Copy the restart helper block up to, but not including, prepare_sources.
    awk '
        /^caelestia_cli\(\)/ {keep=1}
        keep && /^prepare_sources$/ {exit}
        keep {print}
    ' "$repo_dir/install.sh" > "$root/helpers.sh"
    grep -q 'restart_caelestia_shell' "$root/helpers.sh" || fail '未提取到 restart helpers'

    cat > "$fake/caelestia" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state_dir="${VILLODE_TEST_STATE:?}"
log="${VILLODE_TEST_LOG:?}"
pid_file="${VILLODE_TEST_PID:?}"
cmd="${1:-}"
sub="${2:-}"
if [[ "$cmd" == shell && "$sub" == -k ]]; then
    if [[ -f "$pid_file" ]]; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
    fi
    exit 0
fi
if [[ "$cmd" == shell && "$sub" == -d ]]; then
    attempt_file="$state_dir/start-attempt"
    attempt=0
    [[ -f "$attempt_file" ]] && attempt="$(cat "$attempt_file")"
    attempt=$((attempt + 1))
    printf '%s\n' "$attempt" > "$attempt_file"
    if (( attempt == 1 )); then
        # First start pretends another instance still owns the config. The old
        # installer treated this as success and left the desktop without a shell.
        # Write only to stdout; the restart helper owns the install log.
        printf '%s\n' 'An instance of this configuration is already running.'
        exit 0
    fi
    # Second start launches a long-lived process and records its pid. qs list
    # will report this as the live Caelestia instance.
    sleep 3600 &
    echo $! > "$pid_file"
    printf '%s\n' 'started'
    exit 0
fi
echo "unexpected caelestia args: $*" >&2
exit 64
SH
    chmod +x "$fake/caelestia"

    cat > "$fake/qs" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
pid_file="${VILLODE_TEST_PID:?}"
if [[ "${1:-}" == -c && "${2:-}" == caelestia && "${3:-}" == list ]]; then
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        pid="$(cat "$pid_file")"
        printf '[{"config_path":"/tmp/caelestia/shell.qml","id":"test","pid":%s,"shell_id":"test"}]\n' "$pid"
    else
        printf '[]\n'
    fi
    exit 0
fi
if [[ "${1:-}" == -c && "${2:-}" == caelestia && "${3:-}" == kill ]]; then
    if [[ -f "$pid_file" ]]; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
    fi
    exit 0
fi
exit 0
SH
    chmod +x "$fake/qs"
    install -m755 "$fake/caelestia" "$root/home/.local/bin/caelestia"
    install -m755 "$fake/qs" "$root/home/.local/lib/caelestia/bin/qs"

    HOME="$root/home" \
    PATH="$fake:$PATH" \
    VILLODE_TEST_STATE="$root/state" \
    VILLODE_TEST_LOG="$log" \
    VILLODE_TEST_PID="$pid_file" \
    bash -c '
        set -euo pipefail
        # shellcheck disable=SC1091
        source "'"$root"'/helpers.sh"
        restart_caelestia_shell "'"$log"'"
    ' || fail 'restart_caelestia_shell 应在 already-running 后重试成功'

    [[ -f "$pid_file" ]] || fail '未启动伪 shell 进程'
    kill -0 "$(cat "$pid_file")" 2>/dev/null || fail '伪 shell 进程不在运行'
    grep -q 'restart attempt 1: start reported an existing instance' "$log" \
        || fail '未记录 already-running 重试'
    kill "$(cat "$pid_file")" 2>/dev/null || true
}

test_update_repairs_real_revision
test_update_reuses_install_options
test_update_skips_missing_components_by_default
test_preflight_failure_preserves_existing_desktop
test_offline_no_hyprland_installs_successfully
test_operation_lock_rejects_concurrent_update
test_partial_uninstall_rebuilds_session
test_full_uninstall_removes_cursor
test_restart_shell_retries_already_running
echo 'integration tests: ok'
