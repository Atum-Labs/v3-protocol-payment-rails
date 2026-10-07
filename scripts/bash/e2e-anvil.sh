#!/usr/bin/env bash
#
# End-to-end lifecycle run for every PaymentRails module against a mainnet-forked anvil node.
#
# Deployment follows the architecture's split: PaymentRails and CowSwapModule are per-instance, so
# they come from factories with registries; ForwardModule, DexSwapModule and CCTPBridgeModule are
# stateless and shared, so each is deployed once directly from its own script.
#
# What it proves, per module: the production deploy script deploys it (or its factory), the wiring is
# correct, PaymentRails routes real tokens through it, and the external protocol (Uniswap V3, CoW
# Protocol, Circle CCTP) accepts the resulting calls on real mainnet state.
#
# Requires: foundry (anvil/cast/forge), jq, python3, and an archive-capable $ETHEREUM_RPC_URL.
#
# Usage:
#   ETHEREUM_RPC_URL=... ./scripts/bash/e2e-anvil.sh            # forks at latest - 20
#   E2E_FORK_BLOCK=25982374 ./scripts/bash/e2e-anvil.sh         # pinned block
#   E2E_KEEP_ANVIL=1 ./scripts/bash/e2e-anvil.sh                # leave the node running
#   E2E_RPC=http://127.0.0.1:8545 E2E_NO_START=1 ./e2e-anvil.sh # reuse a running node
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
[[ -f .env ]] && { set -a; . ./.env; set +a; }

RPC="${E2E_RPC:-http://127.0.0.1:8545}"
WORKDIR="${E2E_WORKDIR:-$(mktemp -d)}"
ANVIL_LOG="$WORKDIR/anvil.log"

# ───────────────────────────── mainnet addresses ─────────────────────────────
# Uniswap SwapRouter02 on Ethereum mainnet (the module requires SwapRouter02, not SwapRouter)
UNISWAP_V3_ROUTER=0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
GPV2_SETTLEMENT=0x9008D19f58AAbD9eD0D60971565AA8510560ab41
GPV2_AUTHENTICATOR=0x2c4c28DDBdAc9C5E7055b4C863b72eA0149D8aFE
TOKEN_MESSENGER_V2=0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d

USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
DAI=0x6B175474E89094C44Da98b954EedeAC495271d0F

ETH_USD_FEED=0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
USDC_USD_FEED=0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6
DAI_USD_FEED=0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9

MAX_STALENESS=86400        # 24h — matches the Chainlink stablecoin heartbeat
SWAP_DEADLINE=600
SLIPPAGE_BPS=100           # 1%
CCTP_BASE_DOMAIN=6

# ─────────────────────────────── actors ───────────────────────────────
# Anvil's deterministic accounts, except DEPLOYER: BaseScript derives the broadcaster from
# $ETH_FROM or $MNEMONIC, so resolve it the same way and fund whatever comes out. That keeps the
# run honest about which key the repo's deploy scripts would actually use.
TEST_MNEMONIC="test test test test test test test test test test test junk"
DEPLOYER="${ETH_FROM:-$(cast wallet address --mnemonic "${MNEMONIC:-$TEST_MNEMONIC}" --mnemonic-index 0)}"
RAILS_OWNER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8   # stands in for the production multi-sig
KEEPER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC        # permissionless executor
RECIPIENT=0x90F79bf6EB2c4f870365E785982E1f101E93b906
ATTACKER=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
SOLVER=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
SOLVER_PK=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
FUNDER=0x976EA74026E726554dB657fA54763abd0C3a0aa9

# ─────────────────────────────── reporting ───────────────────────────────
PASS=0; FAIL=0; FAILED_LIST=()
C_HDR=$'\033[1;36m'; C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'

phase() { printf "\n%s╔══ %s%s\n" "$C_HDR" "$*" "$C_OFF"; }
step()  { printf "%s── %s%s\n" "$C_DIM" "$*" "$C_OFF"; }
ok()    { PASS=$((PASS+1)); printf "   %s✓%s %s\n" "$C_OK" "$C_OFF" "$*"; }
bad()   { FAIL=$((FAIL+1)); FAILED_LIST+=("$1"); printf "   %s✗%s %s\n" "$C_BAD" "$C_OFF" "$*"; }

assert_eq() { # <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then ok "$1 = $2"; else bad "$1: got '$2', want '$3'"; fi
}
assert_ge() { # <label> <actual> <min>
  if python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$2" "$3"; then
    ok "$1 = $2 (>= $3)"
  else bad "$1: got $2, want >= $3"; fi
}
assert_true() { # <label> <cond-exit-code-cmd...>
  if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi
}

# ─────────────────────────────── chain helpers ───────────────────────────────
c()  { cast call --rpc-url "$RPC" "$@" 2>&1; }                     # raw, keeps revert text
cu() { cast call --rpc-url "$RPC" "$@" 2>/dev/null | awk 'NR==1{print $1}'; }  # first decoded value
# Structs decode onto a single line, so read their fields positionally out of the JSON form.
tuple_field() { # <target> <sig> <arg> <index>
  cast call --rpc-url "$RPC" --json "$1" "$2" "$3" 2>/dev/null | jq -r ".[0][$4]"
}
bal(){ cu "$1" "balanceOf(address)(uint256)" "$2"; }

LAST_RECEIPT=""
send() { # <from> <to> <sig> [args...] -> sets LAST_RECEIPT, fails loudly on revert
  local from="$1"; shift
  LAST_RECEIPT=$(cast send --rpc-url "$RPC" --unlocked --from "$from" --json "$@" 2>&1)
  if [[ "$(echo "$LAST_RECEIPT" | jq -r '.status' 2>/dev/null)" != "0x1" ]]; then
    printf "%s   send reverted: %s%s\n" "$C_BAD" "$(echo "$LAST_RECEIPT" | head -c 400)" "$C_OFF"
    return 1
  fi
  return 0
}
send_reverts() { # <label> <from> <to> <sig> [args...] — asserts the tx does NOT succeed
  local label="$1" from="$2"; shift 2
  local out status
  out=$(cast send --rpc-url "$RPC" --unlocked --from "$from" --json "$@" 2>&1)
  status=$(echo "$out" | jq -r '.status' 2>/dev/null)
  if [[ "$status" == "0x1" ]]; then bad "$label (tx unexpectedly succeeded)"; else ok "$label"; fi
}

