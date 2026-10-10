# Changelog

## 0.3.5 (2026-10-10)

- The manager only looks at the nodes of the user running it. Another user's node, even when readable, is no longer picked up: run `huahua-node` as that user to manage it.
- A node of this user in `~/.chihuahuad` is found even when it is not running: name and ports from `config.toml`, the systemd unit that runs that directory when there is one. Before, a stopped node not set up by the manager was not found at all.

## 0.3.4 (2026-10-10)

- Fix: with nodes of several users on the machine, the dashboard could mix them up. The detection took the first `chihuahuad` process it found, even one of another user whose configuration it could not read; it then fell back to the default RPC port, which belonged to this user's node. The result showed this user's node name and state with the other user's directory and binary ("Permission denied" in place of the version, validator not detected). The detection now prefers this user's nodes, and skips another user's node when its configuration cannot be read.
- Chain queries no longer depend on running the node binary: when this user cannot run it (a node of another user, a Docker image), the upgrade plan, the proposals in voting, the validator state, the validator names of the Consensus view, balances and transactions are read from the node's REST API when it is on, else from the public REST APIs (`HUAHUA_REST_APIS`). The consensus key comes from the node's RPC. The version comes from `/abci_info` when the binary cannot be run.
- The Consensus view shows the validator name alone; the address only when the name is unknown.

## 0.3.3 (2026-10-10)

### Fixes

- Dashboard: the Logs tab and the state sync phase read the logs of the right container; adopted Docker nodes with a name other than `chihuahuad` showed nothing.
- Dashboard: the network height, the data size and the chain queries run in the background. A slow or unreachable public RPC froze the interface for up to 25 seconds every 20 seconds; `du` on a large data directory did the same every 30 seconds.
- Dashboard: the Validator tab offers "Create the validator" to a node set up as validator whose validator does not exist yet (it was keyed on the node type, not on the voting power). Same for the text menu.
- Dashboard: Ctrl-C during an action (validator setup, upgrade, status) stops the action and comes back to the dashboard instead of quitting it. `Esc` no longer quits: a lagging arrow key over SSH was read as `Esc`.
- Dashboard: start, stop and restart ask for the sudo password on the normal screen when it is needed, instead of a hidden prompt.
- Dashboard: "Restart from the snapshot" asks before deleting the chain data, and is offered to any node that is catching up or stopped, not only to state sync nodes.
- Logs: without the rights to read the system journal, `journalctl` shows nothing and no error. `huahua-node logs` and the Logs tab now use sudo in that case, and no longer call sudo every second when the journal is readable.
- Validator: `create-validator` kept only 1 HUAHUA for the fee; at the chain's gas price the fee is a few hundred HUAHUA, so the transaction failed with a full self-delegation. The setup now keeps 600 HUAHUA aside and says so. The balance and transaction queries use the node directory and RPC port of the node (they failed with a custom directory or port). The check for an existing key no longer hides the keyring password prompt. Commission rates and the self-delegation are validated when typed. The sync wait shows the progress.
- Setup: a replace stops the existing service or container whichever way the new node runs. The snapshot step checks the free disk before downloading. A downloaded `chihuahuad` that does not run on the machine stops the setup instead of going on with it. Setting up another node while `chihuahuad.service` (or the container) runs a node in another directory no longer overwrites it: the new node gets `chihuahuad-2`.
- Setup: the closing summary shows the right command when `huahua-node` was installed in `~/.local/bin` outside the PATH, and the `--home` flag when the node directory is not `~/.chihuahuad`.
- `huahua-node update` returns to the shell after the update instead of opening the dashboard.
- `huahua-node status` prints the version and the disk even when the RPC is down; `huahua-node upgrade` says when the scheduled upgrade is already prepared. Chain queries no longer create a stray `~/.chihuahuad` when the node directory is elsewhere.
- `huahua-node upgrade` with a prepared binary that does not run on the machine fails instead of registering it with cosmovisor.
- Upgrade proposals: legacy `SoftwareUpgradeProposal` content (wrapped in `MsgExecLegacyContent`) is listed too.
- The hourly upgrade timer passes the manager's configuration file to the check (`HUAHUA_CONF`).

### Validator state

- The dashboard header, the Validator tab and `huahua-node status` show the validator's operator address, whether it is bonded, jailed or tombstoned, and the blocks missed in the current signing window.
- New: `huahua-node unjail`, also from the Validator tab, sends the unjail transaction once the cause of the jailing is fixed.

### Upgrades

- New: a live **Consensus** view, from the Upgrade tab and with `huahua-node consensus`. It shows the block, round and step of the consensus, the voting power that has prevoted and precommitted with the 2/3 mark, what is still missing, and the validators that have not voted yet, by voting power, with their names. At an upgrade height it tells how far the chain is from resuming; the data comes from this node, or from the public RPCs while the node restarts on the new binary. Validator names are cached in `~/.huahua-node.validators` while the node is up.
- When the node is halted at an upgrade height, the dashboard reads the upgrade from cosmovisor's `upgrade-info.json` and keeps showing it.
- The header, the Upgrade tab and `huahua-node status` say whether the scheduled upgrade's binary is prepared, and how many blocks are left (with an estimated time when the block interval is known).
- The text menu can turn the automatic upgrades on and off.

### Other

- `huahua-node version`.
- The commands that read the node (status, dashboard, ...) install `curl` and `jq` when missing, as the setup does.

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
