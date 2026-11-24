#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Unified Login Header (MOTD) Library
# Path: riscv-data-kit/lib/motd.sh
#
# Converges a clean, sub-10ms, unified login header across Ubuntu, Debian,
# Armbian/OrangePi, SpacemiT Bianbu (`/etc/update-motd.d/10-rvdk-motd`), and
# OpenWrt (`/etc/profile.d/10-rvdk-motd.sh`), while backing up stock distro
# MOTD scripts/banners under `/var/lib/rvdk/backups/motd/` so `rvdk uninstall`
# restores the exact default OS login header.
# ==============================================================================

[[ -n "${_RVDK_MOTD_SH_LOADED:-}" ]] && return 0
_RVDK_MOTD_SH_LOADED=1

if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    _RVDK_MOTD_LIB_DIR=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        _RVDK_MOTD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [[ -n "$_RVDK_MOTD_LIB_DIR" && -f "${_RVDK_MOTD_LIB_DIR}/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_RVDK_MOTD_LIB_DIR}/common.sh"
    fi
    unset _RVDK_MOTD_LIB_DIR
fi

_rvdk_emit_motd_renderer_body() {
    cat <<'MOTD_BODY'
_rvdk_motd_render() {
    os_pretty=""
    if [ -r /etc/os-release ]; then
        os_pretty="$(awk -F= '/^PRETTY_NAME=/ {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' /etc/os-release 2>/dev/null)"
    fi
    if [ -z "$os_pretty" ] && [ -r /etc/openwrt_release ]; then
        os_pretty="$(awk -F= '/^DISTRIB_DESCRIPTION=/ {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' /etc/openwrt_release 2>/dev/null)"
    fi
    [ -z "$os_pretty" ] && os_pretty="$(uname -s 2>/dev/null || echo Linux)"

    os_sys="$(uname -o 2>/dev/null || echo GNU/Linux)"
    os_rel="$(uname -r 2>/dev/null || echo unknown)"
    os_arch="$(uname -m 2>/dev/null || echo riscv64)"

    printf '\n%s (%s %s %s)\n' "$os_pretty" "$os_sys" "$os_rel" "$os_arch"
    printf ' tuned by RVDK (github.com/drewv-labs/riscv-data-kit)\n\n'
    printf ' System information as of %s\n\n' "$(date)"

    if [ -r /proc/loadavg ]; then
        sys_load="$(awk '{v = sprintf("%.2f", $1); sub(/0$/, "", v); print v}' /proc/loadavg 2>/dev/null)"
        [ -n "$sys_load" ] && printf '  %-22s %s\n' "System load:" "$sys_load"
    fi

    root_usage="$(df -P -k / 2>/dev/null | awk 'NR==2 && $2 > 0 {
        pct = ($3 / $2) * 100
        if ($2 >= 1048576) {
            printf "%.1f%% of %.2fGB", pct, $2 / 1048576
        } else {
            printf "%.1f%% of %.1fMB", pct, $2 / 1024
        }
    }')"
    [ -n "$root_usage" ] && printf '  %-22s %s\n' "Usage of /:" "$root_usage"

    if [ -r /proc/meminfo ]; then
        mem_swap="$(awk '
            /^MemTotal:/     { mt = $2 }
            /^MemAvailable:/ { ma = $2; has_ma = 1 }
            /^MemFree:/      { mf = $2 }
            /^Buffers:/      { bf = $2 }
            /^Cached:/       { ca = $2 }
            /^SwapTotal:/    { st = $2 }
            /^SwapFree:/     { sf = $2 }
            END {
                avail = has_ma ? ma : (mf + bf + ca)
                mp = (mt > 0) ? int(((mt - avail) / mt) * 100 + 0.5) : 0
                sp = (st > 0) ? int(((st - sf) / st) * 100 + 0.5) : 0
                if (mp < 0) mp = 0
                if (sp < 0) sp = 0
                printf "%d%%|%d%%", mp, sp
            }
        ' /proc/meminfo 2>/dev/null)"
        if [ -n "$mem_swap" ]; then
            printf '  %-22s %s\n' "Memory usage:" "${mem_swap%|*}"
            printf '  %-22s %s\n' "Swap usage:" "${mem_swap#*|}"
        fi
    fi

    soc_temp=""
    for tz in /sys/class/thermal/thermal_zone*; do
        [ -r "${tz}/temp" ] || continue
        raw_t="$(cat "${tz}/temp" 2>/dev/null || true)"
        case "$raw_t" in
            ''|*[!0-9-]*) continue ;;
        esac
        tz_type="$(cat "${tz}/type" 2>/dev/null || true)"
        cand_t="$(awk -v t="$raw_t" 'BEGIN {
            if (t <= 0 || t > 150000) exit 1
            printf "%.1f C", (t >= 1000) ? (t / 1000.0) : t
        }' 2>/dev/null || true)"
        [ -n "$cand_t" ] || continue
        [ -z "$soc_temp" ] && soc_temp="$cand_t"
        case "$(printf '%s' "$tz_type" | tr '[:upper:]' '[:lower:]')" in
            *cpu*|*soc*|*core*|*pkg*|*cluster*|*x60*|*u74*|*p550*|*eic7700*)
                soc_temp="$cand_t"
                break
                ;;
        esac
    done
    if [ -z "$soc_temp" ]; then
        best_cpu_t=""
        best_any_t=""
        for hm in /sys/class/hwmon/hwmon*; do
            [ -d "$hm" ] || continue
            hm_name=""
            if [ -r "${hm}/name" ]; then
                IFS= read -r hm_name < "${hm}/name" 2>/dev/null || true
            fi
            case "$hm_name" in
                nvme|drivetemp|spd5118|jc42|ina*|ucsi*|bat*|ac|acad*) continue ;;
            esac
            for tf in "${hm}"/temp*_input; do
                [ -r "$tf" ] || continue
                raw_t=""
                IFS= read -r raw_t < "$tf" 2>/dev/null || true
                case "$raw_t" in
                    ''|*[!0-9-]*) continue ;;
                esac
                if [ "$raw_t" -le 0 ] 2>/dev/null || [ "$raw_t" -gt 150000 ] 2>/dev/null; then
                    continue
                fi
                tl_file="${tf%_input}_label"
                hm_label=""
                if [ -r "$tl_file" ]; then
                    IFS= read -r hm_label < "$tl_file" 2>/dev/null || true
                fi
                hm_tag="$(printf '%s %s' "$hm_name" "$hm_label" | tr '[:upper:]' '[:lower:]')"
                case "$hm_tag" in
                    *cpu*|*soc*|*core*|*pkg*|*cluster*|*pvt*|*die*|*tctl*|*x60*|*u74*|*p550*|*eic7700*)
                        if [ -z "$best_cpu_t" ] || [ "$raw_t" -gt "$best_cpu_t" ]; then
                            best_cpu_t="$raw_t"
                        fi
                        ;;
                    *)
                        if [ -z "$best_any_t" ] || [ "$raw_t" -gt "$best_any_t" ]; then
                            best_any_t="$raw_t"
                        fi
                        ;;
                esac
            done
        done
        pick_t="${best_cpu_t:-$best_any_t}"
        if [ -n "$pick_t" ]; then
            soc_temp="$(awk -v t="$pick_t" 'BEGIN {
                printf "%.1f C", (t >= 1000) ? (t / 1000.0) : t
            }' 2>/dev/null || true)"
        fi
    fi
    [ -n "$soc_temp" ] && printf '  %-22s %s\n' "Temperature:" "$soc_temp"

    proc_cnt=0
    for _p in /proc/[0-9]*; do
        [ -d "$_p" ] && proc_cnt=$(( proc_cnt + 1 ))
    done
    [ "$proc_cnt" -gt 0 ] && printf '  %-22s %s\n' "Processes:" "$proc_cnt"

    if command -v who >/dev/null 2>&1; then
        usr_cnt="$(who 2>/dev/null | awk 'NF > 0 { if (!u[$1]++) c++ } END { print c + 0 }')"
        printf '  %-22s %s\n' "Users logged in:" "${usr_cnt:-0}"
    fi

    if command -v ip >/dev/null 2>&1; then
        ip -o addr show up scope global 2>/dev/null | awk '
            {
                dev = $2
                sub(/@.*/, "", dev)
                if (dev ~ /^(lo|docker|veth|br-|virbr|cni|flannel)/) next
                fam = $3
                addr = $4
                sub(/\/.*/, "", addr)
                if (fam == "inet") {
                    printf "  %-22s %s\n", "IPv4 address for " dev ":", addr
                } else if (fam == "inet6") {
                    printf "  %-22s %s\n", "IPv6 address for " dev ":", addr
                }
            }
        '
    fi

    kit_out=""
    # Fast <10ms /bin/sh + awk path when /etc/rvdk/kit.env exists (avoids ~95ms bash CLI fork)
    if [ -r /etc/rvdk/kit.env ]; then
        dt_tune=""
        if [ -r /etc/rvdk/deeptune.env ]; then
            dt_tune="$(awk -F= '/^RVDK_TUNE=/ {sub(/^[^=]*=/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit}' /etc/rvdk/deeptune.env 2>/dev/null)"
        fi
        eng_dir="${RVDK_ENGINE_DIR:-/usr/local/share/rvdk/engine}"

        kit_sc=""
        kit_bd=""
        kit_oi=""
        kit_dt_chain=""
        kit_bd_quirks=""
        while IFS='=' read -r _k _v || [ -n "$_k" ]; do
            case "$_k" in
                RVDK_SOC|RVDK_BOARD|RVDK_OS_ID|RVDK_DEEPTUNE_CHAIN|RVDK_BOARD_QUIRKS)
                    case "$_v" in
                        \"*\") _v="${_v#\"}"; _v="${_v%\"}" ;;
                        \'*\') _v="${_v#\'}"; _v="${_v%\'}" ;;
                    esac
                    case "$_k" in
                        RVDK_SOC)            kit_sc="$_v" ;;
                        RVDK_BOARD)          kit_bd="$_v" ;;
                        RVDK_OS_ID)          kit_oi="$_v" ;;
                        RVDK_DEEPTUNE_CHAIN) kit_dt_chain="$_v" ;;
                        RVDK_BOARD_QUIRKS)   kit_bd_quirks="$_v" ;;
                    esac
                    ;;
            esac
        done < /etc/rvdk/kit.env
        case "$kit_sc" in *..*|/*) kit_sc="" ;; esac
        case "$kit_bd" in *..*|/*) kit_bd="" ;; esac
        case "$kit_oi" in *..*|*/*) kit_oi="" ;; esac

        dt_chain="$kit_dt_chain"
        if [ -z "$dt_chain" ]; then
            if [ -f "${eng_dir}/os/deeptune.sh" ] && [ ! -L "${eng_dir}/os/deeptune.sh" ]; then
                dt_chain="os/deeptune.sh"
            fi
            if [ -n "$kit_oi" ] && [ -f "${eng_dir}/os/deeptune-${kit_oi}.sh" ] && [ ! -L "${eng_dir}/os/deeptune-${kit_oi}.sh" ]; then
                dt_chain="${dt_chain:+${dt_chain} -> }os/deeptune-${kit_oi}.sh"
            fi
            if [ -n "$kit_sc" ] && [ -f "${eng_dir}/bsp/${kit_sc}/deeptune.sh" ] && [ ! -L "${eng_dir}/bsp/${kit_sc}/deeptune.sh" ]; then
                dt_chain="${dt_chain:+${dt_chain} -> }bsp/${kit_sc}/deeptune.sh"
            fi
            if [ -n "$kit_bd" ] && [ -f "${eng_dir}/boards/${kit_bd}/deeptune.sh" ] && [ ! -L "${eng_dir}/boards/${kit_bd}/deeptune.sh" ]; then
                dt_chain="${dt_chain:+${dt_chain} -> }boards/${kit_bd}/deeptune.sh"
            fi
            [ -z "$dt_chain" ] && dt_chain="none"
        fi

        bd_quirks="$kit_bd_quirks"
        if [ -z "$bd_quirks" ] && [ -n "$kit_bd" ]; then
            if [ -x "${eng_dir}/boards/${kit_bd}/motd-quirks.sh" ]; then
                bd_quirks="$("${eng_dir}/boards/${kit_bd}/motd-quirks.sh" 2>/dev/null || true)"
            fi
            if [ -z "$bd_quirks" ] && [ -d "${eng_dir}/boards/${kit_bd}/quirks" ]; then
                for _qf in "${eng_dir}/boards/${kit_bd}/quirks"/*.sh; do
                    [ -f "$_qf" ] || continue
                    _qn="${_qf##*/}"
                    _qn="${_qn%.sh}"
                    bd_quirks="${bd_quirks:+${bd_quirks} }${_qn}"
                done
            fi
        fi
        [ -z "$bd_quirks" ] && bd_quirks="none"

        kit_out="$(awk -F= \
            -v tune="$dt_tune" \
            -v chain="$dt_chain" \
            -v quirks="$bd_quirks" '
            function unq(s) {
                sub(/^[^=]*=/, "", s)
                gsub(/^"|"$/, "", s)
                gsub(/\\\\/, "\x01", s)
                gsub(/\\"/, "\"", s)
                gsub(/\\\$/, "$", s)
                gsub(/\\`/, "`", s)
                gsub(/\x01/, "\\", s)
                return s
            }
            /^RVDK_DT_MODEL=/      { dt = unq($0) }
            /^RVDK_BOARD=/         { bd = unq($0) }
            /^RVDK_BOARD_TAG=/     { bt = unq($0) }
            /^RVDK_SOC=/           { sc = unq($0) }
            /^RVDK_SOC_SLUG=/      { ss = unq($0) }
            /^RVDK_OS_ID=/         { oi = unq($0) }
            /^RVDK_OS_VERSION_ID=/ { ov = unq($0) }
            /^RVDK_PRIMARY_NIC=/   { pn = unq($0) }
            /^RVDK_CPU_HARTS=/     { ch = unq($0) }
            END {
                if (dt != "" || bd != "") {
                    printf "  • Device Tree Model : %s\n", (dt != "" ? dt : "Unknown")
                    printf "  • Board (boards/)   : %s (tag: %s)\n", (bd != "" ? bd : "unrecognized"), (bt != "" ? bt : "-")
                    printf "  • SoC (bsp/)        : %s (slug: %s)\n", (sc != "" ? sc : "unrecognized"), (ss != "" ? ss : "-")
                    printf "  • OS (os/)          : %s %s\n", (oi != "" ? oi : "unknown"), ov
                    printf "  • Primary NIC / CPU : %s | %s Harts\n", (pn != "" ? pn : "none"), (ch != "" ? ch : "?")
                    printf "  • Kit Cache File    : /etc/rvdk/kit.env (cached)\n"
                    if (chain == "") chain = "none"
                    if (tune != "") {
                        printf "  • DeepTune Chain    : %s (active: %s)\n", chain, tune
                    } else {
                        printf "  • DeepTune Chain    : %s\n", chain
                    }
                    printf "  • Board Quirks      : %s\n", (quirks != "" ? quirks : "none")
                }
            }
        ' /etc/rvdk/kit.env 2>/dev/null)"
    fi

    # Fallback ONLY when /etc/rvdk/kit.env does not exist
    if [ -z "$kit_out" ] && [ ! -r /etc/rvdk/kit.env ]; then
        rvdk_bin=""
        if [ -x /usr/local/bin/rvdk ]; then
            rvdk_bin="/usr/local/bin/rvdk"
        elif [ -x /usr/bin/rvdk ]; then
            rvdk_bin="/usr/bin/rvdk"
        elif command -v rvdk >/dev/null 2>&1; then
            rvdk_bin="$(command -v rvdk)"
        fi
        if [ -n "$rvdk_bin" ]; then
            kit_out="$("$rvdk_bin" kit --motd 2>/dev/null || true)"
        fi
    fi

    if [ -n "$kit_out" ]; then
        printf '\nRVDK Kit\n\n%s\n' "$kit_out"
    fi
    printf '\n'
}
MOTD_BODY
}

