#!/bin/bash

# Build a complete Virtualization.framework-on-iPad package from a fresh
# checkout. With no arguments this is an interactive wizard; every choice is
# also available as an option or environment variable for unattended builds.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
MACOS_NAME="UniversalMac_13.2.1_22D68_Restore.ipsw"
BIG_SUR_NAME="UniversalMac_11.6_20G165_Restore.ipsw"
IPADOS_NAME="iPad14,3,iPad14,4,iPad14,5,iPad14,6_16.3.1_20D67_Restore.ipsw"
IPADOS14_NAME="iPad_Spring_2021_14.5_18E199_Restore.ipsw"
IPADOS15_NAME="iPad_Pro_Spring_2021_15.0_19A346_Restore.ipsw"
MACOS_URL="https://updates.cdn-apple.com/2023WinterFCS/fullrestores/032-48346/EFF99C1E-C408-4E7A-A448-12E1468AF06C/$MACOS_NAME"
BIG_SUR_URL="https://updates.cdn-apple.com/2021FallFCS/fullrestores/071-97388/C361BF5E-0E01-47E5-8D30-5990BC3C9E29/$BIG_SUR_NAME"
IPADOS_URL="https://updates.cdn-apple.com/2023WinterFCS/fullrestores/032-50028/ACF197BE-D22C-49EC-94C5-C1B58D7708AC/$IPADOS_NAME"
IPADOS14_URL="https://updates.cdn-apple.com/2021SpringFCS/fullrestores/071-17692/4BB409F6-D860-416B-A0EF-BDC941C74F3E/$IPADOS14_NAME"
IPADOS15_URL="https://updates.cdn-apple.com/2021FallFCS/fullrestores/002-02897/6B63FC96-3F0A-4DC4-B065-BFA88F2EF7AF/$IPADOS15_NAME"
MACOS_SHA256="0310220c8a540dc53a92ec9f9e0894db627d8f97fd18c3275eb96865a6e5fe04"
BIG_SUR_SHA256="9bc6b9e0d42bb892ee139a8d88fc5e8ce2931d57743d8e3ed1ce45aa5da8add6"
IPADOS_SHA256="a4d922f3fdc960fd5714b5d46c13b928c1249e072cb93301bd1f7bb66ec29cc0"
IPADOS14_SHA256="11023b65bc2f08eabbb141fa494873d41a1d4a43fca09904480d8e55e8065dc4"
IPADOS15_SHA256="f678d0c061c1dd8a3afdf4a3aee12123b95c47607a2fe5a8accc4b608ccf7344"
DEVICE_SUPPORT_NAME="DeviceSupport_macOS_27_beta.dmg"
DEVICE_SUPPORT_URL="https://github.com/nfzerox/DeviceSupportMirror/releases/download/1.0/$DEVICE_SUPPORT_NAME"
DEVICE_SUPPORT_SHA256="d02e14429a02a78d8bf9d84df8ae55f5a03f2a00dbf58767f451b68eda417ca1"

BUILD_ROOT="${VZ_BUILD_ROOT:-$REPO_ROOT/build}"
DOWNLOAD_ROOT="${VZ_DOWNLOAD_ROOT:-$BUILD_ROOT/downloads}"
MACOS_IPSW="${VZ_MACOS_IPSW:-}"
BIG_SUR_IPSW="${VZ_BIG_SUR_IPSW:-}"
IPADOS_IPSW="${VZ_IPADOS_IPSW:-}"
IPADOS14_IPSW="${VZ_IPADOS14_IPSW:-}"
IPADOS15_IPSW="${VZ_IPADOS15_IPSW:-}"
DEVICE_SUPPORT_DMG="${VZ_DEVICE_SUPPORT_DMG:-}"
XCODE_PATH="${DEVELOPER_DIR:-${VZ_XCODE_PATH:-}}"
IPAD_UDID="${VZ_IPAD_UDID:-}"
IPAD_PORT="${VZ_IPAD_PORT:-2221}"
IPAD_PASSWORD_FILE=""
INTERACTIVE=-1
FULL_IPADOS_AUDIT=0
INSTALL_IPAD=0
LAUNCH_IPAD=0
SKIP_DEPENDENCIES=0
BUILD_ROOTHIDE=1
INSTALL_ROOTHIDE=0