topic0() { cast keccak "$1"; }
log_data() { # <contract> <event-sig> -> non-indexed data of the first match in LAST_RECEIPT
  local addr t
  addr=$(echo "$1" | tr 'A-Z' 'a-z'); t=$(topic0 "$2")
  echo "$LAST_RECEIPT" | jq -r --arg a "$addr" --arg t "$t" \
    'first(.logs[] | select((.address|ascii_downcase)==$a and .topics[0]==$t) | .data) // ""'
}
log_topic() { # <contract> <event-sig> <topic-index> -> indexed topic
  local addr t
  addr=$(echo "$1" | tr 'A-Z' 'a-z'); t=$(topic0 "$2")
  echo "$LAST_RECEIPT" | jq -r --arg a "$addr" --arg t "$t" --argjson i "$3" \
    'first(.logs[] | select((.address|ascii_downcase)==$a and .topics[0]==$t) | .topics[$i]) // ""'
}
decode() { cast abi-decode "x()($1)" "$2" 2>/dev/null; }

addr_from_log() { # <label> <contract> <event-sig> -> echoes the address in topic 1, or fails
  local raw addr
  raw=$(log_topic "$2" "$3" 1)
  addr=$(cast parse-bytes32-address "$raw" 2>/dev/null)
  if [[ -z "$addr" || "$addr" == "0x0000000000000000000000000000000000000000" ]]; then
    bad "$1 — creation event missing"; echo "0x0000000000000000000000000000000000000000"; return
  fi
  echo "$addr"
}

EV_EXECUTED="ActionExecuted(address,string,uint256,uint256,address,address)"
EV_FAILED="ActionFailed(address,string,uint256,string,address)"
EV_ORDER_CREATED="OrderCreated(bytes32,address,address,address,uint256,uint256,uint32,bytes32)"
EV_BRIDGE="BridgeInitiated(address,uint256,uint32,bytes32,uint256,uint32,bytes)"

deploy_script() { # <script-path> [--sig ... args] -> echoes the created contract address
  local path="$1"; shift
  local name; name=$(basename "$path")
  forge script "$path" --rpc-url "$RPC" --broadcast "$@" >"$WORKDIR/$name.log" 2>&1
  if ! grep -q "ONCHAIN EXECUTION COMPLETE" "$WORKDIR/$name.log"; then
    printf "%s   %s did not broadcast — see %s%s\n" "$C_BAD" "$name" "$WORKDIR/$name.log" "$C_OFF"
    return 1
  fi
  # Broadcast artifacts store addresses lowercased; checksum them so they compare equal to what
  # contract getters return.
  local addr
  addr=$(jq -r 'first(.transactions[] | select(.transactionType=="CREATE") | .contractAddress)' \
    "broadcast/$name/1/run-latest.json" 2>/dev/null)
  [[ -n "$addr" && "$addr" != "null" ]] && cast to-check-sum-address "$addr"
}

cleanup() {
  if [[ -z "${E2E_KEEP_ANVIL:-}" && -n "${ANVIL_PID:-}" ]]; then kill "$ANVIL_PID" 2>/dev/null; fi
}
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 0 — anvil (Ethereum mainnet fork)"

if [[ -z "${E2E_NO_START:-}" ]]; then
  [[ -n "${ETHEREUM_RPC_URL:-}" ]] || { echo "ETHEREUM_RPC_URL is required"; exit 1; }
  FORK_BLOCK="${E2E_FORK_BLOCK:-$(( $(cast block-number --rpc-url "$ETHEREUM_RPC_URL") - 20 ))}"
  pkill -f "anvil --fork-url" 2>/dev/null
  # --auto-impersonate lets the run act as the PaymentRails owner, a CoW solver and the CoW
  # authenticator's manager without holding any of their keys.
  anvil --fork-url "$ETHEREUM_RPC_URL" --fork-block-number "$FORK_BLOCK" \
        --auto-impersonate --chain-id 1 --port "${E2E_PORT:-8545}" >"$ANVIL_LOG" 2>&1 &
  ANVIL_PID=$!
  for _ in $(seq 1 40); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
fi

# Every actor needs gas: the anvil accounts start funded, but the deploy broadcaster comes from the
# repo's own mnemonic and the CoW authenticator's manager is a mainnet address we impersonate.
for a in "$DEPLOYER" "$RAILS_OWNER" "$KEEPER" "$RECIPIENT" "$ATTACKER" "$SOLVER" "$FUNDER"; do
  cast rpc --rpc-url "$RPC" anvil_setBalance "$a" 0x21E19E0C9BAB2400000 >/dev/null 2>&1
done

