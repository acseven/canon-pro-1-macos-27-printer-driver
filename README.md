# Canon PIXMA PRO-1 on macOS 27

Install Canon's last PIXMA PRO-1 driver on an Apple Silicon Mac and add the printer on the network.

Canon stopped this driver at macOS 11. The package is Intel-only. On macOS 27 the installer copies the files, then its own finish script crashes, and Installer reports failure. The queue never appears. `install-canon-pro1.sh` finishes the job.

Tested on macOS 27.0.1 (Apple Silicon) with a PRO-1 on wired Ethernet, firmware 2.100. The script does not send a page to the printer.

## Run

The printer must be on and on the same network. macOS will ask for an administrator password.

```bash
curl -fsSL -o install-canon-pro1.sh \
  https://raw.githubusercontent.com/acseven/canon-pro-1-macos-27-printer-driver/main/install-canon-pro1.sh
chmod +x install-canon-pro1.sh
./install-canon-pro1.sh
```

Or, from a clone of this repository:

```bash
./install-canon-pro1.sh
```

With no arguments the script downloads the driver from Canon. You can also pass a disk image or package you already have:

```bash
./install-canon-pro1.sh /path/to/mcpd-mac-pro_1v1_1-16_50_0_0-ea21_3.dmg
./install-canon-pro1.sh "/path/to/PrinterDriver_PRO-1 v1-1 series_165000.pkg"
./install-canon-pro1.sh --skip-test
./install-canon-pro1.sh --queue Canon_PRO-1
```

Running it again is safe. It does not change the system default printer.

When it finishes, print from any application and choose **Canon PRO-1 v1-1 series**. The CUPS queue name is `Canon_PRO-1`.

## What it does

1. Check this Mac.
2. Download the disk image, or use the `.dmg` or `.pkg` you passed, and check its hash.
3. Install Rosetta if an Intel program cannot start yet.
4. Run the Canon installer. On macOS 27 that installer exits with an error after the files are copied. The script expects that.
5. Confirm the filter, the PPD, and the Canon IJ Network backend. Restore anything the failed finish script skipped. It does not load `BJUSBLoad.kext`.
6. Ask the Canon network backend which PRO-1 answered on the LAN.
7. Add the queue, enabled, not shared.
8. Render one 300 dpi page through `Raster2CanonIJ` into a local socket. The output must contain Canon's `StartJob` and `EndJob`. That temporary queue is then removed.

## Why the Canon installer fails

The package is [PRO-1 series CUPS Printer Driver 16.50.0.0](https://pdisp01.c-wss.com/gdl/WWUFORedirectTarget.do?id=MDEwMDAwMzk3NTIx&cmp=ABR&lang=EN) (signed and notarized, Canon Inc., 29 November 2022). Canon lists it through macOS 11.

Two bugs in the finish script stop it on macOS 27:

- `CIJTools/GetPrinterIDs` is x86_64. Without Rosetta it dies with `Bad CPU type in executable`.
- `CIJScripts/systemversion` reads the OS version with `sw_vers | grep ProductVersion | cut -f2`. macOS 27 prints two tabs between the label and the number, so `cut -f2` is empty. The next `tcsh` test becomes `if ( == -1)` and aborts with `if: Expression Syntax.`

The driver files are already on disk when that happens. There is no package receipt. The script that would register the queue never runs.

The download was checked on 3 October 2026. It redirects to `mcpd-mac-pro_1v1_1-16_50_0_0-ea21_3.dmg`.

| File | SHA-256 |
| --- | --- |
| Disk image | `d5f267776ec402e07d22084a9fe02652fea7a7b81cd9addeaf0e1100bcbef360` |
| `PrinterDriver_PRO-1 v1-1 series_165000.pkg` inside it | `96c1f85ccb3298a79783d9c027f2b67606b8754d9d86a7ec0ee50532264ba299` |

The script refuses to install a file whose hash does not match.

## What still does not work

**USB.** The package installs `BJUSBLoad.kext`, a codeless extension that needs `com.apple.iokit.IOUSBFamily`. That extension is not in macOS 27, so the kext cannot load. Use the network. The printer speaks Canon IJ Network (BJNP on UDP port 8611).

**The Canon print panel.** `CanonIJPDE.bundle` is Intel-only. The arm64 print dialog may not show it. Paper size, media type, quality, 16-bit colour, art papers, and clear coating are still in the printer options. Those come from the PPD.

**The Installer app.** Opening the Canon package again still reports failure. Ignore that dialog if this script has already added the queue.

**A future macOS.** CUPS warns that PPD drivers are obsolete and will stop working in a later release. This one prints on macOS 27.0.1.

Canon requires printer firmware 2.000 or later. The printer's own web page shows the version.

## Driver

The driver itself is Canon's. This repository only holds the script that gets that driver onto macOS 27.
