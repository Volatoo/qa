#!/usr/bin/env bash

set -euo pipefail

active_loop=
cleanup()
{
	if [[ -n $active_loop ]]; then losetup --detach "$active_loop" 2>/dev/null || true; fi
}
trap cleanup EXIT

index=/publication/releases/amd64/channels/v0.1-dev/index.json
live_inputs=/publication/releases/amd64/channels/v0.1-dev/live-media-inputs.json
tampered_live_inputs=/run/live-media-inputs-tampered.json
cp "$live_inputs" "$tampered_live_inputs"
printf ' ' >>"$tampered_live_inputs"
if python3 /qa/scripts/verify-live-media-inputs.py \
	--document "$tampered_live_inputs" \
	--signature "$live_inputs.sig" \
	--trusted-key /keys/release.pub \
	--installer /usr/local/libexec/volatoo-installer-amd64 \
	--keyring-output /run/volatoo-tampered-keyring \
	>/run/tampered-live-inputs.stdout 2>/run/tampered-live-inputs.stderr
then
	echo "error: QA accepted a changed live-media input document" >&2
	exit 1
fi
grep -Fq 'live-media input signature verification failed' \
	/run/tampered-live-inputs.stderr
mixed_release=/run/mixed-release
mkdir "$mixed_release"
cp "$live_inputs" "$live_inputs.sig" "$index" "$mixed_release/"
printf ' ' >>"$mixed_release/index.json"
if python3 /qa/scripts/verify-live-media-inputs.py \
	--document "$mixed_release/live-media-inputs.json" \
	--signature "$mixed_release/live-media-inputs.json.sig" \
	--trusted-key /keys/release.pub \
	--installer /usr/local/libexec/volatoo-installer-amd64 \
	--keyring-output /run/volatoo-mixed-keyring \
	>/run/mixed-release.stdout 2>/run/mixed-release.stderr
then
	echo "error: QA accepted mismatched signed release documents" >&2
	exit 1
fi
grep -Fq 'release index differs from the signed live-media binding' \
	/run/mixed-release.stderr
python3 /qa/scripts/verify-live-media-inputs.py \
	--document "$live_inputs" \
	--signature "$live_inputs.sig" \
	--trusted-key /keys/release.pub \
	--installer /usr/local/libexec/volatoo-installer-amd64 \
	--keyring-output /run/volatoo-release-keyring
for init_system in openrc systemd; do
	staging=/output/.volatoo-installed-$init_system-amd64.img.new
	final=/output/volatoo-installed-$init_system-amd64.img
	[[ ! -e $staging && ! -e $final ]] || {
		echo "error: installer test output already exists" >&2
		exit 1
	}
	truncate --size=2G "$staging"
	active_loop=$(losetup --find --show --partscan "$staging")
	printf '%s\n' "$active_loop" | VOLATOO_INSTALLER_TESTING=1 \
		volatoo-installer install \
		--index "$index" \
		--trusted-key-dir /run/volatoo-release-keyring \
		--channel v0.1-dev \
		--architecture amd64 \
		--init-system "$init_system" \
		--device "$active_loop" \
		--no-provision-access \
		--allow-loop-device
	losetup --detach "$active_loop"
	active_loop=
	mv "$staging" "$final"
done
chown "$HOST_UID:$HOST_GID" /output/*.img
echo "formal installer produced OpenRC and systemd disks"
