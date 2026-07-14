#!/usr/bin/env bash
set -euo pipefail

DSVIEW_VER="${DSVIEW_VER:-1.3.2}"
DSVIEW_SRC="${DSVIEW_SRC:-$HOME/Downloads/DSView-${DSVIEW_VER}}"
INSTALL_PREFIX="${DSVIEW_INSTALL_PREFIX:-$HOME/DSVIEW}"
LOCAL_BIN="${HOME}/.local/bin"
RUN_WRAPPER="${INSTALL_PREFIX}/bin/dsview-run"
RUN_SYMLINK="${LOCAL_BIN}/dsview-run"

RULES_ONLY=0
DO_INSTALL_ONLY=0
DO_REINSTALL=0

usage() {
	cat <<'EOF'
DreamSourceLab DSView — run (auto-install if missing)

Usage:
  dsview_run.sh [options] [-- <dsview args...>]

Options:
  --src PATH          DSView source directory
  --rules-only        install udev rules only (sudo)
  --install-only      install/build and exit (no run)
  --reinstall         force rebuild/reinstall even if installed
  --no-sudo-apt       build deps into ~/.local/dsview-prefix (no apt install)
  -h, --help          show this help

Environment:
  DSVIEW_SRC            path to DSView source (default: ~/Downloads/DSView-1.3.2)
  DSVIEW_VER            tarball version to download if source missing (default: 1.3.2)
  DSVIEW_INSTALL_PREFIX install prefix (default: ~/DSVIEW)
EOF
}

log() { printf 'dsview-run: %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

USE_SUDO_APT=1
DSVIEW_ARGS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	--src)
		DSVIEW_SRC="$2"
		shift 2
		;;
	--rules-only)
		RULES_ONLY=1
		shift
		;;
	--install-only)
		DO_INSTALL_ONLY=1
		shift
		;;
	--reinstall)
		DO_REINSTALL=1
		shift
		;;
	--no-sudo-apt)
		USE_SUDO_APT=0
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	--)
		shift
		DSVIEW_ARGS+=("$@")
		break
		;;
	*)
		DSVIEW_ARGS+=("$1")
		shift
		;;
	esac
done

have_dsview() {
	[[ -x "${HOME}/.local/bin/dsview-run" ]] && return 0
	[[ -x "${INSTALL_PREFIX}/bin/dsview-run" ]] && return 0
	command -v dsview-run >/dev/null 2>&1 && return 0
	return 1
}

run_dsview() {
	if [[ -x "${HOME}/.local/bin/dsview-run" ]]; then
		exec "${HOME}/.local/bin/dsview-run" "${DSVIEW_ARGS[@]}"
	fi
	if [[ -x "${INSTALL_PREFIX}/bin/dsview-run" ]]; then
		exec "${INSTALL_PREFIX}/bin/dsview-run" "${DSVIEW_ARGS[@]}"
	fi
	exec dsview-run "${DSVIEW_ARGS[@]}"
}

find_udev_rules() {
	local src="$1"
	for f in \
		"${src}/DSView/DreamSourceLab.rules" \
		"${src}/DreamSourceLab.rules"; do
		if [[ -f "$f" ]]; then
			echo "$f"
			return 0
		fi
	done
	return 1
}

install_udev_rules() {
	local rules_src="$1"
	local rules_dst="/etc/udev/rules.d/60-dreamsourcelab.rules"

	[[ -f "$rules_src" ]] || die "udev rules not found: $rules_src"

	if [[ "$(id -u)" -eq 0 ]]; then
		install -m 0644 "$rules_src" "$rules_dst"
	else
		need_cmd sudo
		sudo install -m 0644 "$rules_src" "$rules_dst"
	fi

	if command -v udevadm >/dev/null 2>&1; then
		if [[ "$(id -u)" -eq 0 ]]; then
			udevadm control --reload-rules
			udevadm trigger
		else
			sudo udevadm control --reload-rules
			sudo udevadm trigger
		fi
	fi

	log "udev rules installed: $rules_dst"
	log "reconnect the DSLogic/DSCope adapter if it is already plugged in"
}

