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
    mkdir -p "$shell_source"/{assets,components,modules,services,utils}
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
        --no-start --no-hyprland --no-native-build >/dev/null
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
    mkdir -p "$shell_source"/{assets,components,modules,services,utils}
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
    mkdir -p "$zh_source/bin" "$zh_source/patches"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$zh_source/install.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$zh_source/uninstall.sh"
    printf '#!/usr/bin/env bash\nif [[ "${1:-}" == --help ]]; then echo usage; fi\n' \
        > "$zh_source/bin/caelestia-zh-apply"
    printf '%s\n' \
        'diff --git a/shell.qml b/shell.qml' \
        '--- a/shell.qml' \
        '+++ b/shell.qml' \
        '@@ -1 +1 @@' \
        '-Item { property string text: "different" }' \
        '+Item { property string text: "中文" }' \
        > "$zh_source/patches/zh-cn-ui.patch"
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

test_update_repairs_real_revision
test_update_reuses_install_options
test_preflight_failure_preserves_existing_desktop
test_offline_no_hyprland_installs_successfully
test_operation_lock_rejects_concurrent_update
test_partial_uninstall_rebuilds_session
echo 'integration tests: ok'
