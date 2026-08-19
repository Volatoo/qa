#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat >&2 <<'EOF'
Usage: scripts/verify-live-media-release-docker.sh \
  --volatoo-repo DIRECTORY --iso FILE --manifest FILE \
  --descriptor FILE --signature FILE --trusted-key FILE
EOF
}

volatoo_repo=
iso=
manifest=
descriptor=
signature=
trusted_key=
while (( $# > 0 )); do
	case $1 in
		--volatoo-repo|--iso|--manifest|--descriptor|--signature|--trusted-key)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--volatoo-repo) volatoo_repo=$2 ;;
				--iso) iso=$2 ;;
				--manifest) manifest=$2 ;;
				--descriptor) descriptor=$2 ;;
				--signature) signature=$2 ;;
				--trusted-key) trusted_key=$2 ;;
			esac
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
	esac
done
[[ -d $volatoo_repo && ! -L $volatoo_repo ]] || { usage; exit 2; }
for input in "$iso" "$manifest" "$descriptor" "$signature" "$trusted_key"; do
	[[ -f $input && ! -L $input ]] || {
		echo "error: live-media verification input is missing or unsafe: $input" >&2
		exit 1
	}
done
qa_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/require-docker-context.sh
source "$qa_root/scripts/require-docker-context.sh"
volatoo_require_docker_context
absolute_file()
{
	printf '%s/%s\n' "$(cd -- "$(dirname -- "$1")" && pwd)" "$(basename -- "$1")"
}
volatoo_repo=$(cd -- "$volatoo_repo" && pwd)
iso=$(absolute_file "$iso")
manifest=$(absolute_file "$manifest")
descriptor=$(absolute_file "$descriptor")
signature=$(absolute_file "$signature")
trusted_key=$(absolute_file "$trusted_key")
image=volatoo-live-iso-builder:0.1-dev
docker build --platform linux/amd64 --tag "$image" \
	--file "$volatoo_repo/image/live-iso/Dockerfile" "$volatoo_repo"
docker run --rm --network none --platform linux/amd64 \
	--entrypoint python3 \
	--env "ISO_NAME=$(basename -- "$iso")" \
	--mount "type=bind,src=$qa_root/scripts/verify-live-media-release.py,dst=/verify-live-media-release.py,readonly" \
	--mount "type=bind,src=$iso,dst=/input/live.iso,readonly" \
	--mount "type=bind,src=$manifest,dst=/input/live.iso.manifest,readonly" \
	--mount "type=bind,src=$descriptor,dst=/input/live-media.json,readonly" \
	--mount "type=bind,src=$signature,dst=/input/live-media.json.sig,readonly" \
	--mount "type=bind,src=$trusted_key,dst=/input/release.pub,readonly" \
	"$image" /verify-live-media-release.py
