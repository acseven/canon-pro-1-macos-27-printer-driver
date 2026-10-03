#!/bin/bash
#
# Install the Canon PIXMA PRO-1 driver on Apple Silicon, including macOS 27.
#
# Canon never shipped an Apple Silicon build. The last package is
# PRO-1 series CUPS Printer Driver 16.50.0.0 (file 16.50.0.0, November 2022).
# Canon lists it through macOS 11. The download below was checked on
# 2026-10-03: the link redirects to mcpd-mac-pro_1v1_1-16_50_0_0-ea21_3.dmg,
# and the .pkg inside is the same file as the disc image used on this Mac.
#
# What the Canon installer does on macOS 27
# ------------------------------------------
# 1. It copies the driver into /Library/Printers/Canon and links the
#    network backend. That part succeeds.
# 2. Its finish script then fails, so Installer says the install failed.
#    Two separate bugs cause that:
#      - CIJTools/GetPrinterIDs is x86_64. Without Rosetta the script
#        dies with "Bad CPU type in executable".
#      - CIJScripts/systemversion reads the OS version with
#        `sw_vers | grep ProductVersion | cut -f2`. macOS 27 prints two
#        tabs between the label and the number, so cut -f2 is empty.
#        The next tcsh test becomes `if ( == -1)` and aborts with
#        "if: Expression Syntax."
#    The files already copied are left in place. There is no package
#    receipt. makequeues and kextload never run.
# 3. BJUSBLoad.kext cannot load. It is a codeless kext that depends on
#    com.apple.iokit.IOUSBFamily, which this macOS does not ship. USB
#    printing through Canon's own USB class driver is not available.
#    The PRO-1 on the network speaks Canon IJ Network (BJNP on UDP 8611).
#    That path does not need the kext.
#
# What this script does
# ---------------------
# 1. Check this Mac.
# 2. Download the driver, or use a .dmg / .pkg you pass in.
# 3. Install Rosetta, so the Intel filter and network backend can run.
# 4. Run the Canon installer. A non-zero exit is expected. The script
#    checks the files on disk instead of trusting that exit code.
# 5. If the finish script stopped too early, copy the PPD and the
#    backend link ourselves. Do not load the kext.
# 6. Ask the Canon network backend which PRO-1 printers it can see.
# 7. Add a CUPS queue. Do not make it the default. Do not share it.
# 8. Render one page through the real Canon filter into a local socket.
#    Nothing is sent to the printer.
#
# Run:
#   ./install-canon-pro1.sh
#   ./install-canon-pro1.sh /path/to/mcpd-mac-pro_1v1_1-16_50_0_0-ea21_3.dmg
#   ./install-canon-pro1.sh --skip-test
#   ./install-canon-pro1.sh --queue Canon_PRO-1
#
# Re-running the script is safe.

set -o pipefail

DRIVER_URL="https://pdisp01.c-wss.com/gdl/WWUFORedirectTarget.do?id=MDEwMDAwMzk3NTIx&cmp=ABR&lang=EN"
# Redirect target checked 2026-10-03:
# https://gdlp01.c-wss.com/gds/5/0100003975/21/mcpd-mac-pro_1v1_1-16_50_0_0-ea21_3.dmg
DMG_SHA256="d5f267776ec402e07d22084a9fe02652fea7a7b81cd9addeaf0e1100bcbef360"
PKG_SHA256="96c1f85ccb3298a79783d9c027f2b67606b8754d9d86a7ec0ee50532264ba299"
DMG_NAME="mcpd-mac-pro_1v1_1-16_50_0_0-ea21_3.dmg"
CACHE_DIR="/var/tmp/canon-pro1"
QUEUE_NAME="Canon_PRO-1"
PPD_PATH="/Library/Printers/PPDs/Contents/Resources/CanonIJPRO1v11series.ppd.gz"
FILTER_PATH="/Library/Printers/Canon/BJPrinter/Filters/Raster2CanonIJ/Raster2CanonIJ.bundle/Contents/MacOS/Raster2CanonIJ"
BACKEND_PATH="/usr/libexec/cups/backend/canonijnetwork"
BACKEND_TARGET="/Library/Printers/Canon/BJPrinter/Plugins/BJNP/canonijnetwork.bundle/Contents/MacOS/canonijnetwork"
SKIP_TEST=0
SOURCE=""
MOUNT_POINT=""
WORK=""
ORIG_ARGS=("$@")

