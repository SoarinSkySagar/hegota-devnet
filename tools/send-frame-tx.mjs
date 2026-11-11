#!/usr/bin/env node
// Send a demo EIP-8141 frame transaction (type 0x06) from an EOA to the devnet.
//
// Shape (matches ethrex bogota-devnet-2):
//   0x06 || rlp([chain_id, nonce_keys, nonce_seq, sender, frames, signatures,
//                [max_fee, max_priority_fee_per_gas], blob_versioned_hashes])
//   frame     = [mode, flags, target|empty, [execution_gas, state_gas], value, data]
//   signature = [scheme, signer|empty, msg, signature]
//
// The EOA authorises itself with a VERIFY frame (flags 0x3 = approve execution +
// payment) whose default code checks signatures[0] is a SECP256K1 sig by sender
// over the sig_hash (signature bytes elided to their length while hashing).
//
// --format legacy: the older layout spoken by ethrex's eip8141-tracer build and
// the ERC-8421 sidecar (--alt-mempool profile):
//   0x06 || rlp([chain_id, nonce_keys, nonce_seq, sender, frames, signatures,
//                [max_priority_fee_per_gas, max_fee_per_gas, max_fee_per_blob_gas],
//                blob_versioned_hashes, recent_root_references])
//   nonce_keys = [0] for the account nonce; sig_hash elides signature bytes to empty.
// --sidecar URL: submit through the ERC-8421 alt mempool (eth_sendFrameTransaction)
// instead of the EL's public mempool.
//
// Usage:
//   node send-frame-tx.mjs [--rpc URL] [--key HEX] [--demo transfer|batch|revert]
//                          [--format current|legacy] [--sidecar URL] [--dry-run]
//                          [--verify-gas N]  (VERIFY frame gas; >100000 breaks ERC-8421 BUDGET-010)
//                          [--frames FILE.json]  (your own frames instead of a demo)
//                          [--sponsor-key HEX]   (another account pays the gas)
//                          [--nonce N] [--nonce-key K] [--no-wait]
//
// --sponsor-key: gas sponsorship. The validation prefix becomes
//   [VERIFY target=null flags=2 (sender approves execution),
//    VERIFY target=sponsor flags=1 (sponsor approves payment)]
// and signatures = [sender SECP256K1 (signer empty), sponsor SECP256K1 (signer = sponsor)],
// both over the same sig hash. With --frames, write those two VERIFY frames yourself.
// ethrex's public mempool holds at most one pending tx per sponsor.
// --nonce: explicit nonce / sequence.
// --nonce-key K: EIP-8250 keyed nonce. Each key is an independent lane (sequence
// starts at 0, use --nonce for later ones), so one sender can have several txs
// pending at once. ethrex's public mempool simulates against head state, so
// queuing account-nonce n+1 behind a pending n is rejected; use distinct keys.
// The payment-approving VERIFY frame gets 200k state gas (new keyed-nonce slot).
// --no-wait: print the hash and exit instead of waiting for the receipt.
//
// --frames file: a JSON array of frames, in order. Fields:
//   mode      "VERIFY" | "SENDER" | "DEFAULT" | "ASSERT" (or 0-3)
//   flags     number, default 0 (VERIFY approving the sender: 3 = execution + payment)
//   target    address, or null for tx.sender
//   gas       execution gas limit
//   stateGas  EIP-8037 state gas limit (default 600000 for non-VERIFY frames, 0 for VERIFY)
//   value     wei, as a decimal string (only SENDER frames may carry value)
//   data      hex calldata, default "0x"
// The tx is signed with --key (SECP256K1 over the sig hash), so a plain EOA sender
// needs a VERIFY frame with target null and flags 3 first.
import { readFileSync } from "node:fs";
import { secp256k1 } from "@noble/curves/secp256k1";
import { keccak_256 } from "@noble/hashes/sha3";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => {
    if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1]?.startsWith("--") || all[i + 1] === undefined ? true : all[i + 1]]);
    return acc;
  }, []),
);
const RPC = args.rpc || process.env.RPC_URL || "http://127.0.0.1:8545";
// Public ethereum-package devnet key; never use elsewhere.
const KEY = (args.key || process.env.PRIVATE_KEY || "bcdf20249abf0ed6d944c0288fad489e33f66b3960d9e6229c1cd214ed3bbe31").replace(/^0x/, "");
const DEMO = args.demo || "transfer";
const LEGACY = args.format === "legacy";
const SIDECAR = typeof args.sidecar === "string" ? args.sidecar : null;
const NONCE_KEY = args["nonce-key"] !== undefined && args["nonce-key"] !== true ? BigInt(args["nonce-key"]) : null;
const SPONSOR_KEY = typeof args["sponsor-key"] === "string" ? args["sponsor-key"].replace(/^0x/, "") : null;

