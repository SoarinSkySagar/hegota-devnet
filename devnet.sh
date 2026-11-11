#!/usr/bin/env bash
# Single-node Hegota devnet (ethrex EL + lighthouse CL) with EIP-8141 frame
# transactions, via Kurtosis + ethpandaops/ethereum-package.
#
# Fork naming: Hegota = "bogota" on the EL side, "heze" on the CL side.
#
# Two profiles:
#
#   default        ethrex bogota-devnet-2 + lighthouse unstable. Frame txs from
#                  genesis (heze epoch 0). ethereum-package's `frames_enabled`
#                  turns on EL bogota while keeping CL Heze/FOCIL off. Public
#                  mempool only (submit with eth_sendRawTransaction).
#
#   --alt-mempool  ERC-8421 alternative mempool. Adds the Skandha-based ERC-8421
#                  sidecar (./skandha, forshtat/mempool-workshop-sidecar) with
#                  stake + reputation rules and a deployed staking registry.
#                  The sidecar needs ethrex's eip8141-tracer build
#                  (ethrex_simulateFrameTransaction + ERC-7562 tracer), which
#                  speaks the older frame-tx layout (per-gas fees, explicit
#                  nonce key 0, recent-root refs) and needs FOCIL on the CL, so
#                  this profile is its own chain: lighthouse:focil, minimal
#                  preset (8-slot epochs), 1s slots, gloas + heze at epoch 1,
#                  so frame txs work from block 8 (~8s after genesis).
#                  Lighthouse rejects a genesis with gloas/heze already active,
#                  so epoch 1 is the earliest possible.
#
# Usage:
#   ./devnet.sh up [--alt-mempool]   # start (or restart) the devnet
#   ./devnet.sh --alt-mempool        # same as: up --alt-mempool
#   ./devnet.sh info                 # endpoints, fork time, funded account
#   ./devnet.sh accounts             # seed phrase + 10 funded accounts (keys, balances)
#                                    # (every `up` also writes all 21 to ./funded.json)
#   ./devnet.sh logs [el|cl|vc|dora|skandha]
#   ./devnet.sh down                 # destroy the enclave
#   ./devnet.sh frame-tx [transfer|batch|revert]
#                                    # send a demo EIP-8141 tx (via the
#                                    # sidecar when the alt mempool is on)
#   ./devnet.sh dora-build [tag]     # build ./dora into a local image
#   ./devnet.sh skandha-build [tag]  # build ./skandha into a local image
#
# Explorer: Dora runs by default (WITH_DORA=0 to skip). Its transaction page has
# "Frames" and "Signatures" tabs for EIP-8141 txs. `info` prints its URL.
#
# Overridable via env:
#   ENCLAVE, ETHREX_IMAGE, LIGHTHOUSE_IMAGE, DORA_IMAGE, SKANDHA_IMAGE,
#   HEZE_FORK_EPOCH, SLOT_DURATION_MS, PACKAGE_REF, EL_EXTRA_PARAMS
#   (space-separated extra ethrex flags), GLOAS_FORK_EPOCH + PRESET
#   (alt-mempool profile only), WITH_DORA, ALT_MEMPOOL=1,
#   ALT_MIN_STAKE_WEI (ERC-8421 MIN_STAKE_VALUE, default 1 ETH)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.devnet"
ARGS_FILE="${STATE_DIR}/network_params.yaml"
MODE_FILE="${STATE_DIR}/mode"

# ---------- arguments ----------
ALT_MEMPOOL="${ALT_MEMPOOL:-0}"
POSITIONAL=()
for a in "$@"; do
  case "$a" in
    --alt-mempool) ALT_MEMPOOL=1 ;;
    *) POSITIONAL+=("$a") ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"
