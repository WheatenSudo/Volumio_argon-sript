#!/usr/bin/env bash
# Argon ONE installer for Raspberry Pi OS Bookworm
# Refactored from the Argon40 installer. This edition targets CHECKDEVICE="one".
/bin/bash -c "sleep 1; /usr/bin/sudo /bin/date -s \"$(/usr/bin/curl -s --head http://google.com | grep ^Date: | sed 's/Date: //g')\""

set -Eeuo pipefail
IFS=$'\n\t'

readonly ARGON_SERVER="https://download.argon40.com"
readonly INSTALL_DIR="/etc/argon"
readonly CONFIG_FILE="/boot/userconfig.txt"
readonly DAEMON_NAME="argononed"
readonly DAEMON_SCRIPT="$INSTALL_DIR/argononed.py"
readonly POWER_BUTTON_SCRIPT="$INSTALL_DIR/argonpowerbutton.py"
readonly FAN_CONFIG_SCRIPT="$INSTALL_DIR/argonone-fanconfig.sh"
readonly IR_CONFIG_SCRIPT="$INSTALL_DIR/argonone-ir"
readonly BLSTR_DAC_SCRIPT="$INSTALL_DIR/argon-blstrdac.sh"
readonly UNIT_CONFIG_SCRIPT="$INSTALL_DIR/argon-unitconfig.sh"
readonly STATUS_SCRIPT="$INSTALL_DIR/argon-status.sh"
readonly VERSION_SCRIPT="$INSTALL_DIR/argon-versioninfo.sh"
readonly CONFIG_SCRIPT="$INSTALL_DIR/argon-config"
readonly UNINSTALL_SCRIPT="$INSTALL_DIR/argon-uninstall.sh"
readonly SHUTDOWN_SCRIPT="/lib/systemd/system-shutdown/argon-shutdown.sh"
readonly SERVICE_FILE="/lib/systemd/system/argononed.service"
readonly FAN_CONFIG_FILE="/etc/argononed.conf"
readonly UNIT_CONFIG_FILE="/etc/argonunits.conf"
readonly EEPROM_TOOL="/usr/bin/rpi-eeprom-config"
readonly EEPROM_CONFIG_SCRIPT="$INSTALL_DIR/argonone-eepromconfig.py"

SETUP_MODE="Setup"
NEEDS_TIME_SYNC=0

log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
    local exit_code=$?
    printf '\nInstallation failed at line %s: %s\n' "$1" "$2" >&2
    exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

require_root_tools() {
    command -v sudo >/dev/null 2>&1 || die "sudo is required."
    command -v apt-get >/dev/null 2>&1 || die "This installer requires an APT-based operating system."
}

check_platform() {
    [[ -r /etc/os-release ]] || die "/etc/os-release was not found."
    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        raspbian|debian) ;;
        *) warn "This script is intended for Raspberry Pi OS/Debian Bookworm; detected ${PRETTY_NAME:-unknown}." ;;
    esac

    if [[ "${VERSION_CODENAME:-}" != "bookworm" && "${VERSION_ID:-}" != "12" ]]; then
        warn "Bookworm was not detected; detected ${PRETTY_NAME:-unknown}."
    fi

    [[ -f "$CONFIG_FILE" ]] || die "$CONFIG_FILE was not found. Is this Raspberry Pi OS Bookworm?"
}

check_time() {
    local local_time global_time difference
    local_time=$(date -u +%s)
    global_time=$(curl -fsSL --connect-timeout 5 --max-time 10 \
        "https://worldtimeapi.org/api/ip.txt" 2>/dev/null | \
        awk -F': ' '$1 == "unixtime" {print $2; exit}') || true

    if [[ "$global_time" =~ ^[0-9]+$ ]]; then
        difference=$((global_time - local_time))
        (( difference < 0 )) && difference=$((-difference))
        (( difference > 100000 )) && NEEDS_TIME_SYNC=1
    else
        warn "Could not verify the system clock. Continuing installation."
    fi
}

show_time_warning() {
    cat <<'EOF'
**********************************************
* WARNING: Device time seems to be incorrect *
* This may cause problems during setup.      *
**********************************************
Possible Network Time Protocol server issue.
Try:
  curl -fsSL https://download.argon40.com/tools/setntpserver.sh | sudo bash
EOF
}

is_pi5() {
    grep -qE '^Revision[[:space:]]*:[[:space:]]*[123][0-9a-fA-F]{2}4[0-9a-fA-F]{3}$' /proc/cpuinfo
}

