#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# r2.sh has KEY | get KEY FILE | put KEY FILE
#
# The CI's store in the R2 bucket that the R2_ACCOUNT_ID, R2_ACCESS_KEY_ID,
# R2_SECRET_ACCESS_KEY and R2_BUCKET environment values name. `has` succeeds
# when the bucket holds KEY.
set -eu

for name in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET; do
	eval "value=\${$name:-}"
	[ -n "$value" ] || { echo "r2.sh: set the $name repository secret" >&2; exit 1; }
done
if ! command -v aws >/dev/null 2>&1; then
	python3 -m pip install --quiet --user awscli >&2
	PATH="$(python3 -m site --user-base)/bin:$PATH"
fi
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
# R2 does not take every checksum newer AWS CLIs add by default.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
endpoint="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
# Fewer, larger parts: R2 refused to assemble a 1.5 GB image from the CLI's
# default 8 MB parts (InvalidPart), and a transfer that fails is retried.
config=$(mktemp)
trap 'rm -f "$config"' EXIT
printf '%s\n' '[default]' 's3 =' '    multipart_chunksize = 128MB' \
	'    multipart_threshold = 128MB' '    max_concurrent_requests = 4' > "$config"
export AWS_CONFIG_FILE="$config"

# copy SOURCE DESTINATION: aws s3 cp, tried three times.
copy()
{
	for attempt in 1 2 3; do
		if aws s3 cp "$1" "$2" --endpoint-url "$endpoint" --only-show-errors; then
			return 0
		fi
		echo "r2.sh: transfer attempt $attempt failed" >&2
		sleep $((attempt * 10))
	done
	return 1
}

case "${1:-}" in
has)
	aws s3api head-object --bucket "$R2_BUCKET" --key "$2" \
		--endpoint-url "$endpoint" >/dev/null 2>&1
	;;
get)
	copy "s3://$R2_BUCKET/$2" "$3"
	;;
put)
	copy "$3" "s3://$R2_BUCKET/$2"
	;;
*)
	echo "usage: r2.sh has KEY | get KEY FILE | put KEY FILE" >&2
	exit 2
	;;
esac