step "workdir: $WORKDIR"
step "deploy broadcaster: $DEPLOYER"
assert_eq "chain id" "$(cast chain-id --rpc-url "$RPC")" "1"
ok "forked at block $(cast block-number --rpc-url "$RPC")"
for pair in "UniswapV3Router:$UNISWAP_V3_ROUTER" "GPv2Settlement:$GPV2_SETTLEMENT" \
            "TokenMessengerV2:$TOKEN_MESSENGER_V2" "USDC:$USDC" "WETH:$WETH" "DAI:$DAI"; do
  n=${pair%%:*}; a=${pair##*:}
  [[ "$(cast codesize "$a" --rpc-url "$RPC")" -gt 0 ]] && ok "$n is live on the fork" || bad "$n has no code"
done

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 1 — treasury funding via real protocols"
# No cheat codes: ETH is wrapped through WETH and swapped on the real Uniswap V3 pools, so every
# token balance the modules later consume was minted by the same contracts they integrate with.

step "wrap 60 ETH -> WETH"
send "$FUNDER" "$WETH" "deposit()" --value 60ether || bad "WETH deposit"
assert_eq "funder WETH" "$(bal $WETH $FUNDER)" "60000000000000000000"

step "swap 20 WETH -> USDC (0.05% pool) and 10k USDC -> DAI (0.01% pool)"
send "$FUNDER" "$WETH" "approve(address,uint256)" "$UNISWAP_V3_ROUTER" "$(cast max-uint)" || bad "WETH approve"
# SwapRouter02 params carry no `deadline` field — see src/interfaces/ISwapRouter.sol
send "$FUNDER" "$UNISWAP_V3_ROUTER" \
  "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" \
  "($WETH,$USDC,500,$FUNDER,20000000000000000000,0,0)" || bad "WETH->USDC swap"
send "$FUNDER" "$USDC" "approve(address,uint256)" "$UNISWAP_V3_ROUTER" "$(cast max-uint)" || bad "USDC approve"
send "$FUNDER" "$UNISWAP_V3_ROUTER" \
  "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))" \
  "($USDC,$DAI,100,$FUNDER,10000000000,0,0)" || bad "USDC->DAI swap"

FUNDER_USDC=$(bal $USDC $FUNDER); FUNDER_DAI=$(bal $DAI $FUNDER)
assert_ge "funder USDC from Uniswap" "$FUNDER_USDC" "30000000000"
assert_ge "funder DAI from Uniswap" "$FUNDER_DAI" "9900000000000000000000"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 2 — deployment (production deploy scripts)"

step "factories for the per-instance contracts"
RAILS_FACTORY=$(deploy_script scripts/solidity/deploy/DeployPaymentRailsFactory.s.sol --sig "run(address)" "$RAILS_OWNER")
COW_FACTORY=$(deploy_script scripts/solidity/deploy/DeployCowSwapModuleFactory.s.sol \
  --sig "run(address,uint256)" "0x0000000000000000000000000000000000000000" 0)

step "one shared instance each for the stateless modules"
FWD_MODULE=$(deploy_script scripts/solidity/deploy/DeployForwardModule.s.sol)
DEX_MODULE=$(deploy_script scripts/solidity/deploy/DeployDexSwapModule.s.sol \
  --sig "run(address,address,uint256)" "$UNISWAP_V3_ROUTER" "0x0000000000000000000000000000000000000000" 0)
CCTP_MODULE=$(deploy_script scripts/solidity/deploy/DeployCCTPBridgeModule.s.sol \
  --sig "run(address,address)" "$TOKEN_MESSENGER_V2" "$USDC")

for pair in "PaymentRailsFactory:$RAILS_FACTORY" "CowSwapModuleFactory:$COW_FACTORY" \
            "ForwardModule:$FWD_MODULE" "DexSwapModule:$DEX_MODULE" "CCTPBridgeModule:$CCTP_MODULE"; do
  n=${pair%%:*}; a=${pair##*:}
  if [[ -n "$a" && "$(cast codesize "$a" --rpc-url "$RPC" 2>/dev/null)" -gt 0 ]]; then
    ok "$n deployed at $a"
  else
    bad "$n failed to deploy"
  fi
done

step "deployed contracts carry the chain config they were given"
assert_eq "CowSwapModuleFactory.cowSettlement" "$(cu $COW_FACTORY 'cowSettlement()(address)')" "$GPV2_SETTLEMENT"
assert_eq "DexSwapModule.router" "$(cu $DEX_MODULE 'router()(address)')" "$UNISWAP_V3_ROUTER"
assert_eq "CCTPBridgeModule.tokenMessenger" "$(cu $CCTP_MODULE 'tokenMessenger()(address)')" "$TOKEN_MESSENGER_V2"
assert_eq "CCTPBridgeModule.usdc" "$(cu $CCTP_MODULE 'usdc()(address)')" "$USDC"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 3 — PaymentRailsFactory lifecycle"

step "create() — rails A, owned by the multi-sig stand-in"
# Both creation paths are owner-gated, so they come from the factory owner, not the deployer.
send "$RAILS_OWNER" "$RAILS_FACTORY" "create(address)" "$RAILS_OWNER" || bad "create()"
RAILS_A=$(addr_from_log "rails A" "$RAILS_FACTORY" "PaymentRailsCreated(address,address)")
ok "rails A = $RAILS_A"
assert_eq "rails A owner" "$(cu $RAILS_A 'owner()(address)')" "$RAILS_OWNER"
assert_eq "registry: isDeployedInstance(A)" "$(cu $RAILS_FACTORY 'isDeployedInstance(address)(bool)' $RAILS_A)" "true"

step "createDeterministic() — rails B, address predicted before deployment"
SALT_B=$(cast keccak "payment-rails-e2e-b")
SALT_C=$(cast keccak "payment-rails-e2e-c")
PREDICTED_B=$(cu $RAILS_FACTORY "predictDeterministicAddress(address,bytes32)(address)" "$RAILS_OWNER" "$SALT_B")
send "$RAILS_OWNER" "$RAILS_FACTORY" "createDeterministic(address,bytes32)" "$RAILS_OWNER" "$SALT_B" || bad "createDeterministic()"
RAILS_B=$(addr_from_log "rails B" "$RAILS_FACTORY" "PaymentRailsCreated(address,address)")
assert_eq "CREATE2 address matches prediction" "$RAILS_B" "$PREDICTED_B"
assert_eq "rails B owner" "$(cu $RAILS_B 'owner()(address)')" "$RAILS_OWNER"

assert_eq "registry instance count" "$(cu $RAILS_FACTORY 'getInstanceCount()(uint256)')" "2"
assert_eq "registry: unknown address not an instance" \
  "$(cu $RAILS_FACTORY 'isDeployedInstance(address)(bool)' $ATTACKER)" "false"

step "guard rails"
send_reverts "create(address(0)) reverts (zero owner would brick the instance)" \
  "$RAILS_OWNER" "$RAILS_FACTORY" "create(address)" "0x0000000000000000000000000000000000000000"
send_reverts "re-using a salt reverts (CREATE2 collision)" \
  "$RAILS_OWNER" "$RAILS_FACTORY" "createDeterministic(address,bytes32)" "$RAILS_OWNER" "$SALT_B"
send_reverts "attacker cannot register an instance in the rails factory" \
  "$ATTACKER" "$RAILS_FACTORY" "create(address)" "$ATTACKER"
send_reverts "attacker cannot squat a predicted CREATE2 address" \
  "$ATTACKER" "$RAILS_FACTORY" "createDeterministic(address,bytes32)" "$ATTACKER" "$SALT_C"
send_reverts "renounceOwnership() is disabled on PaymentRails" \
  "$RAILS_OWNER" "$RAILS_A" "renounceOwnership()"

step "fund the rails from the funder's real balances"
send "$FUNDER" "$WETH" "transfer(address,uint256)" "$RAILS_A" "10000000000000000000" || bad "fund A WETH"
send "$FUNDER" "$DAI"  "transfer(address,uint256)" "$RAILS_A" "5000000000000000000000" || bad "fund A DAI"
send "$FUNDER" "$USDC" "transfer(address,uint256)" "$RAILS_A" "4000000000" || bad "fund A USDC"
send "$FUNDER" "$USDC" "transfer(address,uint256)" "$RAILS_B" "2000000000" || bad "fund B USDC"
send "$FUNDER" "$WETH" "transfer(address,uint256)" "$RAILS_B" "1000000000000000000" || bad "fund B WETH"
assert_eq "rails A WETH" "$(cu $RAILS_A 'getTokenBalance(address)(uint256)' $WETH)" "10000000000000000000"
assert_eq "rails B USDC" "$(cu $RAILS_B 'getTokenBalance(address)(uint256)' $USDC)" "2000000000"

# ─────────────────── oracle helpers (independent of the module's math) ───────────────────
feed_answer() {
  cast call --rpc-url "$RPC" "$1" "latestRoundData()(uint80,int256,uint256,uint256,uint80)" 2>/dev/null \
    | sed -n 2p | awk '{print $1}'
}
expected_out() { # <amount> <sellPrice> <sellFeedDec> <sellTokenDec> <buyPrice> <buyFeedDec> <buyTokenDec>
  python3 -c '
import sys
amount, sp, sfd, std, bp, bfd, btd = map(int, sys.argv[1:8])
se, be = std + sfd, btd + bfd
print(amount * sp * 10 ** (be - se) // bp if be >= se else amount * sp // (bp * 10 ** (se - be)))' "$@"
}
apply_slippage() { python3 -c 'import sys; print(int(sys.argv[1]) * (10000 - int(sys.argv[2])) // 10000)' "$@"; }

call_reverts_with() { # <label> <expected-substring> <target> <sig> [args...]
  local label="$1" want="$2"; shift 2
  local out; out=$(cast call --rpc-url "$RPC" "$@" 2>&1)
  if grep -qF -- "$want" <<<"$out"; then ok "$label"; else bad "$label — got: $(echo "$out" | tr '\n' ' ' | head -c 180)"; fi
}
assert_action_failed() { # <label> <rails> <expected-reason>
  local data reason
  data=$(log_data "$2" "$EV_FAILED")
  if [[ -z "$data" ]]; then bad "$1 — no ActionFailed event emitted"; return; fi
  reason=$(decode "string,uint256,string" "$data" | sed -n 3p | tr -d '"')
  assert_eq "$1" "$reason" "$3"
}
LAST_AMOUNT_OUT=""
assert_action_executed() { # <label> <rails> -> sets LAST_AMOUNT_OUT
  local data
  LAST_AMOUNT_OUT=""
  data=$(log_data "$2" "$EV_EXECUTED")
  if [[ -z "$data" ]]; then bad "$1 — no ActionExecuted event emitted"; return; fi
  ok "$1"
  LAST_AMOUNT_OUT=$(decode "string,uint256,uint256,address" "$data" | sed -n 3p | awk '{print $1}')
}


ETH_PRICE=$(feed_answer $ETH_USD_FEED); USDC_PRICE=$(feed_answer $USDC_USD_FEED); DAI_PRICE=$(feed_answer $DAI_USD_FEED)

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 4 — ForwardModule: full lifecycle"

ok "ForwardModule = $FWD_MODULE (stateless, shared across every PaymentRails)"
assert_eq "moduleType()" "$(cu $FWD_MODULE 'moduleType()(string)' | tr -d '"')" "FORWARD"

step "owner configures DAI -> FORWARD"
FWD_PARAMS=$(cast abi-encode "f(address,uint256)" "$RECIPIENT" 0)
send_reverts "non-owner cannot configureToken" "$ATTACKER" "$RAILS_A" \
  "configureToken(address,string,address,uint256,bytes,bool)" "$DAI" "FORWARD" "$FWD_MODULE" 0 "$FWD_PARAMS" true
send "$RAILS_OWNER" "$RAILS_A" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$DAI" "FORWARD" "$FWD_MODULE" 0 "$FWD_PARAMS" true || bad "configureToken(DAI)"
assert_eq "config.actionType" \
  "$(tuple_field $RAILS_A 'getTokenConfig(address)((string,address,bool,uint256,bytes))' $DAI 0)" "FORWARD"
assert_eq "config.actionModule" \
  "$(tuple_field $RAILS_A 'getTokenConfig(address)((string,address,bool,uint256,bytes))' $DAI 1)" "$FWD_MODULE"

step "previewExecution before executing"
PREVIEW=$(cu $RAILS_A "previewExecution(address)(uint256,address)" "$DAI")
assert_eq "preview output (1:1 forward of full balance)" "$PREVIEW" "5000000000000000000000"

step "permissionless executeAction — 1000 DAI to the recipient"
REC_BEFORE=$(bal $DAI $RECIPIENT)
send "$KEEPER" "$RAILS_A" "executeAction(address,uint256)" "$DAI" "1000000000000000000000" || bad "executeAction(DAI)"
assert_action_executed "ActionExecuted emitted" "$RAILS_A"; FWD_OUT=$LAST_AMOUNT_OUT
assert_eq "amountOut in event" "$FWD_OUT" "1000000000000000000000"
assert_eq "recipient received DAI" "$(python3 -c "print($(bal $DAI $RECIPIENT)-$REC_BEFORE)")" "1000000000000000000000"
assert_eq "rails A DAI left" "$(bal $DAI $RAILS_A)" "4000000000000000000000"
assert_eq "no DAI stranded in the module" "$(bal $DAI $FWD_MODULE)" "0"
assert_eq "allowance revoked after execution" "$(cu $DAI 'allowance(address,address)(uint256)' $RAILS_A $FWD_MODULE)" "0"

step "soft failure: amount below the module's minAmount"
FWD_PARAMS_MIN=$(cast abi-encode "f(address,uint256)" "$RECIPIENT" "2000000000000000000000")
send "$RAILS_OWNER" "$RAILS_A" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$DAI" "FORWARD" "$FWD_MODULE" 0 "$FWD_PARAMS_MIN" true || bad "reconfigure DAI"
send "$KEEPER" "$RAILS_A" "executeAction(address,uint256)" "$DAI" "1000000000000000000000" || bad "executeAction(DAI) tx"
assert_action_failed "ActionFailed reason" "$RAILS_A" "Amount below minimum"
assert_eq "rails A DAI unchanged after soft failure" "$(bal $DAI $RAILS_A)" "4000000000000000000000"

step "disabled token cannot be executed"
send "$RAILS_OWNER" "$RAILS_A" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$DAI" "FORWARD" "$FWD_MODULE" 0 "$FWD_PARAMS" false || bad "disable DAI"
send_reverts "executeAction reverts while the token is disabled" "$KEEPER" "$RAILS_A" \
  "executeAction(address,uint256)" "$DAI" "1000000000000000000000"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 5 — DexSwapModule: full lifecycle (real Uniswap V3)"

ok "DexSwapModule = $DEX_MODULE (stateless, shared across every PaymentRails)"
assert_eq "no sequencer feed on L1" "$(cu $DEX_MODULE 'sequencerUptimeFeed()(address)')" "0x0000000000000000000000000000000000000000"
assert_eq "moduleType()" "$(cu $DEX_MODULE 'moduleType()(string)' | tr -d '"')" "SWAP"

step "owner configures WETH -> USDC with a 2 WETH per-swap ceiling"
MAX_AMOUNT=2000000000000000000
DEX_PARAMS=$(cast abi-encode "f((address,uint24,uint16,address,address,uint256,uint256,uint256))" \
  "($USDC,500,$SLIPPAGE_BPS,$ETH_USD_FEED,$USDC_USD_FEED,$MAX_STALENESS,$SWAP_DEADLINE,$MAX_AMOUNT)")
send "$RAILS_OWNER" "$RAILS_A" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$WETH" "SWAP" "$DEX_MODULE" 0 "$DEX_PARAMS" true || bad "configureToken(WETH)"

step "maxAmount is enforced on the preview path too (balance 10 WETH > 2 WETH ceiling)"
call_reverts_with "previewExecution reverts: Exceeds max swap amount" "Exceeds max swap amount" \
  "$RAILS_A" "previewExecution(address)(uint256,address)" "$WETH"

step "swap 1 WETH -> USDC through the real router"
SWAP_IN=1000000000000000000
ORACLE_EXPECTED=$(expected_out "$SWAP_IN" "$ETH_PRICE" 8 18 "$USDC_PRICE" 8 6)
ORACLE_FLOOR=$(apply_slippage "$ORACLE_EXPECTED" "$SLIPPAGE_BPS")
MODULE_ESTIMATE=$(cu $DEX_MODULE "estimateOutput(address,uint256,bytes)(uint256,address)" "$WETH" "$SWAP_IN" "$DEX_PARAMS")
assert_eq "module oracle math matches an independent computation" "$MODULE_ESTIMATE" "$ORACLE_EXPECTED"
step "oracle expects $ORACLE_EXPECTED USDC-wei, floor after ${SLIPPAGE_BPS}bps = $ORACLE_FLOOR"

USDC_BEFORE=$(bal $USDC $RAILS_A); WETH_BEFORE=$(bal $WETH $RAILS_A)
send "$KEEPER" "$RAILS_A" "executeAction(address,uint256)" "$WETH" "$SWAP_IN" || bad "executeAction(WETH)"
assert_action_executed "ActionExecuted emitted" "$RAILS_A"; DEX_OUT=$LAST_AMOUNT_OUT
USDC_DELTA=$(python3 -c "print($(bal $USDC $RAILS_A)-$USDC_BEFORE)")
assert_eq "USDC delta equals the reported amountOut" "$USDC_DELTA" "$DEX_OUT"
assert_ge "swap output respects the Chainlink floor" "$USDC_DELTA" "$ORACLE_FLOOR"
assert_eq "WETH spent" "$(python3 -c "print($WETH_BEFORE-$(bal $WETH $RAILS_A))")" "$SWAP_IN"
assert_eq "no WETH stranded in the module" "$(bal $WETH $DEX_MODULE)" "0"
assert_eq "no USDC stranded in the module" "$(bal $USDC $DEX_MODULE)" "0"
assert_eq "allowance revoked after execution" "$(cu $WETH 'allowance(address,address)(uint256)' $RAILS_A $DEX_MODULE)" "0"

step "a swap above the per-swap ceiling is rejected without moving funds"
USDC_BEFORE=$(bal $USDC $RAILS_A); WETH_BEFORE=$(bal $WETH $RAILS_A)
send "$KEEPER" "$RAILS_A" "executeAction(address,uint256)" "$WETH" "3000000000000000000" || bad "executeAction tx"
assert_action_failed "ActionFailed reason" "$RAILS_A" "Exceeds max swap amount"
assert_eq "WETH untouched" "$(bal $WETH $RAILS_A)" "$WETH_BEFORE"
assert_eq "USDC untouched" "$(bal $USDC $RAILS_A)" "$USDC_BEFORE"

step "owner lifts the ceiling (maxAmount = 0) and a 2 WETH swap clears"
DEX_PARAMS_NOCAP=$(cast abi-encode "f((address,uint24,uint16,address,address,uint256,uint256,uint256))" \
  "($USDC,500,$SLIPPAGE_BPS,$ETH_USD_FEED,$USDC_USD_FEED,$MAX_STALENESS,$SWAP_DEADLINE,0)")
send "$RAILS_OWNER" "$RAILS_A" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$WETH" "SWAP" "$DEX_MODULE" 0 "$DEX_PARAMS_NOCAP" true || bad "reconfigure WETH"
PREVIEW=$(cu $RAILS_A "previewExecution(address)(uint256,address)" "$WETH")
assert_eq "previewExecution now returns an estimate for the full 9 WETH balance" \
  "$PREVIEW" "$(expected_out 9000000000000000000 "$ETH_PRICE" 8 18 "$USDC_PRICE" 8 6)"
USDC_BEFORE=$(bal $USDC $RAILS_A)
send "$KEEPER" "$RAILS_A" "executeAction(address,uint256)" "$WETH" "2000000000000000000" || bad "executeAction(WETH) 2e18"
assert_action_executed "ActionExecuted emitted" "$RAILS_A"
assert_ge "2 WETH swap respects the floor" "$(python3 -c "print($(bal $USDC $RAILS_A)-$USDC_BEFORE)")" \
  "$(apply_slippage "$(expected_out 2000000000000000000 "$ETH_PRICE" 8 18 "$USDC_PRICE" 8 6)" "$SLIPPAGE_BPS")"

step "a stale-oracle configuration blocks the swap (maxStaleness = 1s)"
DEX_PARAMS_STALE=$(cast abi-encode "f((address,uint24,uint16,address,address,uint256,uint256,uint256))" \
  "($USDC,500,$SLIPPAGE_BPS,$ETH_USD_FEED,$USDC_USD_FEED,1,$SWAP_DEADLINE,0)")
send "$RAILS_OWNER" "$RAILS_A" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$WETH" "SWAP" "$DEX_MODULE" 0 "$DEX_PARAMS_STALE" true || bad "reconfigure WETH stale"
WETH_BEFORE=$(bal $WETH $RAILS_A)
send "$KEEPER" "$RAILS_A" "executeAction(address,uint256)" "$WETH" "$SWAP_IN" || bad "executeAction tx"
assert_action_failed "ActionFailed reason" "$RAILS_A" "Oracle price unavailable"
assert_eq "WETH untouched" "$(bal $WETH $RAILS_A)" "$WETH_BEFORE"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 6 — CowSwapModule: factory + full order lifecycle (real CoW Protocol)"

step "only the PaymentRails owner may register a module against their instance"
send_reverts "attacker cannot plant a module in rails A's registry entry" "$ATTACKER" "$COW_FACTORY" \
  "create(address,address)" "$ATTACKER" "$RAILS_A"
send_reverts "create() rejects a non-contract PaymentRails" "$RAILS_OWNER" "$COW_FACTORY" \
  "create(address,address)" "$RAILS_OWNER" "$RECIPIENT"

send "$RAILS_OWNER" "$COW_FACTORY" "create(address,address)" "$RAILS_OWNER" "$RAILS_A" || bad "CowSwapModuleFactory.create()"
COW_MODULE=$(addr_from_log "CowSwapModule" "$COW_FACTORY" "CowSwapModuleCreated(address,address,address)")
ok "CowSwapModule = $COW_MODULE"
assert_eq "module is bound to rails A" "$(cu $COW_MODULE 'paymentRails()(address)')" "$RAILS_A"
assert_eq "module owner" "$(cu $COW_MODULE 'owner()(address)')" "$RAILS_OWNER"
assert_eq "settlement wired from the factory" "$(cu $COW_MODULE 'cowSettlement()(address)')" "$GPV2_SETTLEMENT"
assert_eq "vaultRelayer read from the live settlement" "$(cu $COW_MODULE 'vaultRelayer()(address)')" \
  "$(cu $GPV2_SETTLEMENT 'vaultRelayer()(address)')"
assert_eq "domain separator read from the live settlement" "$(cu $COW_MODULE 'cowDomainSeparator()(bytes32)')" \
  "$(cu $GPV2_SETTLEMENT 'domainSeparator()(bytes32)')"

SALT_C=$(cast keccak "cowswap-e2e")
PREDICTED_C=$(cu $COW_FACTORY "predictDeterministicAddress(address,address,bytes32)(address)" "$RAILS_OWNER" "$RAILS_A" "$SALT_C")
send "$RAILS_OWNER" "$COW_FACTORY" "createDeterministic(address,address,bytes32)" "$RAILS_OWNER" "$RAILS_A" "$SALT_C" \
  || bad "createDeterministic()"
COW_MODULE_2=$(addr_from_log "CowSwapModule#2" "$COW_FACTORY" "CowSwapModuleCreated(address,address,address)")
assert_eq "CREATE2 address matches prediction" "$COW_MODULE_2" "$PREDICTED_C"
assert_eq "registry indexes both modules under rails A" \
  "$(cast call --rpc-url "$RPC" $COW_FACTORY 'getModulesForPaymentRails(address)(address[])' $RAILS_A | tr -d '[]' | tr ',' '\n' | grep -c 0x)" "2"

step "owner configures USDC -> DAI as a CoW sell order"
APP_DATA_1=$(cast keccak "e2e-cow-order-1")
COW_PARAMS=$(cast abi-encode "f(address,uint16,address,address,uint256,uint32,bytes32)" \
  "$DAI" "$SLIPPAGE_BPS" "$USDC_USD_FEED" "$DAI_USD_FEED" "$MAX_STALENESS" 3600 "$APP_DATA_1")
send "$RAILS_OWNER" "$RAILS_A" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$USDC" "COWSWAP" "$COW_MODULE" 0 "$COW_PARAMS" true || bad "configureToken(USDC)"

step "a caller other than the bound PaymentRails cannot place an order"
DIRECT=$(cast call --rpc-url "$RPC" --from "$ATTACKER" $COW_MODULE \
  "execute(address,uint256,bytes)((bool,uint256,address,bytes,string))" "$USDC" 1000000 "$COW_PARAMS" 2>&1)
if grep -qF "Caller is not authorized PaymentRails" <<<"$DIRECT"; then
  ok "direct execute() rejected: Caller is not authorized PaymentRails"
else bad "direct execute() not rejected — got: $(echo "$DIRECT" | tr '\n' ' ' | head -c 160)"; fi

step "place the order"
COW_SELL=2000000000
COW_EXPECTED=$(expected_out "$COW_SELL" "$USDC_PRICE" 8 6 "$DAI_PRICE" 8 18)
COW_FLOOR=$(apply_slippage "$COW_EXPECTED" "$SLIPPAGE_BPS")
assert_eq "module oracle math matches an independent computation" \
  "$(cu $COW_MODULE 'estimateOutput(address,uint256,bytes)(uint256,address)' $USDC $COW_SELL $COW_PARAMS)" "$COW_EXPECTED"

RAILS_USDC_BEFORE=$(bal $USDC $RAILS_A); RAILS_DAI_BEFORE=$(bal $DAI $RAILS_A)
send "$KEEPER" "$RAILS_A" "executeAction(address,uint256)" "$USDC" "$COW_SELL" || bad "executeAction(USDC)"
ORDER_ID=$(log_topic "$COW_MODULE" "$EV_ORDER_CREATED" 1)
ORDER_DATA=$(log_data "$COW_MODULE" "$EV_ORDER_CREATED")
if [[ -z "$ORDER_ID" ]]; then bad "OrderCreated not emitted"; else ok "OrderCreated orderId = $ORDER_ID"; fi
ORDER_BUY=$(decode "address,address,uint256,uint256,uint32,bytes32" "$ORDER_DATA" | sed -n 4p | awk '{print $1}')
ORDER_VALID_TO=$(decode "address,address,uint256,uint256,uint32,bytes32" "$ORDER_DATA" | sed -n 5p | awk '{print $1}')
assert_eq "buyAmount equals the oracle floor" "$ORDER_BUY" "$COW_FLOOR"
assert_eq "sellToken escrowed in the module" "$(bal $USDC $COW_MODULE)" "$COW_SELL"
assert_eq "rails A USDC debited" "$(python3 -c "print($RAILS_USDC_BEFORE-$(bal $USDC $RAILS_A))")" "$COW_SELL"
assert_eq "module granted the vault relayer an infinite allowance" \
  "$(cu $USDC 'allowance(address,address)(uint256)' $COW_MODULE $(cu $COW_MODULE 'vaultRelayer()(address)'))" "$(cast max-uint)"
assert_eq "order metadata: bound PaymentRails" \
  "$(tuple_field $COW_MODULE 'getOrder(bytes32)((address,address,address,uint256,uint32,bool))' $ORDER_ID 0)" "$RAILS_A"
assert_eq "order metadata: sellAmount" \
  "$(tuple_field $COW_MODULE 'getOrder(bytes32)((address,address,address,uint256,uint32,bool))' $ORDER_ID 3)" "$COW_SELL"

step "EIP-1271: the module signs its own live order and nothing else"
assert_eq "isValidSignature(orderId) -> magic value" \
  "$(cu $COW_MODULE 'isValidSignature(bytes32,bytes)(bytes4)' "$ORDER_ID" "$ORDER_ID")" "0x1626ba7e"
assert_eq "isValidSignature(unknown digest) -> failure value" \
  "$(cu $COW_MODULE 'isValidSignature(bytes32,bytes)(bytes4)' "$(cast keccak unknown)" "$(cast keccak unknown)")" "0xffffffff"

step "a real CoW solver settles the order through GPv2Settlement"
COW_MANAGER=$(cu $GPV2_AUTHENTICATOR "manager()(address)")
cast rpc --rpc-url "$RPC" anvil_setBalance "$COW_MANAGER" 0xDE0B6B3A7640000 >/dev/null
send "$COW_MANAGER" "$GPV2_AUTHENTICATOR" "addSolver(address)" "$SOLVER" || bad "allow-list the solver"
assert_eq "solver is allow-listed" "$(cu $GPV2_AUTHENTICATOR 'isSolver(address)(bool)' $SOLVER)" "true"

E2E_COW_MODULE=$COW_MODULE E2E_ORDER_ID=$ORDER_ID E2E_BUY_AMOUNT=$ORDER_BUY E2E_APP_DATA=$APP_DATA_1 \
E2E_SOLVER_PK=$SOLVER_PK E2E_SETTLEMENT=$GPV2_SETTLEMENT E2E_ROUTER=$UNISWAP_V3_ROUTER E2E_POOL_FEE=100 \
  forge script scripts/solidity/test/e2e/CowSwapSettleE2E.s.sol --rpc-url "$RPC" --broadcast \
  >"$WORKDIR/settle.log" 2>&1
if grep -q "ONCHAIN EXECUTION COMPLETE" "$WORKDIR/settle.log"; then ok "settle() executed on GPv2Settlement"
else bad "settle() failed — see $WORKDIR/settle.log"; tail -25 "$WORKDIR/settle.log"; fi

ORDER_UID="0x${ORDER_ID#0x}$(echo "${COW_MODULE#0x}" | tr 'A-Z' 'a-z')$(printf '%08x' "$ORDER_VALID_TO")"
assert_eq "GPv2 records the order as fully filled" \
  "$(cu $GPV2_SETTLEMENT 'filledAmount(bytes)(uint256)' "$ORDER_UID")" "$COW_SELL"
assert_ge "rails A received the buyToken directly from the solver" \
  "$(python3 -c "print($(bal $DAI $RAILS_A)-$RAILS_DAI_BEFORE)")" "$ORDER_BUY"
assert_eq "module holds no leftover sellToken" "$(bal $USDC $COW_MODULE)" "0"
assert_eq "module never custodies the buyToken" "$(bal $DAI $COW_MODULE)" "0"
assert_eq "isValidSignature on a filled order -> failure value" \
  "$(cu $COW_MODULE 'isValidSignature(bytes32,bytes)(bytes4)' "$ORDER_ID" "$ORDER_ID")" "0xffffffff"
send_reverts "cancelOrder on a filled order reverts" "$RAILS_OWNER" "$COW_MODULE" "cancelOrder(bytes32)" "$ORDER_ID"

step "cancellation path: a second order is placed and pulled back by the owner"
APP_DATA_2=$(cast keccak "e2e-cow-order-2")
COW_PARAMS_2=$(cast abi-encode "f(address,uint16,address,address,uint256,uint32,bytes32)" \
  "$DAI" "$SLIPPAGE_BPS" "$USDC_USD_FEED" "$DAI_USD_FEED" "$MAX_STALENESS" 3600 "$APP_DATA_2")
send "$RAILS_OWNER" "$RAILS_A" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$USDC" "COWSWAP" "$COW_MODULE" 0 "$COW_PARAMS_2" true || bad "reconfigure USDC"
RAILS_USDC_BEFORE=$(bal $USDC $RAILS_A)
send "$KEEPER" "$RAILS_A" "executeAction(address,uint256)" "$USDC" "$COW_SELL" || bad "executeAction(USDC) #2"
ORDER_ID_2=$(log_topic "$COW_MODULE" "$EV_ORDER_CREATED" 1)
ok "second order = $ORDER_ID_2"
send_reverts "non-owner cannot cancel" "$ATTACKER" "$COW_MODULE" "cancelOrder(bytes32)" "$ORDER_ID_2"
send "$RAILS_OWNER" "$COW_MODULE" "cancelOrder(bytes32)" "$ORDER_ID_2" || bad "cancelOrder"
assert_eq "sellToken returned to rails A" "$(bal $USDC $RAILS_A)" "$RAILS_USDC_BEFORE"
assert_eq "module drained" "$(bal $USDC $COW_MODULE)" "0"
assert_eq "isValidSignature on a cancelled order -> failure value" \
  "$(cu $COW_MODULE 'isValidSignature(bytes32,bytes)(bytes4)' "$ORDER_ID_2" "$ORDER_ID_2")" "0xffffffff"
send_reverts "double cancellation reverts" "$RAILS_OWNER" "$COW_MODULE" "cancelOrder(bytes32)" "$ORDER_ID_2"
send_reverts "renounceOwnership() is disabled on CowSwapModule" "$RAILS_OWNER" "$COW_MODULE" "renounceOwnership()"

# ══════════════════════════════════════════════════════════════════════════════
phase "PHASE 7 — CCTPBridgeModule: full lifecycle (real Circle TokenMessengerV2)"

ok "CCTPBridgeModule = $CCTP_MODULE (stateless, shared across every PaymentRails)"
assert_eq "moduleType()" "$(cu $CCTP_MODULE 'moduleType()(string)' | tr -d '"')" "CCTP_BRIDGE"

step "owner configures USDC on rails B -> Base (domain $CCTP_BASE_DOMAIN), 10 bps fee ceiling, fast finality"
MINT_RECIPIENT=$(cast abi-encode "f(address)" "$RECIPIENT")
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
MAX_FEE_BPS=10
CCTP_PARAMS=$(cast abi-encode "f(uint32,bytes32,bytes32,uint16,uint32,bytes)" \
  "$CCTP_BASE_DOMAIN" "$MINT_RECIPIENT" "$ZERO32" "$MAX_FEE_BPS" 1000 "0x")
send "$RAILS_OWNER" "$RAILS_B" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$USDC" "CCTP_BRIDGE" "$CCTP_MODULE" 0 "$CCTP_PARAMS" true || bad "configureToken(USDC) on rails B"

BRIDGE_AMOUNT=500000000
EXPECTED_MAX_FEE=$(python3 -c "print($BRIDGE_AMOUNT * $MAX_FEE_BPS // 10000)")
step "previewExecution nets the fee ceiling off the full balance"
assert_eq "preview = balance - maxFee" "$(cu $RAILS_B 'previewExecution(address)(uint256,address)' $USDC)" \
  "$(python3 -c "print(2000000000 - 2000000000 * $MAX_FEE_BPS // 10000)")"

step "bridge 500 USDC — burns through Circle's TokenMessengerV2"
SUPPLY_BEFORE=$(cu $USDC "totalSupply()(uint256)"); RAILS_B_BEFORE=$(bal $USDC $RAILS_B)
send "$KEEPER" "$RAILS_B" "executeAction(address,uint256)" "$USDC" "$BRIDGE_AMOUNT" || bad "executeAction(USDC) bridge"
assert_action_executed "ActionExecuted emitted" "$RAILS_B"; CCTP_OUT=$LAST_AMOUNT_OUT
assert_eq "amountOut is net of the fee ceiling" "$CCTP_OUT" "$((BRIDGE_AMOUNT - EXPECTED_MAX_FEE))"
BRIDGE_DATA=$(log_data "$CCTP_MODULE" "$EV_BRIDGE")
assert_eq "BridgeInitiated.maxFee = amount * ${MAX_FEE_BPS}bps" \
  "$(decode "uint256,bytes32,uint256,uint32,bytes" "$BRIDGE_DATA" | sed -n 3p | awk '{print $1}')" "$EXPECTED_MAX_FEE"
assert_eq "rails B USDC debited" "$(python3 -c "print($RAILS_B_BEFORE-$(bal $USDC $RAILS_B))")" "$BRIDGE_AMOUNT"
assert_eq "USDC actually burned by Circle's minter" \
  "$(python3 -c "print($SUPPLY_BEFORE-$(cu $USDC 'totalSupply()(uint256)'))")" "$BRIDGE_AMOUNT"
assert_eq "no USDC stranded in the module" "$(bal $USDC $CCTP_MODULE)" "0"
assert_eq "module's approval to the TokenMessenger revoked" \
  "$(cu $USDC 'allowance(address,address)(uint256)' $CCTP_MODULE $TOKEN_MESSENGER_V2)" "0"
if [[ -n "$(log_data "$TOKEN_MESSENGER_V2" "DepositForBurn(address,uint256,address,bytes32,uint32,bytes32,bytes32,uint256,uint32,bytes)")" ]]; then
  ok "Circle's TokenMessengerV2 emitted DepositForBurn"
else bad "no DepositForBurn event from TokenMessengerV2"; fi

step "hook path — depositForBurnWithHook with destination-chain calldata"
HOOK_DATA=0xdeadbeefcafebabe
CCTP_PARAMS_HOOK=$(cast abi-encode "f(uint32,bytes32,bytes32,uint16,uint32,bytes)" \
  "$CCTP_BASE_DOMAIN" "$MINT_RECIPIENT" "$ZERO32" "$MAX_FEE_BPS" 2000 "$HOOK_DATA")
send "$RAILS_OWNER" "$RAILS_B" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$USDC" "CCTP_BRIDGE" "$CCTP_MODULE" 0 "$CCTP_PARAMS_HOOK" true || bad "reconfigure USDC hook"
SUPPLY_BEFORE=$(cu $USDC "totalSupply()(uint256)")
send "$KEEPER" "$RAILS_B" "executeAction(address,uint256)" "$USDC" "$BRIDGE_AMOUNT" || bad "executeAction(USDC) hook"
assert_action_executed "ActionExecuted emitted (hook path)" "$RAILS_B"
assert_eq "USDC burned on the hook path too" \
  "$(python3 -c "print($SUPPLY_BEFORE-$(cu $USDC 'totalSupply()(uint256)'))")" "$BRIDGE_AMOUNT"
assert_eq "hookData forwarded in BridgeInitiated" \
  "$(decode "uint256,bytes32,uint256,uint32,bytes" "$(log_data "$CCTP_MODULE" "$EV_BRIDGE")" | sed -n 5p)" "$HOOK_DATA"

step "the module only routes USDC"
send "$RAILS_OWNER" "$RAILS_B" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$WETH" "CCTP_BRIDGE" "$CCTP_MODULE" 0 "$CCTP_PARAMS" true || bad "configureToken(WETH) on rails B"
WETH_B_BEFORE=$(bal $WETH $RAILS_B)
send "$KEEPER" "$RAILS_B" "executeAction(address,uint256)" "$WETH" "1000000000000000000" || bad "executeAction(WETH) tx"
assert_action_failed "ActionFailed reason" "$RAILS_B" "Only USDC supported"
assert_eq "WETH untouched" "$(bal $WETH $RAILS_B)" "$WETH_B_BEFORE"

step "invalid economic parameters are rejected before any transfer"
CCTP_PARAMS_BAD=$(cast abi-encode "f(uint32,bytes32,bytes32,uint16,uint32,bytes)" \
  "$CCTP_BASE_DOMAIN" "$MINT_RECIPIENT" "$ZERO32" 10000 1000 "0x")
send "$RAILS_OWNER" "$RAILS_B" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$USDC" "CCTP_BRIDGE" "$CCTP_MODULE" 0 "$CCTP_PARAMS_BAD" true || bad "reconfigure USDC bad fee"
USDC_B_BEFORE=$(bal $USDC $RAILS_B)
send "$KEEPER" "$RAILS_B" "executeAction(address,uint256)" "$USDC" "$BRIDGE_AMOUNT" || bad "executeAction tx"
assert_action_failed "ActionFailed reason (maxFeeBps = 100%)" "$RAILS_B" "Invalid max fee bps"
CCTP_PARAMS_BAD2=$(cast abi-encode "f(uint32,bytes32,bytes32,uint16,uint32,bytes)" \
  "$CCTP_BASE_DOMAIN" "$MINT_RECIPIENT" "$ZERO32" "$MAX_FEE_BPS" 3000 "0x")
send "$RAILS_OWNER" "$RAILS_B" "configureToken(address,string,address,uint256,bytes,bool)" \
  "$USDC" "CCTP_BRIDGE" "$CCTP_MODULE" 0 "$CCTP_PARAMS_BAD2" true || bad "reconfigure USDC bad finality"
send "$KEEPER" "$RAILS_B" "executeAction(address,uint256)" "$USDC" "$BRIDGE_AMOUNT" || bad "executeAction tx"
assert_action_failed "ActionFailed reason (finality != 1000/2000)" "$RAILS_B" "Invalid finality threshold"
assert_eq "USDC untouched across both rejections" "$(bal $USDC $RAILS_B)" "$USDC_B_BEFORE"

# ══════════════════════════════════════════════════════════════════════════════
phase "SUMMARY"
printf "\n  deployed this run\n"
printf "    PaymentRailsFactory      %s\n" "$RAILS_FACTORY"
printf "    CowSwapModuleFactory     %s\n" "$COW_FACTORY"
printf "    PaymentRails A / B       %s / %s\n" "$RAILS_A" "$RAILS_B"
printf "    Forward / DexSwap        %s / %s\n" "$FWD_MODULE" "$DEX_MODULE"
printf "    CowSwap / CCTPBridge     %s / %s\n" "$COW_MODULE" "$CCTP_MODULE"

printf "\n  %s%d passed%s, %s%d failed%s   (logs: %s)\n" "$C_OK" "$PASS" "$C_OFF" \
  "$( ((FAIL)) && echo "$C_BAD" || echo "$C_OK")" "$FAIL" "$C_OFF" "$WORKDIR"
if ((FAIL)); then
  printf "\n  failures:\n"; for f in "${FAILED_LIST[@]}"; do printf "    - %s\n" "$f"; done
  exit 1
fi
exit 0
