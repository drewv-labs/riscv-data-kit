<div align="center">

# riscv-data-kit

**Idempotent Day-0 Bare-Metal Bootstrap, BSP Protection & Kernel Tuning Toolkit for RISC-V Data Engineering and Edge ML Systems.**

</div>

---

`riscv-data-kit` transforms out-of-the-box `riscv64` single-board computers and workstations into deterministic, headless data and inference appliances. It provides vendor-isolated Board Support Package (BSP) guards, hardware Performance Monitoring Unit (PMU) counter exposure, `Sv39` HugePage allocation, PCIe/NVMe storage tuning, and recovery media builders across **SiFive**, **StarFive**, and **Milk-V** silicon.

---

## Architectural Overview

Vendor RISC-V OS images frequently ship with desktop GUI bloat, aggressive background timers, locked hardware performance counters, and fragile U-Boot or Device Tree Blob (DTB) hooks that break during standard package upgrades. `riscv-data-kit` decouples Day-0 bring-up into two strictly idempotent layers:

1. **Layer 1 — OS Normalization (`os/`):** Converges Debian and Ubuntu root filesystems into lean, headless server baselines (`multi-user.target`). Configures operator identity, `NOPASSWD` sudoers, deterministic locales (`en_US.UTF-8`), Ubuntu `snapd` and GNOME eradication with APT pin locks, and raw `nftables` prerouting plus `sysctl` kernel network hardening (`CVE-2026-98432` IPv4 option drop and MPTCP lockdown).
2. **Layer 2 — Silicon & BSP Hardening (`<vendor>/<board>/`):** Applies SoC-specific bootloader and kernel protections (`--force-confdef` / `--force-confold` for vendor `extlinux` and DTB preservation), masks unstable SoC sleep targets, configures active PWM thermal control, and unlocks L1/L2/L3 hardware PMU counters (`kernel.perf_event_paranoid = -1`) for cycle-accurate profiling.

## Repository Structure

```text
riscv-data-kit/
├── README.md
├── os/
│   ├── bootstrap-debian.sh               # Layer 1A: Headless Debian Day-0 normalization & kernel guard
│   └── bootstrap-ubuntu.sh               # Layer 1B: Headless Ubuntu Day-0 de-GUI, de-snap & kernel guard
├── sifive/
│   └── hifive-premier-p550/
│       ├── bootstrap.sh                  # Layer 2: ESWIN EIC7700X BSP guard, PMU unlock, PWM fan & sleep mask
│       └── prepare-recovery-usb.sh       # Host utility: Stages ext4 recovery USB for U-Boot es_fs write
├── starfive/
│   └── visionfive2/
│       ├── bootstrap.sh                  # Layer 2: JH7110 BSP guard, FIT/U-Boot pin & PCIe M.2 tuning
│       └── flash-sd.sh                   # Host utility: Raw block image flasher for SD/eMMC media
└── milkv/                                # Planned RVA22 / RVA23 expansion targets
    ├── jupiter1/
    ├── jupiter2/
    └── titan/
```

## Supported Silicon Matrix

| Vendor | Board | SoC | Core Complex | Status |
| :--- | :--- | :--- | :--- | :--- |
| SiFive | HiFive Premier P550 | ESWIN EIC7700X | 4x P550 OoO | Production |
| StarFive | VisionFive 2 | StarFive JH7110 | 4x U74 InO | Production |
| Milk-V | Jupiter 1 | SpacemiT M1 | 8x X60 InO | Planned |
| Milk-V | Jupiter 2 | SpacemiT K3 | 8x X100 OoO | Planned |
| Milk-V | Titan | UltraRISC DP1000 | 8x CP100 OoO | Planned |

Each board directory exposes a uniform `bootstrap.sh` entry point alongside board-specific out-of-band recovery media utilities.

## Quickstart Usage

### 1. SiFive HiFive Premier P550 (Ubuntu 24.04 BSP)

Run Layer 1 OS normalization followed by Layer 2 P550 BSP hardening:

```bash
sudo ./os/bootstrap-ubuntu.sh --user drew --hostname brakerbox-p550 --nopasswd
sudo ./sifive/hifive-premier-p550/bootstrap.sh
```

### 2. StarFive VisionFive 2 (Debian Headless)

Run Layer 1 Debian normalization followed by Layer 2 JH7110 BSP hardening:

```bash
sudo ./os/bootstrap-debian.sh --user drew --hostname visionferret-h8 --nopasswd
sudo ./starfive/visionfive2/bootstrap.sh
```

### 3. Out-of-Band Recovery Media Builders

Prepare a factory recovery USB drive for the HiFive Premier P550 (`U-Boot` `es_fs write` to onboard eMMC) or flash a VisionFive 2 SD card from a Linux workstation:

```bash
# Stage an ext4 recovery USB stick for SiFive HiFive Premier P550
sudo ./sifive/hifive-premier-p550/prepare-recovery-usb.sh --device /dev/sdX --image /path/to/ubuntu-premier.wic.gz

# Flash a StarFive VisionFive 2 SD card
sudo ./starfive/visionfive2/flash-sd.sh --device /dev/sdX --image /path/to/starfive-jh7110-sd.img.bz2
```

## Core Engineering Guarantees

* **Strict Idempotency:** Every script is safe to execute repeatedly against live production or benchmarking nodes; converged states emit `[SKIP]` without restarting active services or duplicating firewall rules.
* **Vendor BSP & DTB Isolation:** Prevents upstream `apt` kernel upgrades from overwriting board-specific device trees, PCIe ATU mappings, or custom U-Boot bootscripts.
* **Cycle-Accurate PMU Readiness:** Exposes hardware performance counters (`cycles`, `instructions`, `L1-dcache-load-misses`, `dTLB-load-misses`) out of the box for `perf stat` and distributed telemetry agents.
* **Zero-Bloat Execution Profile:** Strips desktop compositors, crash reporters, and background package timers to eliminate OS scheduling jitter during microarchitectural and database benchmarks.

---

<div align="center">

**DREW-V LABS** // **Drew Vandagriff** — *Dallas, TX*  
`Simplicity in Architecture · Efficiency in Engineering · Purity in Science · Audacity in Art · Life in Logic`

</div>
