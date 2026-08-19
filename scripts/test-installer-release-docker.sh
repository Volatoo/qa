#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat >&2 <<'EOF'
Usage: scripts/test-installer-release-docker.sh \
  --installer-repo DIRECTORY --volatoo-repo DIRECTORY \
  --publication DIRECTORY --trusted-key FILE OUTPUT_DIRECTORY
EOF
}

installer_repo=
volatoo_repo=
publication=
trusted_key=
output=
while (( $# > 0 )); do
	case $1 in
		--installer-repo|--volatoo-repo|--publication|--trusted-key)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--installer-repo) installer_repo=$2 ;;
				--volatoo-repo) volatoo_repo=$2 ;;
				--publication) publication=$2 ;;
				--trusted-key) trusted_key=$2 ;;
			esac
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		-*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
		*) [[ -z $output ]] || { echo "error: only one output is allowed" >&2; exit 2; }; output=$1; shift ;;
	esac
done

[[ -d $installer_repo && ! -L $installer_repo && \
	-d $volatoo_repo && ! -L $volatoo_repo && \
	-d $publication && ! -L $publication && \
	-f $trusted_key && ! -L $trusted_key && -n $output ]] || {
	usage
	exit 2
}
index=$publication/releases/amd64/channels/v0.1-dev/index.json
live_inputs=$publication/releases/amd64/channels/v0.1-dev/live-media-inputs.json
[[ -f $index && ! -L $index && -f $index.sig && ! -L $index.sig && \
	-f $live_inputs && ! -L $live_inputs && \
	-f $live_inputs.sig && ! -L $live_inputs.sig ]] || {
	echo "error: publication has no complete signed v0.1-dev contract" >&2
	exit 1
}
[[ ! -e $output && ! -L $output ]] || {
	echo "error: output already exists: $output" >&2
	exit 1
}
qa_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/require-docker-context.sh
source "$qa_root/scripts/require-docker-context.sh"
volatoo_require_docker_context

absolute_directory()
{
	cd -- "$1" && pwd
}
installer_repo=$(absolute_directory "$installer_repo")
volatoo_repo=$(absolute_directory "$volatoo_repo")
publication=$(absolute_directory "$publication")
trusted_key=$(cd -- "$(dirname -- "$trusted_key")" && pwd)/$(basename -- "$trusted_key")
output_name=$(basename -- "$output")
output_parent=$(cd -- "$(dirname -- "$output")" && pwd)
[[ $output_name != . && $output_name != .. ]] || {
	echo "error: unsafe output directory name" >&2
	exit 1
}
staging=$(mktemp -d "$output_parent/.volatoo-installer-e2e.XXXXXX")
cleanup()
{
	if [[ -d $staging ]]; then
		find "$staging" -depth -type f -delete
		find "$staging" -depth -type d -empty -delete
	fi
}
trap cleanup EXIT

"$installer_repo/scripts/test-install-docker.sh" >/dev/null
docker run --rm --privileged --network none \
	--entrypoint /bin/bash \
	--env "HOST_UID=$(id -u)" \
	--env "HOST_GID=$(id -g)" \
	--mount "type=bind,src=$qa_root,dst=/qa,readonly" \
	--mount "type=bind,src=$publication,dst=/publication,readonly" \
	--mount "type=bind,src=$trusted_key,dst=/keys/release.pub,readonly" \
	--mount "type=bind,src=$staging,dst=/output" \
	volatoo-installer-integration:0.1-dev \
	/qa/scripts/test-installer-release-container.sh

for init_system in openrc systemd; do
	disk=$staging/volatoo-installed-$init_system-amd64.img
	[[ -f $disk && ! -L $disk ]] || {
		echo "error: formal installer did not publish $init_system test disk" >&2
		exit 1
	}
	"$volatoo_repo/scripts/test-release-disk-docker.sh" \
		--init-system "$init_system" \
		--firmwares bios,uefi \
		"$disk"
done

mv "$staging" "$output_parent/$output_name"
trap - EXIT
echo "Volatoo formal installer release Gate passed: $output_parent/$output_name"