set_config_var() {
    local key=$1 value=$2 file=$3 target tmp
    target="$key=$value"
    tmp=$(mktemp)

    if ! grep -q '^\[all\]$' "$file"; then
        printf '\n[all]\n' | sudo tee -a "$file" >/dev/null
    fi

    if awk -v target="$target" '
        /^\[all\]$/ {in_all=1; next}
        /^\[/ {in_all=0}
        in_all && $0 == target {found=1}
        END {exit !found}
    ' "$file"; then
        return 0
    fi

    sudo awk -v target="$target" '
        /^\[all\]$/ {print; in_all=1; next}
        /^\[/ && in_all {print target; in_all=0}
        {print}
        END {if (in_all) print target}
    ' "$file" >"$tmp"

    sudo install -m 644 "$tmp" "$file"
    rm -f "$tmp"
}

enable_hardware_interfaces() {
    log "Updating boot configuration..."
    set_config_var dtparam i2c_arm=on "$CONFIG_FILE"
    set_config_var enable_uart 1 "$CONFIG_FILE"

    if is_pi5; then
        set_config_var dtparam nvme "$CONFIG_FILE"
        set_config_var dtparam=pciex1_gen 3 "$CONFIG_FILE"
        set_config_var usb_max_current_enable 1 "$CONFIG_FILE"
    fi
}

package_available() {
    apt-cache show "$1" >/dev/null 2>&1
}

install_dependencies() {
    log "Updating APT package information..."
    sudo apt-get update

    local gpio_package
    if package_available python3-libgpiod; then
        gpio_package=python3-libgpiod
    elif package_available python3-gpiod; then
        gpio_package=python3-gpiod
    else
        die "Neither python3-libgpiod nor python3-gpiod is available from the configured repositories."
    fi

    log "Using GPIO package: $gpio_package"
    sudo apt-get install -y \
        ca-certificates curl wget \
        "$gpio_package" python3-smbus i2c-tools
}

download() {
    local relative_path=$1 destination=$2 mode=${3:-755}
    local url="$ARGON_SERVER/$relative_path" tmp
    tmp=$(mktemp)

    log "Downloading $relative_path"
    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 120 \
        "$url" -o "$tmp"; then
        rm -f "$tmp"
        die "Failed to download $url"
    fi

    sudo install -D -m "$mode" "$tmp" "$destination"
    rm -f "$tmp"
}

prepare_directories() {
    if [[ -f "$CONFIG_SCRIPT" ]]; then
        SETUP_MODE="Update"
    fi

    sudo install -d -m 755 "$INSTALL_DIR"
    sudo install -d -m 755 /lib/systemd/system /lib/systemd/system-shutdown
}

download_argon_files() {
    log "Installing/updating Argon scripts and services..."

    if [[ -x "$EEPROM_TOOL" ]]; then
        download scripts/argon-rpi-eeprom-config-psu.py "$EEPROM_CONFIG_SCRIPT"
    fi

    download scripts/argonone-fanconfig.sh "$FAN_CONFIG_SCRIPT"
    download scripts/argononed.py "$DAEMON_SCRIPT"
    download scripts/argononed.service "$SERVICE_FILE" 644
    download scripts/argonone-irconfig.sh "$IR_CONFIG_SCRIPT"
    download scripts/argon-blstrdac.sh "$BLSTR_DAC_SCRIPT"
    download scripts/argonstatus.py "$INSTALL_DIR/argonstatus.py"
    download scripts/argondashboard.py "$INSTALL_DIR/argondashboard.py"
    download scripts/argon-status.sh "$STATUS_SCRIPT"
    download scripts/argon-versioninfo.sh "$VERSION_SCRIPT"
    download scripts/argonsysinfo.py "$INSTALL_DIR/argonsysinfo.py"
    download scripts/argonregister.py "$INSTALL_DIR/argonregister.py"
    download scripts/argonpowerbutton-libgpiod.py "$POWER_BUTTON_SCRIPT"
    download scripts/argon-unitconfig.sh "$UNIT_CONFIG_SCRIPT"
    download scripts/argon-uninstall.sh "$UNINSTALL_SCRIPT"
    download scripts/argon-shutdown.sh "$SHUTDOWN_SCRIPT"
}

create_default_configs() {
    if [[ ! -e "$FAN_CONFIG_FILE" ]]; then
        sudo tee "$FAN_CONFIG_FILE" >/dev/null <<'EOF'
#
# Argon Fan Speed Configuration (CPU)
#
55=30
60=55
65=100
EOF
        sudo chmod 644 "$FAN_CONFIG_FILE"
    fi

    if [[ ! -e "$UNIT_CONFIG_FILE" ]]; then
        printf '#\n' | sudo tee "$UNIT_CONFIG_FILE" >/dev/null
        sudo chmod 644 "$UNIT_CONFIG_FILE"
    fi
}

create_config_tool() {
    local tmp
    tmp=$(mktemp)

    cat >"$tmp" <<EOF
#!/usr/bin/env bash
set -u

get_number() {
    local number
    read -r number
    if [[ \$number =~ ^[0-9]+$ ]] && (( number >= 0 && number <= 6 )); then
        printf '%s\\n' "\$number"
    else
        printf '%s\\n' -1
    fi
}

while true; do
    echo
    echo "--------------------------"
    echo "Argon Configuration Tool"
    "$VERSION_SCRIPT" simple || true
    echo "--------------------------"
    echo "Choose Option:"
    echo "  1. Configure Fan"
    echo "  2. Configure IR"
    echo "  3. Configure BLSTR DAC"
    echo "  4. Configure Units"
    echo "  5. System Information"
    echo "  6. Uninstall"
    echo
    echo "  0. Exit"
    printf 'Enter Number (0-6): '
    selection=\$(get_number)

    case "\$selection" in
        0) echo "Thank you."; exit 0 ;;
        1) "$FAN_CONFIG_SCRIPT" ;;
        2) "$IR_CONFIG_SCRIPT" ;;
        3) "$BLSTR_DAC_SCRIPT" ;;
        4) "$UNIT_CONFIG_SCRIPT" ;;
        5) "$STATUS_SCRIPT" ;;
        6) "$UNINSTALL_SCRIPT"; exit 0 ;;
        *) echo "Invalid selection." ;;
    esac
