#!/usr/bin/env bash
#
# test-inference.sh — Quick smoke test for MaaS inference
#
# Usage:
#   ./scripts/test-inference.sh --api-key <key>
#   ./scripts/test-inference.sh --api-key <key> --model facebook/opt-125m --prompt "What is AI?"
#   ./scripts/test-inference.sh --api-key <key> --max-tokens 100 --endpoint completions
#

set -euo pipefail

MODEL="facebook/opt-125m"
PROMPT="Hello, how are you?"
MAX_TOKENS=50
ENDPOINT="chat/completions"
API_KEY=""
MAAS_NS="llm"

usage() {
    sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
    echo ""
    echo "Options:"
    echo "  --api-key KEY       (required) MaaS API key"
    echo "  --model MODEL       vLLM model ID (default: $MODEL)"
    echo "  --prompt TEXT       Prompt text (default: \"$PROMPT\")"
    echo "  --max-tokens N      Max tokens to generate (default: $MAX_TOKENS)"
    echo "  --endpoint TYPE     completions | chat/completions (default: $ENDPOINT)"
    echo "  --namespace NS      LLMInferenceService namespace (default: $MAAS_NS)"
    echo "  --list-models       List available models and exit"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key)      API_KEY="$2"; shift 2 ;;
        --model)        MODEL="$2"; shift 2 ;;
        --prompt)       PROMPT="$2"; shift 2 ;;
        --max-tokens)   MAX_TOKENS="$2"; shift 2 ;;
        --endpoint)     ENDPOINT="$2"; shift 2 ;;
        --namespace)    MAAS_NS="$2"; shift 2 ;;
        --list-models)  LIST_MODELS=true; shift ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
if [[ -z "$CLUSTER_DOMAIN" ]]; then
    echo "ERROR: Cannot detect cluster domain. Are you logged in?" >&2
    exit 1
fi

LLMIS_NAME=$(oc get llminferenceservice -n "$MAAS_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$LLMIS_NAME" ]]; then
    echo "ERROR: No LLMInferenceService found in namespace '$MAAS_NS'" >&2
    exit 1
fi

BASE_URL="https://maas.${CLUSTER_DOMAIN}/llm/${LLMIS_NAME}"

if [[ "${LIST_MODELS:-}" == "true" ]]; then
    if [[ -z "$API_KEY" ]]; then
        echo "ERROR: --api-key is required" >&2
        exit 1
    fi
    echo "Available models at ${BASE_URL}/v1/models:"
    curl -sk "${BASE_URL}/v1/models" \
        -H "Authorization: Bearer ${API_KEY}" | python3 -m json.tool
    exit 0
fi

if [[ -z "$API_KEY" ]]; then
    echo "ERROR: --api-key is required" >&2
    echo "Usage: $0 --api-key <key>" >&2
    exit 1
fi

if [[ "$ENDPOINT" == "chat/completions" ]]; then
    BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'messages': [{'role': 'user', 'content': sys.argv[2]}],
    'max_tokens': int(sys.argv[3])
}))" "$MODEL" "$PROMPT" "$MAX_TOKENS")
else
    BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'model': sys.argv[1],
    'prompt': sys.argv[2],
    'max_tokens': int(sys.argv[3])
}))" "$MODEL" "$PROMPT" "$MAX_TOKENS")
fi

URL="${BASE_URL}/v1/${ENDPOINT}"

echo "Model:    $MODEL"
echo "Endpoint: $URL"
echo "Prompt:   $PROMPT"
echo ""

RESPONSE=$(curl -sk --max-time 30 -w '\n%{http_code}' \
    "${URL}" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$BODY" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY_OUT=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "$BODY_OUT" | python3 -m json.tool
else
    echo "ERROR: HTTP $HTTP_CODE" >&2
    echo "$BODY_OUT" >&2
    exit 1
fi
