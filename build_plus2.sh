#!/usr/bin/env bash
# build_plus2.sh — builds esp-gyrologger for M5StickC Plus2
set -euo pipefail

GYRO_REPO="https://github.com/VladimirP1/esp-gyrologger.git"
GYRO_BRANCH="lcd_st7789"
IDF_VERSION="v4.4.7"
IDF_DIR="$HOME/.esp-idf-$IDF_VERSION"
WORK_DIR="$(pwd)/esp-gyrologger-plus2-build"
OUT_DIR="$(pwd)/firmware"
IDF_PYTHON_VER="3.12"   # ESP-IDF 4.4 is not PEP-668-compatible with Python 3.13+

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── 0. System packages & Python 3.12 ────────────────────────────────────────
info "Installing system packages..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    command -v brew &>/dev/null || error "Homebrew not found — install from https://brew.sh"
    for pkg in cmake ninja dfu-util git "python@$IDF_PYTHON_VER"; do
        brew list "$pkg" &>/dev/null || brew install "$pkg"
    done
    PY312_PREFIX="$(brew --prefix "python@$IDF_PYTHON_VER")"
    export PATH="$PY312_PREFIX/bin:$PY312_PREFIX/libexec/bin:$PATH"
else
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        git wget flex bison gperf python3 python3-venv python3-pip \
        cmake ninja-build ccache libffi-dev libssl-dev dfu-util libusb-1.0-0
fi

for tool in git python3 cmake; do
    command -v "$tool" &>/dev/null || error "$tool still missing after install"
done
info "Using Python: $(python3 --version) at $(which python3)"

# ── 1. ESP-IDF ───────────────────────────────────────────────────────────────
PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
IDF_VER_SHORT=$(echo "$IDF_VERSION" | sed 's/^v//' | cut -d. -f1,2)
VENV_PATH="$HOME/.espressif/python_env/idf${IDF_VER_SHORT}_py${PY_VER}_env"

if [[ ! -f "$IDF_DIR/export.sh" ]]; then
    info "Cloning ESP-IDF $IDF_VERSION..."
    git clone --depth 1 --branch "$IDF_VERSION" \
        https://github.com/espressif/esp-idf.git "$IDF_DIR"
    "$IDF_DIR/install.sh" esp32
elif [[ ! -d "$VENV_PATH" ]]; then
    warn "Venv not found at $VENV_PATH — installing for Python $PY_VER..."
    "$IDF_DIR/install.sh" esp32
else
    info "ESP-IDF $IDF_VERSION + Python $PY_VER venv already set up."
fi

# shellcheck source=/dev/null
source "$IDF_DIR/export.sh"
python -c "import packaging" 2>/dev/null \
    || error "ESP-IDF venv broken. Run: rm -rf $VENV_PATH && $IDF_DIR/install.sh esp32"

# ── 2. Clone esp-gyrologger ──────────────────────────────────────────────────
if [[ -d "$WORK_DIR/.git" ]]; then
    info "esp-gyrologger already cloned, updating..."
    git -C "$WORK_DIR" fetch --depth 1 origin "$GYRO_BRANCH"
    git -C "$WORK_DIR" reset --hard "origin/$GYRO_BRANCH"
else
    info "Cloning esp-gyrologger (branch: $GYRO_BRANCH)..."
    git clone --depth 1 --branch "$GYRO_BRANCH" "$GYRO_REPO" "$WORK_DIR"
fi

# ── 3. Apply Plus2 patches ───────────────────────────────────────────────────
info "Patching source for M5StickC Plus2..."

# Real file locations discovered from the actual source tree:
#   Display dispatch: main/misc/display/src/display.cpp  (switch on display_type)
#   Entry point:      main/esp-gyrologger.cpp            (app_main_cpp)
DISPLAY_CPP="$WORK_DIR/main/misc/display/src/display.cpp"
MAIN_CPP="$WORK_DIR/main/esp-gyrologger.cpp"

