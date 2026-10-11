# nexus03 — Client (host) Setup

Setup for replicating the SIGCOMM'26 artifact *"Understanding Host Network Stack Latency"* (this repo).
This file is for **nexus03**, the **client / "host"** side. nexus03 is also the orchestrator: the
experiment scripts run here and drive nexus01 over SSH. The server side is in
[`nexus01_server.md`](nexus01_server.md).

> [!IMPORTANT]
> **Notes for the user (things Claude doesn't do or decide):**
> - **Booting and boot settings are yours.** Claude builds and installs the 5.10.46 kernels (§5) but never reboots, runs `grub-reboot`, or edits GRUB. The 5.10.46 boot entries must have the **IOMMU off** (no `intel_iommu=on`, no `iommu.strict=1`).
> - **Hyperthreading is currently off on nexus03.** The paper's "single core" is both hyperthreads of one physical core, and the client app assumes two logical CPUs per core. `testbed_mode.sh apply` turns SMT on at runtime. If the BIOS has it disabled, that can't work, and you need to enable Hyper-Threading in the BIOS. The CPU lists here assume CPU *n*'s sibling is *n*+64 (33↔97); §6.2 verifies this.
> - **In-tree NIC driver.** nexus03 currently runs DOCA-OFED's `mlx5_core` (25.07-0.9.7). Installing a kernel can trigger OFED's DKMS auto-build, which installs OFED's own driver for 5.10.46. The experiments need the in-tree driver. §5 and §6 check this, but removing an OFED build is your call.
> - **After every kernel switch,** `application/` and `modules/` must be rebuilt against the running kernel (§6.1 does this), and the runtime settings re-applied (`testbed_mode.sh apply`, §3), on **both** machines.
> - **Same repo branch on both machines.** The §4 edits made here must be pulled on nexus01.
> - **Quiet testbed** (probably nothing to do): the nexus02 link (`192.168.100.3`) idle, no NVMe-oF traffic on `192.168.101.x`, and no other jobs on CPUs 32–63/96–127 during experiments. §6 checks it.
> - **Matching settings.** CPU frequency governor and turbo must be the same on both machines. §6.1 compares them. Change them yourself if they differ.

## Rules for Claude on this machine

- This file covers **setup only**: don't run experiments or generate results.
- **Never** reboot, run `grub-reboot`, or edit GRUB, `/etc/modprobe.d` or netplan.
- **Building and installing the 5.10.46 kernels (§5) needs no approval.** Everything else that changes system state is marked **[APPROVAL]**: list those steps for the user; don't run them.
- Repo edits (§4) are code changes. Make them on a git branch, and put nexus01 on the same branch.
- **Record the original values before any change** (§2 and §3 say how).

## Machine facts (reference)

| | nexus03 (client / "host", **this machine**) | nexus01 (server / "target") |
|---|---|---|
| CPU | 2× Xeon Gold 6538Y+, 32 cores/socket, 2 NUMA nodes, **HT currently off** | 2× Xeon Platinum 8592V, 64 cores/socket, SNC → 4 NUMA nodes, HT on |
| RAM / storage | 512 GB / 10× 3.5 TB SSD (enough space for results) | 1 TB / ~100 GB free |
| CX-7 to nexus01 | **`ens5008np0`**, PCI `bf:00.0`, **NUMA 1**, `192.168.101.3` | `ens1np0`, NUMA 2, `192.168.101.111` |
| Other CX-7 | `192.168.100.3` ↔ nexus02 | — |
| Link | direct, back-to-back | |
| Allowed CPUs | physical cores 32–63 (with HT on: logical 32–63 + siblings 96–127) | node 2 |
| Single-core CPUs (both hyperthreads of one core) | **`33,97`** | `65,193` |
| 16-core CPUs | **`33-48,97-112`** | `65-80,193-208` |
| Results dir | `/home/iksingh2/io_uring_lat_study/results` | — |
| Repo | `/home/iksingh2/io_uring_lat_study` | `/home/iksingh2/io_uring_lat_study` |

## 1. Clone the kernel

> [!WARNING]
> The artifact ships **no 5.10 patch**. Its kernel is a full 5.10.46 tree with the changes already applied: `Terabit-Ethernet/linux-latency`, branch `linux-5.10`. A kernel.org 5.10 tree won't work. On nexus01, `~/linux-5.10` turned out to be plain 5.10.0. Check whether `~/linux-5.10` here is the same (`grep SUBLEVEL Makefile`, `ls include/net/latency.h`), and don't use it unless it's 5.10.46 with that header.

Use one clone per kernel variant (the artifact README recommends this):

```sh
cd ~
git clone -b linux-5.10 https://github.com/Terabit-Ethernet/linux-latency.git linux-latency-5.10-default
git clone -b linux-5.10 https://github.com/Terabit-Ethernet/linux-latency.git linux-latency-5.10-latency
```

Configure each clone from the artifact's `kernel_config` (it's part of the artifact: tick rate, preemption model, etc.):

