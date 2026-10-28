"""Order recorder: what happened to each CoreWriter order, by cloid, as this client observed it.

Sends TestnetPricedPerp.rawIoc orders one at a time, polls the info API's orderStatus for each
until a terminal status, checks the outcome and the pool's Core position are what the kind
expects, and only then acknowledges. Appends to recorder/data/orders.jsonl: a "sent" line as soon
as the transaction hash is known, then one "order" line with the block, every status change,
Core's own order and status timestamps, and the position before and after.

    python3 recorder/orders.py run <pool> <kind> <n>
    python3 recorder/orders.py status <pool>     # after a stop: pendingCloid, its status, open orders, position
    python3 recorder/orders.py unwind <pool>     # close a leftover position with one reduce-only IOC (pendingCloid must be 0)

Step 5 (docs/step5-close-from-evm-spec.md), against a deployment with rawIocReduceOnly:
    python3 recorder/orders.py g1 <pool>                  # gate G1: do historical 0x800 reads work?
    python3 recorder/orders.py step5 <pool> <cycles> [seed]   # next cycles of the shuffled plan
    python3 recorder/orders.py lag <pool> <n>             # paired precompile / info API readings
    python3 recorder/orders.py book <minutes> <hours> <coin...>   # mainnet l2Book, read only

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
# RawOrder gained a reduceOnly field with rawIocReduceOnly (step 5); older deployments emit the first
RAW_SIGS = ("RawOrder(uint128,bool,uint64,uint64)", "RawOrder(uint128,bool,uint64,uint64,bool)")


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


def px5(x):
    """A BTC perp price in whole units within 5 significant figures (1 decimal is allowed, unused)."""
    d = len(str(int(x)))
    step = 10 ** max(0, d - 5)
    return int(round(x / step)) * step


def raw_topics():
    return {cast("keccak", sig) for sig in RAW_SIGS}


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
    topics = raw_topics()
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
        px = px5({"margin": o * 1.01, "miss": o * 0.85, "fill": o * (1.01 if is_buy else 0.99)}[kind])
        row = {"line": "order", "kind": kind, "i": i, "pool": pool, "is_buy": is_buy, "limit": px, "sz8": SZ8,
               "oracle": o, "pos_before": before}
        tx, sent_at, rc = send(pool, env, "rawIoc(bool,uint64,uint64)", str(is_buy).lower(), px * 10**8, SZ8)
        t0 = time.monotonic()
        row.update({"tx": tx, "sent_at": round(sent_at, 3), "receipt_at": round(time.time(), 3),
                    "block": int(rc["blockNumber"], 16), "block_hash": rc["blockHash"]})
        lg = next(l for l in rc["logs"] if l["topics"][0] in topics)
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
    """Close a leftover BTC position with one reduce-only IOC 1% through the oracle. Reduce-only
    (review s5 #3): if Core liquidated, ADL'd or otherwise changed the position after the read
    below, this order can only shrink it, never increase or flip it."""
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
    px = px5(oracle() * (1.01 if is_buy else 0.99))
    tx, _, rc = send(pool, key_env(), "rawIocReduceOnly(bool,uint64,uint64)", str(is_buy).lower(), px * 10**8, sz8)
    topics = raw_topics()
    cloid = int(next(l for l in rc["logs"] if l["topics"][0] in topics)["topics"][1], 16)
    if int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0]) != cloid:
        sys.exit("pendingCloid is not the cloid just sent: left as is, check `status`")
    final, changes, r = track(pool, cloid, time.monotonic())
    for _ in range(4):  # the position read can trail orderStatus by a moment
        after = position(pool)
        if after["szi"] == 0:
            break
        time.sleep(0.5)
    o_ = (r or {}).get("order", {}).get("order", {})
    same = (o_.get("cloid"), o_.get("coin"), o_.get("side"), lots(o_.get("origSz", "0"))) == \
        ("0x%032x" % cloid, COIN, "B" if is_buy else "A", sz8 // 10**(8 - SZ_DEC))
    write({"line": "unwind", "pool": pool, "tx": tx, "cloid": "0x%032x" % cloid, "changes": changes,
           "final": final, "response": r, "pos_before": before, "pos_after": after})
    print("unwind", final, after)
    if final == "filled" and after["szi"] == 0 and same and \
            int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0]) == cloid:
        send(pool, key_env(), "acknowledge(uint128)", cloid)
    else:
        sys.exit("not flat: left unacknowledged, check `status`")


# ---------------------------------------------------------------- step 5
# docs/step5-close-from-evm-spec.md (review s5h APPROVE). Every close and recovery close is
# reduce-only. Sizes are integer lots (BTC szDecimals 5: 0.00015 BTC = 15 lots).

import random
import threading

SZ_DEC = 5
LOTS = 15
POSITION_PC = "0x0000000000000000000000000000000000000800"
ORACLE_PC = "0x0000000000000000000000000000000000000807"
MARGIN_PC = "0x000000000000000000000000000000000000080f"
PERP = 3  # testnet BTC
# The public EVM RPC allows about 100 requests a minute; a batch of three probably counts as three.
# 2.5 s (72/min) leaves room for order5's own calls (review s5i1 #3); the first session's error
# count shows whether a shorter period holds (STEP5_LIVE_POLL). Pinned reads (up to 3 calls) run
# after the stream at the same pace. A bracket that spans a failed read is marked degraded.
LIVE_POLL = float(os.environ.get("STEP5_LIVE_POLL", "2.5"))
PINNED_POLL = 2.5
LIVE_FOR = 30
LIVE_MAX = 90
FILLS_EVERY = 2
FILLS_FOR = 30
G1_FILE = os.path.join(os.path.dirname(OUT), "g1.json")
PLAN_FILE = os.path.join(os.path.dirname(OUT), "step5_plan.json")
STEP5_OUT = os.path.join(os.path.dirname(OUT), "step5.jsonl")
BOOK_OUT = os.path.join(os.path.dirname(OUT), "book.jsonl")
MAINNET_INFO = "https://api.hyperliquid.xyz/info"
PLAN = {("close-fill", 1): 30, ("close-fill", -1): 30, ("close-tight", 1): 10, ("close-tight", -1): 10,
        ("close-partial", 1): 5, ("close-partial", -1): 5, ("close-flat", 1): 5, ("close-flat", -1): 5,
        ("close-over", 1): 5, ("close-over", -1): 5, ("close-wrongside", 1): 5, ("close-wrongside", -1): 5}


def write5(row, path=None):
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(path or STEP5_OUT, "a") as f:
        f.write(json.dumps(row, separators=(",", ":")) + "\n")


def lots(s):
    """Exact integer lots from a decimal size string, no floats (review s5d #1)."""
    s = s.strip()
    neg = s.startswith("-")
    whole, _, frac = s.lstrip("+-").partition(".")
    if len(frac) > SZ_DEC and int(frac[SZ_DEC:]) != 0:
        raise ValueError("finer than a lot: " + s)
    n = int(whole or "0") * 10**SZ_DEC + int((frac + "0" * SZ_DEC)[:SZ_DEC] or "0")
    return -n if neg else n


def px8(s):
    """Exact 1e8 integer from a decimal price string; anything finer than 1e-8 is refused, not
    truncated (review s5i1 #2)."""
    whole, _, frac = s.strip().partition(".")
    if len(frac) > 8 and int(frac[8:]) != 0:
        raise ValueError("finer than 1e-8: " + s)
    return int(whole) * 10**8 + int((frac + "0" * 8)[:8])


def word(hexdata, i, signed=False):
    v = int(hexdata[2 + 64 * i: 2 + 64 * (i + 1)], 16)
    return v - (1 << 256) if signed and v >> 255 else v


def enc_addr(a):
    return a.lower()[2:].rjust(64, "0")


def enc_uint(n):
    return hex(n)[2:].rjust(64, "0")


def call_pc(to, data, block="latest"):
    return {"jsonrpc": "2.0", "id": 2, "method": "eth_call", "params": [{"to": to, "data": data}, block]}


def szi_data(pool):
    return "0x" + enc_addr(pool) + enc_uint(PERP)


def read_szi(pool, block="latest"):
    """Lots from 0x800, as a contract would read them."""
    return word(rpc("eth_call", {"to": POSITION_PC, "data": szi_data(pool)}, block), 0, signed=True)


def sntp():
    try:
        return subprocess.run(["sntp", "-t", "3", "time.apple.com"], capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception as e:
        return "error:" + repr(e)[:80]


def live_stream(pool, t0, out, done):
    """0x800 at latest from the receipt on, every request timed on the local clock (questions 1 and
    3(b)). Runs LIVE_FOR s, longer until `done` is set (fills stable), at most LIVE_MAX s. One try
    per sample: a failed or rate-limited read is recorded, not retried."""
    batch = [{"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []},
             call_pc(POSITION_PC, szi_data(pool)),
             {"jsonrpc": "2.0", "id": 3, "method": "eth_blockNumber", "params": []}]
    while True:
        el = time.monotonic() - t0
        if el >= LIVE_MAX or (el >= LIVE_FOR and done.is_set()):
            return
        ts = time.monotonic()
        try:
            r = {x["id"]: x for x in post(RPC, batch, tries=1)}
            tr = time.monotonic()
            out.append({"send": round(ts - t0, 3), "recv": round(tr - t0, 3),
                        "bn_before": int(r[1]["result"], 16), "bn_after": int(r[3]["result"], 16),
                        "szi": word(r[2]["result"], 0, signed=True)})
        except Exception as e:
            out.append({"send": round(ts - t0, 3), "recv": round(time.monotonic() - t0, 3), "error": repr(e)[:80]})
        time.sleep(max(0.0, LIVE_POLL - (time.monotonic() - ts)))


def track5(pool, cloid, t0):
    """orderStatus by cloid with each poll's send and receive time (question 3(a))."""
    oid = "0x%032x" % cloid
    polls = []
    while time.monotonic() - t0 < GIVE_UP:
        ts = time.monotonic()
        try:
            r = info({"type": "orderStatus", "user": pool, "oid": oid})
            st = r["order"]["status"] if r.get("status") == "order" else "api:" + str(r.get("status"))
        except Exception as e:
            r, st = None, "error:" + repr(e)[:80]
        polls.append([round(ts - t0, 3), round(time.monotonic() - t0, 3), st])
        if st in TERMINAL:
            return st, polls, r
        time.sleep(max(0.0, POLL - (time.monotonic() - ts)))
    return None, polls, None


def fills_total(pool, oid):
    fs = [f for f in info({"type": "userFills", "user": pool}) if f.get("oid") == oid and f.get("coin") == COIN]
    return sum(lots(f["sz"]) for f in fs), fs


def g1_result(pool):
    """The G1 result for this pool on testnet, or None if G1 has not run for it (review s5i2 #1)."""
    try:
        with open(G1_FILE) as f:
            g = json.load(f)
    except FileNotFoundError:
        return None
    return g if g.get("pool") == pool.lower() and g.get("chain") == 998 else None


def require_g1(pool):
    g = g1_result(pool)
    if g is None:
        sys.exit("run `g1 %s` first: G1 comes before any step 5 run (review s5i1 #1, s5i2 #1)" % pool)
    return g["passed"] is True


def pinned(pool, block, target, ts_limit):
    """Question 1's end when G1 passed: 0x800 pinned to each block number from the order's block,
    every block read (none skipped), until the target size shows or blocks pass ts_limit."""
    reads, b = [], block
    while True:
        latest = int(rpc("eth_blockNumber"), 16)
        if b > latest:
            time.sleep(1)
            continue
        blk = rpc("eth_getBlockByNumber", hex(b), False)
        ts = int(blk["timestamp"], 16)
        try:
            v = read_szi(pool, hex(b))
        except Exception as e:
            reads.append({"block": b, "error": repr(e)[:80]})
            return {"reads": reads, "match": None}
        reads.append({"block": b, "hash": blk["hash"], "ts": ts, "szi": v})
        if v == target:
            return {"reads": reads, "match": b}
        if ts > ts_limit:
            return {"reads": reads, "match": None}
        b += 1
        time.sleep(PINNED_POLL)


def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after):
    """One order under the acknowledge table (review s5f #2). expect_status None = record whatever
    terminal status comes back; expect_after = lots after, or a function of the fill total F.
    Anything unexpected stops the run with the slot locked."""
    pool, env = ctx["pool"], ctx["env"]
    if int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0]) != 0:
        sys.exit("pendingCloid is set: resolve it by hand first")
    if info({"type": "openOrders", "user": pool}):
        sys.exit("pool has open orders on Core")
    before = read_szi(pool)
    row = {"line": "order5", "pool": pool, "chain": 998, "cycle": ctx["cycle"], "kind": ctx["kind"], "side": ctx["side"], "label": label,
           "fn": fn, "is_buy": is_buy, "limit_px8": px_8, "sz_lots": sz, "before": before, "oracle": oracle()}
    sig = fn + "(bool,uint64,uint64)"
    stream, done = [], threading.Event()
    tx, sent_at, rc = send(pool, env, sig, str(is_buy).lower(), px_8, sz * 10**(8 - SZ_DEC))
    t0 = time.monotonic()  # receipt arrival, local clock
    th = threading.Thread(target=live_stream, args=(pool, t0, stream, done), daemon=True)
    th.start()
    lg = next(l for l in rc["logs"] if l["topics"][0] in ctx["topics"])
    cloid = int(lg["topics"][1], 16)
    blk = int(rc["blockNumber"], 16)
    row.update({"tx": tx, "sent_at": round(sent_at, 3), "receipt_wall": round(time.time(), 3), "block": blk,
                "block_hash": rc["blockHash"], "cloid": "0x%032x" % cloid,
                "block_ts": int(rpc("eth_getBlockByNumber", rc["blockNumber"], False)["timestamp"], 16)})
    pending = int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0])
    final, polls, r = track5(pool, cloid, t0)
    row.update({"polls": polls, "final": final, "response": r, "pending_after_send": "0x%032x" % pending})
    if final is None:
        done.set(); th.join(); row["stream"] = stream
        stop5(row, "no terminal status in %d s" % GIVE_UP)
    o_ = r["order"]["order"]
    oid = o_.get("oid")
    # fill completeness (review s5c #1): equal twice in a row and agreeing with the live 0x800 change
    F, fs, hist, agreed = None, [], [], False
    t_end = time.monotonic() + FILLS_FOR
    while time.monotonic() < t_end:
        try:
            Fn, fs = fills_total(pool, oid)
        except Exception as e:
            hist.append([round(time.monotonic() - t0, 3), "error:" + repr(e)[:60]])
            time.sleep(FILLS_EVERY)
            continue
        last = next((x["szi"] for x in reversed(list(stream)) if "szi" in x), None)
        hist.append([round(time.monotonic() - t0, 3), Fn, last])
        if F is not None and Fn == F and last is not None and Fn == abs(last - before):
            agreed = True
            break
        F = Fn
        time.sleep(FILLS_EVERY)
    done.set()
    th.join()
    after = next((x["szi"] for x in reversed(stream) if "szi" in x), None)
    cls = ("indeterminate" if not agreed else "zero-fill" if F == 0 else "full-fill" if F == sz else
           "partial" if 0 < F < sz else "indeterminate")
    row.update({"oid": oid, "fills": fs, "F": F, "fills_hist": hist, "class": cls, "stream": stream, "after": after,
                "last_fill_time": max((f["time"] for f in fs), default=None)})
    want_after = expect_after(F) if callable(expect_after) else expect_after
    row["want_after"] = want_after
    if pending != cloid:
        stop5(row, "pendingCloid after send is not this order's cloid")
    if (o_.get("cloid"), o_.get("coin"), o_.get("side"), lots(o_.get("origSz", "0")), px8(o_.get("limitPx", "0"))) != \
            (row["cloid"], COIN, "B" if is_buy else "A", sz, px_8):
        stop5(row, "order does not match what was sent")
    if expect_status is not None and final != expect_status:
        stop5(row, "expected %s, got %s" % (expect_status, final))
    if callable(expect_after) and cls == "indeterminate":
        stop5(row, "fills indeterminate")
    if after is None or after != want_after:
        stop5(row, "position %s, expected %s" % (after, want_after))
    if after != before:  # question 3(b) only counts position-changing orders (review s5g #2)
        row["bracket"] = bracket(stream, after)
    else:
        row["bracket"] = "target already present at receipt"
    if ctx["g1"] and after != before:
        row["pinned"] = pinned(pool, blk, after, row["block_ts"] + LIVE_FOR)
    if int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0]) != cloid:
        stop5(row, "pendingCloid changed before acknowledgement")
    write5(row)
    send(pool, env, "acknowledge(uint128)", cloid)
    print(json.dumps({k: row.get(k) for k in ("cycle", "kind", "side", "label", "final", "F", "class", "after")}), flush=True)
    return F, after, blk