[[ -f "$DISPLAY_CPP" ]] || error "Not found: $DISPLAY_CPP"
[[ -f "$MAIN_CPP"    ]] || error "Not found: $MAIN_CPP"

if grep -q "plus2" "$DISPLAY_CPP" 2>/dev/null || \
   grep -q "plus2_power_hold" "$MAIN_CPP" 2>/dev/null; then
    warn "Patches already applied, skipping."
else
    python3 - "$DISPLAY_CPP" "$MAIN_CPP" <<'PYEOF'
import sys, re

display_path = sys.argv[1]
main_path    = sys.argv[2]
display_src  = open(display_path).read()
main_src     = open(main_path).read()

# ── PATCH 1: display.cpp ─────────────────────────────────────────────────────
#
# The actual source structure (discovered from the real repo):
#
#   case 3:  // m5stickc plus
#       ...
#       esplcd_init(&lcd, 15, 13, 5, 23, 18, -1, init_panel_st7789_m5stickc_plus);
#       ...
#       break;
#
# For Plus2 we reuse init_panel_st7789_m5stickc_plus — the DC/RST pins are
# passed in as arguments to esplcd_init(), so no new init_panel function
# is needed.  Only the pin numbers and backlight handling change:
#   dc  = 14   (was 23)
#   rst = 12   (was 18)
#   bl  = -1   (still -1, but we manually set GPIO27 HIGH afterwards)
#
# GPIO4 (HOLD) must be asserted HIGH so the SGM2578 keeps the Plus2 on.

PLUS2_CASE = """
        case 5:  // m5stickc plus2
            // GPIO4 = HOLD: keep SGM2578 latched (no AXP192 on Plus2)
            gpio_reset_pin(4);
            gpio_set_direction(4, GPIO_MODE_OUTPUT);
            gpio_set_level(4, 1);

            esplcd_init(&lcd, 15, 13, 5, 14, 12, -1, init_panel_st7789_m5stickc_plus);

            // GPIO27 = TFT_BL: turn backlight on (was AXP192 LDO3 on Plus)
            gpio_reset_pin(27);
            gpio_set_direction(27, GPIO_MODE_OUTPUT);
            gpio_set_level(27, 1);
            break;
"""

# Find the existing case 3 esplcd_init call and the break; that closes it,
# then insert case 5 right after.
ANCHOR = 'esplcd_init(&lcd, 15, 13, 5, 23, 18, -1, init_panel_st7789_m5stickc_plus)'
if ANCHOR not in display_src:
    print(f"ERROR: could not find anchor in {display_path}:", file=sys.stderr)
    print(f"  {ANCHOR}", file=sys.stderr)
    print("Nearby lines:", file=sys.stderr)
    for i, l in enumerate(open(display_path), 1):
        if 'esplcd_init' in l or 'display_type' in l:
            print(f"  {i}: {l}", end='', file=sys.stderr)
    sys.exit(1)

# Walk forward from the anchor to find the closing break; of this case block
anchor_end = display_src.index(ANCHOR) + len(ANCHOR)
break_pos  = display_src.index('break;', anchor_end)
insert_at  = display_src.index('\n', break_pos) + 1   # after the break; line

display_src = display_src[:insert_at] + PLUS2_CASE + display_src[insert_at:]
open(display_path, 'w').write(display_src)
print("display.cpp patch applied OK")

# ── PATCH 2: esp-gyrologger.cpp ──────────────────────────────────────────────
#
# Add gpio.h include and plus2_power_hold() before app_main_cpp().
# The HOLD pin is also set in case 5 above for safety, but setting it
# here at app startup gives the earliest possible assertion.

if '#include "driver/gpio.h"' not in main_src and 'driver/gpio' not in main_src:
    # Insert after the first existing #include
    eol = main_src.index('\n', main_src.index('#include'))
    main_src = main_src[:eol+1] + '#include "driver/gpio.h"\n' + main_src[eol+1:]

HOLD_FUNC = """
// ── M5StickC Plus2: assert HOLD pin immediately so SGM2578 stays latched ──
static void plus2_power_hold(void) {
    gpio_reset_pin(4);
    gpio_set_direction(4, GPIO_MODE_OUTPUT);
    gpio_set_level(4, 1);
}

"""

