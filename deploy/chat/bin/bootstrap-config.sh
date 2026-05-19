#!/usr/bin/env bash
# bootstrap-config.sh — Apply Jawafdehi config to OpenWebUI via REST API
#
# Reads configs/ directory and pushes everything to a running OpenWebUI
# instance. Idempotent: checks if each item already exists before creating.
#
# Usage:
#   export OWUI_BASE_URL="https://chat.jawafdehi.org"
#   export OWUI_API_KEY="sk-..."
#   ./bootstrap-config.sh
#
# Optional:
#   OWUI_DRY_RUN=1    — print actions without making changes
#   OWUI_VERBOSE=1    — show raw API responses

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGS_DIR="$(dirname "$SCRIPT_DIR")/configs"

: "${OWUI_BASE_URL:?OWUI_BASE_URL must be set (e.g. https://chat.jawafdehi.org)}"
: "${OWUI_API_KEY:?OWUI_API_KEY must be set}"
OWUI_API="${OWUI_BASE_URL}/api/v1"

DRY_RUN="${OWUI_DRY_RUN:-0}"
VERBOSE="${OWUI_VERBOSE:-0}"
TMPDIR="${TMPDIR:-/tmp}"

log()  { echo "[bootstrap] $(date -Iseconds) $*"; }
info() { echo "  -> $*"; }
warn() { echo "  !! $*" >&2; }
err()  { echo "  [ERROR] $*" >&2; exit 1; }

# --- API helpers ---

_api_call() {
    local method="$1" path="$2" data="${3:-}"
    local url="${OWUI_API}${path}"
    local curl_args=(-s -w "\n%{http_code}" -H "Authorization: Bearer ${OWUI_API_KEY}")
    curl_args+=(-H "Content-Type: application/json" -H "x-api-key: ${OWUI_API_KEY}")

    if [ "$method" = "GET" ]; then
        curl_args+=(-X GET)
    elif [ "$method" = "POST" ]; then
        curl_args+=(-X POST -d "$data")
    elif [ "$method" = "PUT" ]; then
        curl_args+=(-X PUT -d "$data")
    elif [ "$method" = "DELETE" ]; then
        curl_args+=(-X DELETE)
    fi

    [ "$VERBOSE" = "1" ] && log "API $method $path"

    local response http_code
    response=$(curl "${curl_args[@]}" "$url" 2>&1) || err "curl failed: $response"
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    [ "$VERBOSE" = "1" ] && echo "    HTTP $http_code: $(echo "$body" | head -c 200)"

    if [ "$http_code" -ge 400 ]; then
        warn "$method $path → HTTP $http_code"
        # Surface response body detail for common failure modes
        local detail
        detail=$(echo "$body" | jq -r '.detail // empty' 2>/dev/null || echo "")
        [ -n "$detail" ] && warn "  Response: $detail"
        return 1
    fi

    echo "$body"
    return 0
}

# --- Permission check ---

verify_model_create_permission() {
    # Call models endpoint with GET to extract user info implicitly;
    # a 401 here signals the key is invalid entirely.
    # Then we attempt a lightweight POST to check workspace.models permission.
    local user_info http_code
    user_info=$(curl -s -w "\n%{http_code}" \
        -X GET "${OWUI_API}/users/user/info" \
        -H "Authorization: Bearer ${OWUI_API_KEY}" \
        -H "Content-Type: application/json" 2>/dev/null)
    http_code=$(echo "$user_info" | tail -1)

    if [ "$http_code" -eq 401 ]; then
        err "API key rejected (HTTP 401) — verify ${SECRETS_DIR:-/opt/openwebui-secrets}/admin-api-key.txt contains a valid OpenWebUI admin API key (must start with 'sk-'). If the key is correct, check that the associated user has admin role or workspace.models permission in OpenWebUI Admin Settings."
    fi

    # Attempt a read on models to verify basic access
    # NOTE: no trailing slash — /api/v1/models/ returns the SPA HTML, not JSON
    local model_check
    model_check=$(curl -s -w "\n%{http_code}" \
        -X GET "${OWUI_API}/models" \
        -H "Authorization: Bearer ${OWUI_API_KEY}" \
        -H "Content-Type: application/json" 2>/dev/null)
    http_code=$(echo "$model_check" | tail -1)

    if [ "$http_code" -eq 401 ]; then
        err "API key rejected on models list (HTTP 401) — your API key is valid for basic endpoints but may lack permissions for model operations. Ensure the user has admin role or workspace.models permission."
    fi

    info "API key accepted for model operations."
}

