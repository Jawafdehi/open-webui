#!/usr/bin/env bash
set -euo pipefail

# === Jawafdehi OpenWebUI Config Bootstrap ===
# Idempotent script that reads configs/ and applies them via OpenWebUI API.
# Safe to run multiple times — existing resources are skipped.

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGS_DIR="${REPO_ROOT}/configs"

OPENWEBUI_URL="${OPENWEBUI_URL:-http://localhost:3000}"
OPENWEBUI_API_KEY="${OPENWEBUI_API_KEY:-}"

# --- Helpers ---

api() {
    local method="$1" path="$2" body="${3:-}"
    local curl_args=(-s -w '\n%{http_code}' -X "$method")
    curl_args+=(-H "Authorization: Bearer ${OPENWEBUI_API_KEY}")
    curl_args+=(-H "Content-Type: application/json")

    if [ -n "$body" ]; then
        curl_args+=(--data-raw "$body")
    fi

    local url="${OPENWEBUI_URL}${path}"
    local response
    response="$(curl "${curl_args[@]}" "$url" 2>/dev/null)" || {
        echo "ERROR" >&2
        return 1
    }

    local http_code
    http_code="$(echo "$response" | tail -1)"
    local body_out
    body_out="$(echo "$response" | sed '$d')"

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        echo "$body_out"
        return 0
    else
        echo "API_ERROR:${http_code}:${body_out}" >&2
        return 1
    fi
}

check_admin() {
    if [ -z "$OPENWEBUI_API_KEY" ]; then
        echo "ERROR: OPENWEBUI_API_KEY is not set. Set it or provide --api-key." >&2
        exit 1
    fi
}

idempotent_action() {
    local label="$1" exists_fn="$2" create_fn="$3"
    echo -n "  ${label} ... "
    if "$exists_fn" 2>/dev/null; then
        echo "exists (skipping)"
        return 0
    fi
    if "$create_fn"; then
        echo "created"
        return 0
    fi
    echo "FAILED"
    return 1
}

# ===================================================================
#  Models
# ===================================================================

model_exists() {
    local model_id="$1"
    local result
    result="$(api GET "/api/v1/models/model?id=${model_id}" 2>/dev/null)" || return 1
    echo "$result" | python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1
}

apply_model() {
    local json_file="$1"
    local model_id
    model_id="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$json_file")"
    local model_name
    model_name="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$json_file")"

    idempotent_action "$model_name ($model_id)" \
        "model_exists '$model_id'" \
        "api POST /api/v1/models/create \"\$(cat '$json_file')\" > /dev/null"
}