# Converge APT dynamic MOTD (`/etc/update-motd.d/10-rvdk-motd`) on Ubuntu/Debian/Bianbu
rvdk_converge_apt_motd() {
    local root_prefix="${1:-}"
    local motd_dir="${root_prefix}/etc/update-motd.d"
    local motd_hook="${motd_dir}/10-rvdk-motd"
    local etc_motd="${root_prefix}/etc/motd"
    local bkp_dir="${root_prefix}/var/lib/rvdk/backups/motd"
    local modes_file="${bkp_dir}/update-motd.modes"
    local links_bkp_dir="${bkp_dir}/update-motd.symlinks"
    local changed="false"

    mkdir -p "$motd_dir" "$bkp_dir"
    chmod 0755 "$motd_dir" "$bkp_dir" 2>/dev/null || true

    # 1. Record original permissions/symlinks of stock /etc/update-motd.d hooks and disable them.
    #    Symlinked hooks (e.g. Ubuntu `50-landscape-sysinfo -> /usr/share/landscape/landscape-sysinfo.wrapper`)
    #    must be parked in `${bkp_dir}/update-motd.symlinks/` rather than `chmod a-x`, which would either be
    #    skipped (duplicating sysinfo) or mutate package-owned binaries under `/usr/share/`.
    local f base fmode lnk_target
    for f in "${motd_dir}"/*; do
        [[ -e "$f" || -L "$f" ]] || continue
        base="$(basename "$f")"
        [[ "$base" == "10-rvdk-motd" ]] && continue
        if [[ -L "$f" ]]; then
            mkdir -p "$links_bkp_dir"
            chmod 0755 "$links_bkp_dir" 2>/dev/null || true
            if [[ ! -L "${links_bkp_dir}/${base}" ]]; then
                lnk_target="$(readlink "$f" 2>/dev/null || true)"
                [[ -n "$lnk_target" ]] && ln -snf "$lnk_target" "${links_bkp_dir}/${base}"
            fi
            rm -f "$f"
            changed="true"
            continue
        fi
        [[ -f "$f" ]] || continue
        if [[ ! -f "$modes_file" ]] || ! awk -v b="$base" '$2 == b { found=1 } END { exit !found }' "$modes_file" 2>/dev/null; then
            fmode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || echo 755)"
            printf '%s %s\n' "$fmode" "$base" >> "$modes_file"
        fi
        if [[ -x "$f" ]]; then
            chmod a-x "$f"
            changed="true"
        fi
    done

    # 2. Back up and clear static /etc/motd (e.g. Debian legal blurb) so pam_motd doesn't append it
    if [[ ! -L "$etc_motd" && -s "$etc_motd" ]]; then
        [[ -f "${bkp_dir}/etc.motd.orig" ]] || cp -a "$etc_motd" "${bkp_dir}/etc.motd.orig" 2>/dev/null || true
        printf '' | rvdk_atomic_write "$etc_motd" 0644
        changed="true"
    fi

    # 3. Suppress Ubuntu motd-news, landscape-sysinfo profile hook, & OrangePi/Armbian vendor MOTD hooks (with backup)
    local lprof="${root_prefix}/etc/profile.d/50-landscape-sysinfo.sh"
    local lprof_bkp="${bkp_dir}/profile.50-landscape-sysinfo.sh.orig"
    if [[ -L "$lprof" ]]; then
        if [[ ! -e "$lprof_bkp" && ! -L "$lprof_bkp" ]]; then
            local lprof_target
            lprof_target="$(readlink "$lprof" 2>/dev/null || true)"
            [[ -n "$lprof_target" ]] && ln -snf "$lprof_target" "$lprof_bkp"
        fi
        rm -f "$lprof"
        changed="true"
    elif [[ -f "$lprof" ]]; then
        [[ -e "$lprof_bkp" || -L "$lprof_bkp" ]] || cp -a "$lprof" "$lprof_bkp" 2>/dev/null || true
        rm -f "$lprof"
        changed="true"
    fi

    local mnews="${root_prefix}/etc/default/motd-news"
    if [[ -f "$mnews" ]] && grep -Eq '^[[:space:]]*ENABLED=1' "$mnews" 2>/dev/null; then
        [[ -f "${bkp_dir}/default.motd-news.orig" ]] || cp -a "$mnews" "${bkp_dir}/default.motd-news.orig" 2>/dev/null || true
        local _mnews_out
        _mnews_out="$(sed 's/^[[:space:]]*ENABLED=1/ENABLED=0/' "$mnews")"
        printf '%s\n' "$_mnews_out" | rvdk_atomic_write "$mnews" 0644
        changed="true"
    fi

    local vname vcfg _vcfg_out
    for vname in orangepi-motd armbian-motd; do
        vcfg="${root_prefix}/etc/default/${vname}"
        [[ -f "$vcfg" ]] || continue
        if ! grep -Eq '^MOTD_DISABLE="header sysinfo tips updates config autoreboot-warn"$' "$vcfg" 2>/dev/null; then
            [[ -f "${bkp_dir}/default.${vname}.orig" ]] || cp -a "$vcfg" "${bkp_dir}/default.${vname}.orig" 2>/dev/null || true
            if grep -Eq '^[[:space:]]*MOTD_DISABLE=' "$vcfg" 2>/dev/null; then
                _vcfg_out="$(sed 's/^[[:space:]]*MOTD_DISABLE=.*/MOTD_DISABLE="header sysinfo tips updates config autoreboot-warn"/' "$vcfg")"
                printf '%s\n' "$_vcfg_out" | rvdk_atomic_write "$vcfg" 0644
            else
                {
                    cat "$vcfg"
                    printf '\nMOTD_DISABLE="header sysinfo tips updates config autoreboot-warn"\n'
                } | rvdk_atomic_write "$vcfg" 0644
            fi
            changed="true"
        fi
    done

    # Clear Armbian/OrangePi interactive root first-login wizard trigger on headless nodes
    if [[ -f "${root_prefix}/root/.not_logged_in_yet" ]]; then
        rm -f "${root_prefix}/root/.not_logged_in_yet" 2>/dev/null || true
    fi

    # 4. Install executable /etc/update-motd.d/10-rvdk-motd via same-dir atomic write
    local want_hook
    want_hook="$(
        printf '#!/bin/sh\n'
        printf '# Managed by RVDK (lib/motd.sh)\n'
        _rvdk_emit_motd_renderer_body
        printf '_rvdk_motd_render\n'
    )"

    if [[ ! -x "$motd_hook" ]] || ! printf '%s\n' "$want_hook" | cmp -s - "$motd_hook" 2>/dev/null; then
        printf '%s\n' "$want_hook" | rvdk_atomic_write "$motd_hook" 0755
        changed="true"
    fi

    if [[ -z "$root_prefix" ]] && command -v run-parts >/dev/null 2>&1 && [[ -d /run ]]; then
        run-parts --lsbsysinit "$motd_dir" > /run/motd.dynamic 2>/dev/null || true
    fi

    if [[ "$changed" == "true" ]]; then
        log_ok "Converged RVDK login MOTD header (${motd_hook})"
    else
        log_skip "RVDK login MOTD header already converged"
    fi
}

