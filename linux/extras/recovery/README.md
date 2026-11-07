# Optional: recovery from hard stalls (Linux)

Not installed by `install.sh`. Hardware specific: read each file and adapt before using it.

| file | purpose | install to |
|---|---|---|
| `arm-watchdog` + `arm-watchdog.service` | load the TCO/iTCO watchdog driver (or `softdog`) and let systemd (PID 1) feed it | `/usr/local/sbin/`, `/etc/systemd/system/` |
| `10-watchdog.conf` | `RuntimeWatchdogSec=60`: a machine that hangs hard is reset after 60 s | `/etc/systemd/system.conf.d/` |
| `90-roost-recovery.conf` | `kernel.panic=10`, `kernel.hardlockup_panic=1`: reboot instead of freezing | `/etc/sysctl.d/` |
| `90-roost-recovery.cfg` | disable NVMe APST (a common cause of silent stalls, about 1 W idle) and shorten the GRUB recordfail wait | `/etc/default/grub.d/`, then `sudo update-grub` |

Never open `/dev/watchdog*` from a script: opening starts the timer. `roost doctor` reports what is active.
