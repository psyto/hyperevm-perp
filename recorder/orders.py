"""Order recorder: what happened to each CoreWriter order, by cloid, as this client observed it.

Sends TestnetPricedPerp.rawIoc orders one at a time, polls the info API's orderStatus for each
until a terminal status, checks the outcome and the pool's Core position are what the kind
expects, and only then acknowledges. Appends to recorder/data/orders.jsonl: a "sent" line as soon
as the transaction hash is known, then one "order" line with the block, every status change,
Core's own order and status timestamps, and the position before and after.

    python3 recorder/orders.py run <pool> <kind> <n>
    python3 recorder/orders.py status <pool>     # after a stop: pendingCloid, its status, open orders, position
    python3 recorder/orders.py unwind <pool>     # close a position a stopped fill run left (pendingCloid must be 0)

Kinds (0.00015 BTC, about 12 USD):
    margin  buy 1% through the oracle, pool perp account empty   -> perpMarginRejected, no fill
    miss    buy 15% under the oracle                            -> iocCancelRejected, no fill
    fill    buy then sell 1% through the oracle, alternating    -> filled, position +-0.00015 (n even)

Fails closed (review rec1): any status outside the terminal list, an unexpected outcome or
position change, a reverted or missing receipt, or a pool that already has an order pending or
open stops the run and leaves the order unacknowledged for a person to look at.

The timings are when this client first saw each status (local monotonic clock from the receipt,
polled every POLL s, plus API latency), not CoreWriter's own delay; Core's order and status
timestamps are recorded separately. HyperEVM blocks are final once produced (HyperBFT), so a
receipt is not reorged. Reads the keeper key from KEY_FILE (default ~/.hyperevm-amm-testnet.key,
must be owner-only). Testnet (chain 998) only.
"""
import json
import os
import stat
import subprocess
import sys
import time
import urllib.request

RPC = "https://rpc.hyperliquid-testnet.xyz/evm"
INFO = "https://api.hyperliquid-testnet.xyz/info"
COIN = "BTC"
SZ8 = 15_000  # 0.00015 BTC
SZ = "0.00015"
POLL = 0.25  # orderStatus is weight 2: 8/s of the 1,200/min budget
RECEIPT_POLL = 0.7  # EVM RPC allows 100 requests/min
GIVE_UP = 60
TERMINAL = {"filled", "canceled", "rejected", "marginCanceled", "iocCancelRejected", "perpMarginRejected",
            "badAloPxRejected", "minTradeNtlRejected", "reduceOnlyRejected", "reduceOnlyCanceled",
            "selfTradeCanceled", "openInterestCapCanceled", "siblingFilledCanceled", "delistedCanceled",
            "liquidatedCanceled", "scheduledCancel", "tickRejected", "insufficientSpotBalanceRejected",
            "oracleRejected", "perpMaxPositionRejected", "positionIncreaseAtOpenInterestCapRejected",
            "positionFlipAtOpenInterestCapRejected", "tooAggressiveAtOpenInterestCapRejected",
            "openInterestIncreaseRejected", "vaultWithdrawalCanceled"}
EXPECT = {"margin": "perpMarginRejected", "miss": "iocCancelRejected", "fill": "filled"}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "orders.jsonl")


