#!/usr/bin/env bash
# Sends 13 frame transactions to the running devnet (default or alt-mempool):
#   - self-paid:          #0 transfer, #1 batch, #2 revert (one failing frame), #5 custom frames file
#   - sponsored (1 each): #3 by #10, #6 by #7, #8 by #9
#   - same sender, 4 txs on separate EIP-8250 nonce keys: #4 sponsored by #11, #12, #13, + self-paid
#     (alt-mempool chain: all 4 pending at once; default chain: one after another)
#   - same sender, same sponsor, back to back:     #6 by #7, twice more
# Keys come from funded.json (run ./devnet.sh up first).
# ethrex's public mempool (default chain) holds at most ONE pending frame tx per
# sender and one per sponsor, so same-sender txs there are sent sequentially.
# The ERC-8421 sidecar (alt-mempool chain) has no per-sender cap for keyed nonces.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

key() { python3 -I -c 'import json,sys;print(json.load(open("funded.json"))["accounts"][int(sys.argv[1])]["privateKey"])' "$1"; }
addr() { python3 -I -c 'import json,sys;print(json.load(open("funded.json"))["accounts"][int(sys.argv[1])]["address"])' "$1"; }
send() { ./devnet.sh frame-tx "$@" 2>&1 | grep -E "^(tx|mined|  frame)|Error" | sed 's/^/    /'; }

[[ -f funded.json ]] || { echo "funded.json missing: run ./devnet.sh up first" >&2; exit 1; }

echo "== self-paid"
echo "  #0 transfer";        send transfer --key "$(key 0)"
echo "  #1 batch";           send batch    --key "$(key 1)"
echo "  #2 revert";          send revert   --key "$(key 2)"
echo "  #5 examples/frames.json"; send --frames examples/frames.json --key "$(key 5)"

echo "== sponsored"
echo "  #3 paid by #10";     send transfer --key "$(key 3)" --sponsor-key "$(key 10)"
echo "  #6 paid by #7";      send batch    --key "$(key 6)" --sponsor-key "$(key 7)"
echo "  #8 paid by #9";      send transfer --key "$(key 8)" --sponsor-key "$(key 9)"

MODE="$(cat .devnet/mode 2>/dev/null || echo default)"
WAIT=(); [[ "$MODE" == "alt" ]] && WAIT=(--no-wait)
echo "== same sender #4, 4 txs on separate nonce keys: 3 sponsors + self-paid ($([[ "$MODE" == alt ]] && echo "all pending at once" || echo "sequential: public mempool allows 1 pending per sender"))"
RPC="$(python3 -I -c 'import json;print(json.load(open("funded.json"))["rpcUrl"])')"
KEYBASE="$(date +%s)"   # fresh nonce-key lanes on every run (each starts at sequence 0)
HASHES=()
for i in 0 1 2 3; do
  case $i in
    0) extra=(--sponsor-key "$(key 11)"); who="paid by #11" ;;
    1) extra=(--sponsor-key "$(key 12)"); who="paid by #12" ;;
    2) extra=(--sponsor-key "$(key 13)"); who="paid by #13" ;;
    3) extra=(); who="self-paid" ;;
  esac
  h="$(./devnet.sh frame-tx transfer --key "$(key 4)" --nonce-key $((KEYBASE + i)) "${WAIT[@]+"${WAIT[@]}"}" "${extra[@]+"${extra[@]}"}" 2>&1 \
       | grep -oE '^tx +0x[0-9a-f]+' | awk '{print $2}' || true)"
  echo "  nonce key $((KEYBASE + i)) $who -> ${h:-REJECTED}"
  [[ -n "$h" ]] && HASHES+=("$h")
done
for h in "${HASHES[@]}"; do
  rc=""
  for _ in $(seq 1 60); do
    rc="$(cast receipt "$h" --rpc-url "$RPC" --json 2>/dev/null || true)"
    [[ -n "$rc" ]] && break; sleep 2
  done
  if [[ -n "$rc" ]]; then
    echo "$rc" | python3 -I -c 'import sys,json; r=json.load(sys.stdin); print("    %s block %d status %s payer %s" % (r["transactionHash"], int(r["blockNumber"], 16), r["status"], r.get("payer")))'
  else
    echo "    $h not mined"
  fi
done

echo "== same sender #6, same sponsor #7, back to back"
send transfer --key "$(key 6)" --sponsor-key "$(key 7)"
send revert   --key "$(key 6)" --sponsor-key "$(key 7)"