```sh
cd ~/linux-latency-5.10-default
cp kernel_config .config
./scripts/config --disable CONFIG_IRQ_TIME_ACCOUNTING --set-str CONFIG_LOCALVERSION "-default"
make olddefconfig && make -s kernelrelease       # 5.10.46-default  (Linux baseline)

cd ~/linux-latency-5.10-latency
cp kernel_config .config
./scripts/config --enable CONFIG_IRQ_TIME_ACCOUNTING --set-str CONFIG_LOCALVERSION "-latency"
make olddefconfig && make -s kernelrelease       # 5.10.46-latency  (IRQa / ACCa / PCSched, runtime-selected)
```

`make olddefconfig` needs `flex`, `bison` and `bc` from §2. If they're missing, install them first.

Optional (Fig 16 only): Linux 6.12.66 from kernel.org plus this repo's `linux-6.12-latency.patch`. The patch's hardcoded IP is set in §4.

**Done when:**

```sh
for t in default latency; do d=~/linux-latency-5.10-$t
  git -C $d branch --show-current; grep -m1 SUBLEVEL $d/Makefile; ls $d/include/net/latency.h
  grep CONFIG_IRQ_TIME_ACCOUNTING $d/.config; make -C $d -s kernelrelease; done
```

Expected: `linux-5.10`, `SUBLEVEL = 46`, header present, `IRQ_TIME_ACCOUNTING` not set / `=y`, and `5.10.46-default` / `5.10.46-latency`.

## 2. Install software dependencies

Record the package list **before** installing anything:

```sh
mkdir -p ~/.testbed_mode
dpkg-query -W -f '${Package}\t${Version}\n' | sort > ~/.testbed_mode/packages-before.txt
```

| Tool | Package | Needed for |
|---|---|---|
| `hwstamp_ctl`, `phc2sys` | `linuxptp` | NIC hardware timestamps, PHC↔system clock sync |
| `trace-cmd` | `trace-cmd` | Clearing the ftrace buffer |
| `sar` | `sysstat` | CPU utilization |
| `ifconfig` | `net-tools` | Experiment scripts |
| `ethtool`, `lstopo`, `tmux` | `ethtool`, `hwloc`, `tmux` | Offloads/coalescing, CPU topology, long sessions |
| `gcc`/`g++` 11.4, `make` | `build-essential` | `application/`, `modules/` (paper: gcc 11.4.0, make 4.3) |
| Kernel build deps | `flex bison bc rsync libncurses-dev libssl-dev libelf-dev dwarves` | Kernel build |
| `/var/log/kern.log` | `rsyslog` | Kernel-module output is read from this file |
| `python3` + `numpy`, `matplotlib` | `python3-numpy python3-matplotlib` (or pip) | `parse/`, `draw_heatmap.py` (parsing happens here) |

Install what's missing **[APPROVAL]** (apt skips anything already installed):