usage() {
    cat <<'EOF'
Usage: ./setup.sh [options]

Build options:
  --build-dir PATH       Generated files (default: ./build)
  --download-dir PATH    Downloaded restore images (default: BUILD/downloads)
  --macos-ipsw PATH      Reuse macOS 13.2.1 (22D68) restore image
  --big-sur-ipsw PATH    Reuse macOS 11.6 (20G165) restore image for iPadOS 14
  --ipados14-ipsw PATH   Reuse iPadOS 14.5 (18E199) matching helper image
  --full-ipados-audit    Audit the built payload against iPadOS 14, 15, and 16
  --ipados-ipsw PATH     Reuse 16.3.1 image for --full-ipados-audit
  --ipados15-ipsw PATH   Reuse 15.0 image for --full-ipados-audit
  --device-support-dmg P Reuse the macOS 27 DeviceSupport disk image
  --xcode PATH           Xcode.app or its Contents/Developer directory
  --skip-dependencies    Do not install Homebrew or Brewfile dependencies
  --no-roothide          Skip the native Dopamine-roothide package
  --non-interactive      Never prompt; download omitted restore images

Optional iPad deployment:
  --install              Install the standard deb over USB SSH
  --install-roothide     Install the Dopamine-roothide deb over USB SSH
  --launch               Install and then launch Virtual Mac
  --ipad-udid UDID       Target device; auto-detected when exactly one is attached
  --ipad-port PORT       Local iproxy port (default: 2221)
  --ipad-password-file P Read the SSH password from P

Environment equivalents are documented in .env.example. Passwords are never
accepted as command-line values because process arguments are observable.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --build-dir) BUILD_ROOT="${2:?missing path}"; shift 2 ;;
        --download-dir) DOWNLOAD_ROOT="${2:?missing path}"; shift 2 ;;
        --macos-ipsw) MACOS_IPSW="${2:?missing path}"; shift 2 ;;
        --big-sur-ipsw) BIG_SUR_IPSW="${2:?missing path}"; shift 2 ;;
        --ipados14-ipsw) IPADOS14_IPSW="${2:?missing path}"; shift 2 ;;
        --ipados15-ipsw) IPADOS15_IPSW="${2:?missing path}"; FULL_IPADOS_AUDIT=1; shift 2 ;;
        --ipados-ipsw) IPADOS_IPSW="${2:?missing path}"; FULL_IPADOS_AUDIT=1; shift 2 ;;
        --device-support-dmg) DEVICE_SUPPORT_DMG="${2:?missing path}"; shift 2 ;;
        --full-ipados-audit) FULL_IPADOS_AUDIT=1; shift ;;
        --xcode) XCODE_PATH="${2:?missing path}"; shift 2 ;;
        --skip-dependencies) SKIP_DEPENDENCIES=1; shift ;;
        --no-roothide) BUILD_ROOTHIDE=0; shift ;;
        --non-interactive) INTERACTIVE=0; shift ;;
        --install) INSTALL_IPAD=1; shift ;;
        --install-roothide) INSTALL_IPAD=1; INSTALL_ROOTHIDE=1; shift ;;
        --launch) INSTALL_IPAD=1; LAUNCH_IPAD=1; shift ;;
        --ipad-udid) IPAD_UDID="${2:?missing UDID}"; shift 2 ;;
        --ipad-port) IPAD_PORT="${2:?missing port}"; shift 2 ;;
        --ipad-password-file) IPAD_PASSWORD_FILE="${2:?missing path}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (run ./setup.sh --help)" ;;
    esac
done

if [[ "$INSTALL_ROOTHIDE" == 1 && "$BUILD_ROOTHIDE" != 1 ]]; then
    die "--install-roothide needs the roothide package; drop --no-roothide"
