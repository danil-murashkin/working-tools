#!/usr/bin/env bash
# WeAct USB2CAN — SLCAN console (bash, 115200 8N1).
#
# Usage:
#   ./weact_slcan.sh                 interactive console
#   ./weact_slcan.sh -i               same
#   ./weact_slcan.sh v                firmware version (V)
#   ./weact_slcan.sh init [bitrate]   C + S* + M0 + O  (default 500000)
#   ./weact_slcan.sh cmd M0           send one command, print response
#   ./weact_slcan.sh send t002133     send CAN frame
#   ./weact_slcan.sh listen [bitrate] init + decode RX until Ctrl+C
#   ./weact_slcan.sh tx [bitrate] [sec] [frame]  continuous TX (default test frame)
#   ./weact_slcan.sh monitor          raw RX (channel must be open)
#
# Documentation: equipment/weact_slcan.md
set -euo pipefail

DEV="${WEACT_DEV:-}"
BAUD="${WEACT_BAUD:-115200}"
READ_MS="${WEACT_READ_MS:-300}"
BITRATE="${WEACT_BITRATE:-100000}"
INTERACTIVE=0

usage() {
	cat <<'EOF'
WeAct USB2CAN SLCAN console

Usage:
  weact_slcan.sh [-d DEV] [-i]
  weact_slcan.sh [-d DEV] v|version
  weact_slcan.sh [-d DEV] reset              close channel (C)
  weact_slcan.sh [-d DEV] init [bitrate]
  weact_slcan.sh [-d DEV] cmd <SLCAN>
  weact_slcan.sh [-d DEV] send [bitrate] <frame>   auto-init + one CAN frame
  weact_slcan.sh [-d DEV] listen [bitrate]
  weact_slcan.sh [-d DEV] tx [bitrate] [interval_sec] [slcan_frame]
  weact_slcan.sh [-d DEV] test [bitrate]   bidir test (needs NC1 on /dev/ttyACM1)

  Default device: /dev/serial/by-id/usb-WeAct_* or /dev/ttyACM0
  See equipment/weact_slcan.md for full guide.

Interactive keys:
  v, version          V
  init [bitrate]      C + S* + M0 + O
  m0, m1, o, c, e     M0, M1, O, C, E
  s3, s6, s8          S3 (100k), S6 (500k), S8 (1M)
  t002133             any raw SLCAN line (t/T/b/...)
  help, h, ?
  quit, q, exit

Environment:
  WEACT_DEV, WEACT_BAUD, WEACT_BITRATE, WEACT_READ_MS
EOF
	exit "${1:-0}"
}

resolve_dev() {
	if [[ -n "$DEV" ]]; then
		return 0
	fi
	for link in /dev/serial/by-id/usb-WeAct_*; do
		[[ -e "$link" ]] || continue
		DEV="$link"
		return 0
	done
	DEV="/dev/ttyACM0"
}

setup_stty() {
	local dev="$1"
	stty -F "$dev" "$BAUD" cs8 -cstopb -parenb raw -echo min 0 time $((READ_MS / 100 + 1))
}

bitrate_to_s() {
	case "$1" in
	10000) echo "S0" ;;
	20000) echo "S1" ;;
	50000) echo "S2" ;;
	100000) echo "S3" ;;
	125000) echo "S4" ;;
	250000) echo "S5" ;;
	500000) echo "S6" ;;
	800000) echo "S7" ;;
	1000000) echo "S8" ;;
	*)
		echo "Unsupported bitrate: $1 (use 100000, 500000, ...)" >&2
		return 1
		;;
	esac
}

# Print SLCAN response; decode single-byte 0x07 bus error.
print_slcan_resp() {
	local cmd="$1"
	local resp="$2"

	if [[ "$resp" == $'\x07' ]]; then
		echo '-> ERROR (\x07: CAN bus error / no ACK)'
		return 1
	fi

	resp="${resp//$'\r'/}"
	resp="${resp//$'\n'/}"
	if [[ -z "$resp" ]]; then
		echo '-> OK'
		return 0
	fi

	echo "-> ${resp}"
	return 0
}