def bracket(stream, target):
    """First live read showing `target`, the last read before it that did not, and whether any
    failed read lies between them (then the bracket is degraded, review s5i1 #3)."""
    hit = next((i for i, x in enumerate(stream) if x.get("szi") == target), None)
    if hit is None:
        return {"hit": None}
    miss = next((i for i in range(hit - 1, -1, -1) if "szi" in stream[i]), None)
    errs = sum(1 for x in stream[(miss if miss is not None else -1) + 1:hit] if "error" in x)
    return {"first_hit": stream[hit], "last_miss": stream[miss] if miss is not None else None,
            "errors_between": errs, "degraded": errs > 0 or miss is None}


def stop5(row, why):
    row["stopped"] = why
    write5(row)
    sys.exit("stopped, order left unacknowledged: " + why)


def through(is_buy):
    return px5(oracle() * (1.01 if is_buy else 0.99)) * 10**8


def cycle5(ctx):
    """One cycle of one kind on one side. Every kind starts and ends flat."""
    k, s = ctx["kind"], ctx["side"]
    close_buy = s < 0
    if read_szi(ctx["pool"]) != 0:
        sys.exit("cycle needs a flat position: use `status` / `unwind`")

    def opn():
        order5(ctx, "open", "rawIoc", s > 0, through(s > 0), LOTS, "filled", s * LOTS)

    def close(label="close", sz=LOTS):
        order5(ctx, label, "rawIocReduceOnly", close_buy, through(close_buy), sz, "filled", 0)

    if k == "close-fill":
        opn(); close()
    elif k == "close-tight":
        opn()
        wrong = px5(oracle() * (0.85 if close_buy else 1.15)) * 10**8
        order5(ctx, "close-tight", "rawIocReduceOnly", close_buy, wrong, LOTS, "iocCancelRejected", s * LOTS)
        close("close-second")
    elif k == "close-partial":
        opn()
        t = time.monotonic()
        book = info({"type": "l2Book", "coin": COIN})
        snap = {"line": "book5", "cycle": ctx["cycle"], "send_wall": round(time.time(), 3),
                "took": round(time.monotonic() - t, 3), "book": book}
        side_levels = book["levels"][1 if close_buy else 0]
        touch = side_levels[0] if side_levels else None
        snap["touch"] = touch
        write5(snap)
        if touch is None or lots(touch["sz"]) >= LOTS:
            write5({"line": "skip", "cycle": ctx["cycle"], "kind": k, "side": s, "touch": touch})
            close("cleanup")
            return
        # the touch is a price Core itself quotes, so it is already on BTC's tick (review s5i1 #2);
        # one that cannot be represented is recorded and the position closed (review s5i2 #2)
        try:
            tpx = px8(touch["px"])
        except ValueError as e:
            write5({"line": "skip", "cycle": ctx["cycle"], "kind": k, "side": s, "touch": touch, "why": str(e)})
            close("cleanup")
            return
        F, after, _ = order5(ctx, "close-partial", "rawIocReduceOnly", close_buy, tpx, LOTS, None,
                             lambda F: s * (LOTS - (F or 0)))
        if after != 0:
            close("close-residual", abs(after))
    elif k == "close-flat":
        order5(ctx, "close-flat", "rawIocReduceOnly", close_buy, through(close_buy), LOTS, None, 0)
    elif k == "close-over":
        opn()
        order5(ctx, "close-over", "rawIocReduceOnly", close_buy, through(close_buy), 2 * LOTS, None, 0)
    elif k == "close-wrongside":
        opn()
        order5(ctx, "close-wrongside", "rawIocReduceOnly", s > 0, through(s > 0), LOTS, None, s * LOTS)
        close("close-after-wrongside")
    else:
        sys.exit("unknown kind " + k)


