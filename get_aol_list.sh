#!/bin/bash
set -euo pipefail

SINCE="${1:?Usage: get_aol_list.sh YYYY-MM-DD}"
OUT="aol_objects.txt"

. /u01/app/EBSapps.env run     # adjust to your environment file

# Connecting via /nolog keeps the APPS password out of `ps` output
sqlplus -s /nolog <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT apps/"${APPS_PWD}"@${TWO_TASK}
@aol_discover.sql ${SINCE} ${OUT}
EOF

# Remove blank lines and stray whitespace
sed -i -e 's/[[:space:]]*$//' -e '/^$/d' "$OUT"

# Stop the pipeline if anything went wrong
grep -q 'ORA-\|SP2-' "$OUT" && { echo "SQL error in $OUT"; exit 1; }
[ -s "$OUT" ] || { echo "No AOL objects changed since $SINCE"; exit 0; }

echo "Found $(wc -l < "$OUT") objects:"
cat "$OUT"