step() {
  echo ""
  echo "== Step $1 of 8. $2 =="
}

die() {
  echo ""
  echo "Stopped: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Install the Canon PIXMA PRO-1 driver on this Mac and add its network queue.

  ./install-canon-pro1.sh
  ./install-canon-pro1.sh /path/to/mcpd-mac-pro_1v1_1-16_50_0_0-ea21_3.dmg
  ./install-canon-pro1.sh /path/to/PrinterDriver_PRO-1\ v1-1\ series_165000.pkg
  ./install-canon-pro1.sh --skip-test
  ./install-canon-pro1.sh --queue Canon_PRO-1

With no path, the script downloads the driver from Canon.
A non-zero result from the Canon installer is expected on macOS 27.
The script checks the copied files and continues.
It does not send a page to the printer.
EOF
  exit 0
}

cleanup() {
  if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 \
      || diskutil eject "$MOUNT_POINT" >/dev/null 2>&1 \
      || true
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

require_hash() {
  local file="$1"
  local expected="$2"
  local label="$3"
  local got
  got=$(sha256_of "$file")
  if [ "$got" != "$expected" ]; then
    die "$label hash is $got, expected $expected. Refusing to install it."
  fi
  echo "Hash matches ($label)."
}

# ----------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --skip-test) SKIP_TEST=1; shift ;;
    --queue)
      [ $# -ge 2 ] || die "--queue needs a name"
      QUEUE_NAME="$2"
      shift 2
      ;;
    --) shift; break ;;
    -*) die "Unknown option: $1" ;;
    *)
      [ -z "$SOURCE" ] || die "Only one driver path is accepted."
      SOURCE="$1"
      shift
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This script installs into /Library and adds a printer. macOS will ask for an administrator password."
  exec sudo -p "Password for %u: " -- "$0" "${ORIG_ARGS[@]}"
fi

WORK=$(mktemp -d /tmp/canon-pro1.XXXXXX)

# ----------------------------------------------------------------
# Step 1. Check this Mac
# ----------------------------------------------------------------
step 1 "Check this Mac"
echo "Product:  $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "CPU:      $(uname -m)"
if [ "$(uname -m)" != "arm64" ]; then
  echo "This Mac is not Apple Silicon. Rosetta is not required. The installer finish script can still fail on macOS 27, and the later steps cover that."
fi
command -v installer >/dev/null || die "installer is missing."
command -v lpadmin >/dev/null || die "lpadmin is missing."
command -v python3 >/dev/null || die "python3 is missing."

# ----------------------------------------------------------------
# Step 2. Get the driver
# The published link is a redirect. curl -L follows it. The file is a
# disk image even though `file` may describe it as zlib data.
# ----------------------------------------------------------------
step 2 "Get the driver"
mkdir -p "$CACHE_DIR"
PKG=""

if [ -n "$SOURCE" ]; then
  [ -e "$SOURCE" ] || die "No such file: $SOURCE"
  case "$SOURCE" in
    *.pkg) PKG="$SOURCE" ;;
    *.dmg)
      require_hash "$SOURCE" "$DMG_SHA256" "disk image"
      DMG="$SOURCE"
      ;;
    *) die "Pass a .dmg or a .pkg. Got: $SOURCE" ;;
  esac
else
  DMG="$CACHE_DIR/$DMG_NAME"
  if [ -f "$DMG" ] && [ "$(sha256_of "$DMG")" = "$DMG_SHA256" ]; then
    echo "Using the disk image already downloaded at $DMG"
  else
    echo "Downloading $DRIVER_URL"
    curl -fL --retry 3 -A "Mozilla/5.0" -o "$DMG.partial" "$DRIVER_URL" \
      || die "Download failed."
    mv "$DMG.partial" "$DMG"
  fi
  require_hash "$DMG" "$DMG_SHA256" "disk image"
fi