def testnet_ctx(pool):
    if int(cast("chain-id", "-r", RPC)) != 998:
        sys.exit("not testnet")
    return {"pool": pool.lower(), "env": key_env(), "topics": raw_topics(), "g1": False}


def step5(pool, cycles, seed=None):
    """The next `cycles` items of a plan shuffled once with a recorded seed (spec: random order,
    several sessions). The plan advances only when a cycle completes."""
    if os.path.exists(PLAN_FILE):
        with open(PLAN_FILE) as f:
            plan = json.load(f)
        if seed is not None and seed != plan["seed"]:
            sys.exit("a plan with seed %s exists" % plan["seed"])
        if plan.get("pool") != pool.lower() or plan.get("chain") != 998:
            sys.exit("the plan belongs to pool %s: move it aside to start one for this pool (review s5i3)" % plan.get("pool"))
    else:
        if seed is None:
            sys.exit("first session: give a seed")
        items = [[k, s] for (k, s), n in sorted(PLAN.items()) for _ in range(n)]
        random.Random(seed).shuffle(items)
        plan = {"seed": seed, "pool": pool.lower(), "chain": 998, "items": items, "done": 0}
    passed = require_g1(pool)
    ctx = testnet_ctx(pool)
    ctx["g1"] = passed
    g = g1_result(pool)
    write5({"line": "session", "start": round(time.time(), 3), "sntp": sntp(), "seed": plan["seed"],
            "pool": ctx["pool"], "chain": 998, "done": plan["done"],
            "g1": {"passed": g["passed"], "at": g["at"], "a": g["a"], "c": g["c"]}})
    for _ in range(cycles):
        if plan["done"] >= len(plan["items"]):
            print("plan complete")
            break
        k, s = plan["items"][plan["done"]]
        ctx.update({"cycle": plan["done"], "kind": k, "side": s})
        cycle5(ctx)
        plan["done"] += 1
        tmp = PLAN_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(plan, f)
        os.replace(tmp, PLAN_FILE)
    write5({"line": "session_end", "pool": ctx["pool"], "end": round(time.time(), 3), "sntp": sntp(), "done": plan["done"]})