apply_models() {
    echo ""
    echo "==> Applying models from configs/models/"
    if [ ! -d "${CONFIGS_DIR}/models" ]; then
        echo "  (no models directory, skipping)"
        return 0
    fi
    for file in "${CONFIGS_DIR}/models"/*.json; do
        [ -f "$file" ] || continue
        apply_model "$file"
    done
}

# ===================================================================
#  Prompts
# ===================================================================

prompt_command_from_filename() {
    local filename="$1"
    local base
    base="$(basename "$filename" .nep)"
    echo "/${base}"
}

prompt_exists() {
    local command="$1"
    local result
    result="$(api GET "/api/v1/prompts/" 2>/dev/null)" || return 1
    echo "$result" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
if any(p.get('command') == '${command}' for p in items):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

apply_prompt() {
    local nep_file="$1"
    local command
    command="$(prompt_command_from_filename "$nep_file")"
    local base
    base="$(basename "$nep_file" .nep)"
    local name
    name="$(echo "$base" | sed 's/-/ /g' | python3 -c "import sys; print(sys.stdin.read().title())")"
    local content
    content="$(cat "$nep_file" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")"

    local payload
    payload="$(python3 -c "
import json
print(json.dumps({
    'command': '${command}',
    'name': '${name}',
    'content': ${content},
    'tags': ['jawafdehi'],
    'is_production': True
}))
")"

    idempotent_action "${name} (${command})" \
        "prompt_exists '$command'" \
        "api POST /api/v1/prompts/create '$payload' > /dev/null"
}

apply_prompts() {
    echo ""
    echo "==> Applying prompts from configs/prompts/"
    if [ ! -d "${CONFIGS_DIR}/prompts" ]; then
        echo "  (no prompts directory, skipping)"
        return 0
    fi
    for file in "${CONFIGS_DIR}/prompts"/*.nep; do
        [ -f "$file" ] || continue
        apply_prompt "$file"
    done
}

# ===================================================================
#  Groups
# ===================================================================

group_exists() {
    local group_name="$1"
    local result
    result="$(api GET "/api/v1/groups/" 2>/dev/null)" || return 1
    echo "$result" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
if any(g.get('name') == '${group_name}' for g in items):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

group_lookup_id() {
    local group_name="$1"
    local result
    result="$(api GET "/api/v1/groups/" 2>/dev/null)" || { echo ""; return 1; }
    echo "$result" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for g in items:
    if g.get('name') == '${group_name}':
        print(g['id'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

set_model_access_for_group() {
    local group_name="$1" model_id="$2"
    local group_id
    group_id="$(group_lookup_id "$group_name")" || return 1
    local model_json
    model_json="$(api GET "/api/v1/models/model?id=${model_id}" 2>/dev/null)" || return 1

    local existing_grants
    existing_grants="$(echo "$model_json" | python3 -c "
import sys, json
m = json.load(sys.stdin)
grants = m.get('access_grants', [])
print(json.dumps(grants))
")"

    local group_granted
    group_granted="$(echo "$existing_grants" | python3 -c "
import sys, json
grants = json.load(sys.stdin)
for g in grants:
    if g.get('principal_type') == 'group' and g.get('principal_id') == '${group_id}':
        sys.exit(0)
sys.exit(1)
" 2>/dev/null && echo "yes" || echo "no")"

    if [ "$group_granted" = "yes" ]; then
        return 0
    fi

    local new_grants
    new_grants="$(echo "$existing_grants" | python3 -c "
import sys, json
grants = json.load(sys.stdin)
grants.append({
    'principal_type': 'group',
    'principal_id': '${group_id}',
    'permission': 'read'
})
print(json.dumps(grants))
")"

    local update_payload
    update_payload="$(python3 -c "
import json
m = json.loads('''$model_json''')
m['access_grants'] = json.loads('''$new_grants''')
update = {k: m[k] for k in ['id','name','base_model_id','params','meta','access_grants','is_active']}
update['base_model_id'] = update['base_model_id'] or None
print(json.dumps(update))
")"

    echo -n "    grant ${model_id} → ${group_name} ... "
    if api POST /api/v1/models/model/update "$update_payload" > /dev/null 2>&1; then
        echo "done"
        return 0
    fi
    echo "FAILED"
    return 1
}

set_tool_access_for_group() {
    local group_name="$1" tool_id="$2"
    local group_id
    group_id="$(group_lookup_id "$group_name")" || return 1

    local tool_json
    tool_json="$(api GET "/api/v1/tools/id/${tool_id}" 2>/dev/null)" || {
        echo "    tool ${tool_id} not found (skipping)" >&2
        return 0
    }

    local existing_grants
    existing_grants="$(echo "$tool_json" | python3 -c "
import sys, json
t = json.load(sys.stdin)
grants = t.get('access_grants', [])
print(json.dumps(grants))
")"

    local group_granted
    group_granted="$(echo "$existing_grants" | python3 -c "
import sys, json
grants = json.load(sys.stdin)
for g in grants:
    if g.get('principal_type') == 'group' and g.get('principal_id') == '${group_id}':
        sys.exit(0)
sys.exit(1)
" 2>/dev/null && echo "yes" || echo "no")"

    if [ "$group_granted" = "yes" ]; then
        return 0
    fi

    echo -n "    grant tool ${tool_id} → ${group_name} ... "
    echo "  (tool access grant update not fully automated, see deploy/chat/README.md)"
}

apply_group() {
    local json_file="$1"

    local group_name
    group_name="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['name'])" "$json_file")"
    local group_desc
    group_desc="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('description',''))" "$json_file")"
    local group_perms
    group_perms="$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('permissions',{})))" "$json_file")"
    local group_models
    group_models="$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('models',[])))" "$json_file")"
    local group_tools
    group_tools="$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get('tools',[])))" "$json_file")"

    local payload
    payload="$(python3 -c "
import json
print(json.dumps({
    'name': '${group_name}',
    'description': '${group_desc}',
    'permissions': json.loads('''$group_perms''')
}))
")"

    idempotent_action "${group_name} group" \
        "group_exists '$group_name'" \
        "api POST /api/v1/groups/create '$payload' > /dev/null" || return 1

    # Set model access grants for the group
    local model_ids
    model_ids="$(echo "$group_models" | python3 -c "
import sys, json
for m in json.load(sys.stdin):
    print(m)
")"
    while IFS= read -r model_id; do
        [ -z "$model_id" ] && continue
        set_model_access_for_group "$group_name" "$model_id"
    done <<< "$model_ids"

    # Set tool access grants for the group
    local tool_ids
    tool_ids="$(echo "$group_tools" | python3 -c "
import sys, json
for t in json.load(sys.stdin):
    print(t)
")"
    while IFS= read -r tool_id; do
        [ -z "$tool_id" ] && continue
        set_tool_access_for_group "$group_name" "$tool_id"
    done <<< "$tool_ids"
}

apply_groups() {
    echo ""
    echo "==> Applying groups from configs/groups/"
    if [ ! -d "${CONFIGS_DIR}/groups" ]; then
        echo "  (no groups directory, skipping)"
        return 0
    fi
    for file in "${CONFIGS_DIR}/groups"/*.json; do
        [ -f "$file" ] || continue
        apply_group "$file"
    done
}

# ===================================================================
#  Knowledge Base
# ===================================================================

upload_file() {
    local file_path="$1"
    local filename
    filename="$(basename "$file_path")"
    local content_type="text/markdown"

    local upload_result
    upload_result="$(curl -s -w '\n%{http_code}' \
        -H "Authorization: Bearer ${OPENWEBUI_API_KEY}" \
        -F "file=@${file_path};type=${content_type}" \
        "${OPENWEBUI_URL}/api/v1/files/upload" 2>/dev/null)" || return 1

    local http_code
    http_code="$(echo "$upload_result" | tail -1)"
    local body_out
    body_out="$(echo "$upload_result" | sed '$d')"

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        echo "$body_out" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])"
        return 0
    fi
    return 1
}

kb_exists() {
    local kb_name="$1"
    local result
    result="$(api GET "/api/v1/knowledge/" 2>/dev/null)" || return 1
    echo "$result" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
if any(k.get('name') == '${kb_name}' for k in items):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

kb_lookup_id() {
    local kb_name="$1"
    local result
    result="$(api GET "/api/v1/knowledge/" 2>/dev/null)" || { echo ""; return 1; }
    echo "$result" | python3 -c "
import sys, json
items = json.load(sys.stdin).get('items', [])
for k in items:
    if k.get('name') == '${kb_name}':
        print(k['id'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

apply_knowledge_base() {
    local kb_dir="$1"

    if [ ! -d "$kb_dir" ]; then
        return 0
    fi

    local kb_name
    kb_name="$(basename "$kb_dir" | sed 's/-/ /g' | python3 -c "import sys; print(sys.stdin.read().title())")"

    echo ""
    echo "==> Applying knowledge base: ${kb_name}"

    idempotent_action "${kb_name} knowledge base" \
        "kb_exists '$kb_name'" \
        "api POST /api/v1/knowledge/create '{\"name\":\"${kb_name}\",\"description\":\"Jawafdehi knowledge: ${kb_name}\"}' > /dev/null"

    local kb_id
    kb_id="$(kb_lookup_id "$kb_name")" || return 1

    echo "  Uploading documents to ${kb_name} ..."
    local uploaded=0
    while IFS= read -r -d '' doc_file; do
        echo -n "    $(basename "$doc_file") ... "
        local file_id
        if file_id="$(upload_file "$doc_file" 2>/dev/null)"; then
            if api POST "/api/v1/knowledge/${kb_id}/file/add" "{\"file_id\":\"${file_id}\"}" > /dev/null 2>&1; then
                echo "uploaded"
                uploaded=$((uploaded + 1))
            else
                echo "FAILED to add to knowledge base"
            fi
        else
            echo "FAILED to upload"
        fi
    done < <(find "$kb_dir" -type f -not -name 'README.md' -print0)

    if [ $uploaded -gt 0 ]; then
        echo "  Uploaded ${uploaded} document(s) to ${kb_name}"
    else
        echo "  (no new documents)"
    fi
}

apply_all_knowledge() {
    if [ ! -d "${CONFIGS_DIR}/knowledge" ]; then
        echo ""
        echo "==> Knowledge: (no knowledge directory, skipping)"
        return 0
    fi
    for kb_dir in "${CONFIGS_DIR}/knowledge"/*/; do
        [ -d "$kb_dir" ] || continue
        apply_knowledge_base "$kb_dir"
    done
}

