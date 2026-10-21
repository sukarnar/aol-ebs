# AOL Auto Extract for FlexDeploy

Automatically discover Oracle EBS AOL objects, extract them with FNDLOAD, commit them to Git, and create a FlexDeploy package in an EBS partial-deploy project. AOL objects never have to be created by hand on the Project Files tab.

- **Target platform:** FlexDeploy 10.0 with the EBS plugin
- **Runs as:** a FlexDeploy Utility project executing a Utility workflow
- **Source system:** EBS build (DEV) instance

---

## Contents

1. [How it works](#1-how-it-works)
2. [Prerequisites](#2-prerequisites)
3. [Repository layout](#3-repository-layout)
4. [Step 1 – Install the scripts on the EBS app tier](#4-step-1--install-the-scripts-on-the-ebs-app-tier)
5. [Step 2 – Test the discovery query manually](#5-step-2--test-the-discovery-query-manually)
6. [Step 3 – Create the Utility workflow](#6-step-3--create-the-utility-workflow)
7. [Step 4 – Create the Utility project](#7-step-4--create-the-utility-project)
8. [Step 5 – Run it](#8-step-5--run-it)
9. [Things to verify in your environment](#9-things-to-verify-in-your-environment)
10. [Customization](#10-customization)
11. [Troubleshooting](#11-troubleshooting)
12. [Appendix – Scripts](#12-appendix--scripts)

---

## 1. How it works

```
[1] Discover  →  [2] Extract (FNDLOAD)  →  [3] Commit to Git  →  [4] Populate project files  →  [5] Create package (REST)  →  [6] Build (REST)
   SQL on EBS      EBS app tier             AOL repo              EBS FlexDeploy project         ordered file list           existing pipeline
```

1. **Discover.** A SQL query on the source EBS database lists custom AOL objects (`XX%`) changed since a given date.
2. **Extract.** Each object is downloaded with `FNDLOAD DOWNLOAD` using the correct `.lct` and entity.
3. **Commit.** The `.ldt` files are committed to the Git repo that the EBS FlexDeploy project populates from, under `aol/<APP>/<TYPE>/<KEY>.ldt`.
4. **Populate.** FlexDeploy classifies `.ldt` files as AOL objects and generates their attributes and FNDLOAD UPLOAD commands through its Default Scripts.
5. **Package.** The FlexDeploy Packages REST API creates a package containing the new files, in dependency order.
6. **Build.** The `buildProject` REST API builds the package. Deployment then follows your normal release or pipeline.

---

## 2. Prerequisites

| Item | Details |
|---|---|
| FlexDeploy | 10.0, EBS plugin and Unix Shell plugin installed |
| EBS FlexDeploy project | An existing **partial-deploy** EBS project sourced from Git |
| EBS build endpoint | FlexDeploy endpoint on the EBS application tier, already used by the EBS build instance |
| EBS instance properties | APPS password and EBS environment script already configured on the EBS instance |
| Git | Git installed on the EBS app tier, and a service account with push access to the AOL repo |
| FlexDeploy API access | A service user or API token allowed to create packages and start builds on the EBS project |
| Database access | `APPS` (required by FNDLOAD). The discovery query alone can use a read-only user with SELECT on the `FND_*` tables. |

---

## 3. Repository layout

### Tools (on the EBS app tier)

```
/u01/fd_tools/aol/
├── aol_discover.sql        # discovery query (Appendix A)
└── get_aol_list.sh         # optional, for manual testing (Appendix B)
```

### AOL repo (cloned on the EBS app tier)

```
/u01/fd_tools/aol_repo/
└── aol/
    ├── XXAP/
    │   ├── PROGRAM/XXAPINV.ldt
    │   ├── LOOKUP/XXAP_INV_STATUS.ldt
    │   └── MESSAGE/XXAP_ERR_MSG.ldt
    └── -/                         # objects with no application short name
        ├── VALUE_SET/XXAP_VENDOR_VS.ldt
        ├── FUNCTION/XXAP_INV_FUNC.ldt
        ├── MENU/XXAP_MAIN_MENU.ldt
        └── RESPONSIBILITY/XXAP_SUPER_USER.ldt
```

> Adjust the paths to your standards. Every path in this README assumes the layout above.

---

## 4. Step 1 – Install the scripts on the EBS app tier

1. Log in to the EBS app tier as the user that owns the FlexDeploy endpoint.
2. Create the tools folder and copy in `aol_discover.sql` from [Appendix A](#appendix-a--aol_discoversql).
   ```bash
   mkdir -p /u01/fd_tools/aol
   ```
3. Clone the AOL repo with the service account.
   ```bash
   git clone <your-aol-repo-url> /u01/fd_tools/aol_repo
   cd /u01/fd_tools/aol_repo
   git config user.name  "FlexDeploy AOL Extract"
   git config user.email "flexdeploy-svc@yourcompany.com"
   ```
4. Confirm that `git pull` and `git push` work without a password prompt, using an SSH key or a credential helper.

---

## 5. Step 2 – Test the discovery query manually

Before automating, check that the query returns the objects you expect.

1. Copy `get_aol_list.sh` from [Appendix B](#appendix-b--get_aol_listsh) to `/u01/fd_tools/aol/` and make it executable.
2. Run it:
   ```bash
   export APPS_PWD='********'
   cd /u01/fd_tools/aol
   ./get_aol_list.sh 2026-10-01 DEVEBS      # uses /DEVEBS_app/oracle/EBSapps.env
   ```
3. Check `aol_objects.txt`. Each line should have the form `TYPE|APP|KEY`:
   ```
   VALUE_SET|-|XXAP_VENDOR_VS
   LOOKUP|XXAP|XXAP_INV_STATUS
   PROGRAM|XXAP|XXAPINV
   FUNCTION|-|XXAP_INV_FUNC
   MENU|-|XXAP_MAIN_MENU
   ```
4. Adjust the `XX%` prefix and the object types in `aol_discover.sql` until the list is right.

> You can also run the query interactively in SQL Developer or Toad against the EBS DEV database. Replace `&since` with a date literal.

---

## 6. Step 3 – Create the Utility workflow

In FlexDeploy, go to **Workflows → Create**.

| Field | Value |
|---|---|
| Name | `AOL Auto Extract` |
| Type | **Utility** |

### 6.1 Workflow inputs

On the **Inputs** tab:

| Code | Type | Required | Description |
|---|---|---|---|
| `SINCE_DATE` | String | Yes | Lower bound for `last_update_date`, format `YYYY-MM-DD` |
| `PACKAGE_NAME` | String | Yes | Package name, e.g. `CHG12345` |

### 6.2 Workflow properties

On the **Properties** tab. The values are set later on the instance or project.

| Code | Scope | Encrypted | Example value |
|---|---|---|---|
| `EBS_DB_NAME` | Target | No | `DEVEBS`; used to build `/DEVEBS/oracle/EBSapps.env` (fallback if the endpoint name can't be used) |
| `EBS_ENDPOINT_SEPARATOR` | Target | No | `-` (default); separator before the DB name in `<machinename>-<DBNAME>` endpoint names |
| `EBS_DIR_SUFFIX` | Target | No | `_app` (default); appended to the DB name to form the folder, e.g. `DEVEBS_app` |
| `AOL_TOOLS_DIR` | Target | No | `/u01/fd_tools/aol` |
| `AOL_REPO_DIR` | Target | No | `/u01/fd_tools/aol_repo` |
| `FD_API_URL` | Target | No | `https://fdhost:8443/flexdeploy/rest` |
| `FD_API_TOKEN` | Target | **Yes** | service token |
| `EBS_PROJECT_ID` | Project | No | numeric ID of the EBS partial-deploy project |
| `EBS_PROJECT_PATH` | Project | No | `/FlexDeploy/EBS/XXAP` |

> The APPS password and EBS environment script already exist as EBS instance properties, so don't redefine them. The environment file follows the convention `/<database_name>/oracle/EBSapps.env`. Step 1 resolves it in this order:
>
> 1. **EBS Source Script** (`FDEBS_SOURCE_SCRIPT`) on the EBS instance, if set
> 2. **Endpoint name postfix.** If FlexDeploy exposes the endpoint name to the shell (as `FD_ENDPOINT_NAME` or `FD_ENDPOINT_CODE`), the text after the last `-` is used as the DB name. Endpoints follow the convention `<machinename>-<DBNAME>`, and `_app` is appended (the `EBS_DIR_SUFFIX` property), e.g. `ebsapp01-DEVEBS` → `DEVEBS_app` → `/DEVEBS_app/oracle/EBSapps.env`. Hyphens inside the machine name are fine; the DB name itself must not contain a hyphen. Set the `EBS_ENDPOINT_SEPARATOR` property only if the convention changes.
> 3. `/${EBS_DB_NAME}/oracle/EBSapps.env`, using the `EBS_DB_NAME` target property
> 4. Auto-discovery, only when exactly one `/*/oracle/EBSapps.env` exists on the server
>
> **Before relying on option 2**, run a one-off shell step on the EBS endpoint with `env | grep '^FD_' | sort` to confirm which endpoint variable your FlexDeploy version provides. The documented execution variables include `FD_ENVIRONMENT_CODE` and `FD_INSTANCE_CODE`, but an endpoint-name variable is not documented. If none exists, use option 1 or 3. Don't rely on auto-discovery on servers that host multiple instances. All workflow execution properties are available to the shell as environment variables, and secure values are masked as `*****` in the logs.

### 6.3 Workflow variables

| Variable | Type | Purpose |
|---|---|---|
| `OBJECT_COUNT` | Integer | Number of objects extracted in step 1 |

### 6.4 Workflow steps

#### Step 1 – Extract and commit

- **Operation:** Invoke Plugin → Unix Shell → `execute`
- **Endpoint:** the EBS build instance's app-tier endpoint
- **User-defined output:** `OBJECT_COUNT`, assigned to the workflow variable `OBJECT_COUNT`
- **Code:** [Appendix C](#appendix-c--workflow-step-1-extract-and-commit)

> In the script, replace `FDEBS_DB_PASSWORD` and `FDEBS_SOURCE_SCRIPT` with the property codes your EBS instance actually uses. You can find them on the instance's Properties tab in Topology.

#### Step 2 – Stop when nothing changed

- **Operation:** If/Condition
- **Condition:** `OBJECT_COUNT > 0`
- **False branch:** end the workflow with a message such as *"No AOL objects changed since SINCE_DATE."*
- **True branch:** continue to step 3.

#### Step 3 – Populate project files

The newly committed `.ldt` files must appear in the EBS project's **Project Files** before a package can reference them. See [Section 9, item 1](#9-things-to-verify-in-your-environment) for the options.

#### Step 4 – Create the package and start the build

- **Operation:** Invoke Plugin → Unix Shell → `execute`
- **Endpoint:** the same EBS endpoint, so it can read `files.txt`
- **Code:** [Appendix D](#appendix-d--workflow-step-4-create-package-and-build)

Save and activate the workflow.

---

## 7. Step 4 – Create the Utility project

1. Under the same application as your EBS project, create a project:

   | Field | Value |
   |---|---|
   | Name | `AOL_AUTO_EXTRACT` |
   | Classification | **Utility** |
   | Workflow | `AOL Auto Extract` |
   | Target instance | your **EBS build instance** |

2. **Project properties** (project's Properties tab):
   - `EBS_PROJECT_ID`
   - `EBS_PROJECT_PATH`
3. **Target properties** (Topology → EBS build instance → DEV environment):
   - `EBS_DB_NAME` (e.g. `DEVEBS`), unless EBS Source Script is already set
   - `AOL_TOOLS_DIR`
   - `AOL_REPO_DIR`
   - `FD_API_URL`
   - `FD_API_TOKEN`
4. Save.

---

## 8. Step 5 – Run it

1. Open `AOL_AUTO_EXTRACT` and click **Execute**.
2. Choose the **DEV** environment.
3. Enter the inputs, e.g. `SINCE_DATE = 2026-10-01` and `PACKAGE_NAME = CHG12345`.
4. Monitor the execution:
   - Step 1 should list each object it downloaded and show `OBJECT_COUNT`.
   - The AOL repo should have a new commit.
   - The EBS project should show a new package named `CHG12345`, followed by a build.
5. Deploy the package through your normal release or pipeline.

**Scheduling.** For a recurring run, trigger the utility project from Stonebranch UAC or another scheduler, passing a rolling `SINCE_DATE` and a generated `PACKAGE_NAME`.

---

## 9. Things to verify in your environment

1. **Populating project files.** The Packages API and `buildProject` API are documented, but a REST call to trigger Populate was not confirmed. Check your instance's REST API reference. If no such call exists, use one of these:
   - **Option A:** Test whether `buildProject` with an explicit `projectFiles` list accepts newly committed paths without a prior Populate.
   - **Option B:** Schedule a Populate on the EBS project ahead of each run.
   - **Option C:** Run Populate manually on the EBS project after step 1, then rerun with step 4 only. This is acceptable while piloting.
2. **Package `filePath` format.** Paths must match exactly what the Project Files screen shows. If the project's SCM source points at the `aol/` folder rather than the repo root, remove the `aol` prefix from the paths written to `files.txt`.
3. **API authentication.** The scripts send `Authorization: Bearer <token>`. If your instance uses basic auth, change the curl calls to `-u user:password`.
4. **AOL Default Script.** Confirm that FlexDeploy generates the correct `FNDLOAD UPLOAD` command and upload mode for each `.ldt`. Override the command per object type only where needed, for example custom modes for responsibilities or value sets.
5. **Git on the EBS server.** If Git is not allowed on the app tier, have step 1 only produce the `.ldt` files as a FlexDeploy artifact (check **Produces Artifacts**). Then add a step on the FlexDeploy server endpoint that consumes the artifact and does the Git commit and push.
6. **Don't write to FlexDeploy's repository tables.** Inserting project-file rows directly into FlexDeploy's database is unsupported and will break on upgrades.

---

## 10. Customization

### Select by ticket instead of by date

Replace the `last_update_date` filters with an explicit list, or join to a control table:

```sql
WHERE concurrent_program_name IN (SELECT obj_key FROM xx_aol_extract_list WHERE ticket = '&ticket')
```

### Request groups on seeded groups

The default query finds only request groups named `XX%`. To catch custom programs added to seeded groups such as *All Reports*, drive the query from `fnd_request_group_units` joined to your `XX` programs. Extract the request group entry rather than the whole seeded group.

### Adding more object types

Add a branch to the discovery `UNION ALL`, then a matching `case` entry in the step 1 script:

| Type | LCT | Entity / key parameters |
|---|---|---|
| PROFILE | `afscprof.lct` | `PROFILE PROFILE_NAME APPLICATION_SHORT_NAME` |
| DFF | `afffload.lct` | `DESC_FLEX APPLICATION_SHORT_NAME DESCRIPTIVE_FLEXFIELD_NAME` |
| XDO data definition | `$XDO_TOP/patch/115/import/xdotmpl.lct` | `XDO_DS_DEFINITIONS APPLICATION_SHORT_NAME DATA_SOURCE_CODE` |

Also add the new type to the `ORDER BY DECODE(...)` so it lands in the correct dependency position.

### Dependency order used

| Seq | Type |
|---|---|
| 10 | VALUE_SET |
| 20 | LOOKUP |
| 30 | MESSAGE |
| 40 | PROFILE |
| 50 | PROGRAM |
| 60 | REQUEST_GROUP |
| 70 | FUNCTION |
| 80 | MENU |
| 90 | RESPONSIBILITY |

---

## 11. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `aol_objects.txt` is empty | No objects match the prefix or date. Run the query in SQL Developer to confirm. |
| `ORA-` or `SP2-` lines in the output | SQL error or bad connection. Check `TWO_TASK`, the APPS password property, and that the environment file was sourced. |
| `FNDLOAD: command not found` | The EBS environment file wasn't sourced. Check the `FDEBS_SOURCE_SCRIPT` property. |
| `.ldt` is created but empty | Wrong entity or key parameter. Check the FNDLOAD `.log` file written next to the `.ldt`. |
| Package API returns 404 | Wrong `EBS_PROJECT_ID`, or the file paths are not in Project Files yet (see Section 9). |
| Package created but files are missing | The `filePath` doesn't match the Project Files path (see Section 9, item 2). |
| `git push` fails | The service account lacks push access, or the SSH key or credentials aren't set up for the endpoint user. |
| Password visible in logs | It shouldn't be. Secure properties are masked as `*****`. Never `set -x` in the shell steps. |

---

## 12. Appendix – Scripts

### Appendix A – `aol_discover.sql`

```sql
-- Usage: @aol_discover.sql <since YYYY-MM-DD> <output file>
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET PAGESIZE 0 LINESIZE 1000 TRIMSPOOL ON HEADING OFF FEEDBACK OFF
SET VERIFY OFF ECHO OFF TERMOUT OFF TAB OFF

DEFINE since = '&1'
SPOOL &2

SELECT obj_type || '|' || NVL(app,'-') || '|' || obj_key
FROM (
  SELECT 'PROGRAM' obj_type, a.application_short_name app, p.concurrent_program_name obj_key
    FROM fnd_concurrent_programs p JOIN fnd_application a ON a.application_id = p.application_id
   WHERE p.concurrent_program_name LIKE 'XX%' AND p.last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'VALUE_SET', NULL, flex_value_set_name
    FROM fnd_flex_value_sets
   WHERE flex_value_set_name LIKE 'XX%' AND last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'LOOKUP', a.application_short_name, l.lookup_type
    FROM fnd_lookup_types l JOIN fnd_application a ON a.application_id = l.application_id
   WHERE l.lookup_type LIKE 'XX%' AND l.last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'FUNCTION', NULL, function_name
    FROM fnd_form_functions
   WHERE function_name LIKE 'XX%' AND last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'MENU', NULL, menu_name
    FROM fnd_menus
   WHERE menu_name LIKE 'XX%' AND last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'RESPONSIBILITY', NULL, responsibility_key
    FROM fnd_responsibility
   WHERE responsibility_key LIKE 'XX%' AND last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'MESSAGE', a.application_short_name, m.message_name
    FROM fnd_new_messages m JOIN fnd_application a ON a.application_id = m.application_id
   WHERE m.message_name LIKE 'XX%' AND m.last_update_date > TO_DATE('&since','YYYY-MM-DD')
  UNION ALL
  SELECT 'REQUEST_GROUP', a.application_short_name, g.request_group_name
    FROM fnd_request_groups g JOIN fnd_application a ON a.application_id = g.application_id
   WHERE g.request_group_name LIKE 'XX%' AND g.last_update_date > TO_DATE('&since','YYYY-MM-DD')
)
ORDER BY DECODE(obj_type,'VALUE_SET',10,'LOOKUP',20,'MESSAGE',30,'PROFILE',40,'PROGRAM',50,
                'REQUEST_GROUP',60,'FUNCTION',70,'MENU',80,'RESPONSIBILITY',90), obj_key;

SPOOL OFF
EXIT
```

### Appendix B – `get_aol_list.sh`

For manual testing only. The FlexDeploy workflow does not use it.

```bash
#!/bin/bash
set -euo pipefail

SINCE="${1:?Usage: get_aol_list.sh YYYY-MM-DD <database_name>}"
OUT="aol_objects.txt"

# 2nd argument is the database name; the env file is /<db_name>_app/oracle/EBSapps.env
DB_NAME="${2:?Usage: get_aol_list.sh YYYY-MM-DD <database_name>}"
EBS_ENV_FILE="/${DB_NAME}${EBS_DIR_SUFFIX-_app}/oracle/EBSapps.env"
if [ ! -f "$EBS_ENV_FILE" ]; then echo "EBS env file not found: $EBS_ENV_FILE"; exit 1; fi

set +u
case "$(basename "$EBS_ENV_FILE")" in
  EBSapps.env) . "$EBS_ENV_FILE" run ;;
  *)           . "$EBS_ENV_FILE" ;;
esac
set -u

# Connecting via /nolog keeps the APPS password out of `ps` output
sqlplus -s /nolog <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT apps/"${APPS_PWD}"@${TWO_TASK}
@aol_discover.sql ${SINCE} ${OUT}
EOF

sed -i -e 's/[[:space:]]*$//' -e '/^$/d' "$OUT"

if grep -q 'ORA-\|SP2-' "$OUT"; then echo "SQL error in $OUT"; exit 1; fi
if [ ! -s "$OUT" ]; then echo "No AOL objects changed since $SINCE"; exit 0; fi

echo "Found $(wc -l < "$OUT") objects:"
cat "$OUT"
```

### Appendix C – Workflow step 1: extract and commit

```bash
set -euo pipefail

# Map to your EBS instance's property codes
APPS_PWD="${FDEBS_DB_PASSWORD}"

# EBS environment file. Convention: /<database_name>/oracle/EBSapps.env
# Resolution order:
#   1. FDEBS_SOURCE_SCRIPT (EBS instance property "EBS Source Script"), if set
#   2. DB name taken from the endpoint name postfix + suffix, e.g. ebsapp01-DEVEBS -> DEVEBS_app
#   3. /${EBS_DB_NAME}${EBS_DIR_SUFFIX}/oracle/EBSapps.env, from the EBS_DB_NAME property
#   4. Auto-discover, only if exactly one /*_app/oracle/EBSapps.env exists on this server
EBS_ENV_FILE="${FDEBS_SOURCE_SCRIPT:-}"

# 2. Endpoint-name postfix. Confirm which variable your FlexDeploy exposes with: env | grep '^FD_'
ENDPOINT_NAME="${FD_ENDPOINT_NAME:-${FD_ENDPOINT_CODE:-}}"
# Endpoint convention: <machinename>-<DBNAME>; take the text after the LAST separator,
# then append the directory suffix (default _app)
SEP="${EBS_ENDPOINT_SEPARATOR:--}"
SUFFIX="${EBS_DIR_SUFFIX-_app}"
if [ -z "$EBS_ENV_FILE" ] && [ -n "$ENDPOINT_NAME" ]; then
  DB_FROM_ENDPOINT="${ENDPOINT_NAME##*"${SEP}"}${SUFFIX}"   # ebsapp01-DEVEBS -> DEVEBS_app
  CANDIDATE="/${DB_FROM_ENDPOINT}/oracle/EBSapps.env"
  if [ -f "$CANDIDATE" ]; then
    EBS_ENV_FILE="$CANDIDATE"
    echo "DB name '$DB_FROM_ENDPOINT' taken from endpoint '$ENDPOINT_NAME'"
  else
    echo "WARN: endpoint '$ENDPOINT_NAME' gives $CANDIDATE, which does not exist"
  fi
fi

# 3. Explicit property
if [ -z "$EBS_ENV_FILE" ] && [ -n "${EBS_DB_NAME:-}" ]; then
  EBS_ENV_FILE="/${EBS_DB_NAME}${SUFFIX}/oracle/EBSapps.env"
fi
if [ -z "$EBS_ENV_FILE" ]; then
  MATCHES=$(ls -1 /*"${SUFFIX}"/oracle/EBSapps.env 2>/dev/null || true)
  if [ "$(printf '%s\n' "$MATCHES" | grep -c .)" -eq 1 ]; then
    EBS_ENV_FILE="$MATCHES"
  else
    echo "ERROR: cannot determine EBS env file. Set EBS_DB_NAME for this environment. Found:"
    printf '%s\n' "$MATCHES"; exit 1
  fi
fi
if [ ! -f "$EBS_ENV_FILE" ]; then echo "ERROR: EBS env file not found: $EBS_ENV_FILE"; exit 1; fi

set +u                                   # EBS env scripts reference unset variables
case "$(basename "$EBS_ENV_FILE")" in
  EBSapps.env) . "$EBS_ENV_FILE" run ;;  # 12.2: source the run file system
  *)           . "$EBS_ENV_FILE" ;;      # 12.1 / APPS<SID>_<host>.env
esac
set -u
echo "Sourced $EBS_ENV_FILE (TWO_TASK=$TWO_TASK)"

cd "$AOL_REPO_DIR"
git pull -q

OUT="$PWD/aol_objects.txt"

# 1. Discover
sqlplus -s /nolog <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT apps/"${APPS_PWD}"@${TWO_TASK}
@${AOL_TOOLS_DIR}/aol_discover.sql ${SINCE_DATE} ${OUT}
EOF
sed -i -e 's/[[:space:]]*$//' -e '/^$/d' "$OUT"
if grep -q 'ORA-\|SP2-' "$OUT"; then echo "Discovery query failed"; cat "$OUT"; exit 1; fi

# 2. Extract
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
    *) echo "Skipping unsupported type $TYPE"; continue;;
  esac

  SAFE=$(echo "$KEY" | tr ' /' '__')
  REL="aol/${APP}/${TYPE}/${SAFE}.ldt"
  mkdir -p "$(dirname "$REL")"

  echo "Downloading $TYPE $KEY -> $REL"
  eval FNDLOAD apps/\"\$APPS_PWD\" 0 Y DOWNLOAD \$FND_TOP/patch/115/import/$LCT \"$REL\" $ARGS

  if [ ! -s "$REL" ]; then echo "ERROR: $REL is empty"; exit 1; fi
  echo "/$REL" >> files.txt
done < "$OUT"

# Remove FNDLOAD logs so they are not committed
rm -f ./*.log

# 3. Commit
COUNT=$(wc -l < files.txt)
if [ "$COUNT" -gt 0 ]; then
  git add aol
  git commit -qm "AOL extract ${PACKAGE_NAME} since ${SINCE_DATE}" || echo "Nothing new to commit"
  git push -q
fi

echo "Extracted $COUNT objects"
setOutput OBJECT_COUNT "$COUNT"
```

### Appendix D – Workflow step 4: create package and build

```bash
set -euo pipefail
cd "$AOL_REPO_DIR"

# Build the package file list in dependency order (seq 10, 20, 30, ...)
FILES_JSON=$(awk 'BEGIN{printf "["}
  {printf "%s{\"filePath\":\"%s\",\"sequenceNumber\":%d}", (NR>1?",":""), $0, NR*10}
  END{printf "]"}' files.txt)

echo "Creating package ${PACKAGE_NAME}"
curl -sf -X PUT "${FD_API_URL}/v1/project/${EBS_PROJECT_ID}/package/${PACKAGE_NAME}" \
  -H "Authorization: Bearer ${FD_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"description\":\"Auto AOL extract since ${SINCE_DATE}\",\"files\":${FILES_JSON}}"

echo "Starting build for ${PACKAGE_NAME}"
curl -sf -X POST "${FD_API_URL}/workflow/buildProject" \
  -H "Authorization: Bearer ${FD_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"projectName\":\"${EBS_PROJECT_PATH}\",\"packageName\":\"${PACKAGE_NAME}\"}"
```

---

## References

- FlexDeploy EBS Object Types Reference – https://flexagon.atlassian.net/wiki/x/eoDMAw
- Project Configuration (EBS), sourcing AOL files from EBS – https://flexagon.atlassian.net/wiki/x/wRssAg
- Project Packages API – https://flexagon.atlassian.net/wiki/x/9W-Idw
- buildProject REST API – https://flexagon.atlassian.net/wiki/x/hICiB
- Workflow appendix (Utility workflows) – https://flexagon.atlassian.net/wiki/x/8wxIiwI
- Unix Shell plugin, execute – https://flexagon.atlassian.net/wiki/x/WAFP