def g1(pool):
    """Gate G1 (review s5i1 #1): open (receipt block A), close (receipt block C), then read 0x800
    pinned at every block from A - 5 to C + 15. Historical reads are accepted only if every read
    succeeds and the series is exactly: 0 before A; one switch to the open size at some block in
    [A, A + 10]; the open size until one switch back to 0 at some block in [C, C + 10]; 0 to the
    end. An RPC that answers with the current state (0) everywhere fails, as does any other shape."""
    ctx = testnet_ctx(pool)
    ctx.update({"cycle": "g1", "kind": "g1", "side": 1, "g1": False})
    if read_szi(ctx["pool"]) != 0:
        sys.exit("G1 needs a flat position")
    _, _, a = order5(ctx, "g1-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
    _, _, c = order5(ctx, "g1-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)
    end = c + 15
    while int(rpc("eth_blockNumber"), 16) <= end:
        time.sleep(2)
    reads = []
    for b in range(a - 5, end + 1):
        try:
            reads.append([b, read_szi(ctx["pool"], hex(b))])
        except Exception as e:
            reads.append([b, "error:" + repr(e)[:80]])
        time.sleep(1.0)
    vals = [v for _, v in reads]
    blocks = [b for b, _ in reads]
    ok = all(isinstance(v, int) for v in vals)
    if ok:
        up = next((b for b, v in reads if v == LOTS), None)
        down = next((b for b, v in reads if up is not None and b > up and v == 0), None)
        ok = (up is not None and down is not None and a <= up <= a + 10 and c <= down <= c + 10
              and all(v == (LOTS if up <= b < down else 0) for b, v in reads))
    res = {"passed": ok, "pool": ctx["pool"], "chain": 998, "a": a, "c": c, "reads": reads, "at": round(time.time(), 3)}
    with open(G1_FILE, "w") as f:
        json.dump(res, f)
    write5({"line": "g1", **res})
    print("G1", "passed" if ok else "failed: question 1 uses live reads only")


def lag(pool, n):
    """Question 2: with a position open, n paired readings of 0x80F / 0x807 and the info API,
    at least 15 s apart, in alternating order, every request timed. Differences only."""
    require_g1(pool)
    ctx = testnet_ctx(pool)
    ctx.update({"cycle": "lag", "kind": "lag", "side": 1})
    if read_szi(ctx["pool"]) != 0:
        sys.exit("lag needs a flat position to start")
    order5(ctx, "lag-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
    t0 = time.monotonic()
    batch = [{"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []},
             call_pc(MARGIN_PC, "0x" + enc_uint(0) + enc_addr(ctx["pool"])),
             call_pc(ORACLE_PC, "0x" + enc_uint(PERP))]
    for i in range(n):
        ts = time.monotonic()
        row = {"line": "lag", "i": i, "evm_first": i % 2 == 0}

        def evm():
            a = time.monotonic()
            r = {x["id"]: x for x in post(RPC, batch, tries=1)}
            row["evm"] = {"send": round(a - t0, 3), "recv": round(time.monotonic() - t0, 3), "block": int(r[1]["result"], 16),
                          "account_value": word(r[2]["result"], 0, signed=True), "oracle": word(r[3]["result"], 0)}

        def api():
            a = time.monotonic()
            st = info({"type": "clearinghouseState", "user": ctx["pool"]})
            b = time.monotonic()
            meta, ctxs = info({"type": "metaAndAssetCtxs"})
            row["api"] = {"send": round(a - t0, 3), "recv": round(b - t0, 3), "account_value": st["marginSummary"]["accountValue"],
                          "oracle_send": round(b - t0, 3), "oracle_recv": round(time.monotonic() - t0, 3),
                          "oracle": ctxs[[x["name"] for x in meta["universe"]].index(COIN)]["oraclePx"]}
        try:
            (evm(), api()) if row["evm_first"] else (api(), evm())
        except Exception as e:
            row["error"] = repr(e)[:80]
        write5(row)
        time.sleep(max(0.0, 15 - (time.monotonic() - ts)))
    order5(ctx, "lag-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)


def impact(levels, notional):
    """Walk displayed levels to `notional` USD: (VWAP, None) or (None, displayed USD depth)."""
    got_ntl = got_sz = 0.0
    for lv in levels:
        p, z = float(lv["px"]), float(lv["sz"])
        take = min(z, (notional - got_ntl) / p)
        got_ntl += take * p
        got_sz += take
        if got_ntl >= notional - 1e-9:
            return got_ntl / got_sz, None
    return None, got_ntl


def book(minutes, hours, coins):
    """Question 5, mainnet info API only: l2Book on a fixed schedule, raw snapshot kept, impact of
    closing 1k-1M USD (long closes walk bids, short closes walk asks) against the snapshot's mid.
    A displayed-book estimate, not an executable close cost; fees are not included."""
    every, start = minutes * 60, time.monotonic()
    ticks = int(hours * 3600 // every)
    meta = post(MAINNET_INFO, {"type": "meta"})
    index = {a["name"]: i for i, a in enumerate(meta["universe"])}
    # the base tier as Hyperliquid reports it (feeSchedule, read for the zero address, whose own
    # rate already differs from the base); not any real account's rate (review s5i2 #3)
    fees = post(MAINNET_INFO, {"type": "userFees", "user": "0x" + "0" * 40}).get("feeSchedule", {})
    write5({"line": "book_session", "start_wall": round(time.time(), 3), "coins": coins,
            "asset_index": {c: index.get(c) for c in coins}, "every_s": every, "ticks": ticks,
            "fee_basis": {"read_wall": round(time.time(), 3), "base_taker_cross": fees.get("cross"),
                          "base_maker_add": fees.get("add"), "source": "info userFees feeSchedule",
                          "schedule": "https://hyperliquid.gitbook.io/hyperliquid-docs/trading/fees",
                          "note": "impact figures exclude fees; base tier, real accounts may pay less"}}, BOOK_OUT)
    for i in range(ticks):
        due = start + i * every
        now = time.monotonic()
        if now > due + every:
            write5({"line": "book_missed", "tick": i, "late": round(now - due, 1)}, BOOK_OUT)
            continue
        time.sleep(max(0.0, due - now))
        for coin in coins:
            a, aw = time.monotonic(), time.time()
            try:
                bk = post(MAINNET_INFO, {"type": "l2Book", "coin": coin}, tries=1)
            except Exception as e:
                write5({"line": "book", "tick": i, "coin": coin, "send_wall": round(aw, 3), "error": repr(e)[:80]}, BOOK_OUT)
                continue
            took = round(time.monotonic() - a, 3)
            bids, asks = bk["levels"]
            row = {"line": "book", "tick": i, "coin": coin, "asset_index": index.get(coin), "send_wall": round(aw, 3),
                   "recv_wall": round(time.time(), 3), "took": took, "raw": bk}
            if bids and asks:
                mid = (float(bids[0]["px"]) + float(asks[0]["px"])) / 2
                row["mid"] = mid
                for side, lv in (("close_long", bids), ("close_short", asks)):
                    for n in (1e3, 1e4, 1e5, 1e6):
                        v, depth = impact(lv, n)
                        row["%s_%d" % (side, n)] = ({"bp": round(abs(v - mid) / mid * 1e4, 3)} if v is not None
                                                    else {"insufficient_depth_usd": round(depth, 2)})
            write5(row, BOOK_OUT)



if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] in ("status", "unwind"):
        {"status": status, "unwind": unwind}[a[0]](a[1])
    elif len(a) == 4 and a[0] == "run" and a[2] in EXPECT:
        run(a[1], a[2], int(a[3]))
    elif len(a) == 2 and a[0] == "g1":
        g1(a[1])
    elif len(a) in (3, 4) and a[0] == "step5":
        step5(a[1], int(a[2]), int(a[3]) if len(a) == 4 else None)
    elif len(a) == 3 and a[0] == "lag":
        lag(a[1], int(a[2]))
    elif len(a) >= 4 and a[0] == "book":
        book(float(a[1]), float(a[2]), a[3:])
    else:
        sys.exit(__doc__)
