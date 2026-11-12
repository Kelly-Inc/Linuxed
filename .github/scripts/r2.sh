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

case "${1:-}" in
has)
	aws s3api head-object --bucket "$R2_BUCKET" --key "$2" \
		--endpoint-url "$endpoint" >/dev/null 2>&1
	;;
get)
	aws s3 cp "s3://$R2_BUCKET/$2" "$3" --endpoint-url "$endpoint" --only-show-errors
	;;
put)
	aws s3 cp "$3" "s3://$R2_BUCKET/$2" --endpoint-url "$endpoint" --only-show-errors
	;;
*)
	echo "usage: r2.sh has KEY | get KEY FILE | put KEY FILE" >&2
	exit 2
	;;
esac
