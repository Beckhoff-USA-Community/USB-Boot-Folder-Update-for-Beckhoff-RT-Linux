# USB Boot-Folder Update for Beckhoff RT Linux

Update the TwinCAT application and/or a published TwinCAT HMI (TF2000)
project on a Beckhoff RT Linux device from a USB stick — no engineering PC,
no network. A technician inserts a labeled stick, power-cycles the machine,
and answers an **Update / Skip** dialog on the HMI. Everything happens at
boot, before TwinCAT and the HMI server start: the current state is backed
up, the new files are verified and swapped in, and after boot a validation
service checks that TwinCAT reached RUN (offering an on-screen revert if it
didn't). A stick left in the port is harmless — once installed, every later
boot is a no-op, and an unanswered dialog times out to Skip.

> **Not an official Beckhoff tool.** Built and tested on one bench setup —
> each [release](https://github.com/Beckhoff-USA-Community/USB-Boot-Folder-Update-for-Beckhoff-RT-Linux/releases)
> lists the versions it was tested against. It uses only stock components,
> but review and test it on your own image before trusting a production
> machine to it.

## Requirements

- Beckhoff RT Linux with the TwinCAT runtime, installed per
  [Installing TwinCAT 3 runtime](https://infosys.beckhoff.com/content/1033/beckhoff_rt_linux/17350412299.html?id=7176322633100356666).
- The TF1200 UI Client, installed per
  [Installing the TF1200 UI Client](https://infosys.beckhoff.com/content/1033/tf1200_tc3_ui_client/20659736843.html?id=7323260229858072202)
  — `sudo ./setup-full.sh --user=<USER> --autologin --autostart` is the
  expected setup.
- `tcadstool` (from the `adstool` package).

## Installation

Download the `.deb` from the
[Releases](https://github.com/Beckhoff-USA-Community/USB-Boot-Folder-Update-for-Beckhoff-RT-Linux/releases)
page, copy it to the device, and install it as `Administrator`:

```bash
sudo apt install ./usb-update_1.0.0_all.deb
```

Before the first real update, review the configuration — every tunable is
documented in the file itself, and the **Before production** notes there
(state preserved across updates, security) matter:

```bash
sudo nano /etc/usb-update/usb-update.conf
```

Updating the tool = installing a newer `.deb` the same way (your edited
config is preserved). Uninstalling = `sudo apt remove usb-update` (add
`purge` instead of `remove` to also delete backups and config).

## Preparing an update stick

1. Format a USB stick FAT32 with volume label `UPDATE`.
2. **TwinCAT part** (optional if HMI-only): copy the boot folder of the
   *activated* project to the stick as `TwinCAT/Boot/` (must contain
   `CurrentConfig.xml`).
3. **HMI part** (optional if TwinCAT-only): on a working system,
   `sudo systemctl stop TcHmiSrv.service`, copy
   `/var/lib/tchmisrv/service/<Instance>/` into the stick's `TwinCAT HMI/`
   folder keeping the folder name, then start the service again.
4. Optionally add a `manifest.txt` at the stick root with `target=<TYPE>`
   (refused unless it prefix-matches the device type, e.g. `CX9240`) and
   `version=<X>` (shown in the update dialog).

```
/            (FAT32, volume label: UPDATE)
├── TwinCAT/
│   └── Boot/               the new boot folder
├── TwinCAT HMI/
│   └── TcHmiProject/       the published HMI instance (name = instance name)
└── manifest.txt    optional
```

## Using it

- **Update:** insert the stick, power-cycle, tap **Update** when the dialog
  appears, remove the stick. If the new version fails to start, the device
  offers a revert to the previous working version.
- **Restore the previous version:** put an empty file named `RESTORE` in the
  root of a labeled stick, insert, power-cycle, confirm the dialog.

## Troubleshooting

Everything logs to the persistent journal under one tag — `validate: SUCCESS`
is the happy ending, `validate: FAILURE` includes TwinCAT's own error lines:

```bash
sudo journalctl -t usb-update -b
```

`man usb-update` gives the on-device overview. The scripts in
`/usr/lib/usb-update/` document the mechanics (dialog and UI gating,
validation and rollback, stick detection) in their headers. To modify the
tool, clone this repo, edit, and rebuild: `./build-deb.sh` runs on any
Debian-based system including the device itself.

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
