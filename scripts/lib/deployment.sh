#!/bin/bash
# Shared app-mutation ownership. The token survives exec (install-dev -> switch)
# but another process cannot release this shell's lock by inheriting its env.
TB_DEPLOY_STATE_TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deployment-state.py"

tb_deployment_lock() {
  TB_DEPLOY_LOCK_TOKEN=$(python3 "$TB_DEPLOY_STATE_TOOL" lock --pid "$$" \
    --lock-token "${TB_DEPLOY_LOCK_TOKEN:-}") || return $?
  export TB_DEPLOY_LOCK_TOKEN
}

tb_deployment_unlock() {
  if [ -n "${TB_DEPLOY_LOCK_TOKEN:-}" ]; then
    python3 "$TB_DEPLOY_STATE_TOOL" unlock --pid "$$" --lock-token "$TB_DEPLOY_LOCK_TOKEN"
    unset TB_DEPLOY_LOCK_TOKEN
  fi
}

tb_deployment_authorize() {
  local operation="$1" sha="$2" channel="$3" unmerged="${4:-0}"
  python3 "$TB_DEPLOY_STATE_TOOL" authorize --pid "$$" \
    --lock-token "$TB_DEPLOY_LOCK_TOKEN" --operation "$operation" \
    --sha "$sha" --channel "$channel" \
    --owner "${TB_DEPLOY_OWNER:-manual}" --preview-token "${TB_PREVIEW_TOKEN:-}" \
    --unmerged "$unmerged"
}
