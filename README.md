# USB Boot-Folder Update for Beckhoff RT Linux

Update the TwinCAT application and/or a published TwinCAT HMI (TF2000)
project on a Beckhoff RT Linux device from a USB stick — no engineering PC,
no network. A technician inserts a labeled stick, power-cycles the machine,
and answers a dialog on the HMI. A stick can carry the TwinCAT application,
the HMI project, or both.

> **Not an official Beckhoff tool.** Built and tested on one bench setup
> (CX9240, TwinCAT `tc31-xar-um` 4026.26.27, TF1200 UI Client 1.13.1). It
> uses only stock components (bash, systemd, swaynag, `tcadstool`), so it
> should run on any Beckhoff RT Linux image — but review and test it on your
> own image before trusting a production machine to it.

## Quick start

1. Install the tool once on the device ([Installation](#installation)).
2. Copy your project onto a USB stick labeled `UPDATE`
   ([Preparing an update stick](#preparing-an-update-stick)).
3. Insert the stick, power-cycle the machine, tap **Update** on the screen.
   Done — remove the stick.

## How it works

Everything happens at boot, before the TwinCAT runtime and the HMI server
start, so nothing ever has to be stopped:

1. A systemd service looks for a USB stick with the configured label. No
   stick, or its package already installed → normal boot.
2. Valid package → an **Update / Skip** dialog on the HMI. It times out to
   Skip, so an unattended power cycle can never hang the machine.
3. On **Update**: the current state is backed up, the new files are staged
   and verified, then swapped in atomically. Device state — event logs and
   PLC persistent data — is always carried over from the machine, never taken
   from the stick.
4. After TwinCAT starts, a second service checks that it reached RUN (and, on
   HMI machines, that the HMI server answers). On success the rollback copy
   is removed; on failure the operator is offered a revert to the previous
   working version.

A stick left in the port is harmless: once its package is installed, every
later boot is a no-op.

## Requirements

- Beckhoff RT Linux with the TwinCAT usermode runtime (`TcSystemServiceUm`).
- A TF1200 UI Client / sway session for the on-screen dialog. Without one the
  tool still boots safely — prompts just time out to Skip.
- `tcadstool` (from the `adstool` package).

## Installation

On the device (log in as `Administrator`, locally or via
`ssh Administrator@<device-ip>`), install git — it is not on the image by
default — then clone this repo and run the installer:

```bash
sudo apt update && sudo apt install -y git
```

```bash
git clone https://github.com/Beckhoff-USA-Community/USB-Boot-Folder-Update-for-Beckhoff-RT-Linux.git
```

```bash
sudo bash USB-Boot-Folder-Update-for-Beckhoff-RT-Linux/usb-update/install.sh
```

This installs everything to `/usr/local/lib/usb-update/` and enables the two
systemd units. An already-edited `usb-update.conf` is preserved on reinstall,
so updating the tool later is just `git pull` in the clone and rerunning the
installer.

Before the first real update, review the configuration:

```bash
sudo nano /usr/local/lib/usb-update/usb-update.conf
```

To uninstall (keeps backups and state unless you add `--purge`):

```bash
sudo /usr/local/lib/usb-update/uninstall.sh
```

## Preparing an update stick

1. Format a USB stick FAT32 with volume label `UPDATE` (Windows: right-click
   the drive → **Format…**).
2. **TwinCAT part** (optional if HMI-only): copy the boot folder of the
   *activated* project to the stick as `TwinCAT/Boot/`. It must contain
   `CurrentConfig.xml`.
3. **HMI part** (optional if TwinCAT-only): on a working system with the
   project published, stop the HMI server, copy the instance folder, and
   start it again:

   ```bash
   sudo systemctl stop TcHmiSrv.service
   ```

   Copy `/var/lib/tchmisrv/service/<Instance>/` (normally `TcHmiProject/`)
   into the stick's `TwinCAT HMI/` folder, keeping the folder name, then
   `sudo systemctl start TcHmiSrv.service`.
4. Optionally add a `manifest.txt` at the stick root:

   ```
   target=CX9240
   version=1.4.2
   ```

   `target`, if present, must match the device type (prefix match against the
   auto-detected hardware type, e.g. `CX9240-0215`) or the update is refused.
   `version` is shown in the update dialog.

Final stick layout (either top-level folder may be absent, at least one must
be present):

```
/            (FAT32, volume label: UPDATE)
├── TwinCAT/
│   └── Boot/               the new boot folder
├── TwinCAT HMI/
│   └── TcHmiProject/       the published HMI instance (name = instance name)
└── manifest.txt    optional
```

## Performing an update (operator procedure)

1. Insert the stick and power-cycle the machine.
2. When the dialog appears, tap **Update** (**Skip** or waiting boots
   normally; the offer repeats on the next power cycle).
3. The machine boots into the new application. If it fails to start, a
   message appears and the previous version is offered as a revert.
4. Remove the stick.

## Restoring the previous version

Every update first snapshots the current state (boot folder plus HMI state,
as one set) to `/var/lib/usb-update/backup/`. To restore it in the field:

1. Put an empty file named `RESTORE` in the root of any stick with the
   configured label.
2. Insert and power-cycle. The dialog offers **Restore backup / Skip**.

A restore puts back exactly what was backed up, including the event logs and
persistent data as they were at backup time.

## If an update fails validation

The previous state stays on the device (`Boot.old`, and `service.old` for the
HMI part). By default the HMI asks "Revert to the previous working version?" —
confirming swaps it back and restarts; the failed state is kept at `.failed`
for diagnosis. Set `PROMPT_REVERT_ON_FAILURE=0` to show a "contact service"
notice instead and leave the machine for a technician. Nothing is ever rolled
back without an operator's confirmation.

Manual rollback from a shell:

```bash
sudo mv /etc/TwinCAT/3.1/Boot /etc/TwinCAT/3.1/Boot.failed
sudo mv /etc/TwinCAT/3.1/Boot.old /etc/TwinCAT/3.1/Boot
sudo reboot
```

## Logs and troubleshooting

Everything logs to the persistent journal under one tag — `validate: SUCCESS`
is the happy ending, `validate: FAILURE` includes TwinCAT's own error lines:

```bash
sudo journalctl -t usb-update -b
```

(Drop the `-b` for the full history across updates.)

If the dialog never appears, check that the sway session is up — a Wayland
socket should exist under `/run/user/*/`. The prompt auto-detects the UI
session from that socket and gives up safely (Skip) after 30 s.

## Configuration

All tunables live in `/usr/local/lib/usb-update/usb-update.conf`, each
documented there. The ones most worth reviewing before production:

- `USB_LABEL` — the stick label that triggers an update offer.
- `PRESERVE_GLOBS` — what inside `Boot` counts as device state and survives
  updates (event log and PLC persistent data by default).
- `REBOOT_AFTER_UPDATE` — restart the IPC after applying instead of
  continuing the current boot.
- `PROMPT_REVERT_ON_FAILURE` — offer an on-screen revert after a failed
  update, or leave the machine for a technician.

## Before production use

- **Check the preserve list.** Activate your real application, look inside
  `/etc/TwinCAT/3.1/Boot`, and make sure everything stateful (persistent
  variables, event logs, etc.) is covered by
  `PRESERVE_GLOBS`. Getting this wrong clobbers machine state.
- **Security.** There is none beyond physical access: anyone with a labeled
  stick and the power switch can replace the application. If that is not
  acceptable, add signing to the manifest check in `detect.sh`.
- **HMI `storage.db` is replaced wholesale.** It carries server-side user
  data (HMI accounts, recipe edits made on the device) — an HMI update
  overwrites it with the stick's copy. If your application stores data
  through the HMI, work out a preserve strategy first.
- **Test on your own hardware.** Exercise the full cycle on a bench device
  before shipping: a normal update, a deliberately broken package (revert
  path), a restore stick, and a boot with no stick.

## Further reading (Beckhoff Infosys)

The tool automates what Beckhoff documents as manual procedures:

- [Performing a PLC update](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/6137491211.html)
- [Performing an update of the complete machine](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/6137492619.html)
- [Cloning a machine](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/6137494027.html)
- [Port_xxx.bootdata](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/4291095051.html)
  — the persistent-data file; the reason `Plc/*.bootdata*` is preserved.

## Disclaimer

All sample code provided by Beckhoff Automation LLC are for illustrative
purposes only and are provided “as is” and without any warranties, express or
implied. Actual implementations in applications will vary significantly.
Beckhoff Automation LLC shall have no liability for, and does not waive any
rights in relation to, any code samples that it provides or the use of such
code samples for any purpose.