CMD="${1:-up}"
[[ $# -gt 0 ]] && shift

# Commands other than `up` follow whatever profile the running chain was started with.
if [[ "$CMD" != "up" && "$ALT_MEMPOOL" != "1" && -f "$MODE_FILE" && "$(cat "$MODE_FILE")" == "alt" ]]; then
  ALT_MEMPOOL=1
fi

ENCLAVE="${ENCLAVE:-hegota-devnet}"
WITH_DORA="${WITH_DORA:-1}"
EL_EXTRA_PARAMS="${EL_EXTRA_PARAMS:-}"

if [[ "$ALT_MEMPOOL" == "1" ]]; then
  # lambdaclass's Dora fork used by ethrex's own Hegota testnet: decodes this
  # lighthouse:focil's Heze blocks (upstream Dora's Heze types have moved on)
  # and the frame-tx table (mode, scope, target, per-frame result, payer).
  DORA_IMAGE="${DORA_IMAGE:-ghcr.io/lambdaclass/dora:heze-decode}"
  # The sidecar author's tested chain (skandha/test/e2e/kurtosis/eip8141-single-node.yaml).
  ETHREX_IMAGE="${ETHREX_IMAGE:-ghcr.io/forshtat/ethrex:eip8141-tracer-9aa3645d795945c64400f41a70aace0edfa7f383}"
  # FOCIL-capable: the tracer ethrex only accepts the Hegota engine API pair it speaks.
  LIGHTHOUSE_IMAGE="${LIGHTHOUSE_IMAGE:-ethpandaops/lighthouse:focil}"
  # Fastest setup that boots and stays healthy (tested): lighthouse:focil rejects
  # a genesis with gloas or heze already active (OffsetsAreDecreasing), so both
  # go at epoch 1; the minimal preset (8-slot epochs) with 1s slots puts that
  # at ~8s after genesis. Steady 1 block/s, finality advancing.
  GLOAS_FORK_EPOCH="${GLOAS_FORK_EPOCH:-1}"
  HEZE_FORK_EPOCH="${HEZE_FORK_EPOCH:-1}"
  PRESET="${PRESET:-minimal}"
  SLOT_DURATION_MS="${SLOT_DURATION_MS:-1000}"
  PACKAGE_REF="${PACKAGE_REF:-b5b3af65248f11702216e377d0377bcd8ccf4caf}"
else
  # Dora master: frame txs with Frames / Signatures tabs on the tx page.
  DORA_IMAGE="${DORA_IMAGE:-ethpandaops/dora:master-5fb1ef2}"
  # ethrex branch with EIP-8141 / bogota support.
  ETHREX_IMAGE="${ETHREX_IMAGE:-ethpandaops/ethrex:bogota-devnet-2}"
  # Needs Gloas support, since Amsterdam (Gloas) must be active below Bogota.
  LIGHTHOUSE_IMAGE="${LIGHTHOUSE_IMAGE:-ethpandaops/lighthouse:unstable}"
  # Epoch at which bogota (frame txs) turns on. 0 => active from genesis.
  HEZE_FORK_EPOCH="${HEZE_FORK_EPOCH:-0}"
  SLOT_DURATION_MS="${SLOT_DURATION_MS:-12000}"
  # Pinned ethereum-package commit known to have `frames_enabled`.
  PACKAGE_REF="${PACKAGE_REF:-5795b77e65235ad223d4d3b413b2739190bf60cc}"
fi
PACKAGE="github.com/ethpandaops/ethereum-package@${PACKAGE_REF}"

# ---------- ERC-8421 sidecar ----------
SKANDHA_IMAGE="${SKANDHA_IMAGE:-pq-wallet/skandha:local}"
SKANDHA_SRC="${SKANDHA_SRC:-$SCRIPT_DIR/skandha}"
SKANDHA_SVC="skandha"
SKANDHA_PORT=14337
# ERC-8421 MIN_STAKE_VALUE is "per-chain, roughly USD 1000"; 1 ETH on this devnet.
ALT_MIN_STAKE_WEI="${ALT_MIN_STAKE_WEI:-1000000000000000000}"
ALT_MIN_UNSTAKE_DELAY=86400 # ERC-8421 MIN_UNSTAKE_DELAY

EL_SVC="el-1-ethrex-lighthouse"
CL_SVC="cl-1-lighthouse-ethrex"
VC_SVC="vc-1-ethrex-lighthouse"
DORA_SVC="dora"

# Prefunded dev accounts: ethereum-package funds indices 0-20 of this public
# mnemonic (standard path m/44'/60'/0'/0/i, same as MetaMask) with 1e9 ETH each,
# on both profiles. Public keys: never use them anywhere real.
MNEMONIC="giant issue aisle success illegal bike spike question tent bar rely arctic volcano long crawl hungry vocal artwork sniff fantasy very lucky have athlete"
# All 21 funded accounts (index = position). 0-9 are yours (MetaMask etc.),
# 10-18 spare, 19-20 reserved for the alt mempool. `./devnet.sh accounts`
# prints 0-9; every `up` writes all 21 to ./funded.json.
ALL_ACCOUNTS=(
  "0x8943545177806ED17B9F23F0a21ee5948eCaa776 bcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31"
  "0xE25583099BA105D9ec0A67f5Ae86D90e50036425 39725efee3fb28614de3bacaffe4cc4bd8c436257e2c8bb887c4b5c4be45e76d"
  "0x614561D2d143621E126e87831AEF287678B442b8 53321db7c1e331d93a11a41d16f004d7ff63972ec8ec7c25db329728ceeb1710"
  "0xf93Ee4Cf8c6c40b329b0c0626F28333c132CF241 ab63b23eb7941c1251757e24b3d2350d2bc05c3c388d06f8fe6feafefb1e8c70"
  "0x802dCbE1B1A97554B4F50DB5119E37E8e7336417 5d2344259f42259f82d2c140aa66102ba89b57b4883ee441a8b312622bd42491"
  "0xAe95d8DA9244C37CaC0a3e16BA966a8e852Bb6D6 27515f805127bebad2fb9b183508bdacb8c763da16f54e0678b16e8f28ef3fff"
  "0x2c57d1CFC6d5f8E4182a56b4cf75421472eBAEa4 7ff1a4c1d57e5e784d327c4c7651e952350bc271f156afb3d00d20f5ef924856"
  "0x741bFE4802cE1C4b5b00F9Df2F5f179A1C89171A 3a91003acaf4c21b3953d94fa4a6db694fa69e5242b2e37be05dd82761058899"
  "0xc3913d4D8bAb4914328651C2EAE817C8b78E1f4c bb1d0f125b4fb2bb173c318cdead45468474ca71474e2247776b2b4c0fa2d3f5"
  "0x65D08a056c17Ae13370565B04cF77D2AfA1cB9FA 850643a0224065ecce3882673c21f56bcf6eef86274cc21cadff15930b59fc8c"
  "0x3e95dFbBaF6B348396E6674C7871546dCC568e56 94eb3102993b41ec55c241060f47daa0f6372e2e3ad7e91612ae36c364042e44"
  "0x5918b2e647464d4743601a865753e64C8059Dc4F daf15504c22a352648a71ef2926334fe040ac1d5005019e09f6c979808024dc7"
  "0x589A698b7b7dA0Bec545177D3963A2741105C7C9 eaba42282ad33c8ef2524f07277c03a776d98ae19f581990ce75becb7cfa1c23"
  "0x4d1CB4eB7969f8806E2CaAc0cbbB71f88C8ec413 3fd98b5187bf6526734efaa644ffbb4e3670d66f5d0268ce0323ec09124bff61"
  "0xF5504cE2BcC52614F121aff9b93b2001d92715CA 5288e2f440c7f0cb61a9be8afdeb4295f786383f96f5e35eb0c94ef103996b64"
  "0xF61E98E7D47aB884C244E39E031978E33162ff4b f296c7802555da2a5a662be70e078cbd38b44f96f8615ae529da41122ce8db05"
  "0xf1424826861ffbbD25405F5145B5E50d0F1bFc90 bf3beef3bd999ba9f2451e06936f0423cd62b815c9233dd3bc90f7e02a1e8673"
  "0xfDCe42116f541fc8f7b0776e2B30832bD5621C85 6ecadc396415970e91293726c3f5775225440ea0844ae5616135fd10d66b5954"
  "0xD9211042f35968820A3407ac3d80C725f8F75c14 a492823c3e193d6c595f37a18e3c06650cf4c74558cc818b16130b293716106f"
  "0xD8F3183DEF51A987222D845be228e0Bbb932C222 c5114526e042343c6d1899cad05e1c00ba588314de9b96929914ee0df18d46b2"
  "0xafF0CA253b97e54440965855cec0A8a2E2399896 04b9f63ecf84210c5366c66d68fa1f5da1fa4f634fad6dfc86178e4d79ff9e59"
)
USER_ACCOUNTS=("${ALL_ACCOUNTS[@]:0:10}")
FUNDED_FILE="${SCRIPT_DIR}/funded.json"
FUNDED_ADDR="${USER_ACCOUNTS[0]% *}"
FUNDED_KEY="${USER_ACCOUNTS[0]#* }"
# Infrastructure keys live at the top of the funded range so they never share
# nonces with accounts 0-9.
RELAYER_ADDR="0xD8F3183DEF51A987222D845be228e0Bbb932C222"   # index 19: sidecar relayer
RELAYER_KEY="c5114526e042343c6d1899cad05e1c00ba588314de9b96929914ee0df18d46b2"
DEPLOYER_ADDR="0xafF0CA253b97e54440965855cec0A8a2E2399896"  # index 20: staking registry deployer
DEPLOYER_KEY="04b9f63ecf84210c5366c66d68fa1f5da1fa4f634fad6dfc86178e4d79ff9e59"

die() { echo "error: $*" >&2; exit 1; }

require() {
  command -v kurtosis >/dev/null || die "kurtosis not installed (https://docs.kurtosis.com/install)"
  command -v docker   >/dev/null || die "docker not installed"
  docker info >/dev/null 2>&1    || die "docker daemon not reachable"
}

rpc_call() { # url method params-json
  curl -s --max-time 5 -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":${3:-[]}}" "$1"
}

write_args() {
  mkdir -p "$STATE_DIR"

  local extra="" params=()
  [[ "$ALT_MEMPOOL" == "1" ]] && params+=("--http.api=ethrex" "--http.api=debug" "--http.api=txpool")
  for p in $EL_EXTRA_PARAMS; do params+=("$p"); done
  if [[ ${#params[@]} -gt 0 ]]; then
    extra="    el_extra_params:"$'\n'
    for p in "${params[@]}"; do extra+="      - \"${p}\""$'\n'; done
  fi

  local services="additional_services: []"
  if [[ "$WITH_DORA" == "1" ]]; then
    services="additional_services:
  - dora
dora_params:
  image: ${DORA_IMAGE}"
  fi

  if [[ "$ALT_MEMPOOL" == "1" ]]; then
    cat > "$ARGS_FILE" <<EOF
participants:
  - el_type: ethrex
    el_image: ${ETHREX_IMAGE}
    cl_type: lighthouse
    cl_image: ${LIGHTHOUSE_IMAGE}
    validator_count: 32
    # Fulu at genesis needs PeerDAS custody; a single node must be a supernode.
    supernode: true
${extra}
network_params:
  network_id: "3151908"
  preset: ${PRESET}
  seconds_per_slot: $((SLOT_DURATION_MS / 1000))
  fulu_fork_epoch: 0
  # Amsterdam (gloas) one epoch ahead of Hegota: a Hegota-active genesis is
  # rejected by lighthouse.
  gloas_fork_epoch: ${GLOAS_FORK_EPOCH}
  heze_fork_epoch: ${HEZE_FORK_EPOCH}
  # EIP-8282 deposit predeploy inhibitor the 6.1.x genesis generator omits
  # (without it the chain freezes at the Amsterdam boundary).
  additional_preloaded_contracts:
    "0x0000BFF46984E3725691FA540A8C7589300D8282":
      balance: "0"
      nonce: "1"
      code: "0x3373fffffffffffffffffffffffffffffffffffffffe1461011c575f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff146102705760015460088111605257506058565b60089003015b601190600182026001905f5b5f821115607f57810190830284830290049160010191906064565b90939004925050503660b814609f57366102705734610270575f5260205ff35b8034106102705760383567ffffffffffffffff1680633b9aca001161027057633b9aca00029034031061027057600154600101600155600354806006026004015f358155600101602035815560010160403581556001016060358155600101608035815560010160a035905560b85f5f3760b85fa0600101600355005b60035460025480820380604011610131575060405b5f5b8181146101d7578281016006026004018160b8028154815260200181600101548152602001816002015480825260401c67ffffffffffffffff16816010018160381c81600701538160301c81600601538160281c81600501538160201c81600401538160181c81600301538160101c81600201538160081c816001015353602001816003015481526020018160040154815260200190600501549052600101610133565b91018092146101e957906002556101f4565b90505f6002555f6003555b36610242575f54600154817fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1461023057600882820111610238575b50505f610264565b0160089003610264565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff5b5f555f60015560b8025ff35b5f5ffd"
      storage:
        "0x0000000000000000000000000000000000000000000000000000000000000000": "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

# The pinned package's default generator predates the EIP-8282 builder predeploys.
ethereum_genesis_generator_params:
  image: ethpandaops/ethereum-genesis-generator:6.1.6

${services}
EOF
  else
    cat > "$ARGS_FILE" <<EOF
participants:
  - el_type: ethrex
    el_image: ${ETHREX_IMAGE}
    cl_type: lighthouse
    cl_image: ${LIGHTHOUSE_IMAGE}
    vc_type: lighthouse
    vc_image: ${LIGHTHOUSE_IMAGE}
    count: 1
${extra}
network_params:
  network_id: "3151908"
  preset: mainnet
  seconds_per_slot: $((SLOT_DURATION_MS / 1000))
  slot_duration_ms: ${SLOT_DURATION_MS}
  fulu_fork_epoch: 0
  gloas_fork_epoch: 0
  heze_fork_epoch: ${HEZE_FORK_EPOCH}
  # EL bogota (EIP-8141 frame txs) on at heze_fork_epoch, CL Heze/FOCIL off.
  frames_enabled: true

${services}
EOF
  fi
}

rpc_url() {
  kurtosis port print "$ENCLAVE" "$EL_SVC" rpc 2>/dev/null | sed 's#^#http://#; s#http://http://#http://#'
}

skandha_url() {
  local u
  u="$(kurtosis port print "$ENCLAVE" "$SKANDHA_SVC" rpc 2>/dev/null || true)"
  [[ -z "$u" ]] && return 0
  [[ "$u" == http* ]] || u="http://$u"
  echo "${u%/}/rpc/"
}

# ---------- ERC-8421 alt mempool ----------
wait_for_rpc() {
  local rpc="$1" i
  for i in $(seq 1 60); do
    rpc_call "$rpc" eth_blockNumber | grep -q '"result"' && return 0
    sleep 2
  done
  die "EL RPC $rpc did not come up"
}

deploy_staking_registry() {
  local rpc="$1" init out addr
  command -v cast >/dev/null || die "foundry's cast is required for --alt-mempool (https://getfoundry.sh)"
  init="$(grep -o '0x[0-9a-fA-F]\{200,\}' "$SKANDHA_SRC/deploy/predeploy/src/protocols/staking-registry-deployment.ts" | head -1)"
  [[ -n "$init" ]] || die "staking registry init code not found in $SKANDHA_SRC"
  out="$(cast send --rpc-url "$rpc" --private-key "0x$DEPLOYER_KEY" --legacy --create "$init" --json)" \
    || die "staking registry deployment failed"
  addr="$(echo "$out" | grep -o '"contractAddress":"0x[0-9a-fA-F]\{40\}"' | grep -o '0x[0-9a-fA-F]\{40\}')"
  [[ -n "$addr" ]] || die "staking registry deployment returned no address: $out"
  echo "$addr"
}

start_skandha() {
  local registry="$1" cfg
  docker image inspect "$SKANDHA_IMAGE" >/dev/null 2>&1 || cmd_skandha_build "$SKANDHA_IMAGE"

  cfg="$(mktemp -d)"
  # ERC-8421 constants where the sidecar exposes them; everything else is the
  # sidecar's ERC-8421 defaults (BUDGET/PREFIX/OPCODES/STORAGE/SOLVENCY/
  # LIFECYCLE rules are always on).
  cat > "$cfg/config.json" <<EOF
{
  "entryPoints": ["0x00000000000000000000000000000000000000aa"],
  "canonicalEntryPoint": "0x00000000000000000000000000000000000000aa",
  "standardMempoolId": "QmcFZKUX9qoo3StwVycJTAhwdiqbEjcwNvQVK246p3z1rk",
  "supportedMempools": [
    { "mempoolId": "QmcFZKUX9qoo3StwVycJTAhwdiqbEjcwNvQVK246p3z1rk",
      "entryPoint": "0x00000000000000000000000000000000000000aa" }
  ],
  "relayers": ["0x${RELAYER_KEY}"],
  "rpcEndpoint": "http://${EL_SVC}:8545",
  "stakingRegistryAddress": "${registry}",
  "minStake": "${ALT_MIN_STAKE_WEI}",
  "minUnstakeDelay": ${ALT_MIN_UNSTAKE_DELAY},
  "minInclusionDenominator": 10,
  "throttlingSlack": 10,
  "banSlack": 50
}
EOF
  kurtosis files upload --name skandha-config "$ENCLAVE" "$cfg" >/dev/null
  rm -rf "$cfg"

  kurtosis service add "$ENCLAVE" "$SKANDHA_SVC" "$SKANDHA_IMAGE" \
    --files "/config:skandha-config" \
    --ports "rpc=http:${SKANDHA_PORT}/tcp" \
    --cmd "standalone --configFile /config/config.json --dataDir /data --api.address 0.0.0.0 --api.port ${SKANDHA_PORT} --explorer.enable --redirectRpc" \
    >/dev/null
}

# Overwrite ./funded.json with all 21 funded accounts for the chain just started.
write_funded_file() {
  local rpc="$1" profile="$2" dora sk="" i addr key role tmp
  dora="$(kurtosis port print "$ENCLAVE" "$DORA_SVC" http 2>/dev/null || true)"
  [[ "$ALT_MEMPOOL" == "1" ]] && sk="$(skandha_url)"
  tmp="$(mktemp)"
  {
    echo "{"
    echo "  \"generatedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"note\": \"Public devnet keys (ethereum-package default mnemonic). Never use them on a real network.\","
    echo "  \"profile\": \"$profile\","
    echo "  \"enclave\": \"$ENCLAVE\","
    echo "  \"chainId\": 3151908,"
    echo "  \"rpcUrl\": \"$rpc\","
    echo "  \"explorerUrl\": \"$dora\","
    echo "  \"altMempoolUrl\": \"$sk\","
    echo "  \"mnemonic\": \"$MNEMONIC\","
    echo "  \"derivationPath\": \"m/44'/60'/0'/0/{index}\","
    echo "  \"genesisBalanceEth\": \"1000000000\","
    echo "  \"accounts\": ["
    for i in "${!ALL_ACCOUNTS[@]}"; do
      addr="${ALL_ACCOUNTS[$i]% *}"; key="${ALL_ACCOUNTS[$i]#* }"
      if (( i < 10 )); then role="user"; else role="spare"; fi
      if [[ "$ALT_MEMPOOL" == "1" ]]; then
        (( i == 19 )) && role="reserved: alt-mempool relayer"
        (( i == 20 )) && role="reserved: staking registry deployer"
      fi
      printf '    {"index": %d, "address": "%s", "privateKey": "0x%s", "path": "m/44'"'"'/60'"'"'/0'"'"'/0/%d", "role": "%s"}%s\n' \
        "$i" "$addr" "$key" "$i" "$role" "$( (( i < ${#ALL_ACCOUNTS[@]} - 1 )) && echo , )"
    done
    echo "  ]"
    echo "}"
  } > "$tmp"
  mv "$tmp" "$FUNDED_FILE"
  echo ">> wrote ${#ALL_ACCOUNTS[@]} funded accounts to $FUNDED_FILE"
}

cmd_up() {
  require
  write_args
  echo ">> profile: $([[ "$ALT_MEMPOOL" == "1" ]] && echo "alt-mempool (ERC-8421)" || echo default)"
  echo ">> args: $ARGS_FILE"
  if kurtosis enclave inspect "$ENCLAVE" >/dev/null 2>&1; then
    echo ">> removing existing enclave $ENCLAVE"
    kurtosis enclave rm -f "$ENCLAVE"
  fi
  rm -f "$MODE_FILE" "$STATE_DIR/staking_registry"
  kurtosis run --enclave "$ENCLAVE" "$PACKAGE" --args-file "$ARGS_FILE"

  if [[ "$ALT_MEMPOOL" == "1" ]]; then
    local rpc registry
    rpc="$(rpc_url)"
    wait_for_rpc "$rpc"
    echo ">> deploying ERC-8421 staking registry"
    registry="$(deploy_staking_registry "$rpc")"
    echo "$registry" > "$STATE_DIR/staking_registry"
    echo ">> starting ERC-8421 sidecar (Skandha) with registry $registry"
    start_skandha "$registry"
    echo alt > "$MODE_FILE"
    write_funded_file "$rpc" "alt-mempool"
  else
    echo default > "$MODE_FILE"
    write_funded_file "$(rpc_url)" "default"
  fi
  cmd_info
}

cmd_info() {
  require
  kurtosis enclave inspect "$ENCLAVE" >/dev/null 2>&1 || die "enclave $ENCLAVE not running"
  local rpc ws beacon dora sk
  rpc="$(rpc_url)"
  ws="$(kurtosis port print "$ENCLAVE" "$EL_SVC" ws 2>/dev/null || true)"
  beacon="$(kurtosis port print "$ENCLAVE" "$CL_SVC" http 2>/dev/null || true)"
  dora="$(kurtosis port print "$ENCLAVE" "$DORA_SVC" http 2>/dev/null || true)"

  echo
  echo "=== Hegota devnet ($ENCLAVE, $([[ "$ALT_MEMPOOL" == "1" ]] && echo "alt-mempool profile" || echo "default profile")) ==="
  echo "EL RPC      : $rpc"
  [[ -n "$ws" ]]     && echo "EL WS       : $ws"
  [[ -n "$beacon" ]] && echo "Beacon API  : $beacon"
  [[ -n "$dora" ]]   && echo "Explorer    : $dora   (Dora; frame txs decoded on the tx page)"
  if [[ "$ALT_MEMPOOL" == "1" ]]; then
    sk="$(skandha_url)"
    echo "Alt mempool : ${sk:-not running}   (ERC-8421 sidecar: eth_sendFrameTransaction, skandha_explorer_*)"
    [[ -f "$STATE_DIR/staking_registry" ]] && echo "Staking reg : $(cat "$STATE_DIR/staking_registry")   (ERC-8421 IStakingRegistry; min stake $(awk "BEGIN{print $ALT_MIN_STAKE_WEI/1e18}") ETH, unstake delay ${ALT_MIN_UNSTAKE_DELAY}s)"
    echo "Relayer     : $RELAYER_ADDR"
  fi
  echo "Chain ID    : 3151908"
  echo "Funded acct : $FUNDED_ADDR   (+9 more: ./devnet.sh accounts)"
  echo "Funded key  : 0x$FUNDED_KEY   (public devnet key, never use elsewhere)"

  if command -v curl >/dev/null && [[ -n "$rpc" ]]; then
    local head
    head="$(rpc_call "$rpc" eth_blockNumber | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
    [[ -n "$head" ]] && echo "Head block  : $((head))"
  fi
  local bogota="" gendir
  gendir="$(mktemp -d)"
  if kurtosis files download "$ENCLAVE" el_cl_genesis_data "$gendir" >/dev/null 2>&1; then
    bogota="$(grep -o '"bogotaTime": *[0-9]*' "$gendir/genesis.json" "$gendir"/metadata/genesis.json 2>/dev/null | grep -o '[0-9]*$' | head -1 || true)"
  fi
  rm -rf "$gendir"
  if [[ -n "$bogota" ]]; then
    if [[ "$bogota" == "0" ]]; then
      echo "bogotaTime  : 0 (active from genesis)  <- frame txs valid from here"
    else
      echo "bogotaTime  : $bogota ($(date -d "@$bogota" 2>/dev/null || echo "unix"))  <- frame txs valid from here"
    fi
  fi
  echo
}

cmd_logs() {
  local which="${1:-el}" svc
  case "$which" in
    el) svc="$EL_SVC" ;; cl) svc="$CL_SVC" ;; vc) svc="$VC_SVC" ;;
    dora) svc="$DORA_SVC" ;; skandha) svc="$SKANDHA_SVC" ;;
    *) die "logs target must be el|cl|vc|dora|skandha" ;;
  esac
  kurtosis service logs -f "$ENCLAVE" "$svc"
}