ENTRY = 'app_main_cpp'
if ENTRY not in main_src:
    print(f"ERROR: '{ENTRY}' not found in {main_path}", file=sys.stderr)
    sys.exit(1)

idx = main_src.index(ENTRY)
# Insert the helper function before the function that contains ENTRY
# Find the preceding newline before the declaration
fn_start = main_src.rindex('\n', 0, idx) + 1
main_src = main_src[:fn_start] + HOLD_FUNC + main_src[fn_start:]

# Now find the opening brace of app_main_cpp body and insert the call
entry_idx  = main_src.index(ENTRY)
body_start = main_src.index('{', entry_idx) + 1
main_src   = (main_src[:body_start]
              + '\n    plus2_power_hold();  // Plus2: keep SGM2578 latched\n'
              + main_src[body_start:])

open(main_path, 'w').write(main_src)
print("esp-gyrologger.cpp patch applied OK")
PYEOF

    [[ $? -eq 0 ]] || error "Patching failed — see output above."
    info "Sources patched successfully."
fi

# ── 4. Build ─────────────────────────────────────────────────────────────────
info "Configuring build (target: esp32)..."
cd "$WORK_DIR"
rm -rf build sdkconfig

# Patch CMakeLists.txt for two toolchain compatibility issues:
#  1. newer CMake removed compat with cmake_minimum_required < 3.5 (fixed via -D flag)
#  2. newer GCC promotes -Wformat-truncation to error in http.cpp
if ! grep -q "format-truncation" CMakeLists.txt; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' '/^project(/a\\
add_compile_options(-Wno-error=format-truncation)
' CMakeLists.txt
    else
        sed -i '/^project(/a add_compile_options(-Wno-error=format-truncation)' CMakeLists.txt
    fi
    info "Added -Wno-error=format-truncation to CMakeLists.txt"
fi

export IDF_TARGET=esp32
info "Building firmware (3-5 min on first run)..."
idf.py -DCMAKE_POLICY_VERSION_MINIMUM=3.5 build

# ── 5. Collect outputs ───────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
cp "$WORK_DIR/build/bootloader/bootloader.bin"           "$OUT_DIR/bootloader.bin"
cp "$WORK_DIR/build/partition_table/partition-table.bin" "$OUT_DIR/partition-table.bin"
cp "$WORK_DIR/build/esp-gyrologger.bin"                  "$OUT_DIR/esp-gyrologger-plus2.bin"

cat > "$OUT_DIR/flash_plus2.sh" <<'FLASH'
#!/usr/bin/env bash
PORT="${1:-}"
if [[ -z "$PORT" ]]; then
    PORT=$(ls /dev/cu.usbserial-* /dev/cu.wchusbserial* /dev/ttyUSB* 2>/dev/null | head -1 || true)
    [[ -n "$PORT" ]] || { echo "ERROR: no serial port found. Pass it as: ./flash_plus2.sh /dev/cu.XXXX"; exit 1; }
    echo "[+] Auto-detected port: $PORT"
fi
DIR="$(dirname "$0")"
python3 -m esptool --chip esp32 --port "$PORT" --baud 921600 \
    --before default_reset --after hard_reset write_flash \
    --flash_mode dio --flash_freq 80m --flash_size detect \
    0x1000  "$DIR/bootloader.bin" \
    0x8000  "$DIR/partition-table.bin" \
    0x10000 "$DIR/esp-gyrologger-plus2.bin"
FLASH
chmod +x "$OUT_DIR/flash_plus2.sh"

echo ""
info "════════════════════════════════════════════════"
info "Done!  Firmware is in: $OUT_DIR"
info ""
info "Plug in your Plus2, then run:"
info "  $OUT_DIR/flash_plus2.sh"
info ""
info "After flashing open /settings and set:"
info "  display_type = 5 | sda_pin = 21 | scl_pin = 22"
info "════════════════════════════════════════════════"
