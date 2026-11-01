#!/usr/bin/env bash
# Play a folder of H.264 streams on HDMI. USER button: short press = next clip,
# long press = previous. The VDEC -> VO path needs the DISP to itself: neither
# soph_drm nor lontium_lt8912b may be loaded, the bridge is programmed here over i2c.
set -u

DIR=${1:-@videodir@}
LONG_MS=${NIX_BADGE_VIDEO_LONG_MS:-600}
BTN=${NIX_BADGE_VIDEO_BUTTON:-user-btn}
GEOM=${NIX_BADGE_VIDEO_GEOM:-}

DSIUP=@out@/bin/nix-badge-video-dsiup
BLVO=@out@/bin/nix-badge-video-blvo
BTNWAIT=@out@/bin/nix-badge-video-btnwait
LT_LAND=@out@/share/nix-badge-video/lt-land1281.sh
LT_DDS=@out@/share/nix-badge-video/lt-dds.sh

log() { echo "[nix-badge-video] $*"; }

# The register fixes around dsiup are mipi_tx module parameters (applied at
# SET_DEV_CFG) and a sysfs setting.
MIPI_TX_PARAMS=/sys/module/cv181x_mipi_tx/parameters
mipi_tx_param() {
	if [ ! -d "$MIPI_TX_PARAMS" ]; then
		log "warning: cv181x_mipi_tx is not loaded, display fix $1=$2 NOT applied"
		return 1
	fi
	echo "$2" > "$MIPI_TX_PARAMS/$1"
}
mipi_tx_attr() {
	local f
	for f in /sys/bus/platform/drivers/cvi-mipi-tx/*/"$1"; do
		[ -e "$f" ] && { printf '%s\n' "$f"; return 0; }
	done
	return 1
}

# The vendor's fabric clock low-power off (_sys_low_power_off). Opt-in with
# NIX_BADGE_VIDEO_FAB_LP_OFF=1: it is not a diagnosed fix and it writes ddrsys.
fab_lowpower() {
	if [ "${NIX_BADGE_VIDEO_FAB_LP_OFF:-0}" = "1" ]; then
		log "disabling fabric lowpower/slowdown (vendor _sys_low_power_off) at SET_DEV_CFG"
		mipi_tx_param fab_lowpower_off 1
	else
		mipi_tx_param fab_lowpower_off 0
	fi
}

# Bring-up waits for a sink on the LT8912B's HPD (0x48:0xc1), but never fails on
# it: a sink that shows up later is caught by the supervisor loop.
HPD_WAIT_S=${NIX_BADGE_VIDEO_HPD_WAIT_S:-20}

# A failed read (no i2c bus) counts as no sink.
hpd_read() {
	local v
	v=$(i2cget -y 2 0x48 0xc1 2>/dev/null) || v=0x00
	[ -n "$v" ] || v=0x00
	printf '%s' "$v"
}

hpd_up() { [ "$(( $(hpd_read) ))" -ne 0 ]; }

wait_hpd() {
	local i=0
	hpd_up && { log "HPD asserted ($(hpd_read)) -- sink present"; return 0; }
	log "HPD low -- waiting up to ${HPD_WAIT_S}s for a sink"
	while [ "$i" -lt "$HPD_WAIT_S" ]; do
		sleep 1
		i=$((i + 1))
		if hpd_up; then
			log "HPD asserted after ${i}s ($(hpd_read))"
			return 0
		fi
	done
	log "warning: no HPD after ${HPD_WAIT_S}s -- programming the bridge anyway"
	return 1
}

# The order matters: SHRD_SEL before any vendor sclr_disp_* call (or every RMW
# reads a consumed shadow bank), the sync-polarity clear after dsiup (inverted
# polarity shows uniform black).
bringup() {
	log "loading vendor display stack"
	# The display loader only: a codec failure would abort the full one, and the
	# codecs come up on the next line anyway.
	if ! out=$(soph-display-load-display 2>&1); then
		log "warning: soph-display-load-display failed:"
		printf '%s\n' "$out" | while IFS= read -r l; do log "  $l"; done
	fi
	modprobe cvi_vc_driver 2>/dev/null || true
	sleep 1

	fab_lowpower

	log "SHRD_SEL (DISP_CFG bit18) at SET_DEV_CFG"
	mipi_tx_param disp_working_bank 1

	# Pin the DISPPLL divider before the D-PHY comes up: the bridge's clock
	# recovery does not re-lock when it is pinned later.
	log "pin disppll SSC synthesizer divider at SET_DEV_CFG (before the D-PHY)"
	mipi_tx_param disppll_fix_div 1

	log "DSI up: 2 lanes"
	$DSIUP --lanes 2 --vpol 0 --hpol 0
	sleep 1

	# The bridge sequence is idempotent, so retry a transient failure.
	wait_hpd
	log "LT8912B 720p60"
	lt_try=1
	while :; do
		out=$(LANES_REG=0x02 sh "$LT_LAND" 2>&1) && rc=0 || rc=$?
		printf '%s\n' "$out" | while IFS= read -r l; do log "$l"; done
		[ "$rc" -eq 0 ] && break
		if [ "$lt_try" -ge 3 ]; then
			log "warning: LT8912B did not program cleanly after $lt_try tries"
			break
		fi
		log "retrying LT8912B program ($lt_try)"
		lt_try=$((lt_try + 1))
		sleep 0.5
	done

	log "clear DISP sync polarity (VS_POL|HS_POL) + force update"
	if f=$(mipi_tx_attr disp_sync_update); then
		echo 1 > "$f"
		log "DISP_CFG now: $(cat "$(mipi_tx_attr disp_cfg)")"
	else
		log "warning: no cvi-mipi-tx disp_sync_update; DISP sync polarity left as dsiup set it"
	fi
}

# Re-apply the bridge DDS block once video flows, as mainline does.
dds_reapply() {
	if ! out=$(sh "$LT_DDS" 2>&1); then
		printf '%s\n' "$out" | while IFS= read -r l; do log "$l"; done
	fi
}

mapfile -t CLIPS < <(find "$DIR" -maxdepth 1 -type f \
	\( -iname '*.264' -o -iname '*.h264' \) -print 2>/dev/null | sort)

if [ "${#CLIPS[@]}" -eq 0 ]; then
	log "no .264/.h264 files in $DIR -- nothing to play"
	log "drop H.264 Annex-B elementary streams there, e.g.:"
	log "  ffmpeg -i in.mp4 -an -c:v libx264 -bsf:v h264_mp4toannexb -f h264 out.264"
	# Not a fault, and the unit restarts on failure.
	exit 0
fi

log "${#CLIPS[@]} clip(s) in $DIR"
bringup

PLAYER_PID=""
stop_player() {
	if [ -n "$PLAYER_PID" ] && kill -0 "$PLAYER_PID" 2>/dev/null; then
		kill "$PLAYER_PID" 2>/dev/null || true
		wait "$PLAYER_PID" 2>/dev/null || true
	fi
	PLAYER_PID=""
}
trap 'stop_player; exit 0' INT TERM

# One player for the whole playlist, moved between clips with SIGUSR1/SIGUSR2:
# its teardown drops VO, so relaunching per clip would re-modeset.
start_player() {
	# shellcheck disable=SC2086
	BLVO_PUMP=1 BLVO_BIND=0 "$BLVO" "${CLIPS[@]}" $GEOM &
	PLAYER_PID=$!
	# Let the decoder get going, then settle the bridge against live video.
	sleep 3
	dds_reapply
}

# Seed the HPD edge tracker so a sink already present is not re-programmed.
if hpd_up; then hpd_last=1; else hpd_last=0; fi

log "starting player: ${#CLIPS[@]} clip(s), short press = next, long = previous"
start_player

while :; do
	# Restart a player that died (bad stream, hung VPU).
	if ! kill -0 "$PLAYER_PID" 2>/dev/null; then
		log "player exited; restarting"
		start_player
		continue
	fi

	# Re-program the bridge on an HPD low->high edge, over i2c only:
	# re-initialising the D-PHY under a live VO hangs the SoC.
	if hpd_up; then
		if [ "$hpd_last" = "0" ]; then
			log "HPD came up -- re-applying the bridge program"
			if out=$(LANES_REG=0x02 sh "$LT_LAND" 2>&1); then
				printf '%s\n' "$out" | while IFS= read -r l; do log "$l"; done
			else
				printf '%s\n' "$out" | while IFS= read -r l; do log "$l"; done
				log "warning: bridge re-program reported failures"
			fi
			dds_reapply
		fi
		hpd_last=1
	else
		[ "$hpd_last" = "1" ] && log "HPD dropped -- sink went away"
		hpd_last=0
	fi

	press=$(timeout 2 "$BTNWAIT" "$BTN" "$LONG_MS" 2>/dev/null || true)
	case "$press" in
	short)
		log "short press -> next"
		kill -USR1 "$PLAYER_PID" 2>/dev/null || true
		;;
	long)
		log "long press -> previous"
		kill -USR2 "$PLAYER_PID" 2>/dev/null || true
		;;
	esac
done
