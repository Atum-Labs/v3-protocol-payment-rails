#!/usr/bin/env bash
#
# Dress rehearsal for the Avalanche C-Chain production deployment.
#
# Walks the exact deployment runbook against an Avalanche-forked anvil node, using the real
# production deploy scripts and the real external protocols (Uniswap SwapRouter02, CoW Protocol,
# Circle CCTP V2, Chainlink). Every owner action is sent by an impersonated stand-in for the
# production multi-sig, so the sequence proven here is the sequence signers will execute.
#
#   §6.1-6.6  deploy factories and modules
#   §6.7      CowSwapModuleFactory.create sent BY the owner
#   §7.1      wiring assertions BEFORE any funding
#   §6.8      configureToken per token (configure first, fund second)
#   §7.2      smoke tests at minimal value through every module
#   §7.3      negative checks
#   §8.1      emergency exit — reconfigure to ForwardModule and drain to a safe address
#
# Requires: foundry (anvil/cast/forge), jq, python3, and $AVALANCHE_RPC_URL.
#
# Usage:
#   AVALANCHE_RPC_URL=... ./scripts/bash/avalanche-dress-rehearsal.sh
#   DR_OWNER=0x<multisig> ./scripts/bash/avalanche-dress-rehearsal.sh   # rehearse with the real owner
#   DR_KEEP_ANVIL=1 ./scripts/bash/avalanche-dress-rehearsal.sh         # leave the node running
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
[[ -f .env ]] && { set -a; . ./.env; set +a; }

# Force the mnemonic path in BaseScript so the broadcaster is a funded anvil account. The fork
# reports Avalanche's chain id, so tell Base.s.sol the target is a local node.
unset ETH_FROM
export ALLOW_TEST_MNEMONIC=true

RPC="${DR_RPC:-http://127.0.0.1:8546}"
CHAIN_ID=43114
WORKDIR="${DR_WORKDIR:-$(mktemp -d)}"
ANVIL_LOG="$WORKDIR/anvil.log"

# ───────────────────────────── Avalanche C-Chain addresses ─────────────────────────────
SWAP_ROUTER_02=0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE
UNISWAP_V3_FACTORY=0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD
GPV2_SETTLEMENT=0x9008D19f58AAbD9eD0D60971565AA8510560ab41
GPV2_VAULT_RELAYER=0xC92E8bdf79f0507f65a392b0ab4667716BFE0110
TOKEN_MESSENGER_V2=0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d

USDC=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
WAVAX=0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7

AVAX_USD_FEED=0x0A77230d17318075983913bC2145DB16C7366156
USDC_USD_FEED=0xF096872672F44d6EBA71458D74fe67F9a77a23B9

# ───────────────────────────── deployment parameters ─────────────────────────────
# USDC/USD on Avalanche has a 24h heartbeat with observed gaps up to 86_422s, so a flat 86_400
# window rejects swaps just before each daily update.
MAX_STALENESS=90000
SWAP_DEADLINE=600
SLIPPAGE_BPS=300
POOL_FEE=500
CCTP_DEST_DOMAIN=0           # Ethereum
CCTP_MAX_FEE_BPS=10
CCTP_FINALITY=1000           # fast
VALIDITY_DURATION=3600
APP_DATA=$(cast keccak "credit-cooperative-payment-rails-v1")

TEST_MNEMONIC="test test test test test test test test test test test junk"
DEPLOYER=$(cast wallet address --mnemonic "${MNEMONIC:-$TEST_MNEMONIC}" --mnemonic-index 0)
# Stand-in for the production multi-sig unless DR_OWNER is supplied.
OWNER="${DR_OWNER:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"
KEEPER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC     # permissionless executor
RECIPIENT=0x90F79bf6EB2c4f870365E785982E1f101E93b906
SAFE_EXIT=0x976EA74026E726554dB657fA54763abd0C3a0aa9   # emergency-exit destination
FUNDER=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65