# --- Model presets ---

apply_models() {
    log "Applying model presets..."

    verify_model_create_permission

    local model_dir="${CONFIGS_DIR}/models"

    [ ! -d "$model_dir" ] && warn "No configs/models/ directory found" && return

    for model_file in "$model_dir"/*.json; do
        [ ! -f "$model_file" ] && continue
        local model_data model_id
        model_data=$(cat "$model_file")
        model_id=$(echo "$model_data" | jq -r '.id // empty')

        [ -z "$model_id" ] && warn "Skipping $model_file: no 'id' field" && continue

        if [ "$DRY_RUN" = "1" ]; then
            log "[DRY RUN] Would replace model: $model_id"
            continue
        fi

        # Delete existing model first (ignore 404 if not found).
        # OpenWebUI returns 401 with NOT_FOUND detail when the model doesn't exist.
        local del_http del_body
        del_body=$(curl -s -w "\n%{http_code}" \
            -X POST "${OWUI_API}/models/model/delete" \
            -H "Authorization: Bearer ${OWUI_API_KEY}" \
            -H "Content-Type: application/json" \
            -H "x-api-key: ${OWUI_API_KEY}" \
            -d "{\"id\":\"${model_id}\"}" 2>/dev/null)
        del_http=$(echo "$del_body" | tail -1)
        if [ "$del_http" -ge 200 ] 2>/dev/null && [ "$del_http" -lt 300 ]; then
            info "  Deleted existing model '$model_id'"
        fi

        # Create (or recreate) the model
        info "Creating model: $model_id"
        local create_body create_http
        create_body=$(curl -s -w "\n%{http_code}" \
            -X POST "${OWUI_API}/models/create" \
            -H "Authorization: Bearer ${OWUI_API_KEY}" \
            -H "Content-Type: application/json" \
            -H "x-api-key: ${OWUI_API_KEY}" \
            -d "$model_data" 2>/dev/null)
        create_http=$(echo "$create_body" | tail -1)

        if [ "$create_http" -ge 200 ] 2>/dev/null && [ "$create_http" -lt 300 ]; then
            info "  Model '$model_id' created successfully."
        else
            local detail
            detail=$(echo "$create_body" | sed '$d' | jq -r '.detail // empty' 2>/dev/null || echo "")
            [ -n "$detail" ] && warn "  Response: $detail"
            warn "  If HTTP 401: verify API key is admin in OpenWebUI Admin Settings."
            warn "  If HTTP 502/503: backend may still be starting. Retry in a moment."
            err "Failed to create model $model_id (HTTP $create_http)"
        fi
    done

    log "Model presets done."
}

# --- Knowledge Base ---

apply_knowledge() {
    log "Applying Knowledge Base collections..."

    local kb_dir="${CONFIGS_DIR}/knowledge"
    local collections_file="${kb_dir}/collections.json"

    [ ! -f "$collections_file" ] && warn "No configs/knowledge/collections.json found" && return

    local collections
    collections=$(jq -c '.collections[]' "$collections_file")

    # Get existing KB collections
    local existing
    existing=$(_api_call GET "/knowledge/" "" 2>/dev/null || echo '[]')

    while IFS= read -r col; do
        local col_id col_name col_desc
        col_id=$(echo "$col" | jq -r '.id')
        col_name=$(echo "$col" | jq -r '.name')
        col_desc=$(echo "$col" | jq -r '.description')

        local kb_id
        kb_id=$(echo "$existing" | jq -r --arg name "$col_name" '[.items[]? | select(.name == $name) | .id // empty] | first' 2>/dev/null || echo "")

        if [ -z "$kb_id" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                log "[DRY RUN] Would create KB collection: $col_name"
                kb_id="dry-run-id"
            else
                info "Creating KB collection: $col_name"
                local response
                response=$(_api_call POST "/knowledge/create" \
                    "$(jq -n --arg name "$col_name" --arg desc "$col_desc" '{name: $name, description: $desc}')") || true
                kb_id=$(echo "$response" | jq -r '.id // empty')
                [ -z "$kb_id" ] && warn "Failed to get ID for KB collection: $col_name" && continue
            fi
        else
            info "KB collection '$col_name' exists (id=$kb_id) — skipping create"
        fi

        # Upload documents
        local docs
        docs=$(echo "$col" | jq -r '.documents[]? // empty')
        while IFS= read -r doc; do
            [ -z "$doc" ] && continue
            local doc_path="${kb_dir}/${doc}"
            [ ! -f "$doc_path" ] && warn "Document not found: $doc_path" && continue

            if [ "$DRY_RUN" = "1" ]; then
                log "[DRY RUN] Would upload: $doc"
                continue
            fi

            info "Uploading document: $doc"
            # OpenWebUI KB file upload flow (two-step):
            #   1. POST /api/v1/files/           (multipart) → {id: "file-uuid", ...}
            #   2. POST /api/v1/knowledge/{id}/file/add  (JSON body: {"file_id": "..."})
            # The /file/add endpoint takes KnowledgeFileIdForm (file_id str),
            # NOT a multipart file upload.
            if [ "$kb_id" != "dry-run-id" ]; then
                local upload_resp http_code file_id
                upload_resp=$(curl -s -w "\n%{http_code}" \
                    -X POST "${OWUI_API}/files/" \
                    -H "Authorization: Bearer ${OWUI_API_KEY}" \
                    -F "file=@${doc_path}" 2>/dev/null)
                http_code=$(echo "$upload_resp" | tail -1)
                if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
                    file_id=$(echo "$upload_resp" | sed '$d' | jq -r '.id // empty')
                    if [[ -z "${file_id}" ]]; then
                        warn "File upload succeeded but no file_id returned for $doc"
                        continue
                    fi
                    local add_code
                    add_code=$(curl -s -o /dev/null -w "%{http_code}" \
                        -X POST "${OWUI_API}/knowledge/${kb_id}/file/add" \
                        -H "Authorization: Bearer ${OWUI_API_KEY}" \
                        -H "Content-Type: application/json" \
                        -d "{\"file_id\":\"${file_id}\"}" 2>/dev/null)
                    if [[ "${add_code}" -ge 200 && "${add_code}" -lt 300 ]]; then
                        info "  Added to KB (file_id=${file_id})"
                    else
                        warn "Failed to add $doc to KB (HTTP ${add_code})"
                    fi
                else
                    warn "File upload failed for $doc (HTTP ${http_code})"
                fi
            fi
        done <<< "$docs"

    done <<< "$collections"

    log "Knowledge Base done."
}

# --- Skills ---

apply_skills() {
    log "Applying Skills..."

    local skills_file="${CONFIGS_DIR}/skills/skills.json"
    [ ! -f "$skills_file" ] && warn "No configs/skills/skills.json found" && return

    local skills
    skills=$(jq -c '.skills[]' "$skills_file")

    # Get existing skills
    local existing
    existing=$(_api_call GET "/skills/" "") || err "Failed to list existing skills"

    while IFS= read -r skill; do
        local skill_id skill_name skill_desc skill_file
        skill_id=$(echo "$skill" | jq -r '.id')
        skill_name=$(echo "$skill" | jq -r '.name')
        skill_desc=$(echo "$skill" | jq -r '.description')
        skill_file=$(echo "$skill" | jq -r '.file')

        local skill_path="${CONFIGS_DIR}/skills/${skill_file}"
        if [[ "$skill_file" =~ ^/ ]] || [[ "$skill_file" =~ (^|/)\.\.(/|$) ]]; then
            warn "Skill file path invalid (must not be absolute or contain '..'): $skill_file"
            continue
        fi
        [ ! -f "$skill_path" ] && warn "Skill file not found: $skill_path" && continue

        local skill_content
        skill_content=$(cat "$skill_path")

        local existing_id
        existing_id=$(echo "$existing" | jq -r --arg id "$skill_id" '.[]? | select(.id == $id) | .id // empty' 2>/dev/null || echo "")

        if [ -z "$existing_id" ]; then
            if [ "$DRY_RUN" = "1" ]; then
                log "[DRY RUN] Would create skill: $skill_name"
            else
                info "Creating skill: $skill_name"
                jq -n --arg id "$skill_id" --arg name "$skill_name" --arg desc "$skill_desc" --arg content "$skill_content" --argjson tags "$(echo "$skill" | jq '.tags')" \
                    '{id: $id, name: $name, description: $desc, content: $content, meta: {tags: $tags}}' \
                    > "${TMPDIR}/skill-create-${skill_id}.json"
                if ! _api_call POST "/skills/create" "@${TMPDIR}/skill-create-${skill_id}.json"; then
                    rm -f "${TMPDIR}/skill-create-${skill_id}.json"
                    err "Failed to create skill $skill_name"
                fi
                rm -f "${TMPDIR}/skill-create-${skill_id}.json"
            fi
        else
            info "Skill '$skill_name' exists (id=$existing_id) — updating content"
            if [ "$DRY_RUN" = "1" ]; then
                log "[DRY RUN] Would update skill: $skill_name"
            else
                jq -n --arg id "$skill_id" --arg name "$skill_name" --arg desc "$skill_desc" --arg content "$skill_content" --argjson tags "$(echo "$skill" | jq '.tags')" \
                    '{id: $id, name: $name, description: $desc, content: $content, meta: {tags: $tags}}' \
                    > "${TMPDIR}/skill-update-${skill_id}.json"
                if ! _api_call POST "/skills/id/${skill_id}/update" "@${TMPDIR}/skill-update-${skill_id}.json"; then
                    rm -f "${TMPDIR}/skill-update-${skill_id}.json"
                    err "Failed to update skill $skill_name"
                fi
                rm -f "${TMPDIR}/skill-update-${skill_id}.json"
            fi
        fi
    done <<< "$skills"

    log "Skills done."
}

# --- Main ---

main() {
    log "=== Jawafdehi OpenWebUI Bootstrap ==="
    log "Target: ${OWUI_BASE_URL}"
    [ "$DRY_RUN" = "1" ] && log "DRY RUN — no changes will be made"

    # Verify API connectivity (with retries — up to 3 minutes)
    local health
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        health=$(curl -s -o /dev/null -w "%{http_code}" "${OWUI_BASE_URL}/api/v1/tools/" \
            -H "Authorization: Bearer ${OWUI_API_KEY}" 2>/dev/null || echo "000")
        [ "$health" != "000" ] && [ "$health" != "502" ] && break
        attempt=$((attempt + 1))
        [ $attempt -lt $max_attempts ] && sleep 6
    done

    if [ "$health" -ge 200 ] 2>/dev/null && [ "$health" -lt 500 ]; then
        info "API reachable (HTTP $health)"
    else
        err "API unreachable (HTTP $health). Check OWUI_BASE_URL and OWUI_API_KEY."
    fi

    apply_models
    apply_knowledge
    apply_skills

    log "=== Bootstrap complete ==="
    log "Next: configure system prompts via Admin Settings → Models"
    log "      or use the OWUI Folder API to attach prompts to models."
}

main "$@"