cmd_down() {
  require
  kurtosis enclave rm -f "$ENCLAVE" && echo ">> removed $ENCLAVE"
  rm -f "$MODE_FILE" "$STATE_DIR/staking_registry"
}

live_rpc() {
  require
  kurtosis enclave inspect "$ENCLAVE" >/dev/null 2>&1 || die "enclave $ENCLAVE not running (./devnet.sh up)"
  local rpc
  rpc="$(rpc_url)"
  [[ -n "$rpc" ]] || die "could not resolve EL RPC port"
  echo "$rpc"
}

need_node() { command -v node >/dev/null || die "node (>=18) is required"; }

# Build the Dora checkout in ./dora (your fork / local edits) into a docker image.
cmd_dora_build() {
  require
  local src="${DORA_SRC:-$SCRIPT_DIR/dora}" tag="${1:-pq-wallet/dora:local}"
  [[ -f "$src/Dockerfile" ]] || die "no Dora source at $src (git clone https://github.com/ethpandaops/dora $src)"
  docker build -t "$tag" "$src"
  echo ">> built $tag — run: DORA_IMAGE=$tag ./devnet.sh up"
}

# Build the ERC-8421 sidecar checkout in ./skandha into a docker image.
cmd_skandha_build() {
  require
  local tag="${1:-$SKANDHA_IMAGE}"
  if [[ ! -f "$SKANDHA_SRC/Dockerfile" ]]; then
    git clone https://github.com/forshtat/mempool-workshop-sidecar "$SKANDHA_SRC"
  fi
  docker build -t "$tag" "$SKANDHA_SRC"
  echo ">> built $tag"
}

