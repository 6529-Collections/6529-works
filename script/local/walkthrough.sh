#!/usr/bin/env bash
# The local walkthrough: deploys the plain core (script/DeployCore.s.sol) on a fresh anvil node,
# accepts the network, reads the deployment back (script/VerifyCore.s.sol), then walks one
# curated work, its editions and one federated work through their whole life and swaps one
# module (script/local/README.md).
#
# Usage: script/local/walkthrough.sh            (from the repository root, in bash or Git Bash)
#
# Environment (all optional):
#   WALKTHROUGH_PORT  the anvil port (default 8545); the script starts and stops its own node
#   PYTHON            the Python 3.12+ interpreter (default: python, else python3)
#   KEEP_ANVIL=1      leave the node running at the end, to explore it with cast
#
# Every account is one of anvil's default test accounts (public keys that exist only on a local
# node); nothing here reads or needs a real key. Exits non-zero at the first failed step.
set -euo pipefail

cd "$(dirname "$0")/../.."
PORT="${WALKTHROUGH_PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"
PYTHON="${PYTHON:-$(command -v python >/dev/null 2>&1 && echo python || echo python3)}"
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266   # anvil account 0
KEEPER=0xa0Ee7A142d267C1f36714E4a8F75612F20a79720     # anvil account 9
FEE_RECIPIENT=0xdF3e18d64BC6A983f673Ab319CCaE4f1a57C7097 # anvil account 14 (no transactions)
GENESIS=config/local/genesis.core.anvil.json

step() { printf '\n=== %s\n' "$*"; }
warp() {
  cast rpc evm_increaseTime "$1" --rpc-url "$RPC" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
}

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "Something already answers on $RPC. Stop it, or set WALKTHROUGH_PORT to a free port." >&2
  exit 1
fi

step "Start anvil on port $PORT (20 accounts)"
ANVIL_LOG="$(mktemp)"
anvil --port "$PORT" --accounts 20 >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
cleanup() {
  if [[ "${KEEP_ANVIL:-0}" != 1 ]]; then kill "$ANVIL_PID" 2>/dev/null || true; fi
  rm -f "$ANVIL_LOG"
}
trap cleanup EXIT
for _ in $(seq 1 50); do
  cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 0.2
done
echo "chain ID $(cast chain-id --rpc-url "$RPC")"

step "Write the local genesis file (anvil accounts as the network and holders)"
"$PYTHON" script/local/make_genesis.py

step "Deploy, configure and accept the network (script/DeployCore.s.sol)"
DEPLOY_OUT="$(GENESIS_CONFIG="$GENESIS" NETWORK_FEE_RECIPIENT="$FEE_RECIPIENT" ACCEPT_NETWORK=1 \
  forge script script/DeployCore.s.sol --rpc-url "$RPC" --broadcast --slow \
  --unlocked --sender "$DEPLOYER" 2>&1)" || { echo "$DEPLOY_OUT"; exit 1; }
echo "$DEPLOY_OUT" | grep -E '^\s+(manager|Stream|Editions|Directory|WorkFacts|recorded) '
RECORD="$(echo "$DEPLOY_OUT" | sed -n 's/^ *recorded *\(deployments\/31337\/core-[0-9]*\.json\).*/\1/p')"
[[ -n "$RECORD" ]] || { echo "no deployment record in the deploy output" >&2; exit 1; }
STATE="${RECORD%.json}.walkthrough.json"

step "Read the deployment back (script/VerifyCore.s.sol)"
VERIFY_OUT="$(DEPLOYMENT="$RECORD" GENESIS_CONFIG="$GENESIS" NETWORK_FEE_RECIPIENT="$FEE_RECIPIENT" \
  forge script script/VerifyCore.s.sol --rpc-url "$RPC" 2>&1)" || { echo "$VERIFY_OUT"; exit 1; }
echo "$VERIFY_OUT" | sed -n '/^== Logs ==/,/^$/p' | sed '1d;/^$/d'

# --skip-simulation: each transaction's gas limit comes from the node's eth_estimateGas when it is
# sent (--slow), not from forge's replay. Forge's own estimate (gas used x 1.3) is too low for
# calls that check they can forward a fixed amount of gas, such as `settle` (DELIVERY_GAS,
# 300,000), which then revert on chain. The script itself still runs first, with every call.
walk() {
  local out
  out="$(WALKTHROUGH_RECORD="$RECORD" WALKTHROUGH_STATE="$STATE" \
    forge script script/local/Walkthrough.s.sol \
    --sig "$1()" --rpc-url "$RPC" --broadcast --slow --skip-simulation \
    --unlocked --sender "$KEEPER" 2>&1)" \
    || { echo "$out"; exit 1; }
  # A transaction that reverted on chain fails the step even if forge exits zero.
  if echo "$out" | grep -qiE 'Transaction Failure|status 0|reverted'; then
    echo "$out"; exit 1
  fi
  # Print the script's own log lines, not forge's transaction summary.
  echo "$out" | sed -n '/^== Logs ==/,/^$/p' | sed '1d;/^$/d'
}

step "Phase 1: curate, store, accept, start with a bid, edition bids, a competing bid, a federated work"
walk curate
step "Move the clock past the 1/1's end (24 hours)"
warp 86401
step "Phase 2: settle, refund, finalize, tokenURI, propose a renderer"
walk settle
step "Move the clock past the edition close (the 1/1's end plus 15 minutes)"
warp 3600
step "Phase 3: settle the edition auction, claim copies and refunds, release the proceeds"
walk editions
DELAY="$(cast call "$(sed -n 's/.*"Stream": *"\(0x[0-9a-fA-F]*\)".*/\1/p' "$RECORD")" \
  "moduleDelay()(uint48)" --rpc-url "$RPC" | awk '{print $1}')"
step "Move the clock past Stream's module waiting period ($DELAY seconds)"
warp "$DELAY"
step "Phase 4: activate the proposed renderer"
walk swap

step "Done"
echo "Deployment record: $RECORD (git-ignored; delete it when you no longer need it)"
if [[ "${KEEP_ANVIL:-0}" == 1 ]]; then
  echo "anvil is still running on $RPC (pid $ANVIL_PID)"
fi