if [ -z "$PKG" ]; then
  echo "Mounting $DMG"
  attach_out=$(hdiutil attach -readonly -nobrowse "$DMG" 2>/dev/null) \
    || die "Could not mount the disk image."
  MOUNT_POINT=$(printf '%s\n' "$attach_out" | awk -F'\t' '/\/Volumes\//{print $NF; exit}')
  [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ] || die "The disk image mounted, but the volume path was not found."
  echo "Mounted at $MOUNT_POINT"
  PKG=$(find "$MOUNT_POINT" -maxdepth 2 -name '*.pkg' -print | head -1)
  [ -n "$PKG" ] || die "The disk image has no .pkg."
fi

echo "Package: $PKG"
require_hash "$PKG" "$PKG_SHA256" "package"
pkgutil --check-signature "$PKG" | head -4

# ----------------------------------------------------------------
# Step 3. Install Rosetta
# Raster2CanonIJ, canonijnetwork, and the printer utility are x86_64.
# A CUPS filter with no arm64 slice does not start until Rosetta is
# installed. cupsd then reports the backend as status 86 (bad CPU type).
# ----------------------------------------------------------------
step 3 "Install Rosetta"
if [ "$(uname -m)" != "arm64" ]; then
  echo "Skipped. This CPU runs the Intel binaries directly."
elif arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
  echo "Rosetta is already installed."
else
  echo "Installing Rosetta. This accepts the Rosetta licence."
  softwareupdate --install-rosetta --agree-to-license \
    || die "Rosetta did not install."
  arch -x86_64 /usr/bin/true >/dev/null 2>&1 \
    || die "Rosetta install reported success, but an Intel program still will not start."
  echo "Rosetta is installed."
fi

# ----------------------------------------------------------------
# Step 4. Run the Canon installer
# Expect a script error. See the header. Success is "the files are
# on disk", not "installer exited 0".
# ----------------------------------------------------------------
step 4 "Run the Canon installer"
echo "Installer will copy the driver, then its own finish script will fail."
echo "That failure is expected on macOS 27. The log is $WORK/installer.log"
installer -pkg "$PKG" -target / -verboseR >"$WORK/installer.log" 2>&1
installer_status=$?
if [ "$installer_status" -eq 0 ]; then
  echo "The Canon installer exited 0."
else
  echo "The Canon installer exited $installer_status. Checking the copied files before treating that as fatal."
fi

# ----------------------------------------------------------------
# Step 5. Finish the files the finish script skips
# The payload is copied before the finish script runs. The PPD is not
# in the payload. The finish script unpacks CanonIJPPD.tgz, and that
# unpack happens before the broken version test, as long as Rosetta
# was already installed. If it did not, unpack it here.
# Do not kextload BJUSBLoad.kext. IOUSBFamily is gone, so the load fails,
# and a loaded copy of this kext would also block Apple's USB printer driver.
# ----------------------------------------------------------------
step 5 "Finish the files the installer script skips"

need_payload=0
[ -x "$FILTER_PATH" ] || need_payload=1
[ -e "$BACKEND_TARGET" ] || need_payload=1

if [ "$need_payload" -eq 1 ]; then
  echo "The driver tree is incomplete. Unpacking the package payload."
  pkgutil --expand-full "$PKG" "$WORK/full" \
    || die "Could not unpack the package payload."
  anchor=$(find "$WORK/full" -type d -path '*/Library/Printers/Canon/BJPrinter' | head -1)
  [ -n "$anchor" ] || die "The unpacked package has no BJPrinter directory."
  payload_root="${anchor%/Library/Printers/Canon/BJPrinter}"
  ditto "$payload_root/Library" /Library
  if [ -d "$payload_root/usr" ]; then
    ditto "$payload_root/usr" /usr
  fi
else
  echo "Driver files are already in /Library/Printers/Canon."
fi

if [ ! -e "$BACKEND_PATH" ]; then
  echo "Linking the Canon IJ Network backend into CUPS."
  [ -x "$BACKEND_TARGET" ] || die "The network backend binary is missing at $BACKEND_TARGET"
  ln -sf "$BACKEND_TARGET" "$BACKEND_PATH"
fi

if [ ! -f "$PPD_PATH" ]; then
  echo "The PPD was not unpacked. Extracting CanonIJPPD.tgz from the package scripts."
  if [ ! -d "$WORK/expanded" ]; then
    pkgutil --expand "$PKG" "$WORK/expanded" || die "Could not expand the package."
  fi
  tgz=$(find "$WORK/expanded" -path '*/CIJModules/CanonIJPPD.tgz' | head -1)
  [ -n "$tgz" ] || die "CanonIJPPD.tgz was not found in the package."
  mkdir -p /Library/Printers/PPDs/Contents/Resources
  tar -xzf "$tgz" -C /Library/Printers/PPDs/Contents/Resources \
    || die "Could not unpack the PPD."
