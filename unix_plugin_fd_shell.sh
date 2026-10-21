set -euo pipefail
APPS_PWD="${FDEBS_DB_PASSWORD}"          # use your EBS instance's password property code
. "${FDEBS_SOURCE_SCRIPT}"               # EBS environment file property

cd "$AOL_REPO_DIR" && git pull -q
OUT="$PWD/aol_objects.txt"

sqlplus -s /nolog <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT apps/"${APPS_PWD}"@${TWO_TASK}
@${AOL_TOOLS_DIR}/aol_discover.sql ${SINCE_DATE} ${OUT}
EOF
sed -i -e 's/[[:space:]]*$//' -e '/^$/d' "$OUT"

: > files.txt
while IFS='|' read -r TYPE APP KEY; do
  case $TYPE in
    VALUE_SET)      LCT=afffload.lct; ARGS="VALUE_SET FLEX_VALUE_SET_NAME=\"$KEY\"";;
    LOOKUP)         LCT=aflvmlu.lct;  ARGS="FND_LOOKUP_TYPE APPLICATION_SHORT_NAME=\"$APP\" LOOKUP_TYPE=\"$KEY\"";;
    MESSAGE)        LCT=afmdmsg.lct;  ARGS="FND_NEW_MESSAGES APPLICATION_SHORT_NAME=\"$APP\" MESSAGE_NAME=\"$KEY\"";;
    PROGRAM)        LCT=afcpprog.lct; ARGS="PROGRAM APPLICATION_SHORT_NAME=\"$APP\" CONCURRENT_PROGRAM_NAME=\"$KEY\"";;
    REQUEST_GROUP)  LCT=afcpreqg.lct; ARGS="REQUEST_GROUP REQUEST_GROUP_NAME=\"$KEY\" APPLICATION_SHORT_NAME=\"$APP\"";;
    FUNCTION)       LCT=afsload.lct;  ARGS="FUNCTION FUNCTION_NAME=\"$KEY\"";;
    MENU)           LCT=afsload.lct;  ARGS="MENU MENU_NAME=\"$KEY\"";;
    RESPONSIBILITY) LCT=afscursp.lct; ARGS="FND_RESPONSIBILITY RESP_KEY=\"$KEY\"";;
    *) echo "Skipping $TYPE"; continue;;
  esac
  SAFE=$(echo "$KEY" | tr ' /' '__')
  REL="aol/${APP}/${TYPE}/${SAFE}.ldt"
  mkdir -p "$(dirname "$REL")"
  eval FNDLOAD apps/\"\$APPS_PWD\" 0 Y DOWNLOAD \$FND_TOP/patch/115/import/$LCT \"$REL\" $ARGS
  echo "/$REL" >> files.txt
done < "$OUT"

COUNT=$(wc -l < files.txt)
if [ "$COUNT" -gt 0 ]; then
  git add aol && git commit -qm "AOL extract ${PACKAGE_NAME} since ${SINCE_DATE}" && git push -q
fi
setOutput OBJECT_COUNT "$COUNT"