fi

# No explicit --non-interactive marker is retained after parsing, so enable
# the wizard whenever a terminal is attached and CI has not opted out.
if [[ "$INTERACTIVE" == -1 ]]; then
    if [[ -t 0 && "${CI:-}" != true && "${VZ_NONINTERACTIVE:-0}" != 1 ]]; then
        INTERACTIVE=1
    else
        INTERACTIVE=0
    fi
fi

prompt_default() {
    local prompt="$1" default_value="$2" answer
    read -r -p "$prompt [$default_value]: " answer
    printf '%s' "${answer:-$default_value}"
}

prompt_yes_no() {
    local prompt="$1" default_value="$2" answer suffix
    if [[ "$default_value" == 1 ]]; then suffix="Y/n"; else suffix="y/N"; fi
    read -r -p "$prompt [$suffix]: " answer
    case "${answer:-}" in
        y|Y|yes|YES) return 0 ;;
        n|N|no|NO) return 1 ;;
        '') [[ "$default_value" == 1 ]] ;;
        *) echo "Please answer yes or no." >&2; prompt_yes_no "$prompt" "$default_value" ;;
    esac
}

absolute_directory() {
    mkdir -p "$1"
    (cd "$1" && pwd -P)
}

absolute_file() {
    local directory basename
    directory="$(dirname "$1")"
    basename="$(basename "$1")"
    (cd "$directory" && printf '%s/%s\n' "$(pwd -P)" "$basename")
}

install_homebrew() {
    if command -v brew >/dev/null 2>&1; then return; fi
    command -v curl >/dev/null 2>&1 || die "curl is required to install Homebrew"
    echo "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    else
        die "Homebrew installation completed but brew is not on PATH"
    fi
}

select_xcode() {
    local developer_path="$XCODE_PATH"
    if [[ -n "$developer_path" && "$developer_path" == *.app ]]; then
        developer_path="$developer_path/Contents/Developer"
    fi
    if [[ -n "$developer_path" ]]; then
        [[ -d "$developer_path" ]] || die "Xcode developer directory not found: $developer_path"
        export DEVELOPER_DIR="$developer_path"
    fi

    if xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then return; fi

    if [[ "$INTERACTIVE" == 1 ]]; then
        echo "A full Xcode with an iPhoneOS SDK is required." >&2
        echo "Install Xcode now, then enter its path below." >&2
        developer_path="$(prompt_default "Xcode.app path" "/Applications/Xcode.app")"
        if [[ "$developer_path" == *.app ]]; then
            developer_path="$developer_path/Contents/Developer"
        fi
        [[ -d "$developer_path" ]] || die "Xcode developer directory not found: $developer_path"
        export DEVELOPER_DIR="$developer_path"
    else
        die "full Xcode is missing; install it or pass --xcode PATH"
    fi
    xcrun --sdk iphoneos --show-sdk-path >/dev/null ||
        die "selected Xcode has no iPhoneOS SDK"
}

find_existing_restore() {
    local requested="$1" filename="$2" candidate
    if [[ -n "$requested" ]]; then printf '%s' "$requested"; return; fi
    for candidate in "$DOWNLOAD_ROOT/$filename" "${HOME:-}/Downloads/$filename"; do
        if [[ -f "$candidate" ]]; then printf '%s' "$candidate"; return; fi
    done
}

obtain_verified_file() {
    local label="$1" current="$2" filename="$3" url="$4" expected="$5" choice actual
    choice="$(find_existing_restore "$current" "$filename")"
    if [[ "$INTERACTIVE" == 1 ]]; then
        if [[ -n "$choice" ]]; then
            choice="$(prompt_default "$label file (blank downloads it)" "$choice")"
        else
            read -r -p "$label file path (blank downloads it): " choice
        fi
    fi
    if [[ -z "$choice" ]]; then
        choice="$DOWNLOAD_ROOT/$filename"
        mkdir -p "$DOWNLOAD_ROOT"
        echo "Downloading $label to $choice" >&2
        curl --fail --location --continue-at - --output "$choice" "$url"
    fi
    [[ -f "$choice" ]] || die "$label file not found: $choice"
    choice="$(absolute_file "$choice")"
    echo "Verifying $label file..." >&2
    actual="$(shasum -a 256 "$choice" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] ||
        die "$label restore image SHA-256 mismatch: expected $expected, got $actual"
    printf '%s' "$choice"
}