else
  echo "PPD is in place: $PPD_PATH"
fi

mkdir -p /Library/Caches/Canon/BJPrinter/DeviceInfo
chmod 777 /Library/Caches/Canon /Library/Caches/Canon/BJPrinter /Library/Caches/Canon/BJPrinter/DeviceInfo

[ -x "$FILTER_PATH" ] || die "The raster filter is still missing."
[ -f "$PPD_PATH" ] || die "The PPD is still missing."
[ -x "$BACKEND_PATH" ] || [ -L "$BACKEND_PATH" ] || die "The network backend is still missing."

echo "Filter:  $FILTER_PATH"
echo "Backend: $BACKEND_PATH"
file "$FILTER_PATH" | sed 's/^/          /'

# ----------------------------------------------------------------
# Step 6. Find the printer
# `canonijnetwork` with no arguments is the CUPS discovery mode.
# A PRO-1 on the LAN answers BJNP on UDP port 8611 and is listed as
# canonijnetwork://Canon/... .
# ----------------------------------------------------------------
step 6 "Find the printer on the network"
echo "Asking the Canon IJ Network backend for printers. This stays on the LAN and does not print."
discover=$(python3 - <<'PY'
import subprocess, sys
try:
    done = subprocess.run(
        ["/usr/libexec/cups/backend/canonijnetwork"],
        capture_output=True, text=True, timeout=25,
    )
except subprocess.TimeoutExpired as exc:
    sys.stdout.write(exc.stdout or "")
    sys.stderr.write("Discovery timed out.\n")
    sys.exit(0)
sys.stdout.write(done.stdout or "")
sys.stderr.write(done.stderr or "")
PY
)
printf '%s\n' "$discover" | sed 's/^/    /'

URI=""
while IFS= read -r line; do
  case "$line" in
    network\ canonijnetwork://*)
      candidate=${line#network }
      candidate=${candidate%% *}
      case "$line" in
        *PRO-1*|*PRO1*|*pro-1*) URI="$candidate" ;;
      esac
      ;;
  esac
done <<EOF
$discover
EOF

if [ -z "$URI" ]; then
  echo ""
  echo "The driver is installed, but no PRO-1 answered on Canon IJ Network."
  echo "Turn the printer on, connect it to this network, and run this script again."
  echo "The queue is not created until the printer answers."
  exit 1
fi
echo "Using $URI"

# ----------------------------------------------------------------
# Step 7. Add the queue
# lpadmin warns that PPD drivers are obsolete. The queue still works
# on this macOS. Do not set the system default, and do not share it.
# -E after -p enables the queue and accepts jobs.
# ----------------------------------------------------------------
step 7 "Add the print queue"
echo "Queue name: $QUEUE_NAME"
lpadmin -p "$QUEUE_NAME" -E \
  -v "$URI" \
  -P "$PPD_PATH" \
  -D "Canon PRO-1 v1-1 series" \
  -L "Network" \
  -o printer-is-shared=false
echo "CUPS may warn that printer resources (PPDs) will stop working in a future release. The queue is still created."
cupsaccept "$QUEUE_NAME" >/dev/null 2>&1 || true
cupsenable "$QUEUE_NAME" >/dev/null 2>&1 || true

echo "Queue:"
lpstat -p "$QUEUE_NAME" -v "$QUEUE_NAME" | sed 's/^/    /'

# ----------------------------------------------------------------
# Step 8. Check the filter without printing
# Build a one-page PDF, point a temporary queue at a local socket,
# and require the Canon filter to emit StartJob ... EndJob.
# The temporary queue is removed afterwards.
# ----------------------------------------------------------------
step 8 "Check the filter without printing"
if [ "$SKIP_TEST" -eq 1 ]; then
  echo "Skipped (--skip-test)."
else
  pdf="$WORK/test.pdf"
  capture="$WORK/capture.bin"
  check_queue="Canon_PRO-1_drvcheck"
  : >"$capture"
  python3 - "$pdf" <<'PY'
