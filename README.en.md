# Villode Caelestia

Personal integration of [Caelestia Shell](https://github.com/caelestia-dots/shell) with optional Dock, Desktop, Launcher, and Simplified Chinese UI.

This repository is the **unified installer and release channel**. Component source lives in separate repos; versions are pinned in `components.tsv`.

## Components

| Component | Role | Repository |
| --- | --- | --- |
| Shell | Villode-tracked Caelestia core | [caelestia-shell](https://github.com/u0n0u/caelestia-shell) |
| Chinese (zh) | Simplified Chinese UI pack | [caelestia-zh-cn](https://github.com/u0n0u/caelestia-zh-cn) |
| Dock | macOS-style dock | [villode-dock](https://github.com/u0n0u/villode-dock) |
| Desktop | Wallpaper / HTML desktop layer | [villode-desktop](https://github.com/u0n0u/villode-desktop) |
| Launcher | Launchpad-style app grid | [villode-launcher](https://github.com/u0n0u/villode-launcher) |
| Cursor | Shake-to-find pointer | Ships inside `caelestia-shell` (`contrib/villode-cursor`) |

Pinned revisions are never auto-bumped from upstream. Sync → test → update `components.tsv`.

## Who this is for

- **Existing Hyprland / CachyOS desktop** — install beside your current session (default keeps the old shell).
- **Bare system / TTY only** — no desktop yet. The installer can pull Hyprland, SDDM, GTK/Qt stacks, daily apps, and a `Villode Hyprland` login entry. After install, reboot and pick **Villode Hyprland** at the greeter.
- **Partial installs** — only Dock / Launcher / zh, etc.

## Prerequisites

| Item | Notes |
| --- | --- |
| Arch / CachyOS (pacman) | Primary target; AUR helper used for a few packages (e.g. Chrome) |
| `git`, `sudo` | Required for online install with deps |
| Network | Or use `--offline` with a prefilled cache |

On a **minimal / TTY** machine the installer (with default `--with-deps`) will try to install:

- Compositor & session: `hyprland`, `uwsm`, **`sddm`**, portals, PipeWire, NetworkManager  
- UI toolkits: **GTK3 / GTK4**, `gtk4-layer-shell`, Qt6 (needed by Dock/Desktop/Shell stack)  
- Daily apps (if missing): terminal (`alacritty`), file manager (`thunar`), player (`mpv`), image viewer (`imv`/`loupe`), browser (`google-chrome` via AUR or `firefox`)  
- Chinese input (when zh or full session): `fcitx5` + pinyin + CJK fonts. On Wayland **do not** set `GTK_IM_MODULE` (use text-input-v3); UWSM `env` unsets any stale value from the long-lived `user@` manager; session startup avoids `dbus-update-activation-environment --all`

If a package is unavailable, it is skipped with a message instead of aborting the whole install.

## Quick start

### From a graphical session

```bash
git clone https://github.com/u0n0u/villode-caelestia.git
cd villode-caelestia
./install.sh --all
```

Log out and choose **Villode Hyprland** in SDDM (or your display manager).

### From a TTY (no desktop)

```bash
# Log in on tty1, then:
git clone https://github.com/u0n0u/villode-caelestia.git
cd villode-caelestia
./install.sh --all
# When prompted, pick GitHub mirror if github.com is slow.
sudo reboot
# At SDDM: select "Villode Hyprland"
```

On TTY the installer **does not try to start** Quickshell/Dock (there is no Wayland compositor yet). It enables SDDM and prints reboot instructions.

### Interactive (choose components)

```bash
./install.sh
```

Shell is always installed. Optional: zh, dock, desktop, launcher, cursor.

## Common options

```bash
./install.sh --all                      # everything + independent session
./install.sh --all --replace-existing   # also migrate away from Noctalia/Waybar/…
./install.sh --all --keep-existing      # default: keep old desktop shell packages
./install.sh --all --no-session         # components only, no Villode login session
./install.sh --components zh,dock,launcher
./install.sh --all --no-deps            # do not install system packages
./install.sh --all --offline            # use local locked cache only
./install.sh --all --no-start           # deploy files, do not launch apps
./install.sh --github-source kkgithub.com
./install.sh --probe-github             # speed-test mirrors, then choose
```

```text
./install.sh --help
```

Help text is bilingual (中文 + English).

## Default applications (smart detection)

After packages are installed, the installer writes `~/.config/caelestia/shell.json` → `general.apps`:

| Key | Detection order (first existing binary wins) |
| --- | --- |
| `terminal` | alacritty, kitty, foot, wezterm, gnome-terminal, … |
| `explorer` | nautilus, dolphin, thunar, nemo, … |
| `browser` | google-chrome-stable, chromium, firefox, … |
| `playback` | mpv, vlc, … |
| `audio` | pavucontrol, … |

Rules:

1. **Only fill missing or broken values** (e.g. default `foot`/`thunar` when not installed, or old `villode-*` wrapper names).  
2. **Never overwrite** a value the user already set in Settings if that command still exists.  
3. Also updates `mimeapps.list` for directories, browser, video, and images when empty.  
4. Shortcuts (Super+Return, Super+E, …) use these **real system commands**, not wrapper names.

Change defaults anytime in **Settings → default apps**; reinstall will respect your choices.

## Chinese input (Wayland / fcitx5)

When Chinese UI or a full session is installed:

- Packages: `fcitx5`, `fcitx5-chinese-addons`, gtk/qt modules, CJK fonts  
- Env written by installer:
  - `~/.config/environment.d/90-villode-fcitx5.conf` — `QT_IM_MODULE` / `XMODIFIERS` / `SDL_IM_MODULE` only (**no `GTK_IM_MODULE`**)
  - `~/.config/uwsm/env` and `env-hyprland` — `unset GTK_IM_MODULE` so a previous session’s value does not stick in `user@`
  - Hyprland session: same vars; starts `env -u GTK_IM_MODULE fcitx5 -d`
- Session uses an explicit `dbus-update-activation-environment` list, **not** `--all` (which would re-export a stale `GTK_IM_MODULE` from the compositor process)
- After install, a full logout (or reboot from TTY) is better than only restarting the compositor if IM env still looks wrong

## Updates

Settings → **Villode updates**, or:

```bash
villode-caelestia-update --check
villode-caelestia-update
```

If GitHub is slow, the installer speed-tests mirrors at install time; the choice is stored and reused. See also `VILLODE_GITHUB_MIRRORS`, `VILLODE_GITHUB_SOURCE`, `VILLODE_GIT_TIMEOUT`.

Hosts-based acceleration (e.g. [github-hosts](https://github.com/maxiaof/github-hosts)) can complement mirrors.

## Shell watchdog

The session starts `villode-caelestia-shell-guard` instead of a one-shot `caelestia shell -d`, so a crashed Quickshell is restarted automatically.

```bash
villode-caelestia-shell-guard status
villode-caelestia-shell-guard restart
```

Log: `~/.local/state/villode-caelestia/shell-guard.log`

## Logout

Power menu → Log out runs `villode-logout` (stop shell guard, then `uwsm stop`) so you return to SDDM cleanly under UWSM sessions.

## Uninstall

```bash
villode-caelestia-uninstall
villode-caelestia-uninstall --all
```

## TTY / headless checklist

1. Run `./install.sh --all` as a normal user with sudo.  
2. Wait for package install + component deploy (can take a while).  
3. Confirm SDDM is enabled: `systemctl is-enabled sddm`.  
4. `sudo reboot`.  
5. At greeter, select **Villode Hyprland**.  
6. Optional: open Settings → Villode updates; set default apps if auto-detect was wrong.  

If install finishes but no greeter appears, check:

```bash
systemctl status sddm
ls /usr/local/share/wayland-sessions/
cat ~/.config/villode-hyprland/hyprland.conf | head
```

## License

Installer: MIT. Installed components keep their own licenses (Caelestia Shell is GPL-3.0-only).

中文说明见 [README.md](README.md)。