BUILD_ROOT="$(absolute_directory "$BUILD_ROOT")"
DOWNLOAD_ROOT="$(absolute_directory "$DOWNLOAD_ROOT")"

if [[ "$INTERACTIVE" == 1 ]]; then
    echo "Virtual Mac on iPad clean build wizard"
    echo "Generated files will remain outside Git. Existing verified downloads are reused."
    BUILD_ROOT="$(absolute_directory "$(prompt_default "Build directory" "$BUILD_ROOT")")"
    DOWNLOAD_ROOT="$(absolute_directory "$(prompt_default "Restore-image directory" "$DOWNLOAD_ROOT")")"
fi

if [[ "$SKIP_DEPENDENCIES" == 0 ]]; then
    install_homebrew
    brew bundle install --file "$REPO_ROOT/Brewfile"
fi

command -v curl >/dev/null 2>&1 || die "missing command: curl"
command -v shasum >/dev/null 2>&1 || die "missing command: shasum"
select_xcode

MACOS_IPSW="$(obtain_verified_file macOS "$MACOS_IPSW" "$MACOS_NAME" "$MACOS_URL" "$MACOS_SHA256")"
BIG_SUR_IPSW="$(obtain_verified_file 'macOS Big Sur' "$BIG_SUR_IPSW" \
    "$BIG_SUR_NAME" "$BIG_SUR_URL" "$BIG_SUR_SHA256")"
IPADOS14_IPSW="$(obtain_verified_file 'iPadOS 14.5' "$IPADOS14_IPSW" \
    "$IPADOS14_NAME" "$IPADOS14_URL" "$IPADOS14_SHA256")"
DEVICE_SUPPORT_DMG="$(obtain_verified_file DeviceSupport "$DEVICE_SUPPORT_DMG" \
    "$DEVICE_SUPPORT_NAME" "$DEVICE_SUPPORT_URL" "$DEVICE_SUPPORT_SHA256")"
if [[ "$FULL_IPADOS_AUDIT" == 1 ]]; then
    IPADOS15_IPSW="$(obtain_verified_file 'iPadOS 15.0' "$IPADOS15_IPSW" \
        "$IPADOS15_NAME" "$IPADOS15_URL" "$IPADOS15_SHA256")"
    IPADOS_IPSW="$(obtain_verified_file iPadOS "$IPADOS_IPSW" "$IPADOS_NAME" "$IPADOS_URL" "$IPADOS_SHA256")"
fi

export VZ_BUILD_ROOT="$BUILD_ROOT"
export VZ_MACOS_IPSW="$MACOS_IPSW"
export VZ_BIG_SUR_IPSW="$BIG_SUR_IPSW"
export VZ_IPADOS14_IPSW="$IPADOS14_IPSW"
export VZ_IPADOS15_IPSW="$IPADOS15_IPSW"
export VZ_IPADOS_IPSW="$IPADOS_IPSW"
export VZ_DEVICE_SUPPORT_DMG="$DEVICE_SUPPORT_DMG"
export VZ_INCLUDE_IPADOS_AUDIT="$FULL_IPADOS_AUDIT"
export VZ_REQUIRE_IPADOS_COMPAT_DSC="$FULL_IPADOS_AUDIT"
if [[ "$FULL_IPADOS_AUDIT" == 1 ]]; then
    export VZ_AUDIT_HOST_VERSIONS="14.5 15.0 16.3.1"
fi
export VZ_IGNORE_ENV_FILE=1