ensure_source() {
	if [[ -f "${DSVIEW_SRC}/CMakeLists.txt" ]]; then
		return 0
	fi

	local dl_dir
	dl_dir="$(dirname "$DSVIEW_SRC")"
	local tarball="${dl_dir}/DSView-${DSVIEW_VER}.tar.gz"
	local url="https://github.com/DreamSourceLab/DSView/archive/refs/tags/v${DSVIEW_VER}.tar.gz"

	mkdir -p "$dl_dir"
	log "source not found, downloading v${DSVIEW_VER}..."
	need_cmd curl
	curl -fsSL "$url" -o "$tarball"
	tar -xf "$tarball" -C "$dl_dir"
	DSVIEW_SRC="${dl_dir}/DSView-${DSVIEW_VER}"
	[[ -d "$DSVIEW_SRC" ]] || DSVIEW_SRC="${dl_dir}/DSView-v${DSVIEW_VER}"
	[[ -f "${DSVIEW_SRC}/CMakeLists.txt" ]] || die "failed to unpack DSView source"
}

patch_sources() {
	local src="$1"

	if ! grep -q '#include <strings.h>' "${src}/libsigrok4DSL/libsigrok-internal.h" 2>/dev/null; then
		sed -i '/#include <glib.h>/i #include <strings.h>' \
			"${src}/libsigrok4DSL/libsigrok-internal.h"
		log "patched libsigrok-internal.h (strings.h)"
	fi

	if ! grep -q '_DEFAULT_SOURCE' "${src}/libsigrok4DSL/lib_main.c" 2>/dev/null; then
		sed -i '/^#include "libsigrok-internal.h"/i #define _DEFAULT_SOURCE' \
			"${src}/libsigrok4DSL/lib_main.c"
		log "patched lib_main.c (_DEFAULT_SOURCE)"
	fi
}

apt_install_deps() {
	local pkgs=(
		git gcc g++ make cmake pkg-config
		libglib2.0-dev zlib1g-dev libusb-1.0-0-dev libboost-dev
		libfftw3-dev python3-dev libudev-dev
		qtbase5-dev qtbase5-dev-tools libqt5svg5-dev
		libgl1-mesa-dev libxkbcommon-dev libvulkan-dev
	)

	if [[ "$USE_SUDO_APT" -eq 0 ]]; then
		return 1
	fi
	if ! command -v sudo >/dev/null 2>&1; then
		return 1
	fi
	if ! sudo -n true 2>/dev/null; then
		log "sudo required for apt packages; you may be prompted for a password"
	fi

	sudo apt-get update
	sudo apt-get install -y "${pkgs[@]}"
	return 0
}

local_prefix_install_deps() {
	local dep_dir="${HOME}/.local/dsview-deps"
	local prefix="${HOME}/.local/dsview-prefix"
	local pkgs=(
		libfftw3-dev libusb-1.0-0-dev libboost-dev libudev-dev
		qtbase5-dev qtbase5-dev-tools qt5-qmake libqt5svg5-dev
		libgl1-mesa-dev libxkbcommon-dev libvulkan-dev
	)

	mkdir -p "$dep_dir"
	cd "$dep_dir"
	rm -rf "$prefix"
	mkdir -p "$prefix"

	log "installing build deps into $prefix (no sudo)..."

	apt download "${pkgs[@]}" 2>/dev/null || apt-get download "${pkgs[@]}"

	local deb
	for deb in *.deb; do
		[[ -f "$deb" ]] || continue
		case "$deb" in
		*_i386.deb) continue ;;
		esac
		dpkg-deb -x "$deb" "$prefix"
	done

	# i386 qt tools from recursive deps can overwrite amd64 moc/rcc
	for deb in qtbase5-dev-tools_*_amd64.deb qt5-qmake_*_amd64.deb; do
		[[ -f "$deb" ]] || continue
		dpkg-deb -x "$deb" "$prefix"
	done

	export DSVIEW_BUILD_PREFIX="$prefix"
	export PKG_CONFIG_PATH="${prefix}/usr/lib/x86_64-linux-gnu/pkgconfig:${prefix}/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
	export CMAKE_PREFIX_PATH="${prefix}/usr"
	export CMAKE_INCLUDE_PATH="${prefix}/usr/include"
	export CMAKE_LIBRARY_PATH="${prefix}/usr/lib/x86_64-linux-gnu"
}

