#!/usr/bin/env bash
# ==============================================================================
# DREW-V Labs // RVDK Idempotent APT Cache, Mirror & Package Helper Library
# Path: riscv-data-kit/lib/apt.sh
#
# Honors:
#   RVDK_NO_APT_UPDATE=1|true        Skip redundant `apt-get update` when index
#                                    lists already exist in /var/lib/apt/lists/.
#   RVDK_APT_STAMP_FILE=<path>       Touched whenever `apt-get update` actually
#                                    runs so parent pipelines (`rvdk` Day-0) can
#                                    skip redundant updates on subsequent steps.
#   RVDK_KEEP_VENDOR_MIRRORS=1|true  Preserve factory/regional APT mirrors
#                                    instead of normalizing to US-first HTTPS.
# ==============================================================================

[[ -n "${_RVDK_APT_SH_LOADED:-}" ]] && return 0
_RVDK_APT_SH_LOADED=1

if [[ -z "${_RVDK_COMMON_SH_LOADED:-}" ]]; then
    _RVDK_APT_LIB_DIR=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        _RVDK_APT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [[ -n "$_RVDK_APT_LIB_DIR" && -f "${_RVDK_APT_LIB_DIR}/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_RVDK_APT_LIB_DIR}/common.sh"
    fi
    unset _RVDK_APT_LIB_DIR
fi

_rvdk_apt_log_ok() {
    if declare -F log_ok >/dev/null 2>&1; then
        log_ok "$1"
    else
        printf "\033[1;32m  [OK]\033[0m %s\n" "$1"
    fi
}

_rvdk_apt_log_skip() {
    if declare -F log_skip >/dev/null 2>&1; then
        log_skip "$1"
    else
        printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"
    fi
}

rvdk_apt_has_lists() {
    compgen -G "/var/lib/apt/lists/*Packages*" >/dev/null 2>&1 || \
    compgen -G "/var/lib/apt/lists/*InRelease" >/dev/null 2>&1
}

# Rewrite APT source stream ($1=in_file, $2=scheme) to stdout from CN / plain
# HTTP mirrors onto US-first canonical endpoints. Uses `@` as the `sed` `s`
# delimiter so ERE `|` alternations never collide with the delimiter, and zero
# inner capture groups in `cn_hosts` for deterministic `\1` / `\2` captures.
_rvdk_apt_rewrite_stream() {
    local in_file="$1"
    local scheme="$2"
    local cn_hosts="repo\\.huaweicloud\\.com|mirrors\\.tuna\\.tsinghua\\.edu\\.cn|mirrors\\.bfsu\\.edu\\.cn|mirrors\\.ustc\\.edu\\.cn|mirrors\\.aliyun\\.com|mirrors\\.163\\.com|mirrors\\.cloud\\.tencent\\.com|mirrors\\.sohu\\.com|mirrors\\.zju\\.edu\\.cn|mirrors\\.nju\\.edu\\.cn|mirrors\\.sjtug\\.sjtu\\.edu\\.cn|mirrors\\.shanghaitech\\.edu\\.cn|mirrors\\.hit\\.edu\\.cn|mirrors\\.lzu\\.edu\\.cn|mirrors\\.cqu\\.edu\\.cn|mirrors\\.neusoft\\.edu\\.cn|mirrors\\.xjtu\\.edu\\.cn|mirror\\.iscas\\.ac\\.cn|mirror\\.sjtu\\.edu\\.cn|mirror\\.lzu\\.edu\\.cn|cn\\.archive\\.ubuntu\\.com|hk\\.archive\\.ubuntu\\.com|ftp\\.cn\\.debian\\.org|ftp\\.hk\\.debian\\.org"

    if [[ "$scheme" == "https" ]]; then
        sed -E \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/debian-security([[:space:]/]|$)@${scheme}://security.debian.org/debian-security\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/debian([[:space:]/]|$)@${scheme}://deb.debian.org/debian\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/ubuntu-ports([[:space:]/]|$)@${scheme}://ports.ubuntu.com/ubuntu-ports\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/ubuntu([[:space:]/]|$)@${scheme}://us.archive.ubuntu.com/ubuntu\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/armbian([[:space:]/]|$)@${scheme}://armbian.chi.auroradev.org/apt\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://apt\\.armbian\\.com([[:space:]/]|$)@${scheme}://armbian.chi.auroradev.org/apt\\1@g" \
            -e '/^[[:space:]]*#/! s@http://(deb|ftp\.us|ftp\.debian)\.debian\.org/debian([[:space:]/]|$)@https://deb.debian.org/debian\2@g' \
            -e '/^[[:space:]]*#/! s@http://security\.debian\.org/debian-security([[:space:]/]|$)@https://security.debian.org/debian-security\1@g' \
            -e '/^[[:space:]]*#/! s@http://ports\.ubuntu\.com/ubuntu-ports([[:space:]/]|$)@https://ports.ubuntu.com/ubuntu-ports\1@g' \
            -e '/^[[:space:]]*#/! s@http://(us\.)?archive\.ubuntu\.com/ubuntu([[:space:]/]|$)@https://us.archive.ubuntu.com/ubuntu\2@g' \
            -e '/^[[:space:]]*#/! s@http://security\.ubuntu\.com/ubuntu([[:space:]/]|$)@https://security.ubuntu.com/ubuntu\1@g' \
            "$in_file"
    else
        sed -E \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/debian-security([[:space:]/]|$)@${scheme}://security.debian.org/debian-security\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/debian([[:space:]/]|$)@${scheme}://deb.debian.org/debian\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/ubuntu-ports([[:space:]/]|$)@${scheme}://ports.ubuntu.com/ubuntu-ports\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/ubuntu([[:space:]/]|$)@${scheme}://us.archive.ubuntu.com/ubuntu\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://(${cn_hosts})/armbian([[:space:]/]|$)@${scheme}://armbian.chi.auroradev.org/apt\\2@g" \
            -e "/^[[:space:]]*#/! s@https?://apt\\.armbian\\.com([[:space:]/]|$)@${scheme}://armbian.chi.auroradev.org/apt\\1@g" \
            "$in_file"
    fi
}

# Normalize factory CN / plain-HTTP APT mirrors onto canonical US-first signed
# HTTPS endpoints (deb.debian.org / security.debian.org / ports.ubuntu.com /
# armbian.chi.auroradev.org), preserving GPG verification and adding missing
# Debian `-security` suites when omitted by vendor board images.
rvdk_apt_normalize_mirrors() {
    local quiet_skip="false"
    [[ "${1:-}" == "--quiet-skip" ]] && quiet_skip="true"

    [[ "$(uname -s)" == "Linux" ]] || return 0
    command -v apt-get >/dev/null 2>&1 || return 0

    if [[ "${RVDK_KEEP_VENDOR_MIRRORS:-0}" == "1" || "${RVDK_KEEP_VENDOR_MIRRORS:-false}" == "true" ]]; then
        [[ "$quiet_skip" == "true" ]] || _rvdk_apt_log_skip "Preserving existing APT mirrors (--keep-mirrors)"
        export _RVDK_APT_MIRRORS_CHECKED="1"
        return 0
    fi

    local os_id="debian" os_codename="" arch=""
    if [[ -r /etc/os-release ]]; then
        os_id="$(awk -F= '/^ID=/ {gsub(/["'\'']/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || echo debian)"
        os_codename="$(awk -F= '/^VERSION_CODENAME=/ {gsub(/["'\'']/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || true)"
    fi
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

    local scheme="http" need_ca_upgrade="false"
    if [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
        scheme="https"
    else
        need_ca_upgrade="true"
    fi

    local src_files=() f
    [[ -f /etc/apt/sources.list ]] && src_files+=("/etc/apt/sources.list")
    if [[ -d /etc/apt/sources.list.d ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] && src_files+=("$f")
        done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) 2>/dev/null | sort)
    fi

    local changed="false" backup_dir="/var/lib/rvdk/backups/apt" rewritten bname
    for f in ${src_files[@]+"${src_files[@]}"}; do
        [[ -f "$f" ]] || continue
        rewritten="$(_rvdk_apt_rewrite_stream "$f" "$scheme")"

        if ! printf '%s\n' "$rewritten" | cmp -s - "$f" 2>/dev/null; then
            mkdir -p "$backup_dir"
            bname="$(printf '%s' "$f" | sed 's@^/@@; s@/@__@g')"
            [[ -f "${backup_dir}/${bname}.orig" ]] || cp -a "$f" "${backup_dir}/${bname}.orig" 2>/dev/null || true
            printf '%s\n' "$rewritten" | rvdk_atomic_write "$f" 0644
            changed="true"
        fi
    done

    # Vendor Debian images (e.g. Orange Pi RV2) frequently omit `${suite}-security`
    if [[ "$os_id" == "debian" && -f /etc/apt/sources.list ]]; then
        if [[ -z "$os_codename" ]]; then
            os_codename="$(awk '!/^[[:space:]]*#/ && $1 == "deb" { for (i=2; i<=NF; i++) if ($i ~ /\/debian\/?$/) { print $(i+1); exit } }' /etc/apt/sources.list 2>/dev/null || true)"
        fi
        if [[ -n "$os_codename" && "$os_codename" != "sid" && "$os_codename" != "unstable" && "$os_codename" != "experimental" ]]; then
            if [[ "$arch" != "riscv64" || ( "$os_codename" != "bookworm" && "$os_codename" != "bullseye" ) ]]; then
                local has_sec="false"
                for f in ${src_files[@]+"${src_files[@]}"}; do
                    if awk -v s="${os_codename}-security" '!/^[[:space:]]*#/ && (index($0, "debian-security") || index($0, s)) { found=1 } END { exit !found }' "$f" 2>/dev/null; then
                        has_sec="true"
                        break
                    fi
                done
                if [[ "$has_sec" == "false" ]] && awk '!/^[[:space:]]*#/ && $1 == "deb" && index($0, "/debian") { found=1 } END { exit !found }' /etc/apt/sources.list 2>/dev/null; then
                    mkdir -p "$backup_dir"
                    [[ -f "${backup_dir}/etc__apt__sources.list.orig" ]] || cp -a /etc/apt/sources.list "${backup_dir}/etc__apt__sources.list.orig" 2>/dev/null || true
                    local sec_opt=""
                    if grep -Eq '^[[:space:]]*deb[[:space:]]+\[signed-by=/usr/share/keyrings/debian-archive-keyring\.gpg\]' /etc/apt/sources.list 2>/dev/null; then
                        sec_opt="[signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] "
                    fi
                    local sec_comps="main contrib non-free non-free-firmware"
                    [[ "$os_codename" == "bullseye" ]] && sec_comps="main contrib non-free"
                    {
                        cat /etc/apt/sources.list
                        printf 'deb %s%s://security.debian.org/debian-security %s-security %s\n' "$sec_opt" "$scheme" "$os_codename" "$sec_comps"
                    } | rvdk_atomic_write /etc/apt/sources.list 0644
                    changed="true"
                fi
            fi
        fi
    fi

    # Purge any leftover CN cached index files in /var/lib/apt/lists/
    local stale_cn_lists="false"
    if [[ -d /var/lib/apt/lists ]]; then
        if find /var/lib/apt/lists -maxdepth 1 -type f \( \
            -name '*huaweicloud*' -o -name '*tsinghua*' -o -name '*aliyun*' \
            -o -name '*ustc.edu*' -o -name '*bfsu.edu*' -o -name '*163.com*' \
            -o -name '*tencent*' -o -name '*iscas.ac.cn*' -o -name '*cn.archive.ubuntu*' \
        \) 2>/dev/null | grep -q .; then
            stale_cn_lists="true"
        fi
    fi

    export _RVDK_APT_MIRRORS_CHECKED="1"

    if [[ "$changed" == "true" || "$stale_cn_lists" == "true" ]]; then
        rm -rf /var/lib/apt/lists/* 2>/dev/null || true
        export RVDK_NO_APT_UPDATE="0"
        if [[ "$need_ca_upgrade" == "true" ]]; then
            apt-get -o Acquire::Check-Valid-Until=false -o DPkg::Lock::Timeout=120 update -q || true
            DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=120 install ca-certificates >/dev/null 2>&1 || true
            if [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
                export _RVDK_APT_MIRRORS_CHECKED="0"
                rvdk_apt_normalize_mirrors --quiet-skip
                return 0
            fi
        fi
        local scheme_upper
        scheme_upper="$(printf '%s' "$scheme" | tr '[:lower:]' '[:upper:]')"
        _rvdk_apt_log_ok "Normalized APT sources onto signed US-first ${scheme_upper} mirrors (${os_id})"
    elif [[ "$quiet_skip" != "true" ]]; then
        _rvdk_apt_log_skip "APT mirrors already converged on signed US-first HTTPS endpoints"
    fi
}

rvdk_apt_mark_updated() {
    export RVDK_NO_APT_UPDATE="1"
    if [[ -n "${RVDK_APT_STAMP_FILE:-}" ]]; then
        touch "$RVDK_APT_STAMP_FILE" 2>/dev/null || true
    fi
}

rvdk_apt_update() {
    if [[ "${_RVDK_APT_MIRRORS_CHECKED:-0}" != "1" ]]; then
        rvdk_apt_normalize_mirrors --quiet-skip
    fi
    if [[ "${RVDK_NO_APT_UPDATE:-0}" == "1" || "${RVDK_NO_APT_UPDATE:-false}" == "true" ]]; then
        if rvdk_apt_has_lists; then
            return 0
        fi
    fi
    apt-get -o Acquire::Check-Valid-Until=false -o DPkg::Lock::Timeout=120 update -q || \
        apt-get -o DPkg::Lock::Timeout=120 update -q
    rvdk_apt_mark_updated
}

rvdk_pkg_installed() {
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -qx "install ok installed"
}

rvdk_apt_ensure() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        [[ -z "$pkg" ]] && continue
        if ! rvdk_pkg_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    local flags=(-y -o DPkg::Lock::Timeout=120 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold")
    if [[ -n "${APT_FLAGS[0]+x}" ]]; then
        flags=("${APT_FLAGS[@]}")
    fi

    rvdk_apt_update
    if ! apt-get install "${flags[@]}" "${missing[@]}"; then
        # Self-heal if --no-apt-update was passed with stale mirror indices
        RVDK_NO_APT_UPDATE="0" rvdk_apt_update
        apt-get install "${flags[@]}" "${missing[@]}"
    fi
}