PASS=0; FAIL=0; FAILED_LIST=()
C_HDR=$'\033[1;36m'; C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'

phase() { printf "\n%s╔══ %s%s\n" "$C_HDR" "$*" "$C_OFF"; }
step()  { printf "%s── %s%s\n" "$C_DIM" "$*" "$C_OFF"; }
ok()    { PASS=$((PASS+1)); printf "   %s✓%s %s\n" "$C_OK" "$C_OFF" "$*"; }
bad()   { FAIL=$((FAIL+1)); FAILED_LIST+=("$1"); printf "   %s✗%s %s\n" "$C_BAD" "$C_OFF" "$*"; }

assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1 = $2"; else bad "$1: got '$2', want '$3'"; fi; }
assert_ge() {
  if python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$2" "$3"
  then ok "$1 = $2 (>= $3)"; else bad "$1: got $2, want >= $3"; fi
}

cu() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | awk 'NR==1{print $1}'; }
bal(){ cu "$1" "balanceOf(address)(uint256)" "$2"; }

LAST_RECEIPT=""
send() { local from="$1"; shift
  LAST_RECEIPT=$(cast send --rpc-url "$RPC" --unlocked --from "$from" --json "$@" 2>&1)
  if [[ "$(echo "$LAST_RECEIPT" | jq -r '.status' 2>/dev/null)" != "0x1" ]]; then
    printf "%s   send reverted: %s%s\n" "$C_BAD" "$(echo "$LAST_RECEIPT" | head -c 300)" "$C_OFF"
    return 1
  fi
  return 0
}
send_reverts() { local label="$1" from="$2"; shift 2
  local out; out=$(cast send --rpc-url "$RPC" --unlocked --from "$from" --json "$@" 2>&1)
  if [[ "$(echo "$out" | jq -r '.status' 2>/dev/null)" == "0x1" ]]; then
    bad "$label (tx unexpectedly succeeded)"; else ok "$label"; fi
}
log_has() { # <contract> <event-sig>
  local addr t; addr=$(echo "$1" | tr 'A-Z' 'a-z'); t=$(cast keccak "$2")
  echo "$LAST_RECEIPT" | jq -e --arg a "$addr" --arg t "$t" \
    'any(.logs[]; (.address|ascii_downcase)==$a and .topics[0]==$t)' >/dev/null 2>&1
}

addr_from_log() { # <contract> <event-sig> <topic-index> -> checksummed address in that topic
  local addr t raw
  addr=$(echo "$1" | tr 'A-Z' 'a-z'); t=$(cast keccak "$2")
  raw=$(echo "$LAST_RECEIPT" | jq -r --arg a "$addr" --arg t "$t" --argjson i "$3" \
    'first(.logs[] | select((.address|ascii_downcase)==$a and .topics[0]==$t) | .topics[$i]) // ""')
  [[ -n "$raw" && "$raw" != "null" ]] && cast parse-bytes32-address "$raw" 2>/dev/null
}

deploy_script() { local path="$1"; shift
  local name; name=$(basename "$path")
  forge script "$path" --rpc-url "$RPC" --broadcast "$@" >"$WORKDIR/$name.log" 2>&1
  if ! grep -q "ONCHAIN EXECUTION COMPLETE" "$WORKDIR/$name.log"; then
    printf "%s   %s did not broadcast — see %s%s\n" "$C_BAD" "$name" "$WORKDIR/$name.log" "$C_OFF"
    return 1
  fi
  local addr
  addr=$(jq -r 'first(.transactions[] | select(.transactionType=="CREATE") | .contractAddress)' \
    "broadcast/$name/$CHAIN_ID/run-latest.json" 2>/dev/null)
  [[ -n "$addr" && "$addr" != "null" ]] && cast to-check-sum-address "$addr"
}

cleanup() { [[ -z "${DR_KEEP_ANVIL:-}" && -n "${ANVIL_PID:-}" ]] && kill "$ANVIL_PID" 2>/dev/null; }
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 0 — anvil (Avalanche C-Chain fork)"

