#!/usr/bin/env bash
#
# Swap a machine between its normal settings and the latency-experiment settings.
#
#   testbed_mode.sh save      record the current (original) runtime settings
#   testbed_mode.sh apply     save (if not saved yet), then apply the experiment settings
#   testbed_mode.sh revert    restore exactly what was saved, then archive the saved state
#   testbed_mode.sh status    show current values next to the saved and experiment values
#   testbed_mode.sh record-persistent        snapshot GRUB/modprobe/netplan/DKMS/packages
#   testbed_mode.sh diff-persistent <dir>    compare a snapshot with the current state
#
# Options:
#   --role client|server   default: nexus03 -> client, nexus01 -> server
#   --pmu                  apply: also set nmi_watchdog=0 (PMU measurements)
#   --force-kernel         apply: allow a kernel other than 5.10.46-* / 6.12.66-*
#   --force                save: overwrite an existing saved state
#
# The experiment settings mirror host_setup.sh / target_setup.sh, plus SMT (hyperthreading)
# on. They're runtime-only, so a reboot also drops them. The saved state lives in $STATE_DIR
# (default ~/.testbed_mode), outside the repo.

set -uo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
STATE_DIR=${STATE_DIR:-$HOME/.testbed_mode}
HOSTNAME_S=$(hostname -s)

CMD=${1:-}
[[ $# -gt 0 ]] && shift
ROLE=""
PMU=0
FORCE_KERNEL=0
FORCE=0
SNAPSHOT=""
while [[ $# -gt 0 ]]; do
	case $1 in
	--role) ROLE=$2; shift 2 ;;
	--pmu) PMU=1; shift ;;
	--force-kernel) FORCE_KERNEL=1; shift ;;
	--force) FORCE=1; shift ;;
	*) SNAPSHOT=$1; shift ;;
	esac
done

if [[ -z $ROLE ]]; then
	case $HOSTNAME_S in
	nexus01) ROLE=server ;;
	nexus03) ROLE=client ;;
	*) echo "Unknown host $HOSTNAME_S; pass --role client|server" >&2; exit 1 ;;
	esac
fi

# Per-role values (see replication/nexus0{1,3}_*.md).
case $ROLE in
server) IF=ens1np0;    IP=192.168.101.111; CPUS="65 193" ;;
client) IF=ens5008np0; IP=192.168.101.3;   CPUS="33 97" ;;
*) echo "Bad role: $ROLE" >&2; exit 1 ;;
esac
PREFIX=24
MTU=9000
TRACE_KB=451200
FLOW_ENTRIES=32768
SOCK_BUF=12582912

STATE=$STATE_DIR/$HOSTNAME_S.state
PHC_PID=$STATE_DIR/$HOSTNAME_S.phc2sys.pid
TRACING=/sys/kernel/debug/tracing
SMT_CONTROL=/sys/devices/system/cpu/smt/control

FAILS=0
warn() { echo "WARN: $*" >&2; FAILS=$((FAILS + 1)); }
rd() { sudo cat "$1" 2>/dev/null; }
wr() { echo "$2" | sudo tee "$1" >/dev/null 2>&1 || warn "could not write '$2' to $1"; }
have_if() { [[ -e /sys/class/net/$IF ]]; }
mlx5_loaded() { lsmod | grep -q '^mlx5_core '; }

# State file: one "type<TAB>key<TAB>value" line per setting.
#   file  <path>  <value>   restored by writing <value> back to <path>
#   kv    <name>  <value>   restored by a dedicated step
#   info  <name>  <value>   recorded only, never changed
put() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OUT"; }
put_file() {
	local v
	v=$(rd "$1") || return 0
	put file "$1" "$v"
}
get() { awk -F'\t' -v t="$1" -v k="$2" '$1 == t && $2 == k { print $3; exit }' "$STATE"; }

irq_list() { ls "/sys/class/net/$IF/device/msi_irqs" 2>/dev/null; }

