#!/usr/bin/env bash
# Build and install the patched desktop stack pinned in versions.env:
#   wlroots + labwc  -> $PREFIX (labwc finds wlroots through its rpath)
#   dms              -> $PREFIX/bin/dms (patched QML shell embedded); /usr/bin/dms
#                       is diverted to it, the apt dms package only supplies
#                       dependencies and the systemd user unit
# Run it again after changing versions.env; parts whose pin did not change are skipped.
#
# Usage: ./install.sh [--skip-apt] [--force] [component...]
#   component: wlroots, labwc, dms (default: all)
#   --skip-apt  do not add PPAs or install packages
#   --force     rebuild even if the installed pin matches
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
. ./versions.env

PREFIX=${PREFIX:-/opt/henn}
SRC=${HENN_SRC:-${XDG_CACHE_HOME:-$HOME/.cache}/henn-desktop/src}
STATE=$PREFIX/share/henn-desktop/installed.env

skip_apt=
force=
components=()
for arg in "$@"; do
    case $arg in
    --skip-apt) skip_apt=1 ;;
    --force) force=1 ;;
    wlroots | labwc | dms) components+=("$arg") ;;
    -h | --help)
        sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown argument: $arg" >&2
        exit 2
        ;;
    esac
done
[ ${#components[@]} -gt 0 ] || components=(wlroots labwc dms)

SUDO=
[ "$(id -u)" -eq 0 ] || SUDO=sudo

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

wants() {
    local c
    for c in "${components[@]}"; do [ "$c" = "$1" ] && return 0; done
    return 1
}

installed_ref() {
    [ -r "$STATE" ] && sed -n "s/^$1=//p" "$STATE"
}

up_to_date() {
    [ -z "$force" ] && [ "$(installed_ref "$1")" = "$2" ]
}

record_ref() {
    local tmp
    tmp=$(mktemp)
    { [ -r "$STATE" ] && grep -v "^$1=" "$STATE"; echo "$1=$2"; } >"$tmp" || true
    $SUDO install -Dm644 "$tmp" "$STATE"
    rm -f "$tmp"
}

# fetch <dir> <repo> <ref>: clone or update a checkout and detach it at ref.
fetch() {
    local dir=$SRC/$1
    if [ ! -d "$dir/.git" ]; then
        git clone --filter=blob:none "$2" "$dir"
    fi
    git -C "$dir" remote set-url origin "$2"
    git -C "$dir" fetch --tags origin
    git -C "$dir" checkout --detach --force "$3"
}

# meson_build <dir> <meson setup args...>: configure fresh, build, install.
meson_build() {
    local dir=$1
    shift
    rm -rf "$dir/build"
    meson setup "$dir/build" "$dir" "$@"
    ninja -C "$dir/build"
    $SUDO ninja -C "$dir/build" install
}

install_packages() {
    log "Adding the DMS PPAs and installing packages"
    $SUDO apt-get update
    $SUDO apt-get install -y software-properties-common git
    $SUDO add-apt-repository -y ppa:avengemedia/dms
    $SUDO add-apt-repository -y ppa:avengemedia/danklinux

    # Build dependencies of wlroots 0.20 and labwc 0.20.
    $SUDO apt-get install -y --no-install-recommends \
        build-essential meson ninja-build pkg-config cmake gettext scdoc \
        wayland-protocols libwayland-dev libdrm-dev libpixman-1-dev \
        libxkbcommon-dev libudev-dev libseat-dev libinput-dev \
        libdisplay-info-dev libliftoff-dev hwdata libgbm-dev libegl-dev \
        libgles-dev libvulkan-dev glslang-tools liblcms2-dev \
        libxcb1-dev libxcb-composite0-dev libxcb-ewmh-dev libxcb-icccm4-dev \
        libxcb-render0-dev libxcb-res0-dev libxcb-xfixes0-dev \
        libxcb-errors-dev xwayland \
        libxml2-dev libglib2.0-dev libcairo2-dev libpango1.0-dev \
        librsvg2-dev libpng-dev libsfdo-dev

    # dms is built from the fork (Go, toolchain version from its go.mod).
    # The apt dms package still brings quickshell, the runtime dependencies
    # and the systemd user unit.
    $SUDO apt-get install -y --no-install-recommends golang-go make
    $SUDO apt-get install -y dms
}

build_wlroots() {
    if up_to_date WLROOTS "$WLROOTS_REF"; then
        log "wlroots is already at $WLROOTS_REF"
        return
    fi
    log "Building wlroots $WLROOTS_REF"
    fetch wlroots "$WLROOTS_REPO" "$WLROOTS_REF"
    meson_build "$SRC/wlroots" --prefix="$PREFIX" --libdir=lib \
        --buildtype=release -Dexamples=false -Dxwayland=enabled
    record_ref WLROOTS "$WLROOTS_REF"
    # labwc must be relinked against the new wlroots.
    force_labwc=1
}

build_labwc() {
    if [ -z "${force_labwc:-}" ] && up_to_date LABWC "$LABWC_REF"; then
        log "labwc is already at $LABWC_REF"
        return
    fi
    log "Building labwc $LABWC_REF"
    fetch labwc "$LABWC_REPO" "$LABWC_REF"
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" meson_build "$SRC/labwc" \
        --prefix="$PREFIX" --buildtype=release \
        -Dc_link_args="-Wl,-rpath,$PREFIX/lib" -Dxwayland=enabled
    if ! ldd "$PREFIX/bin/labwc" | grep -q "$PREFIX/lib/libwlroots"; then
        echo "labwc is not linked to $PREFIX/lib/libwlroots" >&2
        exit 1
    fi
    record_ref LABWC "$LABWC_REF"
}

divert_dms() {
    # Keep apt's binary as /usr/bin/dms.distrib (also on later dms upgrades)
    # and point /usr/bin/dms at ours, so the unit and `dms ipc` use it.
    if [ "$(dpkg-divert --truename /usr/bin/dms)" != /usr/bin/dms.distrib ]; then
        $SUDO dpkg-divert --local --rename --divert /usr/bin/dms.distrib --add /usr/bin/dms
    fi
    $SUDO ln -sfn "$PREFIX/bin/dms" /usr/bin/dms
}

install_dms() {
    if up_to_date DMS "$DMS_REF" && [ "$(readlink /usr/bin/dms)" = "$PREFIX/bin/dms" ]; then
        log "dms is already at $DMS_REF"
        return
    fi
    log "Building dms $DMS_REF"
    fetch dms "$DMS_REPO" "$DMS_REF"
    git -C "$SRC/dms" submodule update --init --recursive

    # Same build as the distro packages: no self-update, shell embedded.
    local arch
    arch=$(go env GOARCH)
    GOTOOLCHAIN=auto make -C "$SRC/dms/core" dist ARCH="$arch" DIST_OSES=linux
    $SUDO install -Dm755 "$SRC/dms/core/bin/dms-linux-$arch" "$PREFIX/bin/dms"
    divert_dms
    record_ref DMS "$DMS_REF"
    restart_dms=1
}

[ -n "$skip_apt" ] || install_packages
mkdir -p "$SRC"
wants wlroots && build_wlroots
wants labwc && build_labwc
wants dms && install_dms

if [ -n "${restart_dms:-}" ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] &&
    systemctl --user is-active --quiet dms 2>/dev/null; then
    log "Restarting the dms service"
    systemctl --user daemon-reload
    systemctl --user restart dms
fi

log "Done. Installed pins ($STATE):"
cat "$STATE"
