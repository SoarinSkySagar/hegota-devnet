# Hegota devnet (EIP-8141 frame transactions)

Single-node local chain for building against EIP-8141 frame transactions, optionally with an ERC-8421 alternative mempool. Everything is driven by `devnet.sh` (Kurtosis + ethpandaops/ethereum-package).

## Setup

1. Install prerequisites:
   - Docker (daemon running)
   - [Kurtosis CLI](https://docs.kurtosis.com/install)
   - Node.js >= 18 (`frame-tx` sender)
   - [Foundry](https://getfoundry.sh) `cast` (alt-mempool mode: staking registry deploy)
   - python3 (`accounts` balance display)
2. Clone with submodules (`dora/`, `skandha/`):
   ```bash
   git clone --recurse-submodules <repo-url> && cd pq-wallet
   # already cloned without them:
   git submodule update --init
   ```
3. Install the tx-sender deps (`frame-tx` also does this on first use):
   ```bash
   (cd tools && npm install)
   ```
4. Start the Kurtosis engine if it isn't running: `kurtosis engine start`.
5. Start a chain:
   ```bash
   ./devnet.sh up              # default: frame txs from genesis
   ./devnet.sh --alt-mempool   # ERC-8421 alt mempool (first run builds pq-wallet/skandha:local, a few minutes)
   ```
6. Read the endpoints and accounts: `./devnet.sh info`, `./devnet.sh accounts`, or `funded.json`.
7. Smoke test: `./devnet.sh frame-tx batch`, then open the tx hash in Dora (`Explorer` URL from `info`).

The first run pulls several Docker images (ethrex, lighthouse, dora, genesis generator), which takes a few minutes.

## Layout

| Path | What |
|---|---|
| `devnet.sh` | Everything: start/stop, info, accounts, logs, demo txs, image builds |
| `funded.json` | All 21 funded accounts, rewritten on every `up` (gitignored) |
| `tools/send-frame-tx.mjs` | Demo frame-tx builder/signer/sender (both tx formats) |
| `dora/` | Submodule: Dora explorer source, ethpandaops/dora @ `5fb1ef2` (`dora-build`) |
| `skandha/` | Submodule: ERC-8421 sidecar, forshtat/mempool-workshop-sidecar @ `2e22ff0` (`skandha-build`) |
| `.devnet/` | Generated Kurtosis args, current mode, staking registry address (gitignored) |

## Commands

```bash
./devnet.sh up                    # start default chain (restarts if running)
./devnet.sh --alt-mempool         # start alt-mempool chain (= up --alt-mempool)
./devnet.sh info                  # RPC / beacon / Dora / sidecar URLs, head, fork time
./devnet.sh accounts              # seed phrase + accounts 0-9 with keys and live balances
./devnet.sh logs [el|cl|vc|dora|skandha]   # follow service logs (default: el)
./devnet.sh frame-tx [transfer|batch|revert] [--verify-gas N]   # send demo frame tx
./devnet.sh frame-tx --frames my.json [--key 0x…]              # send your own frames
./devnet.sh frame-tx transfer --sponsor-key 0x…                  # gas paid by another account
examples/mixed-frame-txs.sh       # 13 mixed txs: self-paid, sponsored, same-sender batches
./devnet.sh down                  # destroy the chain
./devnet.sh dora-build [tag]      # build ./dora -> pq-wallet/dora:local
./devnet.sh skandha-build [tag]   # build ./skandha -> pq-wallet/skandha:local
```

- `info`, `logs`, `frame-tx` and `accounts` follow whichever mode the running chain was started in.
- Pause without losing state (untested, ports change): `kurtosis enclave stop hegota-devnet` / `kurtosis enclave start hegota-devnet`.

## Profiles

|  | Default (`up`) | Alt mempool (`--alt-mempool`) |
|---|---|---|
| EL | `ethpandaops/ethrex:bogota-devnet-2` | `ghcr.io/forshtat/ethrex:eip8141-tracer-9aa3645…` |
| CL | `ethpandaops/lighthouse:unstable` | `ethpandaops/lighthouse:focil` |
| Explorer | `ethpandaops/dora:master-5fb1ef2` | `ghcr.io/lambdaclass/dora:heze-decode` |
| Preset / slot | mainnet / 12s | minimal (8-slot epochs) / 1s |
| Frame txs from | genesis (block 0) | epoch 1 = block 8 (~8s) |
| FOCIL | off (`frames_enabled`) | on |
| Mempool | public (EL) only | public + ERC-8421 sidecar |
| Submit with | `eth_sendRawTransaction` to EL RPC | `eth_sendFrameTransaction` to sidecar |
| Tx format | current (single `max_fee`) | older (per-gas fees) |
| ethereum-package | `5795b77` | `b5b3af6` |

The two profiles are separate chains, not one chain with a toggle. The sidecar only works with the tracer ethrex build, which requires FOCIL and the older tx format.

### Default

- Frame txs valid from genesis (`bogotaTime: 0`).
- Dora tx page has **Frames** and **Signatures** tabs.
- `ethrex_simulateFrameTransaction` is not available on this image.

### Alt mempool (ERC-8421)

- Extra services: `skandha` (ERC-8421 sidecar, standalone mode, `--explorer.enable --redirectRpc`) and a `NaiveStakingRegistry` contract deployed at startup.
- Sidecar config (from the ERC): `minStake` 1 ETH (`ALT_MIN_STAKE_WEI`), `minUnstakeDelay` 86400, `minInclusionDenominator` 10, `throttlingSlack` 10, `banSlack` 50. PREFIX, BUDGET, SIGNATURE, OPCODES, STORAGE, SOLVENCY, REPUTATION and LIFECYCLE rules are always on.
- Example rule: `MAX_VERIFY_GAS` 100000 per unstaked entity (BUDGET-010, signature-verification cost included). Reproduce a rejection with `./devnet.sh frame-tx transfer --verify-gas 150000`.
- Per-tx rule report: `skandha_explorer_getTransaction` on the sidecar RPC.
- Frame txs sent before block 8 are rejected ("not supported before the Hegota fork").
- Why not genesis: lighthouse:focil rejects a genesis with Glamsterdam or Hegota already active (`OffsetsAreDecreasing(0)`).
- 1s slots make slot-based windows short in wall time (e.g. EIP-8272 recent roots: 8191 slots ≈ 2.3h).

#### Sidecar frame-tx JSON (`eth_sendFrameTransaction`, all quantities hex)

```json
{
  "chainId": "0x301824",
  "nonceKeys": ["0x0"], "nonceSeq": "0x0",
  "sender": "0x…",
  "frames": [{ "mode": 1, "flags": 3, "target": null,
               "limits": { "execution": "0xea60", "state": "0x0" },
               "value": "0x0", "data": "0x" }],
  "signatures": [{ "scheme": 1, "signer": "0x", "msg": "0x", "signature": "0x<v||r||s>" }],
  "fees": { "maxPriorityFeePerGas": "0x…", "maxFeePerGas": "0x…", "maxFeePerBlobGas": "0x0" },
  "blobVersionedHashes": [], "recentRootReferences": []
}
```

## Sending your own frame tx

Describe the frames in a JSON file ([examples/frames.json](examples/frames.json)) and send them. The tool fills in chain ID, nonce and fees, signs the sig hash with `--key` (default: account #0), and submits to the EL, or to the sidecar in alt-mempool mode.

```json
[
  { "mode": "VERIFY", "flags": 3, "target": null, "gas": 60000 },
  { "mode": "SENDER", "target": "0xE25583099BA105D9ec0A67f5Ae86D90e50036425", "gas": 50000, "value": "1000000000000000000" },
  { "mode": "SENDER", "target": "0x614561D2d143621E126e87831AEF287678B442b8", "gas": 50000, "value": "2000000000000000000", "data": "0xcafe" }
]
```

```bash
./devnet.sh frame-tx --frames examples/frames.json --key 0x<privateKey from funded.json>
./devnet.sh frame-tx --frames my.json --dry-run     # print the signed raw tx, don't send
```

| Field | Meaning |
|---|---|
| `mode` | `VERIFY`, `SENDER`, `DEFAULT`, `ASSERT` (or 0–3) |
| `flags` | default 0; `VERIFY` approving the sender uses 3 (execution + payment) |
| `target` | address, or `null` = tx.sender |
| `gas` | execution gas limit (required) |
| `stateGas` | EIP-8037 state gas; default 600000 (non-VERIFY), 0 (VERIFY) |
| `value` | wei, decimal string; only `SENDER` frames may carry value |
| `data` | hex calldata, default `0x` |

- A plain EOA sender must start with `{"mode":"VERIFY","flags":3,"target":null}`. Its default code checks the SECP256K1 signature the tool adds.
- Contract call: `SENDER` frame with `target` = contract and `data` = ABI calldata (e.g. `cast calldata "transfer(address,uint256)" 0x… 1`).
- Smart-account / PQ sender: the VERIFY frame targets your account contract, which must `APPROVE`. A PQ signature goes in as an `ARBITRARY` (scheme 0) signature. The tool only signs SECP256K1, so use [send-frame-tx.mjs](tools/send-frame-tx.mjs) as the template for building and encoding those txs in your wallet code.
- MetaMask cannot send frame txs (no wallet supports type `0x06` yet). Use it for funding and regular txs only.

Direct use (no `devnet.sh`): `node tools/send-frame-tx.mjs --rpc <EL RPC> --frames my.json --key 0x…`. Add `--format legacy --sidecar <sidecar URL>` for the alt-mempool chain.

### Sponsorship, nonces, batching

| Option | Effect |
|---|---|
| `--sponsor-key 0x…` | Gas sponsorship. Prefix becomes `VERIFY(target null, flags 2)` (sender approves execution) + `VERIFY(target sponsor, flags 1)` (sponsor approves payment). `signatures[1]` is the sponsor's SECP256K1 sig with `signer` = sponsor. Receipt `payer` = sponsor; the sender pays only frame values. |
| `--nonce N` | Explicit nonce (or sequence, with `--nonce-key`) |
| `--nonce-key K` | EIP-8250 keyed nonce: independent lane, sequence starts at 0. The payment VERIFY frame gets 200k state gas for the new slot. |
| `--no-wait` | Print the hash, don't wait for the receipt |

Public mempool limits (default chain, ethrex):

- **1 pending frame tx per sender**, even with different nonce keys or sponsors ("A pending frame transaction from this sender is already in the pool"). Send same-sender txs one after another.
- **1 pending tx per sponsor** (no canonical paymaster yet).
- Txs are simulated against head state, so account nonce n+1 can't queue behind a pending n.
- Validation prefix capped at 100k execution gas (VERIFY frames + 2800 per SECP256K1 sig). Sponsored txs default to 30k per VERIFY frame.

Several pending txs from one sender is what the ERC-8421 alt mempool (`--alt-mempool`) allows (no per-sender cap on keyed nonces).

## Frame tx notes (both profiles)

- Type `0x06`. Minimal EOA tx: `VERIFY` frame (flags `0x3`, target `null` = sender) followed by `SENDER` frame(s).
- An EOA's VERIFY frame runs default code: requires `signatures[0]` = SECP256K1 over the canonical sig hash (`msg` empty, `v` = 0/1, low-s).
- Sig hash = keccak of the tx with empty-`msg` signature bytes elided: replaced by their **length** (default) or by **empty bytes** (alt).
- Frame modes: 0 DEFAULT, 1 VERIFY, 2 SENDER, 3 ASSERT. Signature schemes: 0 ARBITRARY (e.g. PQ, verified in a VERIFY frame), 1 SECP256K1, 2 P256.
- Give SENDER/DEFAULT frames a **state gas** limit (EIP-8037) when they create accounts or storage, or they fail. The demos use 600k.
- Receipts carry `payer` and `frameReceipts[]` (status 0 fail / 1 ok / 2 skipped, gas, logs). A tx with any failed frame still lands, with receipt `status: 0x0`.
- `tools/send-frame-tx.mjs` is a working reference for encoding and signing both formats (`--format legacy`, `--sidecar URL`).

## Funded accounts

- Mnemonic (public, ethereum-package default): `giant issue aisle success illegal bike spike question tent bar rely arctic volcano long crawl hungry vocal artwork sniff fantasy very lucky have athlete`
- Path `m/44'/60'/0'/0/{i}`, indices 0–20, 1,000,000,000 ETH each, same on both profiles and every run.
- Roles: 0–9 user, 10–18 spare, 19 alt-mempool relayer, 20 staking-registry deployer (19/20 reserved only in alt mode).
- Chain ID: `3151908`.

### funded.json

Overwritten on every `up`:

```json
{
  "generatedAt": "…", "profile": "default|alt-mempool", "enclave": "hegota-devnet",
  "chainId": 3151908, "rpcUrl": "…", "explorerUrl": "…", "altMempoolUrl": "…",
  "mnemonic": "…", "derivationPath": "m/44'/60'/0'/0/{index}", "genesisBalanceEth": "1000000000",
  "accounts": [{ "index": 0, "address": "0x…", "privateKey": "0x…", "path": "m/44'/60'/0'/0/0", "role": "user" }]
}
```

## MetaMask

- Network: RPC URL from `info` / `funded.json`, chain ID `3151908`, symbol ETH.
- Accounts: import the mnemonic (replaces that MetaMask's wallet, so use a separate browser profile), then **Add account** ×9 for accounts 1–9. Or import single `privateKey`s via **Import account**.
- After every restart: update the RPC URL (port changes) and run **Settings → Advanced → Clear activity tab data** (chain and nonces reset).

## Restarts

Every `up` deletes and recreates the chain. Balances, nonces, contracts, the Dora index and sidecar state reset. Ports change. Mnemonic, accounts and chain ID stay the same.

## Environment overrides

| Var | Default (default / alt) |
|---|---|
| `ENCLAVE` | `hegota-devnet` |
| `ETHREX_IMAGE`, `LIGHTHOUSE_IMAGE`, `DORA_IMAGE` | see Profiles |
| `SKANDHA_IMAGE` | `pq-wallet/skandha:local` (built from `./skandha` if missing) |
| `HEZE_FORK_EPOCH` | `0` / `1` |
| `GLOAS_FORK_EPOCH` (alt only) | `1` |
| `PRESET` (alt only) | `minimal` |
| `SLOT_DURATION_MS` | `12000` / `1000` |
| `PACKAGE_REF` | see Profiles |
| `EL_EXTRA_PARAMS` | none (space-separated ethrex flags) |
| `WITH_DORA` | `1` |
| `ALT_MEMPOOL` | `0` (same as `--alt-mempool` when `1`) |
| `ALT_MIN_STAKE_WEI` | `1000000000000000000` |

Example: `PRESET=mainnet SLOT_DURATION_MS=6000 ./devnet.sh --alt-mempool`.

## Troubleshooting

- `Frame transactions … not supported before the Hegota fork`: alt chain is not past block 8 yet.
- Tx stuck in MetaMask after a restart: clear activity tab data.
- Dora "Transaction not found" right after sending: indexing lag, or a cached page. Reload a few seconds later.
- Sidecar rejected a tx: the error names the ERC-8421 rule. `./devnet.sh logs skandha` has details.
- Logs: `./devnet.sh logs el|cl|vc|dora|skandha`.
