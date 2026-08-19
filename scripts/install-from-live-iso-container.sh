#!/usr/bin/env bash

set -euo pipefail

iso=/inputs/live.iso
base_state=/inputs/state.ext4
target=/output/target.img
ssh_key=/inputs/ssh-key
ssh_public_key=/inputs/ssh-key.pub
init_system=${INIT_SYSTEM:?missing INIT_SYSTEM}
installer_digest=${INSTALLER_SHA256:?missing INSTALLER_SHA256}
timeout_seconds=${VOLATOO_LIVE_INSTALL_TIMEOUT:-360}
for input in "$iso" "$base_state" "$target" "$ssh_key" "$ssh_public_key"; do
	[[ -f $input && ! -L $input ]] || { echo "error: live-install input is missing or unsafe: $input" >&2; exit 1; }
done
[[ $init_system == openrc || $init_system == systemd ]] || { echo "error: invalid install target" >&2; exit 2; }
[[ $installer_digest =~ ^[0-9a-f]{64}$ ]] || { echo "error: invalid installer digest" >&2; exit 2; }
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid live-install timeout" >&2; exit 2; }

state=/run/volatoo-live-state.ext4
cp "$base_state" "$state"
debugfs -w -R 'mkdir /volatoo/config' "$state" >/dev/null 2>&1 || true
debugfs -w -R 'mkdir /volatoo/config/access' "$state" >/dev/null 2>&1 || true
debugfs -w -R "write $ssh_public_key /volatoo/config/access/authorized_keys" "$state" >/dev/null
debugfs -w -R 'set_inode_field /volatoo/config/access/authorized_keys mode 0100600' "$state" >/dev/null

log=/run/volatoo-live-install.log
qemu_pid=
cleanup()
{
	if [[ -n $qemu_pid ]]; then
		kill "$qemu_pid" 2>/dev/null || true
		wait "$qemu_pid" 2>/dev/null || true
	fi
}
trap cleanup EXIT
qemu-system-x86_64 \
	-machine accel=tcg \
	-m 4096 -smp 2 -nographic -no-reboot \
	-drive "file=$iso,format=raw,media=cdrom,readonly=on" \
	-drive "file=$state,format=raw,if=virtio" \
	-drive "file=$target,format=raw,if=virtio,cache=writeback" \
	-boot d \
	-netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
	-device virtio-net-pci,netdev=net0 \
	>"$log" 2>&1 &
qemu_pid=$!

deadline=$((SECONDS + timeout_seconds))
ssh_options=(
	-o BatchMode=yes
	-o ConnectTimeout=3
	-o LogLevel=ERROR
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-i "$ssh_key"
	-p 2222
)
ready=no
while (( SECONDS < deadline )); do
	if ssh "${ssh_options[@]}" volatoo@127.0.0.1 \
		'test "$(id -u)" = 1000 && sudo -n true' 2>/dev/null; then
		ready=yes
		break
	fi
	if ! kill -0 "$qemu_pid" 2>/dev/null; then break; fi
	sleep 1
done
if [[ $ready != yes ]]; then
	echo "error: live ISO did not become reachable over authenticated SSH" >&2
	tail -200 "$log" >&2
	exit 1
fi

remote_index=/.volatoo/source/volatoo/distfiles/releases/amd64/channels/v0.1-dev/index.json
remote_command=$(cat <<EOF
set -eu
test "\$(sha256sum /usr/sbin/volatoo-installer | awk '{print \$1}')" = '$installer_digest'
test "\$(/usr/sbin/volatoo-installer version)" = 0.1.0-dev
test -f '$remote_index'
find /usr/share/volatoo/keyring/release -type f -name '*.pub' -print -quit | grep -q .
printf '%s\n' /dev/vdb | sudo env VOLATOO_INSTALLER_TESTING=1 /usr/sbin/volatoo-installer install \
  --index '$remote_index' \
  --channel v0.1-dev --architecture amd64 --init-system '$init_system' \
  --device /dev/vdb --no-provision-access
sudo sync
EOF
)
# The command is assembled only from validated, builder-controlled values.
# shellcheck disable=SC2029
if ! ssh "${ssh_options[@]}" volatoo@127.0.0.1 "$remote_command"; then
	echo "error: formal installer failed inside the live ISO" >&2
	tail -200 "$log" >&2
	exit 1
fi
kill "$qemu_pid"
wait "$qemu_pid" || true
qemu_pid=
echo "live ISO installed $init_system to its explicit target disk"