def post(url, body, tries=4):
    """POST JSON, retrying transient failures with backoff (rate limits included)."""
    for i in range(tries):
        try:
            req = urllib.request.Request(url, json.dumps(body).encode(), {"content-type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as r:
                return json.load(r)
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(1.5 * 2**i)


def rpc(method, *params):
    r = post(RPC, {"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)})
    if "error" in r:
        raise RuntimeError(r["error"])
    return r["result"]


def info(body):
    return post(INFO, body)


def cast(*args, env=None):
    return subprocess.run(["cast", *args], env=env, capture_output=True, text=True, check=True).stdout.strip()


def position(pool):
    s = info({"type": "clearinghouseState", "user": pool})
    szi = next((p["position"]["szi"] for p in s["assetPositions"] if p["position"]["coin"] == COIN), "0")
    return {"szi": float(szi), "account": float(s["marginSummary"]["accountValue"])}


def oracle():
    meta, ctxs = info({"type": "metaAndAssetCtxs"})
    return float(ctxs[[a["name"] for a in meta["universe"]].index(COIN)]["oraclePx"])


def write(row):
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")


def stop(row, why):
    row["stopped"] = why
    write(row)
    sys.exit("stopped, order left unacknowledged: " + why)


def track(pool, cloid, t0):
    """Poll orderStatus until a terminal status or GIVE_UP. Returns (final, changes, last response)."""
    oid = "0x%032x" % cloid
    changes, last, r = [], None, None
    while time.monotonic() - t0 < GIVE_UP:
        t = time.monotonic()
        try:
            r = info({"type": "orderStatus", "user": pool, "oid": oid})
            st = r["order"]["status"] if r.get("status") == "order" else "api:" + str(r.get("status"))
        except Exception as e:  # a failed read is data too
            st = "error:" + repr(e)[:80]
        if st != last:
            changes.append([round(t - t0, 3), st])
            last = st
        if st in TERMINAL:
            return st, changes, r
        time.sleep(max(0.0, POLL - (time.monotonic() - t)))
    return None, changes, r


def send(pool, env, sig, *args):
    """cast send --async; the hash is written before waiting so a crash leaves a trace."""
    sent_at = time.time()
    tx = cast("send", "--async", "-r", RPC, pool, sig, *map(str, args), env=env)
    write({"line": "sent", "pool": pool, "sig": sig, "args": list(map(str, args)), "tx": tx, "sent_at": round(sent_at, 3)})
    deadline = time.monotonic() + 60
    while True:
        try:
            rc = rpc("eth_getTransactionReceipt", tx)
        except Exception:  # keep waiting to the deadline: the transaction is already out
            rc = None
        if rc is not None:
            break
        if time.monotonic() > deadline:
            sys.exit("no receipt for %s after 60 s: check pendingCloid before anything else" % tx)
        time.sleep(RECEIPT_POLL)
    if rc["status"] != "0x1":
        sys.exit("reverted: " + tx)
    return tx, sent_at, rc


def key_env():
    kf = os.path.expanduser(os.environ.get("KEY_FILE", "~/.hyperevm-amm-testnet.key"))
    if os.stat(kf).st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        sys.exit("key file must be owner-only")
    return dict(os.environ, ETH_PRIVATE_KEY=open(kf).read().strip())


def run(pool, kind, n):
    pool = pool.lower()
    if kind == "fill" and n % 2:
        sys.exit("fill needs an even n so the pool ends flat")
    if int(cast("chain-id", "-r", RPC)) != 998:
        sys.exit("not testnet")
    env = key_env()
    raw_topic = cast("keccak", "RawOrder(uint128,bool,uint64,uint64)")
    want = EXPECT[kind]
    for i in range(n):
        # preflight: nothing pending on the contract, nothing open on Core, the right start
        if int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0]) != 0:
            sys.exit("pendingCloid is set: resolve it by hand first")
        if info({"type": "openOrders", "user": pool}):
            sys.exit("pool has open orders on Core")
        before = position(pool)
        is_buy = kind != "fill" or i % 2 == 0
        if kind == "margin" and before["account"] != 0:
            sys.exit("margin needs an empty perp account")
        if kind in ("margin", "miss") and before["szi"] != 0:
            sys.exit("needs a flat position")
        if kind == "fill" and before["szi"] != (0 if is_buy else float(SZ)):
            sys.exit("fill expects position %s before order %d, have %s" % (0 if is_buy else SZ, i, before["szi"]))
        o = oracle()
        px = round({"margin": o * 1.01, "miss": o * 0.85, "fill": o * (1.01 if is_buy else 0.99)}[kind])
        row = {"line": "order", "kind": kind, "i": i, "pool": pool, "is_buy": is_buy, "limit": px, "sz8": SZ8,
               "oracle": o, "pos_before": before}
        # whole dollars stay within BTC's 5 significant figures and 1 decimal
        tx, sent_at, rc = send(pool, env, "rawIoc(bool,uint64,uint64)", str(is_buy).lower(), px * 10**8, SZ8)
        t0 = time.monotonic()
        row.update({"tx": tx, "sent_at": round(sent_at, 3), "receipt_at": round(time.time(), 3),
                    "block": int(rc["blockNumber"], 16), "block_hash": rc["blockHash"]})
        lg = next(l for l in rc["logs"] if l["topics"][0] == raw_topic)
        cloid = int(lg["topics"][1], 16)
        row["log_index"] = int(lg["logIndex"], 16)
        row["block_ts"] = int(rpc("eth_getBlockByNumber", rc["blockNumber"], False)["timestamp"], 16)
        final, changes, r = track(pool, cloid, t0)
        want_delta = 0 if kind != "fill" else (float(SZ) if is_buy else -float(SZ))
        for _ in range(4):  # the position read can trail orderStatus by a moment
            after = position(pool)
            if round(after["szi"] - before["szi"], 8) == want_delta:
                break
            time.sleep(0.5)
        o_ = (r or {}).get("order", {}).get("order", {})
        row.update({"cloid": "0x%032x" % cloid, "changes": changes, "final": final, "response": r,
                    "core_order_ts": o_.get("timestamp"), "core_status_ts": (r or {}).get("order", {}).get("statusTimestamp"),
                    "pos_after": after})
        print(json.dumps({k: row[k] for k in ("kind", "i", "cloid", "block", "changes", "final")}), flush=True)
        if final is None:
            stop(row, "no terminal status in %d s" % GIVE_UP)
        if (o_.get("cloid"), o_.get("coin"), o_.get("side"), o_.get("origSz"), float(o_.get("limitPx", 0))) != \
                (row["cloid"], COIN, "B" if is_buy else "A", SZ, float(px)):
            stop(row, "order does not match what was sent")
        if final != want:
            stop(row, "expected %s, got %s" % (want, final))
        delta = round(after["szi"] - before["szi"], 8)
        if delta != want_delta:
            stop(row, "position moved by %s" % delta)
        write(row)
        send(pool, env, "acknowledge(uint128)", cloid)


def status(pool):
    """Everything needed to recover by hand after a stop."""
    pool = pool.lower()
    pc = int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0])
    print("pendingCloid", "0x%032x" % pc)
    if pc:
        print("orderStatus", json.dumps(info({"type": "orderStatus", "user": pool, "oid": "0x%032x" % pc})))
    print("openOrders", json.dumps(info({"type": "openOrders", "user": pool})))
    print("position", position(pool))