"$REPO_ROOT/scripts/bootstrap.sh"
"$REPO_ROOT/scripts/prepare-inputs.sh"
if [[ "$FULL_IPADOS_AUDIT" == 1 ]]; then
    VZ_IPADOS_COMPAT_IPSW="$IPADOS14_IPSW" \
        "$REPO_ROOT/scripts/fetch-ipados-compat-cache.sh" --version 14.5
    VZ_IPADOS_COMPAT_IPSW="$IPADOS15_IPSW" \
        "$REPO_ROOT/scripts/fetch-ipados-compat-cache.sh" --version 15.0
fi
"$REPO_ROOT/scripts/build-frameworks.sh"
"$REPO_ROOT/scripts/build-ipad-deb.sh"

DEB="$(find "$BUILD_ROOT/release" -maxdepth 1 -type f \
    -name 'VirtualMac_*.deb' -print0 |
    xargs -0 ls -1t | head -1)"
[[ -f "$DEB" ]] || die "build completed without a deb"

# The roothide package is part of the default build. It reuses the component
# products build-ipad-deb.sh just produced and only recompiles its own host
# components, so its component gate is skipped here. It fetches the
# Dopamine-roothide devkit on first use.
if [[ "$BUILD_ROOTHIDE" == 1 ]]; then
    VZ_SKIP_REBUILD=1 "$REPO_ROOT/scripts/build-roothide-deb.sh"
    ROOTHIDE_DEB="$BUILD_ROOT/roothide/VirtualMac_roothide.deb"
    [[ -f "$ROOTHIDE_DEB" ]] || die "roothide build completed without a deb"
fi

if [[ "$INSTALL_ROOTHIDE" == 1 ]]; then
    DEPLOY_DEB="$ROOTHIDE_DEB"
else
    DEPLOY_DEB="$DEB"
fi

if [[ "$INTERACTIVE" == 1 && "$INSTALL_IPAD" == 0 ]]; then
    prompt_yes_no "Install the package on a USB-connected Dopamine iPad?" 0 && INSTALL_IPAD=1
fi

if [[ "$INSTALL_IPAD" == 1 ]]; then
    if [[ -z "$IPAD_UDID" ]]; then
        devices="$(idevice_id -l)"
        count="$(printf '%s\n' "$devices" | awk 'NF { count++ } END { print count+0 }')"
        [[ "$count" == 1 ]] || die "attach exactly one iPad or pass --ipad-udid"
        IPAD_UDID="$devices"
    fi
    if [[ -n "$IPAD_PASSWORD_FILE" ]]; then
        [[ -f "$IPAD_PASSWORD_FILE" ]] || die "password file not found: $IPAD_PASSWORD_FILE"
        VZ_IPAD_PASSWORD="$(<"$IPAD_PASSWORD_FILE")"
    elif [[ -z "${VZ_IPAD_PASSWORD:-}" && "$INTERACTIVE" == 1 ]]; then
        read -r -s -p "iPad SSH password: " VZ_IPAD_PASSWORD
        echo
    fi
    : "${VZ_IPAD_PASSWORD:?set VZ_IPAD_PASSWORD or use --ipad-password-file}"
    export VZ_IPAD_UDID="$IPAD_UDID" VZ_IPAD_PORT="$IPAD_PORT"
    export VZ_IPAD_PASSWORD
    export VZ_IPAD_DEB="$DEPLOY_DEB"
    "$REPO_ROOT/scripts/install-ipad-deb.sh"
    if [[ "$LAUNCH_IPAD" == 1 ]]; then
        "$REPO_ROOT/scripts/launch-ipad-app.sh" 1
    fi
fi

printf '\nBuild complete.\n'
printf '  Package: %s\n' "$DEB"
if [[ "$BUILD_ROOTHIDE" == 1 ]]; then
    printf '  roothide package: %s\n' "$ROOTHIDE_DEB"
fi
printf '  Build:   %s\n' "$BUILD_ROOT"
