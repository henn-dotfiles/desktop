# henn-desktop

Builds and installs the patched desktop stack on Ubuntu 26.04:

| Component | Fork | Installed to |
|---|---|---|
| wlroots 0.20.2 | [henn-dotfiles/wlroots](https://github.com/henn-dotfiles/wlroots) | `/opt/henn/lib` |
| labwc 0.20.3 | [henn-dotfiles/labwc](https://github.com/henn-dotfiles/labwc) | `/opt/henn/bin/labwc` |
| DMS 2.1.0 | [henn-dotfiles/dux-shell](https://github.com/henn-dotfiles/dux-shell) | `/opt/henn/bin/dms` |

Each patch is a commit on a `henn/<name>` branch of its fork. The forks merge
their patch branches into `henn/main`, and `PATCHED.md` in each fork lists
the patches. This repo only pins which commit of each fork to build
(`versions.env`).

## Install

On a fresh Ubuntu 26.04:

```sh
git clone https://github.com/henn-dotfiles/desktop.git
cd desktop
./install.sh
```

The script:

1. Adds the DMS PPAs (`ppa:avengemedia/dms`, `ppa:avengemedia/danklinux`)
   and installs the build dependencies, Go and the `dms` package.
2. Clones the forks at the pinned commits into `~/.cache/henn-desktop/src`.
3. Builds wlroots into `/opt/henn`, then labwc against it. labwc finds this
   wlroots through its rpath, so the apt `libwlroots` is left alone.
4. Builds the `dms` binary from the fork with the patched QML shell embedded,
   installs it to `/opt/henn/bin/dms` and diverts `/usr/bin/dms` to it with
   `dpkg-divert`. The apt `dms` package still supplies quickshell, the other
   runtime dependencies and the systemd user unit. apt upgrades of `dms` put
   their binary at `/usr/bin/dms.distrib` and do not replace the patched one.
5. Restarts the `dms` user service if it is running.

The installed pins are recorded in `/opt/henn/share/henn-desktop/installed.env`.
Running `./install.sh` again rebuilds only the components whose pin changed.

Options: `--skip-apt` skips step 1, `--force` rebuilds everything, and
component names (`wlroots`, `labwc`, `dms`) limit the run to those.
`PREFIX` and `HENN_SRC` override the install and source directories.

Start the session with `/opt/henn/bin/labwc`. The session entry and its
launcher (NVIDIA/HDMI handling) are in
[henn-dotfiles/dotfiles](https://github.com/henn-dotfiles/dotfiles).

## Adding a patch

1. In the fork, branch `henn/<name>` off the upstream release tag, commit the
   patch, and merge it with `--no-ff` into `henn/main`. Add it to `PATCHED.md`.
2. Push both branches.
3. Put the new `henn/main` commit in `versions.env` and commit it here.
4. Run `./install.sh`.

## Upgrading upstream

Rebase each `henn/*` branch of the fork onto the new release tag, rebuild
`henn/main` from the tag, merge the patch branches again (see the fork's
`PATCHED.md`), then bump the pin here. A wlroots bump usually needs the
matching labwc release.

## Uninstall

```sh
sudo rm /usr/bin/dms
sudo dpkg-divert --rename --remove /usr/bin/dms
sudo rm -rf /opt/henn
```