# Converge OpenWrt interactive login header (`/etc/profile.d/10-rvdk-motd.sh` + empty `/etc/banner`)
rvdk_converge_openwrt_motd() {
    local root_prefix="${1:-}"
    local prof_dir="${root_prefix}/etc/profile.d"
    local prof_hook="${prof_dir}/10-rvdk-motd.sh"
    local banner_f="${root_prefix}/etc/banner"
    local etc_motd="${root_prefix}/etc/motd"
    local bkp_dir="${root_prefix}/var/lib/rvdk/backups/motd"
    local changed="false"

    mkdir -p "$prof_dir" "$bkp_dir"
    chmod 0755 "$prof_dir" "$bkp_dir" 2>/dev/null || true

    if [[ ! -L "$banner_f" && -s "$banner_f" ]]; then
        [[ -f "${bkp_dir}/etc.banner.orig" ]] || cp -a "$banner_f" "${bkp_dir}/etc.banner.orig" 2>/dev/null || true
        printf '' | rvdk_atomic_write "$banner_f" 0644
        changed="true"
    fi

    if [[ ! -L "$etc_motd" && -s "$etc_motd" ]]; then
        [[ -f "${bkp_dir}/etc.motd.orig" ]] || cp -a "$etc_motd" "${bkp_dir}/etc.motd.orig" 2>/dev/null || true
        printf '' | rvdk_atomic_write "$etc_motd" 0644
        changed="true"
    fi

    local want_prof
    want_prof="$(
        cat <<'MOTD_PROF_HDR'
#!/bin/sh
# Managed by RVDK (lib/motd.sh)
if [ -n "${PS1:-}" ] && [ -z "${_RVDK_MOTD_SHOWN:-}" ]; then
    _RVDK_MOTD_SHOWN=1
MOTD_PROF_HDR
        _rvdk_emit_motd_renderer_body
        printf '    _rvdk_motd_render\n'
        printf 'fi\n'
    )"

    if ! printf '%s\n' "$want_prof" | cmp -s - "$prof_hook" 2>/dev/null; then
        printf '%s\n' "$want_prof" | rvdk_atomic_write "$prof_hook" 0644
        changed="true"
    fi

    if [[ "$changed" == "true" ]]; then
        log_ok "Converged OpenWrt RVDK login header (${prof_hook})"
    else
        log_skip "OpenWrt RVDK login header already converged"
    fi
}

