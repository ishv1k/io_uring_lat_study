# nexus01 — Server (target) Setup

Setup for replicating the SIGCOMM'26 artifact *"Understanding Host Network Stack Latency"* (this repo).
This file is for **nexus01**, the **server / "target"** side. The client side is in
[`nexus03_client.md`](nexus03_client.md).

> [!IMPORTANT]
> **Notes for the user (things Claude doesn't do or decide):**
> - **Booting and boot settings are yours.** Claude builds and installs the 5.10.46 kernels (§5) but never reboots, runs `grub-reboot`, or edits GRUB. The 5.10.46 boot entries must have the **IOMMU off**. nexus01's global `GRUB_CMDLINE_LINUX` has `intel_iommu=on,sm_on … iommu.strict=1`, which those entries would otherwise inherit.
> - **In-tree NIC driver.** Installing a kernel can trigger OFED's DKMS auto-build (DOCA-OFED 25.07 is installed), which installs OFED's own `mlx5_core` for 5.10.46. The experiments need the in-tree driver. §5 and §6 check this, but removing an OFED build is your call.
> - **After every kernel switch,** `application/` and `modules/` must be rebuilt against the running kernel (§6.1 does this), and the runtime settings re-applied (`testbed_mode.sh apply`, §3).
> - **Same repo branch on both machines.** nexus03 makes the experiment-script edits (§4 of its file); pull them here.
> - **Quiet testbed** (probably nothing to do): no NVMe-over-RDMA traffic on the `192.168.101.x` link and no other jobs on CPUs 64–95/192–223 during experiments. §6 checks it.
> - **Matching settings.** CPU frequency governor and turbo must be the same on both machines. §6 records them, and nexus03's Claude compares the two. Change them yourself if they differ.

## Rules for Claude on this machine

- This file covers **setup only**: don't run experiments or generate results.
- **Never** reboot, run `grub-reboot`, or edit GRUB, `/etc/modprobe.d` or netplan.
- **Building and installing the 5.10.46 kernels (§5) needs no approval.** Everything else that changes system state is marked **[APPROVAL]**: list those steps for the user; don't run them.
- **Record the original values before any change** (§2 and §3 say how).

## Machine facts (reference)

| | nexus03 (client / "host") | nexus01 (server / "target", **this machine**) |
|---|---|---|
| CPU | 2× Xeon Gold 6538Y+, 32 cores/socket, 2 NUMA nodes, **HT currently off** | 2× Xeon Platinum 8592V, 64 cores/socket, SNC → 4 NUMA nodes, HT on |
| CX-7 interface | `ens5008np0`, PCI `bf:00.0`, NUMA 1 | **`ens1np0`**, PCI `98:00.0`, NUMA 2 |
| CX-7 IP | `192.168.101.3` | **`192.168.101.111/24`** (netplan `cx7-static.yaml`, MTU 4000) |
| Link | direct, back-to-back | |
| Single-core CPUs (both hyperthreads of one core) | `33,97` | **`65,193`** |
| 16-core CPUs | `33-48,97-112` | **`65-80,193-208`** |
| Management hostname / user | — | `nexus01.csl.illinois.edu` / `iksingh2` |
| Repo | `/home/iksingh2/io_uring_lat_study` | `/home/iksingh2/io_uring_lat_study` |

## 1. Clone the kernel

> [!WARNING]
> `~/linux-5.10` on nexus01 is **plain Linux 5.10.0** (`SUBLEVEL = 0`, no `include/net/latency.h`), not the artifact kernel. The artifact ships **no 5.10 patch**. Its kernel is a full 5.10.46 tree with the changes already applied: `Terabit-Ethernet/linux-latency`, branch `linux-5.10`.

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

Disk: `/` has about 100 GB free (97% used). Two built clones take roughly 50–60 GB.

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

| Tool | Package | Needed for | Status on nexus01 (2026-10-11) |
|---|---|---|---|
| `hwstamp_ctl`, `phc2sys` | `linuxptp` | NIC hardware timestamps, PHC↔system clock sync | **missing** |
| `trace-cmd` | `trace-cmd` | Clearing the ftrace buffer | **missing** |
| `sar` | `sysstat` | CPU utilization (run remotely by nexus03) | present |
| `ifconfig` | `net-tools` | Experiment scripts | present |
| `ethtool` | `ethtool` | Offloads, interrupt coalescing | present |
| `lstopo` | `hwloc` | CPU topology | present |
| `gcc`/`g++` 11.4, `make` | `build-essential` | `application/`, `modules/` (paper: gcc 11.4.0, make 4.3) | present (gcc 11.4.0) |
| Kernel build deps | `flex bison bc rsync libncurses-dev libssl-dev libelf-dev dwarves` | Kernel build | check |
| `/var/log/kern.log` | `rsyslog` | Kernel-module output is read from this file | check `systemctl is-active rsyslog` |
| Python `numpy`, `matplotlib` | — | Only if parsing on nexus01 (normally done on nexus03) | present (1.26.4 / 3.5.1) |

Install the missing ones **[APPROVAL]** (apt skips anything already installed):

```sh
sudo apt install linuxptp trace-cmd build-essential flex bison bc rsync libncurses-dev libssl-dev libelf-dev dwarves
```

**Done when:**

```sh
for t in hwstamp_ctl phc2sys trace-cmd sar ifconfig ethtool lstopo gcc g++ make flex bison bc pahole; do printf "%-12s " $t; command -v $t || echo MISSING; done
gcc --version | head -1; systemctl is-active rsyslog
```

**Revert:** remove only what was added:

```sh
dpkg-query -W -f '${Package}\t${Version}\n' | sort > ~/.testbed_mode/packages-after.txt
comm -13 <(cut -f1 ~/.testbed_mode/packages-before.txt) <(cut -f1 ~/.testbed_mode/packages-after.txt)   # packages to apt remove
```

## 3. Settings switch script

`replication/testbed_mode.sh` (in this repo) swaps nexus01 between its normal settings and the experiment settings. It records the originals first. It detects the machine by hostname: on nexus01 it uses `ens1np0`, `192.168.101.111` and CPUs 65/193.

```sh
cd ~/io_uring_lat_study
replication/testbed_mode.sh record-persistent  # once, before installing the kernels (§5)
replication/testbed_mode.sh status             # current vs. experiment values (read-only)
replication/testbed_mode.sh save               # record the originals to ~/.testbed_mode/nexus01.state
replication/testbed_mode.sh apply              # start of a session: apply experiment settings   [APPROVAL]
replication/testbed_mode.sh revert             # end of a session: restore exactly what was saved [APPROVAL]
replication/testbed_mode.sh diff-persistent <snapshot>   # persistent changes since the snapshot
```

### Runtime settings (lost on reboot)

`apply` sets the same values as the repo's `target_setup.sh`, plus SMT on, so use it **instead of** `target_setup.sh`. `revert` restores what `save` recorded:

| Setting | Experiment value | Saved from |
|---|---|---|
| SMT (hyperthreading) | on (already on here) | `/sys/devices/system/cpu/smt/control` |
| `mlx5_core` | loaded (it's blacklisted, so `apply` runs `modprobe`; `revert` unloads it if it wasn't loaded originally) | `lsmod` |
| irqbalance | stopped | `systemctl is-active irqbalance` (currently active) |
| C-states 1–3 | disabled on all CPUs | `/sys/devices/system/cpu/cpu*/cpuidle/state*/disable` |
| MTU | 9000 (must match nexus03) | `/sys/class/net/ens1np0/mtu` (currently 4000) |
| IP | `192.168.101.111/24` added only if missing (removed on revert only if the script added it) | `ip -4 addr` |
| Offloads | `ntuple on gro on gso on tso on lro off` | `ethtool -k ens1np0` |
| Coalescing | Set per run by the experiment scripts; saved and restored here | `ethtool -c ens1np0` |
| RFS | `rps_sock_flow_entries=32768`, `rps_flow_cnt=32768` per RX queue | `/proc/sys/net/core/`, `/sys/class/net/ens1np0/queues/` |
| IRQ affinity | `affinity_tool/set_irq_affinity.sh ens1np0` | `/proc/irq/*/smp_affinity_list` |
| Socket buffers | `wmem_max=rmem_max=12582912` | `/proc/sys/net/core/` |
| HW timestamps / clock sync | `hwstamp_ctl -r 1`; `phc2sys` started (stopped on revert) | `hwstamp_ctl -i ens1np0` |
| ftrace buffer | `buffer_size_kb=451200` per CPU (≈ 110 GiB RAM across 256 CPUs) | real size, e.g. 1408 from `7 (expanded: 1408)` |
| `nmi_watchdog` | 0 only with `apply --pmu` | `/proc/sys/kernel/nmi_watchdog` |
| Latency-kernel knobs | Toggled per run by the experiment scripts | `net.core.latency_*`, `accu_irq_accounting`, `scheduler_accounting` |
| Recorded only, never changed | governor (`schedutil`), turbo (on), `numa_balancing` (1), THP (`madvise`) | |

Safeguards:
- `save` refuses to overwrite an existing saved state, so experiment settings can never be recorded as the originals.
- `apply` runs only on `5.10.46-*` / `6.12.66-*` kernels (override: `--force-kernel`).
- `revert` archives the state file as `nexus01.state.reverted-<time>`.

### Persistent changes (survive reboot): record before, revert by hand

`record-persistent` snapshots `/etc/default/grub`, `/etc/grub.d/`, `/etc/modprobe.d/`, `/etc/netplan/`, `grub-editenv list`, `/boot` and `/lib/modules` listings, `dkms status`, and the package list.

| Change | Who | Revert |
|---|---|---|
| Packages (§2) | Claude, **[APPROVAL]** | `sudo apt remove` the packages listed by the §2 revert command |
| Kernels `5.10.46-default`, `5.10.46-latency` (§5) | Claude, no approval needed | Per kernel: `sudo update-initramfs -d -k <ver>; sudo rm -rf /lib/modules/<ver>; sudo rm -f /boot/{vmlinuz,System.map,config,initrd.img}-<ver>; sudo update-grub` |
| Boot entries / options (IOMMU off), `grub-reboot` | **User only** | User's call |
| Remove an OFED `mlx5_core` DKMS build for 5.10.46 | **User only** | `sudo dkms install <module>/<version> -k <ver>` (from the snapshot's `dkms.txt`) |
| **Never changed by Claude:** `/etc/default/grub`, `/etc/grub.d/*`, `/etc/modprobe.d/*` (incl. `blacklist-mlx5.conf`), `/etc/netplan/*` | — | `diff-persistent` shows whether anything changed |

**Done when:** `status` runs, a persistent snapshot exists under `~/.testbed_mode/persistent/`, and `~/.testbed_mode/nexus01.state` was written by `save` (`save` only reads system state).

## 4. Update existing files with this testbed's hardware info

The experiment scripts (`scripts/*.sh`, `experiment/`, `parse/`) run on nexus03 and are edited there; see `nexus03_client.md` §4. Both machines must use the **same git branch** of this repo. The edits that matter on nexus01:

### Kernel source (both clones from §1; do this before §5)

| File | Change (nexus01 values) |
|---|---|
| `include/net/latency.h` | `LATENCY_MONITOR_SOURCE_IP` → `192.168.101.111` (keep the macro's existing literal format) |
| `drivers/net/ethernet/mellanox/mlx5/core/en_tx.c` (`mlx5e_txwqe_complete`) | `(cpu == 1 \|\| cpu == 73)` → `(cpu == 65 \|\| cpu == 193)` |
| `net/ipv4/tcp.c` (`tcp_recvmsg`) | `(cpu == 1 \|\| cpu == 73)` → `(cpu == 65 \|\| cpu == 193)` |

### Repo files used on nexus01

| File | Change |
|---|---|
| `env.sh` (shared by both machines; `target_setup.sh` reads it here) | `HOST=192.168.101.3`, `TARGET=192.168.101.111`, `case $(hostname -s) in nexus01) INTF=ens1np0 ;; *) INTF=ens5008np0 ;; esac`, `TARGET_INTF=ens1np0`, `TARGETC=nexus01.csl.illinois.edu`, `USER=iksingh2`, `TARGETDIR=/home/iksingh2`, `TARGET_REPO=/home/iksingh2/io_uring_lat_study` |
| `application/latency_server.cc:506` | `cpu_list[32] = {65, 193, 66, 194, 67, 195, 68, 196, 69, 197, 70, 198, 71, 199, 72, 200, 73, 201, 74, 202, 75, 203, 76, 204, 77, 205, 78, 206, 79, 207, 80, 208}` (the single-core configuration uses `cpu_list[0..1]` = `65, 193`) |
| `modules/softirq_packets.c:42,44`, `modules/packet_dist.c:34,36` | `192.168.1.101` → `192.168.101.3` (client), `192.168.1.102` → `192.168.101.111` (server) |
| `modules/softirq_packets.c:12-14`, `modules/packet_dist.c:11-13` | nexus01: `FILTER_OUTPUT_CPUS(x) (x == 65 \|\| x == 193)`, `FILTER_PRINT_CPUS(x) (x == 193)`, `COUNTING_SERVER_SIDE` defined. Since the source is shared with nexus03 (33/97, not server side), select the values by hostname in `modules/Makefile` (`ifeq ($(shell hostname -s),nexus01)` → `ccflags-y += -DCOUNTING_SERVER_SIDE …`) and make the macros use those defines. |
| `linux-6.12-latency.patch:126` (optional, Fig 16) | `192.168.1.101` → `192.168.101.3` (the patch hardcodes the client IP) |
| `scripts/multi_cores_helper.sh` | No edit: nexus03 passes it the server CPU list. |

**Done when:**

```sh
grep -n LATENCY_MONITOR_SOURCE_IP ~/linux-latency-5.10-*/include/net/latency.h             # 192.168.101.111
grep -n 'cpu == ' ~/linux-latency-5.10-*/drivers/net/ethernet/mellanox/mlx5/core/en_tx.c \
                  ~/linux-latency-5.10-*/net/ipv4/tcp.c                                    # 65 / 193
cd ~/io_uring_lat_study
grep -rn '192\.168\.1\.' env.sh modules/ linux-6.12-latency.patch                         # expect nothing
grep -n 'cpu_list\[32\]' application/latency_server.cc                                    # starts 65, 193
bash -c 'source ./env.sh; echo "$INTF $TARGET $TARGET_REPO"'                               # ens1np0 192.168.101.111 /home/iksingh2/io_uring_lat_study
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

Settings that must match nexus03 (recorded, not changed; nexus03's Claude compares them):

```sh
cat /sys/devices/system/cpu/cpu65/cpufreq/scaling_governor /sys/devices/system/cpu/intel_pstate/no_turbo
cat /proc/sys/kernel/numa_balancing /sys/kernel/mm/transparent_hugepage/enabled
```

Quiet machine (most likely nothing to report):

```sh
nvme list-subsys 2>/dev/null | grep -i rdma                    # expect nothing (no NVMe-oF on the test link)
uptime; top -b -n1 -o %CPU | head -15                          # no heavy jobs, especially on CPUs 64-95,192-223
```

### 6.2 After the session's `testbed_mode.sh apply`

```sh
replication/testbed_mode.sh status          # every row at its experiment value
```

Then check:

```sh
ethtool -i ens1np0 | head -3                                   # driver mlx5_core, version 5.10.46-... (NOT 25.07-...)
ethtool ens1np0 | grep -E 'Speed|Link detected'                # 400000Mb/s, yes
ip -br addr show ens1np0; ip link show ens1np0 | grep -o 'mtu [0-9]*'   # 192.168.101.111/24, mtu 9000
cat /sys/devices/system/cpu/cpu65/topology/thread_siblings_list         # 65,193
for i in $(ls /sys/class/net/ens1np0/device/msi_irqs); do echo "$i $(cat /proc/irq/$i/smp_affinity_list 2>/dev/null)"; done | grep -wE '65|193'
                                                               # 65 and 193 each own a NIC IRQ (RX steering needs it)
pgrep -a phc2sys; sudo cat /sys/kernel/debug/tracing/buffer_size_kb      # phc2sys running; 451200
```