cmd_frame_tx() {
  need_node
  local rpc args=()
  rpc="$(live_rpc)"
  if [[ ! -d "$SCRIPT_DIR/tools/node_modules/@noble" ]]; then
    (cd "$SCRIPT_DIR/tools" && npm install --silent)
  fi
  if [[ "$ALT_MEMPOOL" == "1" ]]; then
    local sk
    sk="$(skandha_url)"
    [[ -n "$sk" ]] || die "alt mempool sidecar is not running"
    args+=(--format legacy --sidecar "$sk")
  fi
  # First arg is a demo name unless it is an option (e.g. `frame-tx --frames my.json`).
  local demo="transfer"
  if [[ $# -gt 0 && "$1" != --* ]]; then demo="$1"; shift; fi
  node "$SCRIPT_DIR/tools/send-frame-tx.mjs" --rpc "$rpc" --demo "$demo" "${args[@]+"${args[@]}"}" "$@"
}

cmd_accounts() {
  local rpc="" i addr key bal
  if command -v kurtosis >/dev/null && kurtosis enclave inspect "$ENCLAVE" >/dev/null 2>&1; then
    rpc="$(rpc_url)"
  fi
  echo
  echo "Seed phrase (MetaMask: import, then 'Add account' for #1-#9):"
  echo "  $MNEMONIC"
  echo
  printf "  %-2s  %-42s  %-66s  %s\n" "#" "address" "private key" "balance (ETH)"
  for i in "${!USER_ACCOUNTS[@]}"; do
    addr="${USER_ACCOUNTS[$i]% *}"; key="${USER_ACCOUNTS[$i]#* }"; bal="-"
    if [[ -n "$rpc" ]]; then
      bal="$(rpc_call "$rpc" eth_getBalance "[\"$addr\",\"latest\"]" \
        | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p' \
        | python3 -I -c 'import sys;v=sys.stdin.read().strip();print(f"{int(v,16)/1e18:,.4f}" if v else "-")' 2>/dev/null || echo "-")"
    fi
    printf "  %-2s  %s  0x%s  %s\n" "$i" "$addr" "$key" "$bal"
  done
  echo
  echo "  Chain ID 3151908. Public devnet keys: never send real funds to them."
  [[ "$ALT_MEMPOOL" == "1" ]] && echo "  Reserved by the alt mempool: #19 relayer $RELAYER_ADDR, #20 registry deployer $DEPLOYER_ADDR."
  echo
}

case "$CMD" in
  up)            cmd_up ;;
  accounts)      cmd_accounts ;;
  info)          cmd_info ;;
  logs)          cmd_logs "$@" ;;
  down)          cmd_down ;;
  frame-tx)      cmd_frame_tx "$@" ;;
  dora-build)    cmd_dora_build "$@" ;;
  skandha-build) cmd_skandha_build "$@" ;;
  *) die "usage: $0 [--alt-mempool] {up|info|accounts|logs [el|cl|vc|dora|skandha]|down|frame-tx [transfer|batch|revert]|dora-build [tag]|skandha-build [tag]}" ;;
esac
