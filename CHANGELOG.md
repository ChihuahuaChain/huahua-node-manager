# Changelog

## 0.3.2 (2026-10-01)

### Automatic upgrades

- New: an hourly check prepares the chain upgrade scheduled by governance. When an upgrade proposal has passed, the matching `chihuahuad` release is downloaded, verified (sha256, and that it runs) and placed in `cosmovisor/upgrades/<name>/bin`, hours before the upgrade height. Cosmovisor still does the switch at the height; the running node is never touched.
- Turn it on or off at any time: `huahua-node auto-upgrade on|off|status`, or from the dashboard (tab **4 Upgrade**). It runs as a systemd timer, `huahua-node-upgrade-<user>`; each check is logged in the journal.
- The setup turns it on for new nodes with cosmovisor on systemd machines (a question in the advanced setup, `AUTO_UPGRADE` for unattended installs). Existing and adopted nodes keep it off until it is turned on.
- `huahua-node uninstall` also removes the timer.

### Upgrade proposals in voting

- The Upgrade tab and `huahua-node status` list the software upgrade proposals still in voting, with the upgrade name, height and end of the vote.
- `huahua-node upgrade` can prepare the upgrade of a proposal in voting, before it passes (it asks first). The binary is used only if the proposal passes.

## 0.3.1 (2026-09-28)

- `huahua-node upgrade` prepares the binary without the cosmovisor CLI, so nodes adopted by the manager (with a cosmovisor installed elsewhere) can stage upgrades too.

## 0.3.0 (2026-09-27)

- Installs itself as `huahua-node` on the first run, and checks for a newer release at every start (sha256 verified before updating).
- Cosmovisor gets a shutdown grace at upgrades (`DAEMON_SHUTDOWN_GRACE=30s`).
- Snapshots from snapshots.chihuahua.wtf.
- First release: set up and manage a Chihuahua node (systemd or Docker, snapshot or state sync, cosmovisor, guided validator creation, live dashboard).