# Decode standard SLCAN RX line: tIIILDD...
decode_std_frame() {
	local line="$1"
	if [[ ! "$line" =~ ^t([0-9A-Fa-f]{3})([0-8])([0-9A-Fa-f]*)$ ]]; then
		return 1
	fi
	local id="${BASH_REMATCH[1]}"
	local len="${BASH_REMATCH[2]}"
	local data="${BASH_REMATCH[3]}"
	local bytes="" ascii="" i
	for ((i = 0; i < ${#data}; i += 2)); do
		local b="${data:i:2}"
		[[ -n "$bytes" ]] && bytes+=" "
		bytes+="$b"
		local n=$((16#$b))
		if ((n >= 32 && n <= 126)); then
			ascii+="$(printf "\\$(printf '%03o' "$n")")"
		else
			ascii+="."
		fi
	done
	printf 'RX ID=0x%s len=%s data=%s ascii="%s"\n' "$id" "$len" "${bytes:-<none>}" "$ascii"
	return 0
}

print_rx_line() {
	local line="$1"
	line="${line//$'\r'/}"
	line="${line//$'\n'/}"
	[[ -z "$line" ]] && return 0
	if [[ "$line" == $'\x07' ]]; then
		printf 'RX ERROR (\\x07)\n'
		return 0
	fi
	if decode_std_frame "$line"; then
		return 0
	fi
	printf 'RX %s\n' "$line"
}

is_slcan_frame() {
	[[ "$1" =~ ^[tTbBrR] ]]
}

is_bitrate() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

# Open CAN channel on fd 3 (must exec 3<> first).
slcan_open_channel() {
	local bitrate="$1"
	local speed
	speed="$(bitrate_to_s "$bitrate")"
	for cmd in C "$speed" M0 O; do
		slcan_tx_fd "$cmd"
	done
}

slcan_init_session() {
	local dev="$1"
	local bitrate="${2:-100000}"
	local speed
	speed="$(bitrate_to_s "$bitrate")"

	setup_stty "$dev"
	printf 'Init %s @ %s bit/s (%s), normal mode\n' "$dev" "$bitrate" "$speed"
	exec 3<>"$dev"
	slcan_open_channel "$bitrate"
	slcan_exchange_fd "E" || true
	exec 3>&-
}

# Init + send one frame in a single serial session (fixes send without init).
send_frame_session() {
	local dev="$1"
	local bitrate="$2"
	local frame="$3"
	local speed resp

	speed="$(bitrate_to_s "$bitrate")"
	setup_stty "$dev"
	exec 3<>"$dev"
	printf 'Open %s @ %s bit/s (%s)\n' "$dev" "$bitrate" "$speed"
	slcan_open_channel "$bitrate"
	printf '%s\r' "$frame" >&3
	resp=$(dd bs=1 count=512 <&3 2>/dev/null || true)
	exec 3>&-
	printf 'TX %s\n' "$frame"
	print_slcan_resp "$frame" "$resp" || true
}

parse_send_args() {
	local br="$BITRATE"
	local frame=""

	if [[ $# -eq 1 ]]; then
		frame="$1"
	elif [[ $# -eq 2 ]] && is_bitrate "$1" && is_slcan_frame "$2"; then
		br="$1"
		frame="$2"
	else
		echo "Usage: $0 send [bitrate] <frame>   e.g. send t002133 or send 100000 t002133" >&2
		return 1
	fi

	if ! is_slcan_frame "$frame"; then
		echo "Expected SLCAN frame (t/T/b/...), got: $frame" >&2
		return 1
	fi
	send_frame_session "$DEV" "$br" "$frame"
}

slcan_exchange() {
	local dev="$1"
	local cmd="$2"
	local resp

	setup_stty "$dev"
	resp=$(
		exec 3<>"$dev"
		printf '%s\r' "$cmd" >&3
		dd bs=1 count=512 <&3 2>/dev/null
		exec 3>&-
	)

	printf 'TX %s\n' "$cmd"
	print_slcan_resp "$cmd" "$resp" || true
}

slcan_init() {
	slcan_init_session "$1" "${2:-100000}"
}

interactive_session() {
	local dev="$1"
	local line cmd

	setup_stty "$dev"
	exec 3<>"$dev"

	printf 'WeAct SLCAN on %s (%s baud). Type help.\n' "$dev" "$BAUD"
	slcan_exchange_fd "C" || true

	while true; do
		drain_rx 0.08 || true

		if ! IFS= read -r -e -p "slcan> " line; then
			printf '\n'
			break
		fi
		[[ -z "$line" ]] && continue

		cmd="${line%% *}"
		case "${cmd,,}" in
		help | h | \?)
			cat <<'EOF'
Commands:
  v, version                 read firmware (V)
  init [bitrate]             C + S* + M0 + O (default 100000)
  m0 m1 o c e                mode / open / close / errors
  s3 s6 s8                   100k / 500k / 1M
  t002133                    any SLCAN frame (t/T/b/...)
  quit                       exit
EOF
			continue
			;;
		quit | q | exit)
			break
			;;
		version | v)
			slcan_exchange_fd "V"
			;;
		init)
			local br="${line#init }"
			[[ "$br" == "init" ]] && br="100000"
			local speed
			speed="$(bitrate_to_s "$br")"
			slcan_exchange_fd "C" || true
			slcan_exchange_fd "$speed" || true
			slcan_exchange_fd "M0" || true
			slcan_exchange_fd "O" || true
			slcan_exchange_fd "E" || true
			;;
		m0) slcan_exchange_fd "M0" ;;
		m1) slcan_exchange_fd "M1" ;;
		o) slcan_exchange_fd "O" ;;
		c) slcan_exchange_fd "C" ;;
		e) slcan_exchange_fd "E" ;;
		s0) slcan_exchange_fd "S0" ;;
		s1) slcan_exchange_fd "S1" ;;
		s2) slcan_exchange_fd "S2" ;;
		s3) slcan_exchange_fd "S3" ;;
		s4) slcan_exchange_fd "S4" ;;
		s5) slcan_exchange_fd "S5" ;;
		s6) slcan_exchange_fd "S6" ;;
		s7) slcan_exchange_fd "S7" ;;
		s8) slcan_exchange_fd "S8" ;;
		*)
			slcan_exchange_fd "$line"
			;;
		esac
		drain_rx 0.2 || true
	done

	slcan_exchange_fd "C" >/dev/null 2>&1 || true
	exec 3>&-
	printf 'Bye.\n'
}

