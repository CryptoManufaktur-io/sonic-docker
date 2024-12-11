#!/usr/bin/env bash
set -euo pipefail

# Set verbosity
shopt -s nocasematch
case ${LOG_LEVEL} in
  error)
    __verbosity="--verbosity 1"
    ;;
  warn)
    __verbosity="--verbosity 2"
    ;;
  info)
    __verbosity="--verbosity 3"
    ;;
  debug)
    __verbosity="--verbosity 4"
    ;;
  trace)
    __verbosity="--verbosity 5"
    ;;
  *)
    echo "LOG_LEVEL ${LOG_LEVEL} not recognized"
    __verbosity=""
    ;;
esac

__public_ip="--nat=extip:$(curl -s https://ifconfig.me/ip)"

if [ ! -d /var/lib/sonic/chaindata ]; then
  curl \
    --fail \
    --show-error \
    --silent \
    --retry-connrefused \
    --retry-all-errors \
    --retry 5 \
    --retry-delay 5 \
    "${GENESIS_URL}" \
    -o /var/lib/sonic/sonic.g
 GOMEMLIMIT=50GiB sonictool --datadir /var/lib/sonic --cache 12000 genesis /var/lib/sonic/sonic.g
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
GOMEMLIMIT=50GiB exec "$@" ${__public_ip} ${__verbosity}