trace_kb() {
	# "7 (expanded: 1408)" means the buffer is still unexpanded; 1408 is its real size.
	local v
	v=$(rd $TRACING/buffer_size_kb) || return 1
	if [[ $v =~ expanded:\ ([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; else echo "${v%% *}"; fi
}

coalesce_val() { ethtool -c "$IF" 2>/dev/null | awk -v k="$1:" '$1 == k { print $2; exit }'; }
adaptive_val() { ethtool -c "$IF" 2>/dev/null | awk -v w="$1" '/^Adaptive RX:/ { print (w == "rx" ? $3 : $5); exit }'; }
feature_val() { ethtool -k "$IF" 2>/dev/null | awk -v k="$1:" '$1 == k { print $2; exit }'; }

declare -A FEATURE=([ntuple]=ntuple-filters [gro]=generic-receive-offload \
	[gso]=generic-segmentation-offload [tso]=tcp-segmentation-offload [lro]=large-receive-offload)

save_system() {
	put info kernel "$(uname -r)"
	put info date "$(date -Is)"
	put info role "$ROLE"
	put kv smt "$(cat $SMT_CONTROL 2>/dev/null)"
	put kv mlx5_core_loaded "$(mlx5_loaded && echo 1 || echo 0)"
	put kv irqbalance "$(systemctl is-active irqbalance 2>/dev/null)"
	local f
	for f in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/disable; do put_file "$f"; done
	put_file /proc/sys/net/core/rps_sock_flow_entries
	put_file /proc/sys/net/core/wmem_max
	put_file /proc/sys/net/core/rmem_max
	put_file /proc/sys/kernel/nmi_watchdog
	put_file $TRACING/tracing_on
	put kv trace_kb "$(trace_kb)"
	# Instrumentation knobs (latency kernels only); the experiment scripts toggle them per run.
	for f in /proc/sys/net/core/latency_* /sys/module/core/parameters/accu_irq_accounting \
		/sys/module/core/parameters/scheduler_accounting; do
		[[ -e $f ]] && put_file "$f"
	done
	put info governor "$(rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
	put info no_turbo "$(rd /sys/devices/system/cpu/intel_pstate/no_turbo)"
	put info numa_balancing "$(rd /proc/sys/kernel/numa_balancing)"
	put info thp "$(rd /sys/kernel/mm/transparent_hugepage/enabled)"
	put info cmdline "$(cat /proc/cmdline)"
}

save_netdev() {
	have_if || return 0
	put kv netdev_saved 1
	put_file "/sys/class/net/$IF/mtu"
	put info addrs "$(ip -4 -o addr show "$IF" | awk '{print $4}' | xargs)"
	local f irq
	for f in /sys/class/net/"$IF"/queues/rx-*/rps_flow_cnt; do put_file "$f"; done
	for irq in $(irq_list); do put_file "/proc/irq/$irq/smp_affinity_list"; done
	for f in "${!FEATURE[@]}"; do put kv "feature.$f" "$(feature_val "${FEATURE[$f]}")"; done
	put kv adaptive-rx "$(adaptive_val rx)"
	put kv adaptive-tx "$(adaptive_val tx)"
	for f in rx-usecs rx-frames tx-usecs tx-frames; do put kv "$f" "$(coalesce_val $f)"; done
	if command -v hwstamp_ctl >/dev/null; then
		local hw
		hw=$(sudo hwstamp_ctl -i "$IF" 2>/dev/null)
		put kv hw.tx_type "$(awk '$1 == "tx_type" {print $2}' <<<"$hw")"
		put kv hw.rx_filter "$(awk '$1 == "rx_filter" {print $2}' <<<"$hw")"
	fi
}

cmd_save() {
	if [[ -e $STATE && $FORCE -eq 0 ]]; then
		echo "Already saved: $STATE (revert first, or --force to overwrite)" >&2
		exit 1
	fi
	mkdir -p "$STATE_DIR"
	OUT=$(mktemp "$STATE_DIR/.state.XXXX")
	save_system
	save_netdev
	mv "$OUT" "$STATE"
	echo "Saved $(wc -l < "$STATE") settings to $STATE"
	have_if || echo "Note: $IF is absent; its settings will be saved by 'apply' once the driver is loaded."
}

cmd_apply() {
	local kver
	kver=$(uname -r)
	if [[ ! $kver =~ ^(5\.10\.46|6\.12\.66) && $FORCE_KERNEL -eq 0 ]]; then
		echo "Running $kver, not an experiment kernel. Refusing (use --force-kernel)." >&2
		exit 1
	fi
	[[ -e $STATE ]] || cmd_save

	if ! mlx5_loaded; then
		echo "Loading mlx5_core"
		sudo modprobe mlx5_core || { echo "modprobe mlx5_core failed" >&2; exit 1; }
	fi
	local _
	for _ in $(seq 30); do have_if && break; sleep 1; done
	have_if || { echo "$IF did not appear" >&2; exit 1; }
	if [[ -z $(get kv netdev_saved) ]]; then
		OUT=$STATE
		save_netdev
	fi

	echo "Applying experiment settings on $HOSTNAME_S ($ROLE, $IF)"
	# The paper's "single core" is both hyperthreads of one physical core, so SMT must be on.
	# Turn it on first so the sibling CPUs also get the C-state and IRQ settings below.
	case $(cat $SMT_CONTROL 2>/dev/null) in
	on) ;;
	off) wr $SMT_CONTROL on ;;
	*) warn "SMT is '$(cat $SMT_CONTROL 2>/dev/null)': cannot enable at runtime (enable Hyper-Threading in the BIOS)" ;;
	esac
	local f
	for f in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[123]/disable; do wr "$f" 1; done
	sudo ip link set "$IF" mtu $MTU up || warn "mtu"
	if ! ip -4 -o addr show "$IF" | grep -q " $IP/"; then
		sudo ip addr add "$IP/$PREFIX" dev "$IF" && printf 'kv\tadded_ip\t1\n' >> "$STATE"
	fi
	sudo systemctl stop irqbalance
	sudo ethtool -K "$IF" ntuple on gro on gso on tso on lro off || warn "ethtool -K"
	wr /proc/sys/net/core/rps_sock_flow_entries $FLOW_ENTRIES
	for f in /sys/class/net/"$IF"/queues/rx-*/rps_flow_cnt; do wr "$f" $FLOW_ENTRIES; done
	sudo "$REPO/affinity_tool/set_irq_affinity.sh" "$IF" >/dev/null || warn "set_irq_affinity.sh"
	sudo sysctl -q -w net.core.wmem_max=$SOCK_BUF net.core.rmem_max=$SOCK_BUF
	sudo hwstamp_ctl -i "$IF" -r 1 >/dev/null || warn "hwstamp_ctl (is linuxptp installed?)"
	if ! pgrep -f "phc2sys .*-c $IF" >/dev/null; then
		# The log is meant to be user-owned, so the redirect stays outside sudo.
		# shellcheck disable=SC2024
		sudo nohup phc2sys -s CLOCK_REALTIME -c "$IF" -O 0 -m > "$STATE_DIR/phc2sys.log" 2>&1 &
		sleep 1
		pgrep -f "phc2sys .*-c $IF" > "$PHC_PID" || warn "phc2sys did not start"
	fi
	wr $TRACING/buffer_size_kb $TRACE_KB
	[[ $PMU -eq 1 ]] && wr /proc/sys/kernel/nmi_watchdog 0

	echo "Applied ($FAILS warnings). Revert with: $0 revert"
}

cmd_revert() {
	[[ -e $STATE ]] || { echo "Nothing saved at $STATE" >&2; exit 1; }
	echo "Reverting $HOSTNAME_S to the settings saved on $(get info date)"

	if [[ -s $PHC_PID ]]; then
		xargs sudo kill < "$PHC_PID" 2>/dev/null
		rm -f "$PHC_PID"
	fi

	if have_if && [[ -n $(get kv netdev_saved) ]]; then
		local f v
		for f in "${!FEATURE[@]}"; do
			v=$(get kv "feature.$f")
			[[ $v == on || $v == off ]] && { sudo ethtool -K "$IF" "$f" "$v" 2>/dev/null || warn "ethtool -K $f $v"; }
		done
		local args=()
		for f in rx-usecs rx-frames tx-usecs tx-frames; do
			v=$(get kv "$f")
			[[ $v =~ ^[0-9]+$ ]] && args+=("$f" "$v")
		done
		sudo ethtool -C "$IF" adaptive-rx off adaptive-tx off "${args[@]}" 2>/dev/null
		local ar at
		ar=$(get kv adaptive-rx); at=$(get kv adaptive-tx)
		[[ $ar == on || $ar == off ]] && sudo ethtool -C "$IF" adaptive-rx "$ar" 2>/dev/null
		[[ $at == on || $at == off ]] && sudo ethtool -C "$IF" adaptive-tx "$at" 2>/dev/null
		v=$(get kv hw.rx_filter)
		[[ -n $v ]] && { sudo hwstamp_ctl -i "$IF" -t "$(get kv hw.tx_type)" -r "$v" >/dev/null || warn "hwstamp_ctl"; }
		[[ $(get kv added_ip) == 1 ]] && sudo ip addr del "$IP/$PREFIX" dev "$IF"
	fi

	# Write back every saved file value (C-states, MTU, RPS, IRQ affinity, sysctls, ...).
	local path val
	while IFS=$'\t' read -r type path val; do
		[[ $type == file && -e $path ]] && wr "$path" "$val"
	done < "$STATE"
	local kb
	kb=$(get kv trace_kb)
	[[ $kb =~ ^[0-9]+$ ]] && wr $TRACING/buffer_size_kb "$kb"

	[[ $(get kv smt) == off && $(cat $SMT_CONTROL 2>/dev/null) == on ]] && wr $SMT_CONTROL off
	[[ $(get kv irqbalance) == active ]] && sudo systemctl start irqbalance
	if [[ $(get kv mlx5_core_loaded) == 0 ]] && mlx5_loaded; then
		echo "Unloading mlx5_core (it was not loaded originally)"
		sudo modprobe -r mlx5_ib 2>/dev/null
		sudo modprobe -r mlx5_core || warn "could not unload mlx5_core"
	fi

	local archive
	archive=$STATE.reverted-$(date +%Y%m%d-%H%M%S)
	mv "$STATE" "$archive"
	echo "Reverted ($FAILS warnings). Saved state archived at $archive"
}

cmd_status() {
	echo "host=$HOSTNAME_S role=$ROLE kernel=$(uname -r) if=$IF ip=$IP cpus=$CPUS"
	if [[ -e $STATE ]]; then echo "saved: $STATE ($(get info date))"; else echo "saved: none"; fi
	printf '%-28s %-28s %s\n' setting current experiment
	row() { printf '%-28s %-28s %s\n' "$1" "${2:-n/a}" "$3"; }
	row "SMT (hyperthreading)" "$(cat $SMT_CONTROL 2>/dev/null)" on
	local c
	for c in $CPUS; do
		row "cpu$c siblings" "$(cat /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list 2>/dev/null)" "${CPUS// /,}"
	done
	row mlx5_core "$(mlx5_loaded && echo loaded || echo absent)" loaded
	row irqbalance "$(systemctl is-active irqbalance 2>/dev/null)" inactive
	local s
	for c in $CPUS; do
		s=$(for f in /sys/devices/system/cpu/cpu$c/cpuidle/state[123]/disable; do cat "$f"; done 2>/dev/null | xargs)
		row "cpu$c state1-3 disable" "$s" "1 1 1"
	done
	row rps_sock_flow_entries "$(cat /proc/sys/net/core/rps_sock_flow_entries)" $FLOW_ENTRIES
	row wmem_max/rmem_max "$(sysctl -n net.core.wmem_max)/$(sysctl -n net.core.rmem_max)" "$SOCK_BUF/$SOCK_BUF"
	row ftrace buffer_size_kb "$(trace_kb)" $TRACE_KB
	row nmi_watchdog "$(cat /proc/sys/kernel/nmi_watchdog)" "1 (0 with --pmu)"
	row phc2sys "$(pgrep -f "phc2sys .*-c $IF" >/dev/null && echo running || echo stopped)" running
	if have_if; then
		row mtu "$(cat /sys/class/net/$IF/mtu)" $MTU
		row addrs "$(ip -4 -o addr show "$IF" | awk '{print $4}' | xargs)" "$IP/$PREFIX"
		local f
		for f in ntuple gro gso tso lro; do
			row "$f" "$(feature_val "${FEATURE[$f]}")" "$([[ $f == lro ]] && echo off || echo on)"
		done
		row adaptive-rx/tx "$(adaptive_val rx)/$(adaptive_val tx)" "set per run"
		row "rx-usecs/frames" "$(coalesce_val rx-usecs)/$(coalesce_val rx-frames)" "set per run"
		local irqs=""
		for irq in $(irq_list); do
			for c in $CPUS; do
				[[ $(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null) == "$c" ]] && irqs+="$irq->$c "
			done
		done
		row "IRQs on $CPUS" "${irqs:-none}" "one per CPU"
	else
		row "$IF" absent present
	fi
	echo "recorded only (never changed): governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)" \
		"no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)" \
		"numa_balancing=$(cat /proc/sys/kernel/numa_balancing)"
}

collect_persistent() {
	local d=$1
	mkdir -p "$d/etc"
	sudo cp -a /etc/default/grub "$d/etc/" 2>/dev/null
	sudo cp -a /etc/grub.d "$d/etc/" 2>/dev/null
	sudo cp -a /etc/modprobe.d "$d/etc/" 2>/dev/null
	sudo cp -a /etc/netplan "$d/etc/" 2>/dev/null
	sudo chown -R "$(id -u):$(id -g)" "$d"
	# shellcheck disable=SC2024  # snapshot files are user-owned
	sudo grub-editenv list > "$d/grubenv.txt" 2>&1
	ls -1 /boot > "$d/boot.txt"
	ls -1 /lib/modules > "$d/lib_modules.txt"
	dkms status > "$d/dkms.txt" 2>&1
	dpkg-query -W -f '${Package}\t${Version}\n' | sort > "$d/packages.txt"
	cat /proc/cmdline > "$d/cmdline.txt"
	uname -r > "$d/kernel.txt"
}

cmd_record_persistent() {
	local d
	d=$STATE_DIR/persistent/$(date +%Y%m%d-%H%M%S)
	collect_persistent "$d"
	echo "Persistent snapshot: $d"
	echo "Compare later with: $0 diff-persistent $d"
}

cmd_diff_persistent() {
	[[ -d $SNAPSHOT ]] || { echo "usage: $0 diff-persistent <snapshot dir>" >&2; exit 1; }
	local now
	now=$(mktemp -d "$STATE_DIR/.now.XXXX")
	collect_persistent "$now"
	# cmdline/kernel differ whenever another kernel is booted; show them but don't count them.
	diff -r "$SNAPSHOT" "$now" -x cmdline.txt -x kernel.txt && echo "No persistent changes since $SNAPSHOT"
	rm -rf "$now"
}

case $CMD in
save) cmd_save ;;
apply) cmd_apply ;;
revert) cmd_revert ;;
status) cmd_status ;;
record-persistent) cmd_record_persistent ;;
diff-persistent) cmd_diff_persistent ;;
*) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