import sys
path = sys.argv[1]
parts = []
def add(blob):
    parts.append(blob if isinstance(blob, bytes) else blob.encode())
add("%PDF-1.4\n")
offsets = [0]
def obj(body):
    offsets.append(sum(len(p) for p in parts))
    add(body if isinstance(body, bytes) else body.encode())
    raw = body if isinstance(body, bytes) else body.encode()
    if not raw.endswith(b"\n"):
        add(b"\n")
    add(b"endobj\n")
obj("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\n")
obj("2 0 obj\n<< /Type /Pages /Count 1 /Kids [3 0 R] >>\n")
stream = b"BT /F1 24 Tf 72 700 Td (PRO-1 driver check) Tj ET\n"
obj("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\n")
obj(b"4 0 obj\n<< /Length %d >>\nstream\n" % len(stream) + stream + b"endstream\n")
obj("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\n")
startxref = sum(len(p) for p in parts)
add(b"xref\n")
add(("0 %d\n" % len(offsets)).encode())
add(b"0000000000 65535 f \n")
for off in offsets[1:]:
    add(("%010d 00000 n \n" % off).encode())
add(("trailer << /Size %d /Root 1 0 R >>\n" % len(offsets)).encode())
add(("startxref\n%d\n%%EOF\n" % startxref).encode())
open(path, "wb").write(b"".join(parts))
PY

  port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
  nc -l 127.0.0.1 "$port" >"$capture" &
  nc_pid=$!
  sleep 0.3

  lpadmin -p "$check_queue" -E \
    -v "socket://127.0.0.1:$port" \
    -P "$PPD_PATH" \
    -D "Canon PRO-1 filter check" \
    -o printer-is-shared=false >/dev/null

  echo "Rendering one page at 300 dpi through Raster2CanonIJ. The listener is local."
  lp -d "$check_queue" -o Resolution=300x300dpi -t "driver-check" "$pdf" >/dev/null

  ok=0
  i=0
  while [ "$i" -lt 45 ]; do
    if grep -a -q "EndJob" "$capture" 2>/dev/null; then
      ok=1
      break
    fi
    if ! kill -0 "$nc_pid" 2>/dev/null; then
      # The backend closed the socket. Give the file a moment to flush.
      sleep 0.5
      if grep -a -q "EndJob" "$capture" 2>/dev/null; then
        ok=1
      fi
      break
    fi
    i=$((i + 1))
    sleep 1
  done

  cancel -a "$check_queue" >/dev/null 2>&1 || true
  lpadmin -x "$check_queue" >/dev/null 2>&1 || true
  kill "$nc_pid" >/dev/null 2>&1 || true
  wait "$nc_pid" 2>/dev/null || true

  if [ "$ok" -ne 1 ]; then
    echo "The filter check did not produce a Canon job."
    echo "The queue $QUEUE_NAME is still installed. See /private/var/log/cups/error_log."
    exit 1
  fi
  bytes=$(wc -c <"$capture" | tr -d ' ')
  echo "The filter wrote a Canon job ($bytes bytes) with StartJob and EndJob. It was not sent to the printer."
fi

# ----------------------------------------------------------------
# Done
# ----------------------------------------------------------------
echo ""
echo "The PRO-1 is ready."
echo ""
echo "  Queue:   $QUEUE_NAME"
echo "  Dialog:  Canon PRO-1 v1-1 series"
echo "  Address: $URI"
echo ""
echo "Choose that printer in any application. This script did not send a page."
echo ""
echo "The Canon installer says the install failed. That is expected on macOS 27."
echo "The driver files are on disk, and the queue was added after that failure."
echo ""
echo "USB printing is not available. BJUSBLoad.kext needs IOUSBFamily, and this"
echo "macOS does not include that extension. Use the network connection."
echo ""
echo "The Canon print panel is an Intel plug-in. The print dialog may not show it."
echo "Paper size, media type, quality, 16-bit colour, art papers, and clear coating"
echo "remain available under the printer options."
echo ""
echo "Canon requires printer firmware 2.000 or later. The printer web page shows"
echo "the version (a unit checked with this driver reported firmware 2.100)."
echo ""
if [ "$(uname -m)" = "arm64" ]; then
  echo "Rosetta stays installed. This driver does not run without it."
fi
exit 0
