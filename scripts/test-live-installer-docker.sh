#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat >&2 <<'EOF'
Usage: scripts/test-live-installer-docker.sh \
  --volatoo-repo DIRECTORY --iso FILE --state FILE \
  --descriptor FILE --signature FILE --trusted-key FILE \
  --ssh-private-key FILE --init-system openrc|systemd OUTPUT.img
EOF
}
volatoo_repo=
iso=
state=
descriptor=
signature=
trusted_key=
ssh_private_key=
init_system=
output=
while (( $# > 0 )); do
	case $1 in
		--volatoo-repo|--iso|--state|--descriptor|--signature|--trusted-key|--ssh-private-key|--init-system)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--volatoo-repo) volatoo_repo=$2 ;;
				--iso) iso=$2 ;;
				--state) state=$2 ;;
				--descriptor) descriptor=$2 ;;
				--signature) signature=$2 ;;
				--trusted-key) trusted_key=$2 ;;
				--ssh-private-key) ssh_private_key=$2 ;;
				--init-system) init_system=$2 ;;
			esac
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		-*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
		*) [[ -z $output ]] || { echo "error: only one output is allowed" >&2; exit 2; }; output=$1; shift ;;
	esac
done
[[ -d $volatoo_repo && ! -L $volatoo_repo && $init_system =~ ^(openrc|systemd)$ && -n $output ]] || { usage; exit 2; }
manifest=$iso.manifest
for input in "$iso" "$manifest" "$state" "$descriptor" "$signature" "$trusted_key" "$ssh_private_key" "$ssh_private_key.pub"; do
	[[ -f $input && ! -L $input ]] || { echo "error: live-install input is missing or unsafe: $input" >&2; exit 1; }
done
[[ ! -e $output && ! -L $output ]] || { echo "error: output already exists or is unsafe" >&2; exit 1; }
[[ $(docker context show) == orbstack ]] || { echo "error: Docker context must be orbstack" >&2; exit 1; }

absolute_file()
{
	printf '%s/%s\n' "$(cd -- "$(dirname -- "$1")" && pwd)" "$(basename -- "$1")"
}
volatoo_repo=$(cd -- "$volatoo_repo" && pwd)
iso=$(absolute_file "$iso")
manifest=$(absolute_file "$manifest")
state=$(absolute_file "$state")
descriptor=$(absolute_file "$descriptor")
signature=$(absolute_file "$signature")
trusted_key=$(absolute_file "$trusted_key")
ssh_private_key=$(absolute_file "$ssh_private_key")
qa_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_name=$(basename -- "$output")
output_parent=$(cd -- "$(dirname -- "$output")" && pwd)
[[ $output_name =~ ^[A-Za-z0-9._-]+\.img$ ]] || { echo "error: unsafe output name" >&2; exit 1; }
staging=$(mktemp -d "$output_parent/.volatoo-live-install.XXXXXX")
cleanup()
{
	if [[ -d $staging ]]; then
		find "$staging" -depth -type f -delete
		find "$staging" -depth -type d -empty -delete
	fi
}
trap cleanup EXIT

"$qa_root/scripts/verify-live-media-release-docker.sh" \
	--volatoo-repo "$volatoo_repo" --iso "$iso" --manifest "$manifest" \
	--descriptor "$descriptor" --signature "$signature" \
	--trusted-key "$trusted_key"
installer_digest=$(awk -F= '$1 == "installer_sha256" {print $2}' "$manifest")
[[ $installer_digest =~ ^[0-9a-f]{64}$ ]] || { echo "error: live ISO manifest has no installer digest" >&2; exit 1; }
truncate -s 2G "$staging/target.img"
image=volatoo-qemu-runner:1
docker build --tag "$image" "$volatoo_repo/scripts/qemu-container"
docker run --rm --network none \
	--env "INIT_SYSTEM=$init_system" \
	--env "INSTALLER_SHA256=$installer_digest" \
	--env "VOLATOO_LIVE_INSTALL_TIMEOUT=${VOLATOO_LIVE_INSTALL_TIMEOUT:-360}" \
	--mount "type=bind,src=$qa_root,dst=/qa,readonly" \
	--mount "type=bind,src=$iso,dst=/inputs/live.iso,readonly" \
	--mount "type=bind,src=$state,dst=/inputs/state.ext4,readonly" \
	--mount "type=bind,src=$ssh_private_key,dst=/inputs/ssh-key,readonly" \
	--mount "type=bind,src=$ssh_private_key.pub,dst=/inputs/ssh-key.pub,readonly" \
	--mount "type=bind,src=$staging,dst=/output" \
	"$image" /qa/scripts/install-from-live-iso-container.sh
mv "$staging/target.img" "$output_parent/$output_name"
trap - EXIT
rmdir "$staging"
"$volatoo_repo/scripts/test-release-disk-docker.sh" \
	--init-system "$init_system" --firmwares bios,uefi \
	"$output_parent/$output_name"
echo "Volatoo live ISO installer Gate passed: $output_parent/$output_name"