def unwind(pool):
    """Close a leftover BTC position with one IOC 1% through the oracle (after a stopped fill run)."""
    pool = pool.lower()
    if int(cast("chain-id", "-r", RPC)) != 998:
        sys.exit("not testnet")
    if int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0]) != 0:
        sys.exit("pendingCloid is set: check `status` and acknowledge by hand first")
    if info({"type": "openOrders", "user": pool}):
        sys.exit("pool has open orders on Core")
    before = position(pool)
    if before["szi"] == 0:
        sys.exit("already flat")
    is_buy = before["szi"] < 0
    sz8 = int(round(abs(before["szi"]) * 10**8))
    px = round(oracle() * (1.01 if is_buy else 0.99))
    tx, _, rc = send(pool, key_env(), "rawIoc(bool,uint64,uint64)", str(is_buy).lower(), px * 10**8, sz8)
    raw_topic = cast("keccak", "RawOrder(uint128,bool,uint64,uint64)")
    cloid = int(next(l for l in rc["logs"] if l["topics"][0] == raw_topic)["topics"][1], 16)
    final, changes, r = track(pool, cloid, time.monotonic())
    after = position(pool)
    write({"line": "unwind", "pool": pool, "tx": tx, "cloid": "0x%032x" % cloid, "changes": changes,
           "final": final, "response": r, "pos_before": before, "pos_after": after})
    print("unwind", final, after)
    if final == "filled" and after["szi"] == 0:
        send(pool, key_env(), "acknowledge(uint128)", cloid)
    else:
        sys.exit("not flat: left unacknowledged, check `status`")


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] in ("status", "unwind"):
        {"status": status, "unwind": unwind}[a[0]](a[1])
    elif len(a) == 4 and a[0] == "run" and a[2] in EXPECT:
        run(a[1], a[2], int(a[3]))
    else:
        sys.exit(__doc__)