build_and_install() {
	local src="$1"
	local prefix="${DSVIEW_BUILD_PREFIX:-}"

	cd "$src"
	[[ -x ./clean ]] && ./clean || true

	local cmake_args=(
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5
		-DCMAKE_INSTALL_PREFIX="${INSTALL_PREFIX}"
	)

	if [[ -n "$prefix" ]]; then
		cmake_args+=(
			-DCMAKE_PREFIX_PATH="${prefix}/usr"
			-DCMAKE_INCLUDE_PATH="${prefix}/usr/include"
			-DCMAKE_LIBRARY_PATH="${prefix}/usr/lib/x86_64-linux-gnu"
		)
	fi

	cmake "${cmake_args[@]}" .
	make -j"$(nproc)"

	mkdir -p "${INSTALL_PREFIX}/bin" "${INSTALL_PREFIX}/share/DSView"
	cp -f build.dir/DSView "${INSTALL_PREFIX}/bin/DSView"
	chmod +x "${INSTALL_PREFIX}/bin/DSView"

	# make install tries to write /usr/share/applications without permission
	if [[ -d DSView/res ]]; then
		cp -a DSView/res "${INSTALL_PREFIX}/share/DSView/" 2>/dev/null || true
	fi
	if [[ -d DSView/demo ]]; then
		cp -a DSView/demo "${INSTALL_PREFIX}/share/DSView/" 2>/dev/null || true
	fi
	if [[ -d lang ]]; then
		cp -a lang "${INSTALL_PREFIX}/share/DSView/" 2>/dev/null || true
	fi
	if [[ -d libsigrokdecode4DSL/decoders ]]; then
		mkdir -p "${INSTALL_PREFIX}/share/libsigrokdecode4DSL"
		cp -a libsigrokdecode4DSL/decoders "${INSTALL_PREFIX}/share/libsigrokdecode4DSL/" 2>/dev/null || true
	fi

	log "installed binary: ${INSTALL_PREFIX}/bin/DSView"
}

write_launcher() {
	local prefix="${DSVIEW_BUILD_PREFIX:-${HOME}/.local/dsview-prefix}"

	mkdir -p "${INSTALL_PREFIX}/bin"
	cat >"$RUN_WRAPPER" <<EOF
#!/usr/bin/env bash
PREFIX="${prefix}"
if [[ -d "\$PREFIX/usr/lib/x86_64-linux-gnu/qt5/plugins" ]]; then
	export LD_LIBRARY_PATH="\$PREFIX/usr/lib/x86_64-linux-gnu:\$PREFIX/usr/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
	export QT_PLUGIN_PATH="\$PREFIX/usr/lib/x86_64-linux-gnu/qt5/plugins"
fi
exec "${INSTALL_PREFIX}/bin/DSView" "\$@"
EOF
	chmod +x "$RUN_WRAPPER"
	log "launcher: $RUN_WRAPPER"
}

ensure_path_launcher() {
	mkdir -p "$LOCAL_BIN"
	ln -sf "$RUN_WRAPPER" "$RUN_SYMLINK"
	log "PATH launcher: $RUN_SYMLINK"
}

add_plugdev_group() {
	if ! getent group plugdev >/dev/null 2>&1; then
		return 0
	fi
	if id -nG "$USER" | tr ' ' '\n' | grep -qx plugdev; then
		log "user $USER is already in group plugdev"
		return 0
	fi
	if command -v sudo >/dev/null 2>&1; then
		log "adding $USER to plugdev (re-login may be required)"
		sudo usermod -aG plugdev "$USER" || true
	fi
}

do_install() {
	need_cmd cmake
	need_cmd make
	need_cmd gcc
	need_cmd g++

	ensure_source
	local udev_rules_src=""
	udev_rules_src="$(find_udev_rules "$DSVIEW_SRC")" || true

	log "source: $DSVIEW_SRC"
	patch_sources "$DSVIEW_SRC"

	if apt_install_deps; then
		log "system packages installed via apt"
		DSVIEW_BUILD_PREFIX=""
	else
		log "falling back to local prefix (~/.local/dsview-prefix)"
		local_prefix_install_deps
	fi

	build_and_install "$DSVIEW_SRC"
	write_launcher
	ensure_path_launcher

	if [[ -n "$udev_rules_src" ]]; then
		install_udev_rules "$udev_rules_src"
	else
		log "warning: udev rules not found; USB device may need manual permissions"
	fi

	add_plugdev_group
}

main() {
	if [[ "$RULES_ONLY" -eq 1 ]]; then
		ensure_source
		local rules_src
		rules_src="$(find_udev_rules "$DSVIEW_SRC")" \
			|| die "DreamSourceLab.rules not found under $DSVIEW_SRC"
		install_udev_rules "$rules_src"
		exit 0
	fi

	if [[ "$DO_REINSTALL" -eq 1 ]]; then
		do_install
		if [[ "$DO_INSTALL_ONLY" -eq 1 ]]; then
			exit 0
		fi
		run_dsview
	fi

	if ! have_dsview; then
		log "DSView not found; installing..."
		do_install
	fi

	if ! have_dsview; then
		die "install finished but dsview-run still not found"
	fi

	if [[ "$DO_INSTALL_ONLY" -eq 1 ]]; then
		exit 0
	fi

	run_dsview
}

main