# ===================================================================
#  Main
# ===================================================================

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Idempotent script to bootstrap Jawafdehi OpenWebUI config from configs/ directory.

Options:
  --url URL         OpenWebUI API URL (default: \$OPENWEBUI_URL or http://localhost:3000)
  --api-key KEY     OpenWebUI admin API key (default: \$OPENWEBUI_API_KEY)
  --models-only     Apply only model configs
  --prompts-only    Apply only prompt configs
  --groups-only     Apply only group configs
  --knowledge-only  Apply only knowledge base configs
  --dry-run         Show what would be done without making changes
  -h, --help        Show this help

Environment:
  OPENWEBUI_URL       OpenWebUI API base URL
  OPENWEBUI_API_KEY   Admin API key for OpenWebUI
EOF
    exit 0
}

MODE="all"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --url) OPENWEBUI_URL="$2"; shift 2 ;;
        --api-key) OPENWEBUI_API_KEY="$2"; shift 2 ;;
        --models-only) MODE="models"; shift ;;
        --prompts-only) MODE="prompts"; shift ;;
        --groups-only) MODE="groups"; shift ;;
        --knowledge-only) MODE="knowledge"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

echo "============================================"
echo " Jawafdehi OpenWebUI Config Bootstrap"
echo "============================================"
echo ""
echo "API URL:   ${OPENWEBUI_URL}"
echo "Configs:   ${CONFIGS_DIR}"
echo "API Key:   ${OPENWEBUI_API_KEY:0:8}..."
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN — no changes will be made"
    echo ""
fi

check_admin

case "$MODE" in
    all)
        apply_models
        apply_prompts
        apply_groups
        apply_all_knowledge
        ;;
    models)    apply_models ;;
    prompts)   apply_prompts ;;
    groups)    apply_groups ;;
    knowledge) apply_all_knowledge ;;
esac

echo ""
echo "============================================"
echo " Bootstrap complete."
echo "============================================"