// ---------- minimal RLP ----------
const concat = (...arrs) => {
  const out = new Uint8Array(arrs.reduce((n, a) => n + a.length, 0));
  let o = 0;
  for (const a of arrs) { out.set(a, o); o += a.length; }
  return out;
};
const intToBytes = (n) => {
  n = BigInt(n);
  if (n === 0n) return new Uint8Array();
  let h = n.toString(16);
  if (h.length % 2) h = "0" + h;
  return hexToBytes(h);
};
const lenPrefix = (len, short, long) => {
  if (len < 56) return Uint8Array.of(short + len);
  const l = intToBytes(len);
  return concat(Uint8Array.of(long + l.length), l);
};
function rlp(x) {
  if (Array.isArray(x)) {
    const body = concat(...x.map(rlp));
    return concat(lenPrefix(body.length, 0xc0, 0xf7), body);
  }
  const b = x instanceof Uint8Array ? x : intToBytes(x);
  if (b.length === 1 && b[0] < 0x80) return b;
  return concat(lenPrefix(b.length, 0x80, 0xb7), b);
}
const hex = (b) => "0x" + bytesToHex(b);
const addr = (a) => (a ? hexToBytes(a.replace(/^0x/, "")) : new Uint8Array());
const data = (d) => hexToBytes((d || "0x").replace(/^0x/, ""));