[[ -n "${AVALANCHE_RPC_URL:-}" ]] || { echo "AVALANCHE_RPC_URL is required"; exit 1; }
FORK_BLOCK="${DR_FORK_BLOCK:-$(( $(cast block-number --rpc-url "$AVALANCHE_RPC_URL") - 5 ))}"
pkill -f "anvil --fork-url.*avax" 2>/dev/null
anvil --fork-url "$AVALANCHE_RPC_URL" --fork-block-number "$FORK_BLOCK" \
      --auto-impersonate --chain-id $CHAIN_ID --port "${DR_PORT:-8546}" >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 40); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done

for a in "$DEPLOYER" "$OWNER" "$KEEPER" "$RECIPIENT" "$SAFE_EXIT" "$FUNDER"; do
  cast rpc --rpc-url "$RPC" anvil_setBalance "$a" 0x21E19E0C9BAB2400000 >/dev/null 2>&1
done

step "workdir:    $WORKDIR"
step "deployer:   $DEPLOYER"
step "owner:      $OWNER $([[ -z "${DR_OWNER:-}" ]] && echo '(stand-in — set DR_OWNER for the real multi-sig)')"
assert_eq "chain id" "$(cast chain-id --rpc-url "$RPC")" "$CHAIN_ID"
ok "forked at block $(cast block-number --rpc-url "$RPC")"