# Send on open fd 3; read immediate response.
slcan_exchange_fd() {
	local cmd="$1"
	local resp

	printf '%s\r' "$cmd" >&3
	resp=$(dd bs=1 count=512 <&3 2>/dev/null || true)
	printf 'TX %s\n' "$cmd"
	print_slcan_resp "$cmd" "$resp" || true
}

setup_stty_listen() {
	local dev="$1"
	stty -F "$dev" "$BAUD" cs8 -cstopb -parenb raw -echo min 0 time 0
}

# Read and print any pending async RX (CAN frames from bus).
drain_rx() {
	local chunk=""
	local part

	chunk=$(dd bs=1 count=512 iflag=nonblock <&3 2>/dev/null || true)
	[[ -z "$chunk" ]] && return 0

	while IFS= read -r -d $'\r' part; do
		print_rx_line "$part"
	done <<<"$chunk"
}

listen_read_loop() {
	while true; do
		drain_rx || true
		sleep 0.05
	done
}

monitor_session() {
	local dev="$1"

	setup_stty_listen "$dev"
	exec 3<>"$dev"
	trap 'exec 3>&-; exit 0' INT TERM

	printf 'Monitor %s — incoming SLCAN (open channel first: init/listen)\n' "$dev"
	listen_read_loop
}