// ---------- rpc ----------
let id = 0;
async function rpc(method, params = [], url = RPC) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}${j.error.data ? " " + JSON.stringify(j.error.data) : ""}`);
  return j.result;
}

// ---------- build ----------
const MODE = { DEFAULT: 0, VERIFY: 1, SENDER: 2 };
const priv = hexToBytes(KEY);
const pub = secp256k1.getPublicKey(priv, false).slice(1);
const sender = "0x" + bytesToHex(keccak_256(pub).slice(-20));
const toAddress = (k) => "0x" + bytesToHex(keccak_256(secp256k1.getPublicKey(hexToBytes(k), false).slice(1)).slice(-20));
const sponsor = SPONSOR_KEY ? toAddress(SPONSOR_KEY) : null;

const ALICE = "0x000000000000000000000000000000000000a11c";
const BOB = "0x0000000000000000000000000000000000000b0b";
const ONE_GWEI = 10n ** 9n;

// EIP-8037: creating accounts / storage is paid from a separate per-frame
// state-gas budget, so SENDER/DEFAULT frames that may touch new state get one.
const STATE_GAS = 600_000n;

const MODE_NAMES = { DEFAULT: 0, VERIFY: 1, SENDER: 2, ASSERT: 3 };
function fileFrames(path) {
  const list = JSON.parse(readFileSync(path, "utf8"));
  if (!Array.isArray(list) || list.length === 0) throw new Error(`${path}: expected a non-empty JSON array of frames`);
  return list.map((f, i) => {
    const mode = typeof f.mode === "string" ? MODE_NAMES[f.mode.toUpperCase()] : Number(f.mode);
    if (mode === undefined || Number.isNaN(mode)) throw new Error(`${path}: frame ${i} has unknown mode ${f.mode}`);
    if (f.gas === undefined) throw new Error(`${path}: frame ${i} needs "gas"`);
    const frame = {
      mode,
      flags: Number(f.flags ?? 0),
      target: f.target ?? null,
      gas: BigInt(f.gas),
      value: BigInt(f.value ?? 0),
      data: f.data ?? "0x",
    };
    if (f.stateGas !== undefined) frame.stateGas = BigInt(f.stateGas);
    return frame;
  });
}

function demoFrames() {
  if (typeof args.frames === "string") return fileFrames(args.frames);
  // The public mempool caps the whole validation prefix (VERIFY frames + 2800 per
  // SECP256K1 signature) at MAX_VERIFY_GAS = 100000, so sponsored txs get 30k each.
  const vgas = BigInt(args["verify-gas"] ?? (sponsor ? 30_000 : 60_000));
  const prefix = sponsor
    ? [
        { mode: MODE.VERIFY, flags: 0x2, target: null, gas: vgas, value: 0n, data: "0x" },    // sender: execution
        { mode: MODE.VERIFY, flags: 0x1, target: sponsor, gas: vgas, value: 0n, data: "0x" }, // sponsor: payment
      ]
    : [{ mode: MODE.VERIFY, flags: 0x3, target: null, gas: vgas, value: 0n, data: "0x" }];
  // Payment APPROVE writes the new keyed-nonce slot; it draws on that frame's state gas.
  if (NONCE_KEY !== null) prefix[prefix.length - 1].stateGas = 200_000n;
  return [...prefix, ...demoBody()];
}

function demoBody() {
  switch (DEMO) {
    case "transfer":
      return [{ mode: MODE.SENDER, flags: 0, target: ALICE, gas: 50_000n, value: 10n ** 15n, data: "0x" }];
    case "batch":
      return [
        { mode: MODE.SENDER, flags: 0, target: ALICE, gas: 50_000n, value: 10n ** 15n, data: "0x" },
        { mode: MODE.SENDER, flags: 0, target: BOB, gas: 50_000n, value: 2n * 10n ** 15n, data: "0xdeadbeef" },
        { mode: MODE.DEFAULT, flags: 0, target: BOB, gas: 30_000n, value: 0n, data: "0x1234" },
      ];
    case "revert":
      // SENDER frame that runs out of gas on a precompile call (ecrecover needs 3000),
      // so it fails while the tx itself stays valid.
      return [
        { mode: MODE.SENDER, flags: 0, target: ALICE, gas: 50_000n, value: 10n ** 15n, data: "0x" },
        { mode: MODE.SENDER, flags: 0, target: "0x0000000000000000000000000000000000000001", gas: 100n, value: 0n, data: "0x" + "00".repeat(128) },
      ];
    default:
      throw new Error(`unknown --demo ${DEMO} (transfer|batch|revert)`);
  }
}
const withStateGas = (fs) => fs.map((f) => (f.mode === MODE.VERIFY ? f : { stateGas: STATE_GAS, ...f }));

function encode(tx, sigs) {
  if (LEGACY) {
    return concat(
      Uint8Array.of(0x06),
      rlp([
        tx.chainId,
        tx.nonceKeys,
        tx.nonceSeq,
        addr(tx.sender),
        tx.frames.map((f) => [f.mode, f.flags, addr(f.target), [f.gas, f.stateGas ?? 0n], f.value, data(f.data)]),
        sigs.map((s) => [s.scheme, addr(s.signer), s.msg, s.signature]),
        [tx.maxPriority, tx.maxFeePerGas, 0n],
        [],
        [],
      ]),
    );
  }
  return concat(
    Uint8Array.of(0x06),
    rlp([
      tx.chainId,
      tx.nonceKeys,
      tx.nonceSeq,
      addr(tx.sender),
      tx.frames.map((f) => [f.mode, f.flags, addr(f.target), [f.gas, f.stateGas ?? 0n], f.value, data(f.data)]),
      sigs.map((s) => [s.scheme, addr(s.signer), s.msg, s.signature]),
      [tx.maxFee, tx.maxPriority],
      [],
    ]),
  );
}

const chainId = BigInt(await rpc("eth_chainId"));
const nonce = args.nonce !== undefined && args.nonce !== true
  ? BigInt(args.nonce)
  : NONCE_KEY !== null
    ? 0n
    : BigInt(await rpc("eth_getTransactionCount", [sender, "pending"]));
const baseFee = BigInt((await rpc("eth_getBlockByNumber", ["latest", false])).baseFeePerGas || "0x1");
const frames = withStateGas(demoFrames());
const totalGas = frames.reduce((n, f) => n + f.gas + (f.stateGas ?? 0n), 0n) + 200_000n; // + intrinsic/sig/calldata headroom
const maxPriority = ONE_GWEI;
const maxFeePerGas = baseFee * 2n + maxPriority;
const tx = {
  chainId,
  // current: empty => account nonce. legacy: explicit key 0 => account nonce (EIP-8250).
  nonceKeys: NONCE_KEY !== null ? [NONCE_KEY] : LEGACY ? [0n] : [],
  nonceSeq: nonce,
  sender,
  frames,
  maxFee: totalGas * maxFeePerGas,
  maxFeePerGas,
  maxPriority,
};

// sig_hash: signature bytes replaced by their length (65 for secp256k1) in the
// current layout, by empty bytes in the legacy one.
const elided = LEGACY ? new Uint8Array() : intToBytes(65);
// signatures[0] = sender (signer empty -> tx.sender); signatures[1] = sponsor (explicit signer).
const signers = [{ key: KEY, signer: null }, ...(sponsor ? [{ key: SPONSOR_KEY, signer: sponsor }] : [])];
const sigHash = keccak_256(encode(tx, signers.map((s) => ({ scheme: 1, signer: s.signer, msg: new Uint8Array(), signature: elided }))));
const signVrs = (k) => {
  const sg = secp256k1.sign(sigHash, hexToBytes(k), { lowS: true });
  return concat(Uint8Array.of(sg.recovery), hexToBytes(sg.r.toString(16).padStart(64, "0")), hexToBytes(sg.s.toString(16).padStart(64, "0")));
};
const sigs = signers.map((s) => ({ scheme: 1, signer: s.signer, msg: new Uint8Array(), signature: signVrs(s.key) }));
const vrs = sigs[0].signature;
const raw = hex(encode(tx, sigs));

console.log(`rpc      ${RPC}`);
console.log(`sender   ${sender}  nonce ${nonce}${NONCE_KEY !== null ? ` (key ${NONCE_KEY})` : ""}`);
if (sponsor) console.log(`sponsor  ${sponsor}`);
console.log(`frames   ${typeof args.frames === "string" ? args.frames : `demo ${DEMO}`} (${frames.length} frames)`);
console.log(`sig_hash ${hex(sigHash)}`);

if (!SIDECAR) {
  try {
    const sim = await rpc("ethrex_simulateFrameTransaction", [raw]);
    console.log("simulate", JSON.stringify(sim).slice(0, 300));
  } catch (e) {
    console.log(`simulate unavailable: ${e.message}`);
  }
}
if (args["dry-run"]) { console.log(`raw      ${raw}`); process.exit(0); }

const h = (n) => "0x" + BigInt(n).toString(16);
let hash;
if (SIDECAR) {
  // ERC-8421 alt mempool: JSON frame transaction, all quantities hex.
  const body = {
    chainId: h(tx.chainId),
    nonceKeys: tx.nonceKeys.map(h),
    nonceSeq: h(tx.nonceSeq),
    sender,
    frames: frames.map((f) => ({
      mode: f.mode, flags: f.flags, target: f.target,
      limits: { execution: h(f.gas), state: h(f.stateGas ?? 0n) },
      value: h(f.value), data: f.data || "0x",
    })),
    signatures: sigs.map((s) => ({ scheme: 1, signer: s.signer ?? "0x", msg: "0x", signature: hex(s.signature) })),
    fees: { maxPriorityFeePerGas: h(maxPriority), maxFeePerGas: h(maxFeePerGas), maxFeePerBlobGas: "0x0" },
    blobVersionedHashes: [],
    recentRootReferences: [],
  };
  console.log(`sidecar  ${SIDECAR}`);
  hash = await rpc("eth_sendFrameTransaction", [body], SIDECAR);
  console.log(`admitted ${hash}  (ERC-8421 alt mempool)`);
} else {
  hash = await rpc("eth_sendRawTransaction", [raw]);
}
console.log(`tx       ${hash}`);
if (args["no-wait"]) process.exit(0);
for (let i = 0; i < 60; i++) {
  const rc = await rpc("eth_getTransactionReceipt", [hash]);
  if (rc) {
    console.log(`mined    block ${BigInt(rc.blockNumber)} status ${rc.status} payer ${rc.payer ?? "-"}`);
    (rc.frameReceipts || []).forEach((f, i) =>
      console.log(`  frame ${i}: status ${["fail", "ok", "skipped"][Number(f.status)] ?? f.status} gas ${BigInt(f.gasUsed)}`));
    process.exit(0);
  }
  await new Promise((r) => setTimeout(r, 2000));
}
console.log("not mined after 120s");
process.exit(1);