```sh
sudo apt install linuxptp trace-cmd sysstat net-tools ethtool hwloc tmux build-essential \
  flex bison bc rsync libncurses-dev libssl-dev libelf-dev dwarves python3-numpy python3-matplotlib
```

**Done when:**

```sh
for t in hwstamp_ctl phc2sys trace-cmd sar ifconfig ethtool lstopo tmux gcc g++ make flex bison bc pahole python3; do printf "%-12s " $t; command -v $t || echo MISSING; done
gcc --version | head -1; make --version | head -1; systemctl is-active rsyslog
python3 -c 'import numpy, matplotlib; print(numpy.__version__, matplotlib.__version__)'
```

**Revert:** remove only what was added:

```sh
dpkg-query -W -f '${Package}\t${Version}\n' | sort > ~/.testbed_mode/packages-after.txt
comm -13 <(cut -f1 ~/.testbed_mode/packages-before.txt) <(cut -f1 ~/.testbed_mode/packages-after.txt)   # packages to apt remove
```

## 3. Settings switch script

`replication/testbed_mode.sh` (in this repo) swaps nexus03 between its normal settings and the experiment settings. It records the originals first. It detects the machine by hostname: on nexus03 it uses `ens5008np0`, `192.168.101.3` and CPUs 33/97.

```sh
cd ~/io_uring_lat_study
replication/testbed_mode.sh record-persistent  # once, before installing the kernels (§5)
replication/testbed_mode.sh status             # current vs. experiment values (read-only)
replication/testbed_mode.sh save               # record the originals to ~/.testbed_mode/nexus03.state
replication/testbed_mode.sh apply              # start of a session: apply experiment settings   [APPROVAL]
replication/testbed_mode.sh revert             # end of a session: restore exactly what was saved [APPROVAL]
replication/testbed_mode.sh diff-persistent <snapshot>   # persistent changes since the snapshot
```

### Runtime settings (lost on reboot)

`apply` sets the same values as the repo's `host_setup.sh`, plus SMT on, so use it **instead of** `host_setup.sh`. `revert` restores what `save` recorded:

| Setting | Experiment value | Saved from |
|---|---|---|
| SMT (hyperthreading) | on (currently off; `revert` turns it off again). Fails if the BIOS disabled HT. | `/sys/devices/system/cpu/smt/control` |
| `mlx5_core` | loaded (`revert` unloads it only if it wasn't loaded originally) | `lsmod` |
| irqbalance | stopped | `systemctl is-active irqbalance` |
| C-states 1–3 | disabled on all CPUs (applied after SMT on, so siblings are covered) | `/sys/devices/system/cpu/cpu*/cpuidle/state*/disable` |
| MTU | 9000 (must match nexus01) | `/sys/class/net/ens5008np0/mtu` |
| IP | `192.168.101.3/24` added only if missing (removed on revert only if the script added it) | `ip -4 addr` |
| Offloads | `ntuple on gro on gso on tso on lro off` | `ethtool -k ens5008np0` |
| Coalescing | Set per run by the experiment scripts; saved and restored here | `ethtool -c ens5008np0` |
| RFS | `rps_sock_flow_entries=32768`, `rps_flow_cnt=32768` per RX queue | `/proc/sys/net/core/`, `/sys/class/net/ens5008np0/queues/` |
| IRQ affinity | `affinity_tool/set_irq_affinity.sh ens5008np0` | `/proc/irq/*/smp_affinity_list` |
| Socket buffers | `wmem_max=rmem_max=12582912` | `/proc/sys/net/core/` |
| HW timestamps / clock sync | `hwstamp_ctl -r 1`; `phc2sys` started (stopped on revert) | `hwstamp_ctl -i ens5008np0` |
| ftrace buffer | `buffer_size_kb=451200` per CPU (≈ 55 GiB RAM across 128 CPUs) | real size, e.g. 1408 from `7 (expanded: 1408)` |
| `nmi_watchdog` | 0 only with `apply --pmu` | `/proc/sys/kernel/nmi_watchdog` |
| Latency-kernel knobs | Toggled per run by the experiment scripts | `net.core.latency_*`, `accu_irq_accounting`, `scheduler_accounting` |
| Recorded only, never changed | governor, turbo, `numa_balancing`, THP | |

Safeguards:
- `save` refuses to overwrite an existing saved state, so experiment settings can never be recorded as the originals.
- `apply` runs only on `5.10.46-*` / `6.12.66-*` kernels (override: `--force-kernel`).
- `revert` archives the state file as `nexus03.state.reverted-<time>`.

### Persistent changes (survive reboot): record before, revert by hand

`record-persistent` snapshots `/etc/default/grub`, `/etc/grub.d/`, `/etc/modprobe.d/`, `/etc/netplan/`, `grub-editenv list`, `/boot` and `/lib/modules` listings, `dkms status`, and the package list.

| Change | Who | Revert |
|---|---|---|
| Packages (§2) | Claude, **[APPROVAL]** | `sudo apt remove` the packages listed by the §2 revert command |
| Kernels `5.10.46-default`, `5.10.46-latency` (§5) | Claude, no approval needed | Per kernel: `sudo update-initramfs -d -k <ver>; sudo rm -rf /lib/modules/<ver>; sudo rm -f /boot/{vmlinuz,System.map,config,initrd.img}-<ver>; sudo update-grub` |
| Boot entries / options (IOMMU off), `grub-reboot`, BIOS Hyper-Threading | **User only** | User's call |
| Remove an OFED `mlx5_core` DKMS build for 5.10.46 | **User only** | `sudo dkms install <module>/<version> -k <ver>` (from the snapshot's `dkms.txt`) |
| **Never changed by Claude:** `/etc/default/grub`, `/etc/grub.d/*`, `/etc/modprobe.d/*`, `/etc/netplan/*` | — | `diff-persistent` shows whether anything changed |

**Done when:** `status` runs, a persistent snapshot exists under `~/.testbed_mode/persistent/`, and `~/.testbed_mode/nexus03.state` was written by `save` (`save` only reads system state).

## 4. Update existing files with this testbed's hardware info

The CPU numbers below assume HT on with CPU *n*'s sibling = *n*+64. HT is currently off, so the numbering is verified in §6.2 after `apply`. If it differs, recompute every CPU list below and tell the user.

### Kernel source (both clones from §1; do this before §5)

| File | Change (nexus03 values) |
|---|---|
| `include/net/latency.h` | `LATENCY_MONITOR_SOURCE_IP` → `192.168.101.3` (keep the macro's existing literal format) |
| `drivers/net/ethernet/mellanox/mlx5/core/en_tx.c` (`mlx5e_txwqe_complete`) | `(cpu == 1 \|\| cpu == 73)` → `(cpu == 33 \|\| cpu == 97)` |
| `net/ipv4/tcp.c` (`tcp_recvmsg`) | `(cpu == 1 \|\| cpu == 73)` → `(cpu == 33 \|\| cpu == 97)` |

### `env.sh` (shared by both machines)

```sh
HOST=192.168.101.3
TARGET=192.168.101.111
case $(hostname -s) in nexus01) INTF=ens1np0 ;; *) INTF=ens5008np0 ;; esac   # local interface
TARGET_INTF=ens1np0                                  # nexus01's interface, used inside ssh commands
TARGETC=nexus01.csl.illinois.edu                     # management network, NOT 192.168.101.x
USER=iksingh2
TARGETDIR=/home/iksingh2
TARGET_REPO=/home/iksingh2/io_uring_lat_study        # replaces "$TARGETDIR/latency" in scripts
```

### `application/`

| File | Change |
|---|---|
| `latency_client.cc:682` | `cpu_list[32] = {33, 97, 34, 98, 35, 99, 36, 100, 37, 101, 38, 102, 39, 103, 40, 104, 41, 105, 42, 106, 43, 107, 44, 108, 45, 109, 46, 110, 47, 111, 48, 112}` |
| `latency_client_imbalanced.cc:709` | Same list |
| `latency_client_cores.cc:835` | `int core_offset = sc < 64 ? (sc - 33) : (sc - 97 + 16);` (maps `33..48,97..112` → `0..31`; the README's r650 formula doesn't apply) |
| `latency_server.cc:506` | nexus01's list (see `nexus01_server.md` §4) |
| `Makefile` | Add `latency_client_imbalanced` to `BINS`. `scripts/single_core_lag_evaporation_acca.sh` needs it, but the Makefile doesn't build it. |

### `modules/`

- `softirq_packets.c:42,44`, `packet_dist.c:34,36`: `192.168.1.101` → `192.168.101.3`, `192.168.1.102` → `192.168.101.111`.
- nexus03 filter: `FILTER_OUTPUT_CPUS(x) (x == 33 || x == 97)`, `FILTER_PRINT_CPUS(x) (x == 97)`, `COUNTING_SERVER_SIDE` **not** defined. nexus01 needs 65/193 with `COUNTING_SERVER_SIDE`, so select by hostname in `modules/Makefile` (see `nexus01_server.md` §4).

### `scripts/*.sh` (17 scripts; `multi_cores_helper.sh` needs no edit)

All scripts share one structure. The paper's scripts assume both machines have the same interface name and CPU numbering; ours don't.

| Rule | Where |
|---|---|
| `$INTF` → `$TARGET_INTF` | Only in commands run on nexus01: a line containing `ssh`, or a continuation line starting with `"` right after `ssh … -t \` (`ifconfig`, `ethtool -C`). Local `$INTF` stays. |
| `$TARGETDIR/latency/` → `$TARGET_REPO/` | Everywhere (server binary, temp dir, modules, helper) |
| Single-core: `TASKSET="1,73"` → `TASKSET="33,97"`; add `SERVER_TASKSET="65,193"` | 11 `single_core_*` scripts, line 22 |
| Single-core server launch: `taskset -c $TASKSET` → `taskset -c $SERVER_TASKSET` | The two occurrences followed within 2 lines by `latency_server` (the ssh launch and its `echo`). The client's `taskset -c '"$TASKSET"'` stays. |
| Multi-core: `TASKSET="33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112"`; add `SERVER_TASKSET="65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,208"` | 6 `multi_cores_*` scripts, line 22 |
| Multi-core: `'$TASKSET' \` in `SERVER_CMD` → `'$SERVER_TASKSET' \` | 6 `multi_cores_*` scripts |
| `sample_cpu=73`: local `insmod ../modules/…` → `sample_cpu=97`; remote (ssh) → `sample_cpu=193` | 3 `single_core_understand_*` scripts |

### `experiment/*.py`, `parse/*.py`, `.gitignore`

- `/data/projects/latency` → `/home/iksingh2/io_uring_lat_study/results` (20 runners plus the `result_dir` in each parser).
- Add `results/` and `temp/` to `.gitignore`.

### `linux-6.12-latency.patch` (optional, Fig 16)

- Line 126: `192.168.1.101` → `192.168.101.3` (the patch hardcodes the client IP).

**Done when:**

```sh
grep -n LATENCY_MONITOR_SOURCE_IP ~/linux-latency-5.10-*/include/net/latency.h             # 192.168.101.3
grep -n 'cpu == ' ~/linux-latency-5.10-*/drivers/net/ethernet/mellanox/mlx5/core/en_tx.c \
                  ~/linux-latency-5.10-*/net/ipv4/tcp.c                                    # 33 / 97
cd ~/io_uring_lat_study
bash -n scripts/*.sh
grep -rn '192\.168\.1\.' env.sh modules/ linux-6.12-latency.patch                         # expect nothing
grep -n '"1,73"\|1,3,5,7\|sample_cpu=73\|\$TARGETDIR/latency' scripts/*.sh                 # expect nothing
grep -n -A2 'taskset -c \$TASKSET' scripts/*.sh | grep latency_server                     # expect nothing
grep -rn '/data/projects' experiment parse                                                # expect nothing
grep -n 'cpu_list\[32\]' application/latency_client*.cc; grep -n core_offset application/latency_client_cores.cc
bash -c 'source ./env.sh; echo "$INTF $HOST $TARGETC $TARGET_REPO"'                        # ens5008np0 192.168.101.3 nexus01.csl.illinois.edu /home/iksingh2/io_uring_lat_study
```

## 5. Build and install the kernels (no approval needed)

Prerequisites: §1 clones configured, §2 build deps installed, §4 kernel-source edits done, and the §3 `record-persistent` snapshot taken. **Don't reboot afterwards**; the user boots the new kernels.

```sh
for t in default latency; do
  cd ~/linux-latency-5.10-$t
  make -j"$(nproc)" bzImage && make -j"$(nproc)" modules || break
  sudo make modules_install && sudo make install
done
```

- If the build fails in BTF generation (`pahole` / `CONFIG_DEBUG_INFO_BTF`), run `./scripts/config --disable CONFIG_DEBUG_INFO_BTF && make olddefconfig`, rebuild, and tell the user.
- `make install` runs `update-grub` and DKMS post-install hooks. Report what they did (checks below).

**Done when:**

```sh
ls -l /boot/vmlinuz-5.10.46-default /boot/vmlinuz-5.10.46-latency /lib/modules/ | grep 5.10.46
grep -E '^GRUB_DEFAULT' /etc/default/grub; sudo grub-editenv list            # default boot entry unchanged vs. snapshot
grep -c "5.10.46-" /boot/grub/grub.cfg                                        # new entries exist (user picks them)
for v in 5.10.46-default 5.10.46-latency; do
  modinfo -k $v mlx5_core | grep filename                                     # must be .../kernel/drivers/net/ethernet/mellanox/...
  ls /lib/modules/$v/updates 2>/dev/null                                      # OFED DKMS output would land here
done
dkms status | grep 5.10.46                                                    # report any OFED build to the user
replication/testbed_mode.sh diff-persistent ~/.testbed_mode/persistent/<snapshot>   # expect only /boot, /lib/modules, grub.cfg-related changes
```

## 6. Post-kernel-switch checks

Run these **every time the user has booted into a 5.10.46 kernel**: once for `-default`, once for `-latency`. Report each result to the user. Don't fix boot-level problems; report them.

### 6.1 Right after boot (before `apply`)

```sh
uname -r                                                       # 5.10.46-default or 5.10.46-latency
grep CONFIG_IRQ_TIME_ACCOUNTING /boot/config-$(uname -r)       # not set for -default, =y for -latency
cat /proc/cmdline                                              # must NOT contain intel_iommu=on or iommu.strict=1
sudo dmesg | grep -iE 'DMAR: IOMMU enabled|iommu.*strict'      # expect nothing
modinfo mlx5_core | grep -E '^(filename|version)'              # in-tree path under kernel/drivers/...; not updates/
cat /sys/devices/system/cpu/smt/control                        # on/off is fine (apply turns it on); forceoff/notsupported → BIOS, tell the user
```

Latency-kernel interfaces (the experiment scripts write these on **both** kernels):

```sh
for s in latency_breakdown_on latency_rx_sched_lat_only latency_breakdown_log latency_breakdown_validation \
         latency_breakdown_nrfs latency_dumb_schedule_weight latency_dumb_schedule_disable_clamp \
         latency_dumb_schedule_enable latency_perstage_rdpmc_on; do
  printf "%-40s " $s; sysctl -n net.core.$s 2>/dev/null || echo MISSING; done
ls /sys/module/core/parameters/ | grep -E 'accu_irq_accounting|scheduler_accounting'
mountpoint /sys/kernel/debug
```

Rebuild the repo's binaries and modules against this kernel (no approval needed):

```sh
cd ~/io_uring_lat_study/application && make clean && make -j"$(nproc)"
cd ~/io_uring_lat_study/modules && make clean && make
modinfo ~/io_uring_lat_study/modules/vruntime_probe.ko | grep vermagic      # must match uname -r
```

Access to nexus01 (the experiment scripts use non-interactive `ssh -t`, `scp` and `sudo` throughout):

```sh
sudo -n true && echo local-sudo-ok
getent hosts nexus01.csl.illinois.edu                          # must NOT resolve to 192.168.101.x (control traffic stays off the test link)
ssh -o BatchMode=yes iksingh2@nexus01.csl.illinois.edu 'hostname; uname -r; sudo -n true && echo remote-sudo-ok'
ssh -o BatchMode=yes iksingh2@nexus01.csl.illinois.edu 'cd ~/io_uring_lat_study && git branch --show-current && git rev-parse --short HEAD'
git -C ~/io_uring_lat_study branch --show-current; git -C ~/io_uring_lat_study rev-parse --short HEAD   # same branch and commit on both
```

Settings that must match on both machines (compare; report differences to the user; don't change them):

```sh
q='cat /sys/devices/system/cpu/cpu$C/cpufreq/scaling_governor /sys/devices/system/cpu/intel_pstate/no_turbo /proc/sys/kernel/numa_balancing /sys/kernel/mm/transparent_hugepage/enabled'
echo "nexus03:"; C=33 bash -c "$q"
echo "nexus01:"; ssh -o BatchMode=yes iksingh2@nexus01.csl.illinois.edu "C=65 bash -c '$q'"
```

Quiet machine (most likely nothing to report):

```sh
nx02=$(ip -br addr | awk '/192\.168\.100\.3\//{print $1}')
ip -s link show "$nx02" | grep -A1 -E 'RX:|TX:'; sleep 5; ip -s link show "$nx02" | grep -A1 -E 'RX:|TX:'   # counters ~unchanged
ls /sys/kernel/config/nvmet/ports 2>/dev/null                  # NVMe-oF target ports: confirm no host is using them on 192.168.101.x
uptime; top -b -n1 -o %CPU | head -15                          # no heavy jobs, especially on CPUs 32-63,96-127
```

### 6.2 After the session's `testbed_mode.sh apply` (on both machines)

```sh
replication/testbed_mode.sh status          # every row at its experiment value
```

Then check:

```sh
cat /sys/devices/system/cpu/smt/control                                 # on
for c in 33 48 97 112; do echo "cpu$c: $(cat /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list) $(ls -d /sys/devices/system/cpu/cpu$c/node* | grep -o 'node[0-9]*')"; done
                                                                        # 33,97 / 48,112, all node1 (else recompute §4 CPU lists)
cat /sys/class/net/ens5008np0/device/numa_node                          # 1
ethtool -i ens5008np0 | head -3                                         # driver mlx5_core, version 5.10.46-... (NOT 25.07-0.9.7)
ethtool ens5008np0 | grep -E 'Speed|Link detected'                      # 400000Mb/s, yes
ip -br addr show ens5008np0; ip link show ens5008np0 | grep -o 'mtu [0-9]*'   # 192.168.101.3/24, mtu 9000
ping -c 3 -M do -s 8972 -I ens5008np0 192.168.101.111                   # jumbo frames pass end to end (nexus01 also at MTU 9000)
for i in $(ls /sys/class/net/ens5008np0/device/msi_irqs); do echo "$i $(cat /proc/irq/$i/smp_affinity_list 2>/dev/null)"; done | grep -wE '33|97'
                                                                        # 33 and 97 each own a NIC IRQ (RX steering needs it)
pgrep -a phc2sys; sudo cat /sys/kernel/debug/tracing/buffer_size_kb     # phc2sys running; 451200
ssh -o BatchMode=yes iksingh2@nexus01.csl.illinois.edu '~/io_uring_lat_study/replication/testbed_mode.sh status'   # nexus01 side applied too
```