done
EOF

    sudo install -m 755 "$tmp" "$CONFIG_SCRIPT"
    rm -f "$tmp"
}

create_links() {
    sudo ln -sfn "$CONFIG_SCRIPT" /usr/bin/argon-config
    sudo ln -sfn "$CONFIG_SCRIPT" /usr/bin/argonone-config
    sudo ln -sfn "$UNINSTALL_SCRIPT" /usr/bin/argonone-uninstall
    sudo ln -sfn "$IR_CONFIG_SCRIPT" /usr/bin/argonone-ir
}

create_desktop_shortcut() {
    local target_user home_dir desktop icon shortcut tmp
    target_user=${SUDO_USER:-${USER:-}}
    [[ -n "$target_user" ]] || return 0

    home_dir=$(getent passwd "$target_user" | cut -d: -f6)
    [[ -n "$home_dir" ]] || return 0
    desktop="$home_dir/Desktop"
    [[ -d "$desktop" ]] || return 0

    icon=/usr/share/pixmaps/ar1config.png
    shortcut="$desktop/argonone-config.desktop"
    download ar1config.png "$icon" 644

    tmp=$(mktemp)
    cat >"$tmp" <<EOF
[Desktop Entry]
Name=Argon Configuration
Comment=Argon Configuration
Icon=$icon
Exec=argonone-config
Type=Application
Terminal=true
Categories=Settings;System;
EOF
    sudo install -m 755 -o "$target_user" -g "$(id -gn "$target_user")" "$tmp" "$shortcut"
    rm -f "$tmp"
}

start_service() {
    log "Initializing service..."
    sudo systemctl daemon-reload
    sudo systemctl enable --now argononed.service
    sudo systemctl --no-pager --full status argononed.service || true
}

update_eeprom() {
    if [[ -x "$EEPROM_TOOL" && -x "$EEPROM_CONFIG_SCRIPT" ]]; then
        log "Checking Raspberry Pi EEPROM..."
        sudo rpi-eeprom-update || warn "EEPROM check/update returned a non-zero status."
        sudo "$EEPROM_CONFIG_SCRIPT" || warn "Argon EEPROM configuration did not complete successfully."
    fi
}

main() {
    echo "*************"
    echo " Argon Setup "
    echo " Bookworm   "
    echo "*************"

    require_root_tools
    check_platform
    check_time
    (( NEEDS_TIME_SYNC == 1 )) && show_time_warning

    install_dependencies
    prepare_directories
    enable_hardware_interfaces
    download_argon_files
    create_default_configs
    create_config_tool
    create_links
    create_desktop_shortcut
    start_service
    update_eeprom

    echo
    echo "*********************"
    echo "  $SETUP_MODE Completed"
    echo "*********************"
    "$VERSION_SCRIPT" || true
    echo
    echo "Use 'sudo argonone-config' to configure the device."
    echo "A reboot is recommended so boot configuration changes take effect:"
    echo "  sudo reboot"

    
}

main "$@"