step "§3 preflight — every external dependency is live on the fork"
for pair in "SwapRouter02:$SWAP_ROUTER_02" "GPv2Settlement:$GPV2_SETTLEMENT" \
            "TokenMessengerV2:$TOKEN_MESSENGER_V2" "USDC:$USDC" "WAVAX:$WAVAX" \
            "AVAX/USD:$AVAX_USD_FEED" "USDC/USD:$USDC_USD_FEED"; do
  n=${pair%%:*}; a=${pair##*:}
  [[ "$(cast codesize "$a" --rpc-url "$RPC")" -gt 0 ]] && ok "$n live" || bad "$n has no code"
done
assert_eq "SwapRouter02.factory()" "$(cu $SWAP_ROUTER_02 'factory()(address)')" "$UNISWAP_V3_FACTORY"
assert_eq "settlement.vaultRelayer()" "$(cu $GPV2_SETTLEMENT 'vaultRelayer()(address)')" "$GPV2_VAULT_RELAYER"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 1 — treasury funding through the real protocols"
# No cheat codes: AVAX is wrapped and swapped on the real Uniswap V3 pool, so every balance the
# modules later consume was minted by contracts they actually integrate with.

step "wrap 300 AVAX -> WAVAX"
send "$FUNDER" "$WAVAX" "deposit()" --value 300ether || bad "WAVAX deposit"
assert_eq "funder WAVAX" "$(bal $WAVAX $FUNDER)" "300000000000000000000"

step "swap 200 WAVAX -> USDC on the 0.05% pool"
send "$FUNDER" "$WAVAX" "approve(address,uint256)" "$SWAP_ROUTER_02" "$(cast max-uint)" || bad "WAVAX approve"
send "$FUNDER" "$SWAP_ROUTER_02" \
  "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" \
  "($WAVAX,$USDC,$POOL_FEE,$FUNDER,200000000000000000000,0,0)" || bad "WAVAX->USDC funding swap"
FUNDER_USDC=$(bal $USDC $FUNDER)
assert_ge "funder USDC from Uniswap" "$FUNDER_USDC" "1000000000"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 2 — §6.1-6.6 deploy from the production scripts"

step "§6.1 PaymentRailsFactory"
RAILS_FACTORY=$(deploy_script scripts/solidity/deploy/DeployPaymentRailsFactory.s.sol --sig "run(address)" "$OWNER") \
  && ok "PaymentRailsFactory $RAILS_FACTORY" || bad "deploy PaymentRailsFactory"

step "§6.2 PaymentRailsFactory.create(owner) — owner-gated; sent by the factory owner"
send "$OWNER" "$RAILS_FACTORY" "create(address)" "$OWNER" || bad "factory.create"
RAILS=$(addr_from_log "$RAILS_FACTORY" "PaymentRailsCreated(address,address)" 1)
[[ -n "$RAILS" ]] || { bad "could not read PaymentRailsCreated"; exit 1; }
ok "PaymentRails $RAILS"
assert_eq "factory registry knows the instance" "$(cu $RAILS_FACTORY 'isDeployedInstance(address)(bool)' $RAILS)" "true"
assert_eq "rails owner is the multi-sig" "$(cu $RAILS 'owner()(address)')" "$OWNER"

step "§6.3 ForwardModule"
FORWARD=$(deploy_script scripts/solidity/deploy/DeployForwardModule.s.sol) \
  && ok "ForwardModule $FORWARD" || bad "deploy ForwardModule"

step "§6.4 CCTPBridgeModule"
BRIDGE=$(deploy_script scripts/solidity/deploy/DeployCCTPBridgeModule.s.sol \
  --sig "run(address,address)" "$TOKEN_MESSENGER_V2" "$USDC") \
  && ok "CCTPBridgeModule $BRIDGE" || bad "deploy CCTPBridgeModule"

step "§6.5 DexSwapModule (SwapRouter02, no sequencer feed — Avalanche is an L1)"
DEXSWAP=$(deploy_script scripts/solidity/deploy/DeployDexSwapModule.s.sol \
  --sig "run(address,address,uint256)" "$SWAP_ROUTER_02" "0x0000000000000000000000000000000000000000" 0) \
  && ok "DexSwapModule $DEXSWAP" || bad "deploy DexSwapModule"

step "§6.6 CowSwapModuleFactory"
COW_FACTORY=$(deploy_script scripts/solidity/deploy/DeployCowSwapModuleFactory.s.sol \
  --sig "run(address,address,uint256)" "$OWNER" "0x0000000000000000000000000000000000000000" 0) \
  && ok "CowSwapModuleFactory $COW_FACTORY" || bad "deploy CowSwapModuleFactory"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 3 — §6.7 CowSwapModule, created BY the owner"

step "the deployer must NOT be able to create it"
send_reverts "create() from the deployer reverts" "$DEPLOYER" "$COW_FACTORY" \
  "create(address,address)" "$OWNER" "$RAILS"

step "the owner creates it"
send "$OWNER" "$COW_FACTORY" "create(address,address)" "$OWNER" "$RAILS" || bad "owner create()"
COWMOD=$(addr_from_log "$COW_FACTORY" "CowSwapModuleCreated(address,address,address)" 1)
[[ -n "$COWMOD" ]] || { bad "could not read CowSwapModuleCreated"; exit 1; }
ok "CowSwapModule $COWMOD"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 4 — §7.1 wiring assertions (BEFORE any funding)"

assert_eq "rails.owner()"              "$(cu $RAILS 'owner()(address)')"               "$OWNER"
assert_eq "dexSwap.router()"           "$(cu $DEXSWAP 'router()(address)')"            "$SWAP_ROUTER_02"
assert_eq "dexSwap.sequencerUptimeFeed()" "$(cu $DEXSWAP 'sequencerUptimeFeed()(address)')" "0x0000000000000000000000000000000000000000"
assert_eq "cowModule.paymentRails()"   "$(cu $COWMOD 'paymentRails()(address)')"       "$RAILS"
assert_eq "cowModule.owner()"          "$(cu $COWMOD 'owner()(address)')"              "$OWNER"
assert_eq "cowModule.vaultRelayer()"   "$(cu $COWMOD 'vaultRelayer()(address)')"       "$GPV2_VAULT_RELAYER"
assert_eq "bridge.usdc()"              "$(cu $BRIDGE 'usdc()(address)')"               "$USDC"
assert_eq "bridge.tokenMessenger()"    "$(cu $BRIDGE 'tokenMessenger()(address)')"     "$TOKEN_MESSENGER_V2"
assert_eq "forward.moduleType()"       "$(cast call --rpc-url $RPC $FORWARD 'moduleType()(string)')" '"FORWARD"'

step "renounceOwnership is permanently disabled on both owned contracts"
send_reverts "rails.renounceOwnership() reverts"     "$OWNER" "$RAILS"  "renounceOwnership()"
send_reverts "cowModule.renounceOwnership() reverts" "$OWNER" "$COWMOD" "renounceOwnership()"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 5 — §6.8 configureToken (owner only), then fund"
# executeAction is permissionless, so configuration must land BEFORE any balance arrives.

FWD_PARAMS=$(cast abi-encode "f((address,uint256))" "($RECIPIENT,0)")
DEX_PARAMS=$(cast abi-encode "f((address,uint24,uint16,address,address,uint256,uint256,uint256))" \
  "($USDC,$POOL_FEE,$SLIPPAGE_BPS,$AVAX_USD_FEED,$USDC_USD_FEED,$MAX_STALENESS,$SWAP_DEADLINE,0)")
MINT_RECIPIENT=$(python3 -c "print('0x' + '0'*24 + '$RECIPIENT'[2:].lower())")
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
# CCTPBridgeParams contains a dynamic member (hookData), so `abi.encode(struct)` in Solidity emits
# the members in place with NO leading offset word. cast's tuple form "f((...))" DOES add that
# word, producing 256 bytes the module cannot decode — and it fails softly as ActionFailed.
# The flat-argument form matches Solidity byte for byte at 224 bytes.
BRIDGE_PARAMS=$(cast abi-encode "f(uint32,bytes32,bytes32,uint16,uint32,bytes)" \
  "$CCTP_DEST_DOMAIN" "$MINT_RECIPIENT" "$ZERO32" "$CCTP_MAX_FEE_BPS" "$CCTP_FINALITY" "0x")

step "a non-owner cannot configure"
send_reverts "configureToken from the keeper reverts" "$KEEPER" "$RAILS" \
  "configureToken(address,string,address,uint256,bytes,bool)" \
  "$WAVAX" "SWAP" "$DEXSWAP" 0 "$DEX_PARAMS" true

step "owner configures WAVAX -> USDC via DexSwapModule"
send "$OWNER" "$RAILS" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$WAVAX" "SWAP" "$DEXSWAP" 0 "$DEX_PARAMS" true || bad "configure WAVAX"
ok "WAVAX configured"

step "owner configures USDC -> CCTP bridge (domain $CCTP_DEST_DOMAIN, ${CCTP_MAX_FEE_BPS}bps, fast)"
send "$OWNER" "$RAILS" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$USDC" "BRIDGE" "$BRIDGE" 0 "$BRIDGE_PARAMS" true || bad "configure USDC"
ok "USDC configured"

step "§7.1 read the config back before funding"
# DexSwapParams is fully static, so maxStaleness is word index 5 of moduleParams.
CFG_PARAMS=$(cast call --rpc-url "$RPC" "$RAILS" "getTokenConfig(address)((string,address,bool,uint256,bytes))" "$WAVAX" 2>/dev/null \
  | tr -d '()' | awk -F', ' '{print $NF}')
CFG_STALENESS=$(python3 -c "
h='''$CFG_PARAMS'''.strip().replace('0x','')
print(int(h[5*64:6*64], 16) if len(h) >= 6*64 else 'unreadable')
")
assert_eq "configured maxStaleness (word 6 of moduleParams)" "$CFG_STALENESS" "$MAX_STALENESS"

step "now fund the rails"
send "$FUNDER" "$WAVAX" "transfer(address,uint256)" "$RAILS" "50000000000000000000" || bad "fund WAVAX"
send "$FUNDER" "$USDC"  "transfer(address,uint256)" "$RAILS" "500000000" || bad "fund USDC"
assert_eq "rails WAVAX" "$(bal $WAVAX $RAILS)" "50000000000000000000"
assert_eq "rails USDC"  "$(bal $USDC $RAILS)"  "500000000"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 6 — §7.2 smoke tests at minimal value"

step "DexSwap: 1 WAVAX -> USDC through the real SwapRouter02, triggered by the keeper"
USDC_BEFORE=$(bal $USDC $RAILS)
PREVIEW=$(cast call --rpc-url "$RPC" "$RAILS" "previewExecution(address)(uint256,address)" "$WAVAX" 2>/dev/null | head -1)
send "$KEEPER" "$RAILS" "executeAction(address,uint256)" "$WAVAX" "1000000000000000000" || bad "executeAction(WAVAX)"
log_has "$RAILS" "ActionExecuted(address,string,uint256,uint256,address,address)" \
  && ok "ActionExecuted emitted" || bad "no ActionExecuted for the swap"
USDC_OUT=$(python3 -c "print($(bal $USDC $RAILS) - $USDC_BEFORE)")
assert_ge "USDC received from the swap" "$USDC_OUT" "1000000"
assert_eq "no WAVAX stranded in the module" "$(bal $WAVAX $DEXSWAP)" "0"
assert_eq "no USDC stranded in the module"  "$(bal $USDC $DEXSWAP)"  "0"
assert_eq "router allowance revoked" "$(cu $WAVAX 'allowance(address,address)(uint256)' $DEXSWAP $SWAP_ROUTER_02)" "0"

step "CCTP: bridge 100 USDC through Circle's TokenMessengerV2"
USDC_BEFORE=$(bal $USDC $RAILS)
send "$KEEPER" "$RAILS" "executeAction(address,uint256)" "$USDC" "100000000" || bad "executeAction(USDC) bridge"
if log_has "$RAILS" "ActionExecuted(address,string,uint256,uint256,address,address)"; then
  ok "ActionExecuted emitted (bridge)"
else
  bad "no ActionExecuted for the bridge"
  # PaymentRails swallows module failure, so ask the module directly why.
  step "  diagnosing: validate() straight from the rails' perspective"
  cast call --rpc-url "$RPC" --from "$RAILS" "$BRIDGE" \
    "validate(address,uint256,bytes)(bool,string)" "$USDC" "100000000" "$BRIDGE_PARAMS" 2>&1 | head -3
  step "  moduleParams length: $(( (${#BRIDGE_PARAMS} - 2) / 2 )) bytes (module requires >= 224)"
fi
log_has "$TOKEN_MESSENGER_V2" "DepositForBurn(address,uint256,uint256,address,bytes32,uint32,bytes32,bytes32,uint256,uint32,bytes)" \
  && ok "Circle's TokenMessengerV2 emitted DepositForBurn" || step "  (DepositForBurn signature varies by version — balance check below is authoritative)"
assert_eq "rails USDC debited" "$(python3 -c "print($USDC_BEFORE - $(bal $USDC $RAILS))")" "100000000"
assert_eq "no USDC stranded in the bridge module" "$(bal $USDC $BRIDGE)" "0"

step "CowSwap: place an order against the real GPv2Settlement"
COW_PARAMS=$(cast abi-encode "f((address,uint16,address,address,uint256,uint32,bytes32))" \
  "($USDC,$SLIPPAGE_BPS,$AVAX_USD_FEED,$USDC_USD_FEED,$MAX_STALENESS,$VALIDITY_DURATION,$APP_DATA)")
send "$OWNER" "$RAILS" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$WAVAX" "SWAP" "$COWMOD" 0 "$COW_PARAMS" true || bad "reconfigure WAVAX to CowSwap"
send "$KEEPER" "$RAILS" "executeAction(address,uint256)" "$WAVAX" "1000000000000000000" || bad "executeAction(WAVAX) cow"
log_has "$COWMOD" "OrderCreated(bytes32,address,address,address,uint256,uint256,uint32,bytes32)" \
  && ok "OrderCreated emitted by the module" || bad "no OrderCreated event"
assert_eq "vault relayer allowance granted" \
  "$(python3 -c "print('yes' if $(cu $WAVAX 'allowance(address,address)(uint256)' $COWMOD $GPV2_VAULT_RELAYER) > 0 else 'no')")" "yes"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 7 — §7.3 negative checks"

send_reverts "executeAction on an unconfigured token reverts" "$KEEPER" "$RAILS" \
  "executeAction(address,uint256)" "0x152b9d0FdC40C096757F570A51E494bd4b943E50" "1000000"
send_reverts "executeAction with zero amount reverts" "$KEEPER" "$RAILS" \
  "executeAction(address,uint256)" "$USDC" "0"
send_reverts "cancelOrder from a non-owner reverts" "$KEEPER" "$COWMOD" \
  "cancelOrder(bytes32)" "0x0000000000000000000000000000000000000000000000000000000000000001"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 8 — §8.1 emergency exit rehearsal"
# There is no pause and no rescue function. The only way funds leave PaymentRails is through a
# configured module, so the exit is: owner reconfigures to ForwardModule -> safe address, then
# anyone calls executeAction. Signers should have done this once before they need it.

step "step 1 (multi-sig): disable the token to stop routing"
send "$OWNER" "$RAILS" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$USDC" "BRIDGE" "$BRIDGE" 0 "$BRIDGE_PARAMS" false || bad "disable USDC"
send_reverts "executeAction blocked while disabled" "$KEEPER" "$RAILS" \
  "executeAction(address,uint256)" "$USDC" "1000000"

step "step 2 (multi-sig): point the token at ForwardModule -> safe address"
EXIT_PARAMS=$(cast abi-encode "f((address,uint256))" "($SAFE_EXIT,0)")
send "$OWNER" "$RAILS" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$USDC" "FORWARD" "$FORWARD" 0 "$EXIT_PARAMS" true || bad "configure emergency exit"

step "step 3 (anyone): drain"
STRANDED=$(bal $USDC $RAILS)
SAFE_BEFORE=$(bal $USDC $SAFE_EXIT)
send "$KEEPER" "$RAILS" "executeAction(address,uint256)" "$USDC" "$STRANDED" || bad "emergency drain"
assert_eq "safe address received the full balance" \
  "$(python3 -c "print($(bal $USDC $SAFE_EXIT) - $SAFE_BEFORE)")" "$STRANDED"
assert_eq "rails USDC fully drained" "$(bal $USDC $RAILS)" "0"

# ══════════════════════════════════════════════════════════════════════════════
phase "SUMMARY"
cat <<EOF

  deployed this run (fork only — addresses will differ on mainnet)
    PaymentRailsFactory   $RAILS_FACTORY
    PaymentRails          $RAILS
    ForwardModule         $FORWARD
    DexSwapModule         $DEXSWAP
    CCTPBridgeModule      $BRIDGE
    CowSwapModuleFactory  $COW_FACTORY
    CowSwapModule         $COWMOD

    owner used            $OWNER $([[ -z "${DR_OWNER:-}" ]] && echo '(STAND-IN)')
EOF
if [[ $FAIL -eq 0 ]]; then
  printf "\n  %s%d passed%s, 0 failed   (logs: %s)\n\n" "$C_OK" "$PASS" "$C_OFF" "$WORKDIR"
else
  printf "\n  %s%d passed%s, %s%d failed%s   (logs: %s)\n\n  failures:\n" \
    "$C_OK" "$PASS" "$C_OFF" "$C_BAD" "$FAIL" "$C_OFF" "$WORKDIR"
  for f in "${FAILED_LIST[@]}"; do echo "    - $f"; done
  echo
  exit 1
fi
