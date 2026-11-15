<div align="center">

  <img src="./.github/images/rvdk-banner.png" alt="RVDK Banner" width="100%"/>

  Idempotent Day-0 Bare-Metal Bootstrap, BSP Protection, Multi-Layer Kernel Tuning & Prebuilt Package Catalog for  
  **[RISC-V](https://riscv.org/) Data, Storage, Networking, and Edge ML Systems.**

</div>

---

The `riscv-data-kit` (**RVDK**) transforms out-of-the-box `riscv64` single-board computers and workstations into deterministic, headless Linux servers. It provides vendor-isolated Board Support Package (BSP) guards, `<1ms` hardware/OS Kit discovery (`/etc/rvdk/kit.env`), hardware Performance Monitoring Unit (PMU) counter exposure, workload-aware `deeptune` profiles (`data`, `ml`, `ai`), board-specific hardware `quirk` toggles, host recovery media flashers, native `4Kn` NVMe + Btrfs RAID 10 storage modules, and precompiled `io_uring` PostgreSQL 18.6 bundles across **[SiFive](https://www.sifive.com/)**, **[Tenstorrent](https://tenstorrent.com/)**, **[StarFive](https://www.starfivetech.com/en/)**, **[Milk-V](https://milkv.io/)**, **[SpacemiT](https://www.spacemit.com/en/)**, **[UltraRISC](https://www.ultrarisc.com/)**, **[Banana Pi](https://www.banana-pi.org/)**, **[Firefly](https://www.t-firefly.com/pages/riscv)**, and **[Orange Pi](http://www.orangepi.org/)** platforms.

<!-- TODO: Swap the CTD link below to the dedicated CTD architecture writeup URL once published -->
While **RVDK** supplies the atomic provisioning primitives and prebuilt binary catalog, **[BrakerRak](https://github.com/drewv-labs/brakerrak)** builds on top of **RVDK** as a stateful execution harness—pairing declarative node personas with a **[CarrierPigeons](https://github.com/drewv-labs/carrierpigeons)**-powered **HamStak** **[Continuous Telemetric Documentation (CTD)](https://github.com/drewv-labs/carrierpigeons)** mesh for a streamlined, plug-and-play RISC-V R&D platform.

> **Choosing Between `RVDK` and `BrakerRak`:**
> * **Use `RVDK` (`rvdk`) standalone** if you want clean, unopinionated building blocks—plugging Day-0 OS de-bloating, safe vendor DTB/U-Boot upgrades, `deeptune` kernel tuning, `4Kn` NVMe formatting, or prebuilt `io_uring` PostgreSQL 18.6 directly into your own scripts, Ansible playbooks, or CI pipelines without adopting an external stack.
> * **Use [`BrakerRak`](https://github.com/drewv-labs/brakerrak) (`brakerrak`)** if you want the full turnkey R&D harness—adding `Targets × Roles` state convergence (`databroker` / `braksky` / `databench` / `visionferret` / `devbench` / `devsky`), signed ORT/CTD hardware provenance manifests, Day-0 destructive factory rollback, cold-cache `io_uring` benchmark showdowns, and live **HamStak** telemetry orchestration.

---

## Architectural Overview

Vendor RISC-V OS images frequently ship with desktop GUI bloat, background package timers, locked hardware performance counters, board-specific interrupt quirks, and fragile U-Boot or Device Tree Blob (DTB) hooks that break during standard `apt` upgrades. `RVDK` decouples bare-metal bring-up and service provisioning into independent, strictly idempotent layers dispatched via `/usr/local/bin/rvdk` or standalone `curl | sudo bash` endpoints:

1. **Kit Inference & `<1ms` Cache (`lib/kit.sh` -> `/etc/rvdk/kit.env`):** Probes `/proc/device-tree/model`, `/etc/os-release`, active default-route NICs, and hart counts once, caching the resolved `Board × SoC × OS` identity for instant reuse across modules.
2. **Layer 1 — OS Normalization (`os/`):** Converges Debian, Ubuntu, Bianbu, and OpenWrt root filesystems into lean, headless server/router baselines. Configures operator accounts, `NOPASSWD` sudoers, UTF-8 locales, UCI hostnames, Ubuntu/Bianbu `snapd` & GUI eradication with APT pin locks, and raw `nftables` prerouting + MPTCP kernel network hardening.
3. **Layer 2 — Silicon BSP, Quirks & Multi-Layer `DeepTune` (`bsp/` & `boards/`):** Organizes silicon hooks by SoC die (`bsp/<vendor>/<soc>/`) and board specifics (`boards/<vendor>/<board>/`). Protects vendor `extlinux` and `zz-u-boot-menu` hooks (`--force-confdef` / `--force-confold`), migrates stale factory APT snapshots, masks unstable sleep targets, unlocks hardware PMU counters (`kernel.perf_event_paranoid = -1`), toggles board quirks (`hdmi`, `fusb`), and chains `os -> bsp -> board` kernel/IRQ/VM tuning (`--tune data|ml|ai`).
4. **Layer 3 — Composable Data, Storage & Network Modules (`postgresql/`, `mods/`):** Self-contained, opt-in modules for `io_uring` PostgreSQL 18.6 (prebuilt `.tar.zst` bundle by default, or `--force-build` cold compilation), native `4Kn` NVMe + LVM (`vg_rvdk`), kernel Btrfs RAID 10, Mosquitto MQTT, NFSv4 (auto-selecting kernel `nfsd` or userspace `nfs-ganesha`), and static `riscv64` Tailscale mesh VPN.

## Repository Structure

```text
riscv-data-kit/
├── README.md
├── LICENSE
├── bootstrap.sh                          # Universal dispatcher & `/usr/local/bin/rvdk` CLI entrypoint
├── install-cli.sh                        # Clones ~/.rvdk/engine, caches /etc/rvdk/kit.env & links `rvdk`
├── lib/
│   ├── kit.sh                            # Hardware/OS Kit inference & <1ms /etc/rvdk/kit.env cache
│   ├── apt.sh                            # Idempotent APT lock/stamp & single-pass update helper
│   └── progbar.sh                        # Persistent VT100 bottom progress bar (standalone or stacked)
├── os/
│   ├── bootstrap-debian.sh               # Layer 1A: Headless Debian Day-0 normalization & network guard
│   ├── bootstrap-ubuntu.sh               # Layer 1B: Headless Ubuntu Day-0 de-GUI, de-snap & network guard
│   ├── bootstrap-bianbu.sh               # Layer 1C: Headless SpacemiT Bianbu OS Day-0 normalization
│   ├── bootstrap-openwrt.sh              # Layer 1D: OpenWrt UCI hostname & procd/nftables router guard
│   └── deeptune.sh                       # Layer 1 DeepTune: Workload THP, VM dirty ratios & scheduler tuning
├── bsp/
│   ├── eswin/eic7700x/                   # Layer 2: EIC7700X DTB guard, end0 netplan, PWM fan, P550 PMU & DeepTune
│   ├── sifive/fu740/                     # Layer 2: SiFive Freedom U740 (4x U74) BSP
│   ├── starfive/jh7110/                  # Layer 2: JH7110 U-Boot guard, Debian repo migration, U74 cpufreq & PMU
│   ├── spacemit/{k1,k3}/                 # Layer 2: SpacemiT K1/M1 (RVA22) & K3 (RVA23) RVV 1.0 BSPs
│   ├── ultrarisc/dp1000/                 # Layer 2: UltraRISC UR-DP1000 (8x CP100 OoO + PCIe Gen4 x16) BSP
│   └── tenstorrent/atlantis/             # Layer 2: Tenstorrent Atlantis (8x Ascalon-X RVA23 OoO) BSP
├── boards/
│   ├── sifive/{p550,unmatched}/          # Media manifests, P550 flash-usb.sh, board deeptune.sh & quirks/
│   ├── starfive/{vf2,vf2-lite}/          # Media manifests & VF2 flash-sd.sh block image flasher
│   ├── milkv/{jupiter,jupiter2,mars,megrez,titan}/ # Media manifests (Milk-V Jupiter 1/2, Mars, Megrez & Titan)
│   ├── bananapi/{f3,cm6}/                # Media manifests (Banana Pi BPI-F3 & BPI-CM6)
│   ├── orangepi/{rv,rv2,r2s}/            # Media manifests (Orange Pi RV, RV2 & R2S)
│   ├── firefly/aibox-k3/                 # Media manifest (Firefly AIBOX-K3 Edge Mini PC)
│   └── tenstorrent/atlantis/             # Media manifest (Tenstorrent Atlantis)
├── postgresql/
│   ├── 18-6-io_uring/forge.sh            # Module: PostgreSQL 18.6 (io_uring + Sv39 HugePages; prebuilt or --force-build)
│   └── latest/forge.sh                   # Dispatcher alias -> 18-6-io_uring
├── mods/
│   ├── nvme-4kn/forge.sh                 # Module: Native 4Kn LBA format + LVM (vg_rvdk) + XFS/ext4
│   ├── btrfs-raid/forge.sh               # Module: Declarative native kernel Btrfs RAID 10 builder
│   ├── mosquitto/forge.sh                # Module: Eclipse Mosquitto MQTT (:1883 + Unix domain socket)
│   ├── nfs-vault/forge.sh                # Module: NFSv4 exporter (auto kernel nfsd -> userspace NFS-Ganesha)
│   └── tailscale/forge.sh                # Module: Static riscv64 Tailscale mesh VPN + optional userspace netstack
└── utils/
    └── purge-user.sh                     # Utility: Migrate ~/.rvdk state & purge factory default user account
```

## Supported Silicon Matrix

| Board Vendor | Board Model | Board Slug (`boards/`) | SoC Silicon (`bsp/`) | Core Complex (`-mtune`) | ISA Profile | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| SiFive | HiFive Premier P550 | `sifive/p550` | `eswin/eic7700x` | 4x SiFive P550 (3-Wide OoO) | RVA20 + Zba/Zbb | Production |
| StarFive | VisionFive 2 | `starfive/vf2` | `starfive/jh7110` | 4x SiFive U74 (2-Wide InO) | RVA20 + Zba/Zbb | Production |
| StarFive | VisionFive 2 Lite | `starfive/vf2-lite` | `starfive/jh7110` | 4x SiFive U74 (2-Wide InO) | RVA20 + Zba/Zbb | Supported |
| Milk-V | Mars | `milkv/mars` | `starfive/jh7110` | 4x SiFive U74 (2-Wide InO) | RVA20 + Zba/Zbb | Supported |
| Milk-V | Megrez | `milkv/megrez` | `eswin/eic7700x` | 4x SiFive P550 (3-Wide OoO) | RVA20 + Zba/Zbb | Supported |
| Banana Pi | BPI-F3 | `bananapi/f3` | `spacemit/k1` | 8x SpacemiT X60 (2-Wide InO) | RVA22 + RVV 1.0 | Supported |
| Banana Pi | BPI-CM6 | `bananapi/cm6` | `spacemit/k1` | 8x SpacemiT X60 (2-Wide InO) | RVA22 + RVV 1.0 | Supported |
| Orange Pi | Orange Pi RV | `orangepi/rv` | `starfive/jh7110` | 4x SiFive U74 (2-Wide InO) | RVA20 + Zba/Zbb | Supported |
| Orange Pi | Orange Pi RV2 / R2S | `orangepi/rv2`, `orangepi/r2s` | `spacemit/k1` | 8x SpacemiT X60 (2-Wide InO) | RVA22 + RVV 1.0 | ActiveDev |
| Milk-V | Titan | `milkv/titan` | `ultrarisc/dp1000` | 8x UltraRISC CP100 (4-Wide OoO) | RVA22 + H-Ext 1.0 | EnRoute |
| Milk-V | Jupiter 2 | `milkv/jupiter2` | `spacemit/k3` | 8x SpacemiT X100 (4-Wide OoO) | RVA23 + RVV 1.0 | Planned |
| Firefly | AIBOX-K3 | `firefly/aibox-k3` | `spacemit/k3` | 8x SpacemiT X100 (4-Wide OoO) | RVA23 + RVV 1.0 | Planned |
| Milk-V | Jupiter 1 | `milkv/jupiter` | `spacemit/k1` | 8x SpacemiT X60 (2-Wide InO) | RVA22 + RVV 1.0 | Planned |
| SiFive | HiFive Unmatched Rev B | `sifive/unmatched` | `sifive/fu740` | 4x SiFive U74 (2-Wide InO) | RVA20 (`RV64GC`) | Planned |
| Tenstorrent | Atlantis | `tenstorrent/atlantis` | `tenstorrent/atlantis` | 8x Tenstorrent Ascalon-X (Wide OoO) | RVA23 + RVV 1.0 | Planned |

## Quickstart Usage

### 1. Day-0 Bare-Metal Bootstrap (Auto-Detects Board, SoC & OS)

Boot a freshly flashed RISC-V board and run `bootstrap.sh` to install the `rvdk` CLI (`~/.rvdk/engine` -> `/usr/local/bin/rvdk`), cache `/etc/rvdk/kit.env`, and converge both Layer 1 (`os/`) and Layer 2 (`bsp/`):

```bash
curl -fsSL https://rvdk.drewv-labs.dev/bootstrap.sh | sudo bash -s -- --user drew --hostname rv-p550 --nopasswd
```

Or install the `rvdk` CLI first and invoke only the specific primitives you need:

```bash
curl -fsSL https://rvdk.drewv-labs.dev/install-cli.sh | sudo bash

rvdk kit                                                 # Inspect resolved Board/SoC/OS Kit & DeepTune chain
sudo rvdk os --user drew --hostname rv-vf2 --nopasswd    # OS normalization only
sudo rvdk bsp                                            # Silicon BSP & PMU unlock only
sudo rvdk deeptune --tune data                           # Multi-layer kernel tuning (data | ml | ai)
sudo rvdk quirk list                                     # List & toggle board hardware quirks (e.g. hdmi, fusb)
```

### 2. A-La-Carte Storage, Database & Network Modules

Every Layer 3 module runs standalone—accepting explicit CLI flags or optional defaults from `~/.rvdk/config.env` (`RVDK_ENV_FILE`):

```bash
# Format secondary NVMe to native 4Kn (4096B) sectors + LVM (vg_rvdk/lv_pgdata) + XFS/ext4
sudo rvdk mods/nvme-4kn --device /dev/nvme0n1 --mount /mnt/nvme_pgdata

# Install silicon-tuned PostgreSQL 18.6 with io_uring & Sv39 HugePages (prebuilt .tar.zst default)
sudo rvdk postgresql --data-mount /mnt/nvme_pgdata

# Or force a reproducible cold source compile on-device
sudo rvdk postgresql --force-build

# Optional storage & network modules
sudo rvdk mods/btrfs-raid --json '[...]'
sudo rvdk mods/mosquitto --port 1883
sudo rvdk mods/nfs-vault --subnet 10.0.10.0/24 --auto
sudo rvdk mods/tailscale --up --ssh
```

You can also invoke any module directly inside an external CI/CD script without installing the full CLI:

```bash
curl -fsSL https://rvdk.drewv-labs.dev/postgresql/latest/forge.sh | sudo bash
```

### 3. Host Recovery Media Flashers (macOS & Linux)

Install `rvdk` on a macOS or Linux workstation to pull, `SHA-256` verify, cache (`~/.rvdk/cache/`), and flash vendor recovery media with hardware safety interlocks (blocking internal system drives and disks `>256 GiB`):

```bash
rvdk flash list
rvdk flash vf2 sd 4                                      # Flash StarFive VisionFive 2 SD card (/dev/disk4)
rvdk flash p550 usb 4                                    # Stage U-Boot ext4 recovery USB for HiFive Premier P550
rvdk flash p550 usb --device /dev/sdX --image /path/to/custom.img.zst
```

## Core Engineering Guarantees

- **Zero Lock-In:** Every layer and module works independently via standard POSIX/Bash flags and clean environment hooks (`RVDK_ENV_FILE`, `RVDK_APT_STAMP_FILE`, `RVDK_PARENT_*`)—use one script or the whole catalog.
- **Strict Idempotency:** Every module inspects live system state before acting; converged nodes emit `[SKIP]` without restarting active databases, wiping mounted volumes, or repeating `apt-get update`.
- **Vendor BSP & DTB Isolation:** Prevents upstream `apt` kernel upgrades from overwriting board-specific device trees, PCIe mappings, or custom U-Boot hooks (`zz-u-boot-menu`).
- **Prebuilt Binary Speed + Source Provenance:** Default PostgreSQL 18.6 runs pull architecture-tuned (`-O3 -march=rv64gc_zba_zbb`) `.tar.zst` bundles for rapid convergence, while `--force-build` executes a cold source build.
- **Cycle-Accurate PMU Readiness:** Exposes hardware performance counters (`cycles`, `instructions`, `L1-dcache-load-misses`, `dTLB-load-misses`) out of the box for Linux `perf` and external telemetry agents.

---

## Ecosystem & Community Links

#### Related DREW-V Labs Projects
- [BrakerRak — Stateful RISC-V Execution & Benchmarking Harness (Built on RVDK)](https://github.com/drewv-labs/brakerrak)
- [CarrierPigeons — Continuous Telemetric Documentation (CTD) Pipeline](https://github.com/drewv-labs/carrierpigeons)

#### Orgs & Special Projects
- [RISC-V International](https://riscv.org/)
- [RISE Project (RISC-V Software Ecosystem)](https://riseproject.dev/)

#### Industry
- [SiFive](https://www.sifive.com/)
- [Tenstorrent](https://tenstorrent.com/en)
---
- [Milk-V](https://milkv.io/)
- [SpacemiT](https://www.spacemit.com/)
- [StarFive](https://www.starfivetech.com/en/)
- [UltraRISC](https://ultrarisc.com/en/)
---
- [BananaPi](https://banana-pi.org/)
- [OrangePi RISC-V](https://orangepi.net/shop.html?tag=risc-v)
- [Firefly RISC-V](https://www.t-firefly.com/pages/riscv)

#### Software
- [PostgreSQL 18.6 Release Notes (`io_uring`)](https://www.postgresql.org/docs/18/release-18-6.html)
- [NFS-Ganesha](https://github.com/nfs-ganesha/nfs-ganesha)
- [MQTT](https://mqtt.org/)
- [Eclipse Mosquitto](https://mosquitto.org/)
- [BTRFS RAID](https://btrfs.readthedocs.io/en/latest/Volume-management.html)

---

###### Trademarks & Non-Affiliation Notice
> **RVDK** (`riscv-data-kit`) is an independent open-source project developed and maintained by **DREW-V Labs** and is not affiliated with, endorsed by, or sponsored by **RISC-V International**, the **Linux Foundation**, the **RISE Project**, **SiFive**, **Tenstorrent**, **StarFive**, **Milk-V**, **SpacemiT**, **UltraRISC**, **Banana Pi**, **Firefly**, or **Orange Pi**. "RISC-V" is a registered trademark of RISC-V International. All other product names, logos, and brands are property of their respective owners and are used strictly for identification and hardware compatibility purposes under nominative fair use.

---

<div align="center">

**DREW-V LABS** // **Drew Vandagriff** — *Dallas, TX*  
`Simplicity in Architecture · Efficiency in Engineering · Purity in Science · Audacity in Art · Life in Logic`

</div>