# Restore original distro MOTD/banner state on `rvdk uninstall` (both standard & `--purge`).
# Returns 0 if any MOTD state was restored/removed, 1 if nothing was present.
rvdk_restore_login_motd() {
    local dry_run="${1:-false}"
    local root_prefix="${2:-}"
    local motd_dir="${root_prefix}/etc/update-motd.d"
    local motd_hook="${motd_dir}/10-rvdk-motd"
    local prof_hook="${root_prefix}/etc/profile.d/10-rvdk-motd.sh"
    local bkp_dir="${root_prefix}/var/lib/rvdk/backups/motd"
    local modes_file="${bkp_dir}/update-motd.modes"
    local links_bkp_dir="${bkp_dir}/update-motd.symlinks"
    local did_restore="false"

    if [[ -e "$motd_hook" || -L "$motd_hook" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY-RUN] Would remove RVDK MOTD hook: ${motd_hook}"
        else
            rm -f "$motd_hook"
            log_ok "Removed ${motd_hook}"
        fi
        did_restore="true"
    fi

    if [[ -e "$prof_hook" || -L "$prof_hook" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY-RUN] Would remove OpenWrt RVDK login hook: ${prof_hook}"
        else
            rm -f "$prof_hook"
            log_ok "Removed ${prof_hook}"
        fi
        did_restore="true"
    fi

    if [[ -d "$links_bkp_dir" ]]; then
        local lnk_f lnk_name lnk_target has_links="false"
        for lnk_f in "${links_bkp_dir}"/*; do
            [[ -L "$lnk_f" ]] || continue
            has_links="true"
            if [[ "$dry_run" != "true" ]]; then
                lnk_name="$(basename "$lnk_f")"
                [[ "$lnk_name" == */* || "$lnk_name" == ".." ]] && continue
                lnk_target="$(readlink "$lnk_f" 2>/dev/null || true)"
                if [[ -n "$lnk_target" ]]; then
                    mkdir -p "$motd_dir"
                    ln -snf "$lnk_target" "${motd_dir}/${lnk_name}"
                fi
                rm -f "$lnk_f"
            fi
        done
        if [[ "$has_links" == "true" ]]; then
            if [[ "$dry_run" == "true" ]]; then
                log_info "[DRY-RUN] Would restore default MOTD symlinks in ${motd_dir}"
            else
                rmdir "$links_bkp_dir" 2>/dev/null || true
                log_ok "Restored default MOTD symlinks in ${motd_dir}"
            fi
            did_restore="true"
        elif [[ "$dry_run" != "true" ]]; then
            rmdir "$links_bkp_dir" 2>/dev/null || true
        fi
    fi

    if [[ -f "$modes_file" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY-RUN] Would restore default permissions on ${motd_dir}/* from ${modes_file}"
        else
            local fmode fname target_f
            while IFS=' ' read -r fmode fname; do
                [[ -n "$fmode" && -n "$fname" ]] || continue
                [[ "$fname" == */* || "$fname" == ".." ]] && continue
                target_f="${motd_dir}/${fname}"
                [[ -f "$target_f" && ! -L "$target_f" ]] && chmod "$fmode" "$target_f" 2>/dev/null || true
            done < "$modes_file"
            rm -f "$modes_file"
            log_ok "Restored default MOTD script permissions in ${motd_dir}"
        fi
        did_restore="true"
    fi

    local pair src_bkp dst_orig bkp_target
    for pair in \
        "etc.motd.orig:${root_prefix}/etc/motd" \
        "etc.banner.orig:${root_prefix}/etc/banner" \
        "profile.50-landscape-sysinfo.sh.orig:${root_prefix}/etc/profile.d/50-landscape-sysinfo.sh" \
        "default.motd-news.orig:${root_prefix}/etc/default/motd-news" \
        "default.orangepi-motd.orig:${root_prefix}/etc/default/orangepi-motd" \
        "default.armbian-motd.orig:${root_prefix}/etc/default/armbian-motd"; do
        src_bkp="${bkp_dir}/${pair%%:*}"
        dst_orig="${pair#*:}"
        [[ -f "$src_bkp" || -L "$src_bkp" ]] || continue
        if [[ "$dry_run" == "true" ]]; then
            log_info "[DRY-RUN] Would restore default login file: ${dst_orig}"
        else
            mkdir -p "$(dirname "$dst_orig")"
            if [[ -L "$src_bkp" ]]; then
                bkp_target="$(readlink "$src_bkp" 2>/dev/null || true)"
                [[ -n "$bkp_target" ]] && ln -snf "$bkp_target" "$dst_orig"
            else
                cp -a "$src_bkp" "$dst_orig" 2>/dev/null || cp "$src_bkp" "$dst_orig"
            fi
            rm -f "$src_bkp"
            log_ok "Restored default ${dst_orig}"
        fi
        did_restore="true"
    done

    if [[ "$did_restore" == "true" && "$dry_run" != "true" ]]; then
        rmdir "$bkp_dir" "${root_prefix}/var/lib/rvdk/backups" "${root_prefix}/var/lib/rvdk" 2>/dev/null || true
        if [[ -z "$root_prefix" && -d /etc/update-motd.d && -d /run ]] && command -v run-parts >/dev/null 2>&1; then
            run-parts --lsbsysinit /etc/update-motd.d > /run/motd.dynamic 2>/dev/null || rm -f /run/motd.dynamic 2>/dev/null || true
            [[ -s /run/motd.dynamic ]] || rm -f /run/motd.dynamic 2>/dev/null || true
        fi
    fi

    [[ "$did_restore" == "true" ]]
}
