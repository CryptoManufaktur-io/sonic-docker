#!/usr/bin/env bash
set -Eeuo pipefail

__me="$(basename "$0")"
__compose_service=""
__compose_service_set=0
__container=""
__local_rpc=""
__public_rpc="https://rpc.soniclabs.com"
__block_lag=2
__env_file=""
__no_install=0

usage() {
  echo "usage: ${__me} [--compose-service name] [--container name] [--local-rpc url] [--public-rpc url]"
  echo "             [--block-lag n] [--env-file path] [--no-install]"
  echo
  echo "Defaults:"
  echo "  local RPC:  http://127.0.0.1:\${RPC_PORT:-8545}"
  echo "  public RPC: ${__public_rpc}"
  echo "  block lag:  ${__block_lag}"
}

__load_env_file() {
  local __file="$1"
  [ -f "${__file}" ] || return 0
  while IFS= read -r __line || [ -n "${__line}" ]; do
    [[ -z "${__line}" || "${__line}" =~ ^[[:space:]]*# ]] && continue
    if [[ "${__line}" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local __key="${BASH_REMATCH[1]}"
      local __value="${BASH_REMATCH[2]}"
      __value="${__value#"${__value%%[![:space:]]*}"}"
      __value="${__value%"${__value##*[![:space:]]}"}"
      if [[ "${__value}" =~ ^\".*\"$ ]]; then
        __value="${__value:1:-1}"
      elif [[ "${__value}" =~ ^\'.*\'$ ]]; then
        __value="${__value:1:-1}"
      fi
      export "${__key}=${__value}"
    fi
  done < "${__file}"
}

__need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Missing required command: $1"
    exit 2
  fi
}

__hex_to_dec() {
  local __hex="$1"
  if [ -z "${__hex}" ] || [ "${__hex}" = "null" ]; then
    echo ""
    return
  fi
  printf '%d' "$((16#${__hex#0x}))"
}

__dec_to_hex() {
  printf '0x%x' "$1"
}

__format_duration() {
  local __seconds="$1"
  if [ -z "${__seconds}" ] || [ "${__seconds}" -le 0 ]; then
    echo "n/a"
    return
  fi
  local __h=$((__seconds / 3600))
  local __m=$(((__seconds % 3600) / 60))
  local __s=$((__seconds % 60))
  if [ "${__h}" -gt 0 ]; then
    printf '%dh%dm%ds' "${__h}" "${__m}" "${__s}"
  elif [ "${__m}" -gt 0 ]; then
    printf '%dm%ds' "${__m}" "${__s}"
  else
    printf '%ds' "${__s}"
  fi
}

__compose_cmd=("docker" "compose")

__compose_exec() {
  "${__compose_cmd[@]}" exec -T "${__compose_service}" sh -lc "$1"
}

__compose_exec_root() {
  "${__compose_cmd[@]}" exec -T --user root "${__compose_service}" sh -lc "$1"
}

__container_exec() {
  docker exec -i "${__container}" sh -lc "$1"
}

__container_exec_root() {
  docker exec -i --user root "${__container}" sh -lc "$1"
}

__in_container_exec() {
  if [ -n "${__container}" ]; then
    __container_exec "$1"
  else
    __compose_exec "$1"
  fi
}

__in_container_exec_root() {
  if [ -n "${__container}" ]; then
    __container_exec_root "$1"
  else
    __compose_exec_root "$1"
  fi
}

__ensure_container_tools() {
  if [ "${__no_install}" -eq 1 ]; then
    echo "⚠️  Skipping tool installation checks (--no-install)."
    return
  fi
  echo "⏳ Checking tools inside container"
  if __in_container_exec "command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1"; then
    echo "✅ Tools available in container"
    return
  fi
  echo "⚠️  curl/jq missing in container; attempting install"
  if __in_container_exec_root "command -v apt-get >/dev/null 2>&1"; then
    __in_container_exec_root "apt-get update -y >/dev/null 2>&1 && apt-get install -y curl jq >/dev/null 2>&1"
  elif __in_container_exec_root "command -v apk >/dev/null 2>&1"; then
    __in_container_exec_root "apk add --no-cache curl jq >/dev/null 2>&1"
  else
    echo "❌ Could not install curl/jq (no apt-get or apk)"
    exit 2
  fi
  if __in_container_exec "command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1"; then
    echo "✅ Installed curl/jq in container"
  else
    echo "❌ curl/jq still missing after install attempt"
    exit 2
  fi
}

__rpc_jq() {
  local __rpc="$1"
  local __payload="$2"
  local __filter="$3"
  local __jq_opts="$4"
  if [ "${__use_container}" -eq 1 ]; then
    __in_container_exec "curl -sS --fail -H 'Content-Type: application/json' --data '${__payload}' '${__rpc}' | jq \"${__jq_opts}\" '${__filter}'"
  else
    curl -sS --fail -H 'Content-Type: application/json' --data "${__payload}" "${__rpc}" | jq "${__jq_opts}" "${__filter}"
  fi
}

__payload_head_number='{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}'
__payload_syncing='{"jsonrpc":"2.0","id":1,"method":"eth_syncing","params":[]}'

__payload_block_by_tag() {
  local __tag="$1"
  echo "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBlockByNumber\",\"params\":[\"${__tag}\",false]}"
}

__payload_block_by_height() {
  local __height_dec="$1"
  local __hex
  __hex=$(__dec_to_hex "${__height_dec}")
  __payload_block_by_tag "${__hex}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-service)
      __compose_service="$2"
      __compose_service_set=1
      shift 2
      ;;
    --container)
      __container="$2"
      shift 2
      ;;
    --local-rpc)
      __local_rpc="$2"
      shift 2
      ;;
    --public-rpc)
      __public_rpc="$2"
      shift 2
      ;;
    --block-lag)
      __block_lag="$2"
      shift 2
      ;;
    --env-file)
      __env_file="$2"
      shift 2
      ;;
    --no-install)
      __no_install=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [ -z "${__env_file}" ] && [ -f .env ]; then
  __env_file=.env
fi

if [ -n "${__env_file}" ]; then
  __load_env_file "${__env_file}"
fi

__rpc_port="${RPC_PORT:-8545}"
if [ -z "${__local_rpc}" ]; then
  __local_rpc="http://127.0.0.1:${__rpc_port}"
fi

if [ -z "${__public_rpc}" ]; then
  echo "❌ --public-rpc is required"
  exit 2
fi

__use_container=0
if [ -n "${__container}" ]; then
  __use_container=1
elif [ "${__compose_service_set}" -eq 1 ] && [ -n "${__compose_service}" ]; then
  __use_container=1
fi

if [ "${__use_container}" -eq 1 ]; then
  if [ -n "${__env_file}" ]; then
    __compose_cmd+=("--env-file" "${__env_file}")
  fi
  __ensure_container_tools
else
  __need_cmd curl
  __need_cmd jq
fi

echo "⏳ Sync status"
if ! __syncing_raw=$(__rpc_jq "${__local_rpc}" "${__payload_syncing}" '.result' '-c'); then
  echo "❌ Failed to query eth_syncing from local RPC"
  exit 2
fi

__is_syncing=0
if [ "${__syncing_raw}" = "false" ]; then
  echo "✅ eth_syncing: false"
elif [ "${__syncing_raw}" = "null" ] || [ -z "${__syncing_raw}" ]; then
  echo "⚠️  eth_syncing: unavailable"
else
  __is_syncing=1
  echo "⏳ eth_syncing: true"
  if ! __sync_start_hex=$(__rpc_jq "${__local_rpc}" "${__payload_syncing}" '.result.startingBlock' '-r'); then
    __sync_start_hex=""
  fi
  if ! __sync_current_hex=$(__rpc_jq "${__local_rpc}" "${__payload_syncing}" '.result.currentBlock' '-r'); then
    __sync_current_hex=""
  fi
  if ! __sync_highest_hex=$(__rpc_jq "${__local_rpc}" "${__payload_syncing}" '.result.highestBlock' '-r'); then
    __sync_highest_hex=""
  fi
  __sync_start_dec=$(__hex_to_dec "${__sync_start_hex}")
  __sync_current_dec=$(__hex_to_dec "${__sync_current_hex}")
  __sync_highest_dec=$(__hex_to_dec "${__sync_highest_hex}")
  [ -n "${__sync_start_dec}" ] && echo "  startingBlock: ${__sync_start_dec}"
  [ -n "${__sync_current_dec}" ] && echo "  currentBlock:  ${__sync_current_dec}"
  [ -n "${__sync_highest_dec}" ] && echo "  highestBlock:  ${__sync_highest_dec}"
fi

echo
echo "⏳ Head comparison"
if ! __local_hex=$(__rpc_jq "${__local_rpc}" "${__payload_head_number}" '.result' '-r'); then
  echo "❌ Failed to query local block height"
  exit 2
fi
if ! __public_hex=$(__rpc_jq "${__public_rpc}" "${__payload_head_number}" '.result' '-r'); then
  echo "❌ Failed to query public block height"
  exit 2
fi

__local_height=$(__hex_to_dec "${__local_hex}")
__public_height=$(__hex_to_dec "${__public_hex}")

if [ -z "${__local_height}" ] || [ -z "${__public_height}" ]; then
  echo "❌ Missing local/public block height"
  exit 2
fi

__lag=$((__public_height - __local_height))
__lag_note=""
if [ "${__lag}" -lt 0 ]; then
  __lag_note=" (local ahead)"
  __lag=0
fi

__eta="n/a"
if [ "${__public_height}" -ge 100 ] && [ "${__lag}" -gt 0 ]; then
  __sample_old=$((__public_height - 100))
  if __ts_head_hex=$(__rpc_jq "${__public_rpc}" "$(__payload_block_by_height "${__public_height}")" '.result.timestamp' '-r'); then
    if __ts_old_hex=$(__rpc_jq "${__public_rpc}" "$(__payload_block_by_height "${__sample_old}")" '.result.timestamp' '-r'); then
      __ts_head_dec=$(__hex_to_dec "${__ts_head_hex}")
      __ts_old_dec=$(__hex_to_dec "${__ts_old_hex}")
      if [ -n "${__ts_head_dec}" ] && [ -n "${__ts_old_dec}" ] && [ "${__ts_head_dec}" -gt "${__ts_old_dec}" ]; then
        __delta=$((__ts_head_dec - __ts_old_dec))
        __avg=$((__delta / 100))
        if [ "${__avg}" -gt 0 ]; then
          __eta=$(__format_duration $((__lag * __avg)))
        fi
      fi
    fi
  fi
fi

if ! __local_latest_num_hex=$(__rpc_jq "${__local_rpc}" "$(__payload_block_by_tag latest)" '.result.number' '-r'); then
  __local_latest_num_hex=""
fi
if ! __local_latest_hash=$(__rpc_jq "${__local_rpc}" "$(__payload_block_by_tag latest)" '.result.hash' '-r'); then
  __local_latest_hash=""
fi
if ! __public_latest_num_hex=$(__rpc_jq "${__public_rpc}" "$(__payload_block_by_tag latest)" '.result.number' '-r'); then
  __public_latest_num_hex=""
fi
if ! __public_latest_hash=$(__rpc_jq "${__public_rpc}" "$(__payload_block_by_tag latest)" '.result.hash' '-r'); then
  __public_latest_hash=""
fi

__local_latest_num=$(__hex_to_dec "${__local_latest_num_hex}")
__public_latest_num=$(__hex_to_dec "${__public_latest_num_hex}")

__diverged=0
__compare_height=""
if [ -n "${__local_height}" ] && [ -n "${__public_height}" ]; then
  if [ "${__local_height}" -le "${__public_height}" ]; then
    __compare_height="${__local_height}"
  else
    __compare_height="${__public_height}"
  fi
fi

if [ -n "${__compare_height}" ] && [ "${__compare_height}" -gt 0 ]; then
  if __local_common_hash=$(__rpc_jq "${__local_rpc}" "$(__payload_block_by_height "${__compare_height}")" '.result.hash' '-r'); then
    if __public_common_hash=$(__rpc_jq "${__public_rpc}" "$(__payload_block_by_height "${__compare_height}")" '.result.hash' '-r'); then
      if [ -n "${__local_common_hash}" ] && [ -n "${__public_common_hash}" ] && [ "${__local_common_hash}" != "${__public_common_hash}" ]; then
        __diverged=1
        __divergence_note="Hash mismatch at height ${__compare_height}"
      fi
    fi
  fi
fi

if [ -n "${__divergence_note:-}" ]; then
  echo "❌ ${__divergence_note}"
fi

echo "Local head:  ${__local_height}"
echo "Public head: ${__public_height}"
echo "Lag:         ${__lag} blocks (threshold: ${__block_lag})${__lag_note}"
echo "ETA sample:  ${__eta}"

echo
echo "⏳ Latest block comparison"
if [ -n "${__local_latest_num}" ]; then
  echo "Local latest:  ${__local_latest_num} ${__local_latest_hash}"
else
  echo "Local latest:  unavailable"
fi

if [ -n "${__public_latest_num}" ]; then
  echo "Public latest: ${__public_latest_num} ${__public_latest_hash}"
else
  echo "Public latest: unavailable"
fi

__exit_code=0
if [ "${__diverged}" -eq 1 ]; then
  __exit_code=2
  echo
  echo "❌ Final status: diverged"
elif [ "${__is_syncing}" -eq 1 ] || [ "${__lag}" -gt "${__block_lag}" ]; then
  __exit_code=1
  echo
  echo "⏳ Final status: syncing"
else
  echo
  echo "✅ Final status: in sync"
fi

exit "${__exit_code}"