# Init channel and listen.
listen_session() {
	local dev="$1"
	local bitrate="${2:-100000}"
	local speed

	speed="$(bitrate_to_s "$bitrate")"
	setup_stty_listen "$dev"
	exec 3<>"$dev"
	trap 'slcan_tx_fd "C"; exec 3>&-; exit 0' INT TERM

	printf 'Listen %s @ %s bit/s (%s) — Ctrl+C to stop\n' "$dev" "$bitrate" "$speed"
	for cmd in C "$speed" M0 O; do
		slcan_tx_fd "$cmd"
	done

	listen_read_loop
}

# Send on open fd 3 without printing (used during listen/tx init).
slcan_tx_fd() {
	printf '%s\r' "$1" >&3
	dd bs=1 count=64 <&3 >/dev/null 2>&1 || true
}

# Continuous TX (default frame: ID 0x100, data "test").
tx_session() {
	local dev="$1"
	local bitrate="${2:-100000}"
	local interval="${3:-1}"
	local frame="${4:-t100474657374}"
	local speed

	speed="$(bitrate_to_s "$bitrate")"
	setup_stty "$dev"
	exec 3<>"$dev"
	trap 'slcan_tx_fd "C"; exec 3>&-; exit 0' INT TERM

	printf 'TX %s @ %s bit/s (%s) frame=%s every %ss — Ctrl+C to stop\n' \
		"$dev" "$bitrate" "$speed" "$frame" "$interval"
	for cmd in C "$speed" M0 O; do
		slcan_tx_fd "$cmd"
	done

	while true; do
		printf '%s\r' "$frame" >&3
		resp=$(dd bs=1 count=64 <&3 2>/dev/null || true)
		if [[ "$resp" == $'\x07' ]]; then
			echo "WARN: ${frame} -> bus error (\\x07, no ACK)" >&2
		fi
		sleep "$interval"
	done
}

while getopts "d:ih" opt; do
	case "$opt" in
	d) DEV="$OPTARG" ;;
	i) INTERACTIVE=1 ;;
	h) usage 0 ;;
	*) usage 2 ;;
	esac
done
shift $((OPTIND - 1))

resolve_dev

if [[ ! -e "$DEV" ]]; then
	echo "Device not found: $DEV" >&2
	exit 1
fi

if [[ "$INTERACTIVE" -eq 1 ]] || [[ $# -eq 0 ]]; then
	interactive_session "$DEV"
	exit 0
fi

case "$1" in
-h | --help | help)
	usage 0
	;;
v | version)
	slcan_exchange "$DEV" "V"
	;;
init)
	shift
	slcan_init "$DEV" "${1:-100000}"
	;;
reset)
	slcan_exchange "$DEV" "C"
	;;
cmd)
	shift
	[[ $# -ge 1 ]] || {
		echo "Usage: $0 cmd <SLCAN>" >&2
		exit 2
	}
	if is_slcan_frame "$1"; then
		parse_send_args "$@"
	else
		slcan_exchange "$DEV" "$1"
	fi
	;;
send)
	shift
	[[ $# -ge 1 ]] || {
		echo "Usage: $0 send [bitrate] <frame>" >&2
		exit 2
	}
	parse_send_args "$@"
	;;
monitor)
	monitor_session "$DEV"
	;;
listen)
	shift
	listen_session "$DEV" "${1:-100000}"
	;;
tx)
	shift
	tx_session "$DEV" "${1:-100000}" "${2:-1}" "${3:-t100474657374}"
	;;
test)
	shift
	SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
	exec python3 "${SCRIPT_DIR}/nc1_can_host_test.py" --weact "$DEV" "$@"
	;;
t* | T* | b* | M* | O | C | S* | E | V)
	slcan_exchange "$DEV" "$1"
	;;
*)
	echo "Unknown command: $1" >&2
	usage 2
	;;
esac
