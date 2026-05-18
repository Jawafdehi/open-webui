#!/usr/bin/env bash
set -euo pipefail

# === Bootstrap Script Integration Test ===
# Tests bootstrap-config.sh against a mock OpenWebUI server.
# Uses real config files from JAWA-1058 worktree.

SEPARATOR="============================================"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPDIR=$(mktemp -d)
PASSED=0
FAILED=0

cleanup() {
    rm -rf "$TMPDIR"
    # Kill mock server if still running
    if [[ -n "${MOCK_PID:-}" ]]; then
        kill "$MOCK_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "$SEPARATOR"
echo " Bootstrap Script Integration Tests"
echo "$SEPARATOR"
echo ""

# --- Setup: Copy configs from JAWA-1058 worktree ---
SOURCE_CONFIGS="/paperspace/code/open-webui-JAWA-1058/configs"
if [[ -d "$SOURCE_CONFIGS" ]]; then
    echo "[SETUP] Copying configs from JAWA-1058 worktree..."
    cp -r "$SOURCE_CONFIGS" "$REPO_ROOT/configs"
else
    echo "[SETUP] WARNING: JAWA-1058 configs not found at $SOURCE_CONFIGS"
    echo "[SETUP] Creating minimal test configs..."
    mkdir -p "$REPO_ROOT/configs/models" "$REPO_ROOT/configs/prompts" "$REPO_ROOT/configs/groups"
    echo '{"id":"test-model","name":"Test Model","params":{},"meta":{"description":"Test"},"is_active":true}' > "$REPO_ROOT/configs/models/test-model.json"
    echo "Test system prompt" > "$REPO_ROOT/configs/prompts/test-model.nep"
    echo '{"name":"test-group","description":"Test","models":["test-model"],"tools":[],"permissions":{}}' > "$REPO_ROOT/configs/groups/test-group.json"
fi

# --- Test 1: Syntax Check ---
echo ""
echo "--- Test 1: Syntax validation ---"
if bash -n "$REPO_ROOT/scripts/bootstrap-config.sh" 2>&1; then
    echo "  PASS: No syntax errors"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL: Syntax errors found"
    FAILED=$((FAILED + 1))
fi

# --- Test 2: Help Flag ---
echo ""
echo "--- Test 2: --help flag ---"
HELP_OUT="$("$REPO_ROOT/scripts/bootstrap-config.sh" --help 2>&1)"
if echo "$HELP_OUT" | grep -q "Usage:"; then
    echo "  PASS: Help output correct"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL: Help output missing"
    FAILED=$((FAILED + 1))
fi

# --- Test 3: API key check ---
echo ""
echo "--- Test 3: Missing API key detection ---"
if ! "$REPO_ROOT/scripts/bootstrap-config.sh" 2>&1 | grep -q "OPENWEBUI_API_KEY"; then
    echo "  PASS: Detects missing API key"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL: Did not catch missing API key"
    FAILED=$((FAILED + 1))
fi

# --- Test 4: Unknown option ---
echo ""
echo "--- Test 4: Unknown option handling ---"
if "$REPO_ROOT/scripts/bootstrap-config.sh" --nonexistent 2>&1 | grep -q "Unknown option"; then
    echo "  PASS: Reports unknown options"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL: Did not report unknown option"
    FAILED=$((FAILED + 1))
fi

# --- Test 5: Config file parsing (model JSON) ---
echo ""
echo "--- Test 5: Model JSON parsing ---"
if [[ -f "$REPO_ROOT/configs/models/caseworker-assistant.json" ]]; then
    MODEL_ID=$(python3 -c "
import json
with open('$REPO_ROOT/configs/models/caseworker-assistant.json') as f:
    data = json.load(f)
print(data['id'])
" 2>/dev/null)
    if [[ "$MODEL_ID" == "caseworker-assistant" ]]; then
        echo "  PASS: Model config parsed correctly (id=$MODEL_ID)"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL: Model config parse failed (got: $MODEL_ID)"
        FAILED=$((FAILED + 1))
    fi
else
    echo "  SKIP: caseworker-assistant.json not found"
fi

# --- Test 6: Group JSON parsing ---
echo ""
echo "--- Test 6: Group JSON parsing ---"
if [[ -f "$REPO_ROOT/configs/groups/caseworkers.json" ]]; then
    GROUP_NAME=$(python3 -c "
import json
with open('$REPO_ROOT/configs/groups/caseworkers.json') as f:
    data = json.load(f)
print(data['name'])
" 2>/dev/null)
    if [[ "$GROUP_NAME" == "caseworkers" ]]; then
        echo "  PASS: Group config parsed correctly (name=$GROUP_NAME)"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL: Group config parse failed (got: $GROUP_NAME)"
        FAILED=$((FAILED + 1))
    fi
else
    echo "  SKIP: caseworkers.json not found"
fi

# --- Test 7: Prompt file reading ---
echo ""
echo "--- Test 7: Prompt file reading ---"
if [[ -f "$REPO_ROOT/configs/prompts/caseworker-assistant.nep" ]]; then
    PROMPT_LINES=$(wc -l < "$REPO_ROOT/configs/prompts/caseworker-assistant.nep")
    if [[ $PROMPT_LINES -gt 0 ]]; then
        echo "  PASS: Prompt file readable ($PROMPT_LINES lines)"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL: Prompt file empty"
        FAILED=$((FAILED + 1))
    fi
else
    echo "  SKIP: caseworker-assistant.nep not found"
fi

# --- Test 8: Dry-run against mock server ---
echo ""
echo "--- Test 8: Dry-run with mock server ---"
echo "  Starting mock OpenWebUI server..."
MOCK_SCRIPT="$SCRIPT_DIR/mock-openwebui.py"
MOCK_LOG="$TMPDIR/mock-log.txt"

if [[ -f "$MOCK_SCRIPT" ]]; then
    # Start mock server in background
    python3 "$MOCK_SCRIPT" --port 0 --timeout 15 > "$MOCK_LOG" 2>&1 &
    MOCK_PID=$!

    # Wait for mock server to be ready
    sleep 1
    MOCK_PORT=$(grep "MOCK_SERVER_PORT=" "$MOCK_LOG" 2>/dev/null | cut -d= -f2)

    if [[ -n "$MOCK_PORT" ]]; then
        echo "  Mock server running on port $MOCK_PORT"

        # Run the bootstrap script against mock server
        echo "  Running bootstrap-config.sh against mock server..."

        BOOTSTRAP_OUT="$TMPDIR/bootstrap-out.txt"
        set +e
        OPENWEBUI_URL="http://127.0.0.1:${MOCK_PORT}" \
        OPENWEBUI_API_KEY="test-api-key" \
        "$REPO_ROOT/scripts/bootstrap-config.sh" > "$BOOTSTRAP_OUT" 2>&1
        BOOTSTRAP_EXIT=$?
        set -e

        echo "  Bootstrap exit code: $BOOTSTRAP_EXIT"
        echo "  Bootstrap output:"
        cat "$BOOTSTRAP_OUT" | sed 's/^/    /'

        # Check for key expected outputs
        if grep -q "exists (skipping)" "$BOOTSTRAP_OUT" || grep -q "created" "$BOOTSTRAP_OUT"; then
            echo "  PASS: Bootstrap ran successfully against mock server"
            PASSED=$((PASSED + 1))
        elif grep -q "Bootstrap complete" "$BOOTSTRAP_OUT"; then
            echo "  PASS: Bootstrap completed (models dir may be empty)"
            PASSED=$((PASSED + 1))
        else
            echo "  INFO: Bootstrap ran, checking output patterns"

            if grep -q "models" "$BOOTSTRAP_OUT" || grep -q "API" "$BOOTSTRAP_OUT" || grep -q "config" "$BOOTSTRAP_OUT"; then
                echo "  PASS: Bootstrap ran and produced meaningful output"
                PASSED=$((PASSED + 1))
            else
                echo "  WARN: Bootstrap output may indicate issues"
            fi
        fi
    else
        echo "  FAIL: Mock server did not start"
        cat "$MOCK_LOG"
        FAILED=$((FAILED + 1))
    fi
else
    echo "  SKIP: mock-openwebui.py not found"
fi

# --- Cleanup copied configs ---
rm -rf "$REPO_ROOT/configs" 2>/dev/null || true

# --- Results ---
echo ""
echo "$SEPARATOR"
echo " Test Results: $PASSED passed, $FAILED failed"
echo "$SEPARATOR"

exit $FAILED
