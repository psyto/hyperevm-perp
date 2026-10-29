codex
I’ll inspect the full implementation, the prior review, and session artifacts, then trace the acknowledgement and logging paths against the amended spec.
exec
/bin/zsh -lc "sed -n '1,260p' recorder/orders.py && sed -n '261,560p' recorder/orders.py && sed -n '561,920p' recorder/orders.py" in ~/src/hyperevm-perp
 succeeded in 0ms:
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
    python3 recorder/orders.py ackopen <pool>             # after a stopped open: acknowledge it if flat
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
    # cast 1.7 no longer reads ETH_PRIVATE_KEY, so the key goes on the command line; a failure
    # prints cast's stderr only, never the command (which holds the key)
    r = subprocess.run(["cast", "send", "--async", "-r", RPC, "--private-key", env["ETH_PRIVATE_KEY"], pool, sig,
                        *map(str, args)], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("cast send %s failed: %s" % (sig, r.stderr.strip()[-400:]))
    tx = r.stdout.strip()
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
    """The local clock against NTP: sntp where it exists (macOS), else chrony's own report (the AWS
    host, which has no sntp; review s5r1 #4)."""
    for cmd in (["sntp", "-t", "3", "time.apple.com"], ["chronyc", "tracking"]):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        except FileNotFoundError:
            continue
        except Exception as e:
            return "error:" + repr(e)[:80]
    return "error: neither sntp nor chronyc found"


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


def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after, through_bps=None):
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
           "fn": fn, "is_buy": is_buy, "limit_px8": px_8, "sz_lots": sz, "before": before, "oracle": oracle(),
           "through_bps": through_bps}
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
    failed read lies between them (then the bracket is degraded, review s5i1 #3). When no read
    before the hit succeeded, the result is an upper bound from the receipt to the hit, labelled
    "no observed post-receipt non-match" (review s5r1 #3), not a degraded bracket."""
    hit = next((i for i, x in enumerate(stream) if x.get("szi") == target), None)
    if hit is None:
        return {"hit": None}
    miss = next((i for i in range(hit - 1, -1, -1) if "szi" in stream[i]), None)
    errs = sum(1 for x in stream[(miss if miss is not None else -1) + 1:hit] if "error" in x)
    return {"first_hit": stream[hit], "last_miss": stream[miss] if miss is not None else None,
            "errors_between": errs, "degraded": errs > 0 and miss is not None,
            "upper_bound_only": "no observed post-receipt non-match" if miss is None else None}


def stop5(row, why):
    row["stopped"] = why
    write5(row)
    sys.exit("stopped, order left unacknowledged: " + why)


def through(is_buy, bps=100):
    return px5(oracle() * (1 + (bps if is_buy else -bps) / 1e4)) * 10**8


# Opens (rawIoc, never reduce-only) go 2% through: the testnet book sat over 1% from the oracle and
# an open at 1% found nothing (session 1, cycle 22; review s5r1 #2). Closes stay at 1% through, the
# measured quantity. Every order5 row records its through_bps, so 1% and 2% opens stay apart.
OPEN_BPS = 200


def cycle5(ctx):
    """One cycle of one kind on one side. Every kind starts and ends flat."""
    k, s = ctx["kind"], ctx["side"]
    close_buy = s < 0
    if read_szi(ctx["pool"]) != 0:
        sys.exit("cycle needs a flat position: use `status` / `unwind`")

    def opn():
        order5(ctx, "open", "rawIoc", s > 0, through(s > 0, OPEN_BPS), LOTS, "filled", s * LOTS, OPEN_BPS)

    def close(label="close", sz=LOTS):
        order5(ctx, label, "rawIocReduceOnly", close_buy, through(close_buy), sz, "filled", 0, 100)

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
        snap = {"line": "book5", "pool": ctx["pool"], "chain": 998, "cycle": ctx["cycle"], "send_wall": round(time.time(), 3),
                "took": round(time.monotonic() - t, 3), "book": book}
        side_levels = book["levels"][1 if close_buy else 0]
        touch = side_levels[0] if side_levels else None
        snap["touch"] = touch
        write5(snap)
        if touch is None or lots(touch["sz"]) >= LOTS:
            write5({"line": "skip", "pool": ctx["pool"], "chain": 998, "cycle": ctx["cycle"], "kind": k, "side": s, "touch": touch})
            close("cleanup")
            return
        # the touch is a price Core itself quotes, so it is already on BTC's tick (review s5i1 #2);
        # one that cannot be represented is recorded and the position closed (review s5i2 #2)
        try:
            tpx = px8(touch["px"])
        except ValueError as e:
            write5({"line": "skip", "pool": ctx["pool"], "chain": 998, "cycle": ctx["cycle"], "kind": k, "side": s, "touch": touch, "why": str(e)})
            close("cleanup")
            return
        F, after, _ = order5(ctx, "close-partial", "rawIocReduceOnly", close_buy, tpx, LOTS, None,
                             lambda F: s * (LOTS - (F or 0)))
        if after != 0:
            close("close-residual", abs(after))
    elif k == "close-flat":
        order5(ctx, "close-flat", "rawIocReduceOnly", close_buy, through(close_buy), LOTS, None, 0, 100)
    elif k == "close-over":
        opn()
        order5(ctx, "close-over", "rawIocReduceOnly", close_buy, through(close_buy), 2 * LOTS, None, 0, 100)
    elif k == "close-wrongside":
        opn()
        order5(ctx, "close-wrongside", "rawIocReduceOnly", s > 0, through(s > 0), LOTS, None, s * LOTS, 100)
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
    why = "completed"
    try:
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
    except BaseException as e:  # a stop (SystemExit) or a crash still ends the session on record (review s5r1 #4)
        why = "stopped: " + (str(e) if isinstance(e, SystemExit) else repr(e))[:200]
        raise
    finally:
        write5({"line": "session_end", "pool": ctx["pool"], "end": round(time.time(), 3), "sntp": sntp(),
                "done": plan["done"], "why": why})


def ackopen(pool):
    """Recovery for a stopped opening order (review s5r1 #1): acknowledge it only if the pending cloid
    is the one in the last stopped row, that row is an opening rawIoc, its status is terminal, the
    pool has no open orders, and the position is flat and equal to the row's position before. The
    checks and the transaction are recorded in step5.jsonl. Anything else stays for a person."""
    ctx = testnet_ctx(pool)
    pool = ctx["pool"]
    rows = [json.loads(l) for l in open(STEP5_OUT)]
    last = next((r for r in reversed(rows) if r.get("line") == "order5" and r.get("pool") == pool), None)
    pc = int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0])
    st = info({"type": "orderStatus", "user": pool, "oid": "0x%032x" % pc}) if pc else None
    final = (st or {}).get("order", {}).get("status") if (st or {}).get("status") == "order" else None
    oo = info({"type": "openOrders", "user": pool})
    szi = read_szi(pool)
    checks = {"pending": "0x%032x" % pc, "last_stopped_cloid": (last or {}).get("cloid"),
              "last_stopped": (last or {}).get("stopped"), "fn": (last or {}).get("fn"), "label": (last or {}).get("label"),
              "status": final, "open_orders": len(oo), "szi": szi, "before": (last or {}).get("before")}
    ok = (pc != 0 and last is not None and last.get("stopped") and last.get("cloid") == checks["pending"]
          and last.get("fn") == "rawIoc" and last.get("label") == "open" and final in TERMINAL and final != "filled"
          and not oo and szi == 0 and last.get("before") == 0)
    rec = {"line": "manual_ack", "pool": pool, "chain": 998, "cycle": (last or {}).get("cycle"), "wall": round(time.time(), 3),
           "checks": checks, "ok": bool(ok)}
    if not ok:
        write5(rec)
        sys.exit("not acknowledged: " + json.dumps(checks))
    tx, _, rc = send(pool, ctx["env"], "acknowledge(uint128)", pc)
    rec.update({"tx": tx, "block": int(rc["blockNumber"], 16)})
    write5(rec)
    print(json.dumps(rec))


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
        row = {"line": "lag", "pool": ctx["pool"], "chain": 998, "i": i, "evm_first": i % 2 == 0}

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
    elif len(a) == 2 and a[0] == "ackopen":
        ackopen(a[1])
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

exec
/bin/zsh -lc "sed -n '1,240p' <scratchpad>/s5r1.out; sed -n '110,190p' docs/step5-close-from-evm-spec.md; nl -ba recorder/orders.py | sed -n '450,735p'; find <scratchpad>/s1 -maxdepth 2 -type f -print" in ~/src/hyperevm-perp
 succeeded in 1ms:
Reading additional input from stdin...
OpenAI Codex v0.160.1
--------
workdir: ~/src/hyperevm-perp
model: gpt-5.6-terra
provider: openai
approval: never
sandbox: read-only
reasoning effort: high
reasoning summaries: none
session id: 01a18572-fab6-7852-bd71-4714f90f37d1
--------
user
# Review s5r1: step 5 testnet session 1 — results and handling, before session 2

Adversarial review. Spec: docs/step5-close-from-evm-spec.md (s5h APPROVE). Recorder:
recorder/orders.py at 2e62211 (s5i6 APPROVE). Session 1 data (read only) in <scratchpad>/s1/:
g1.json, step5.jsonl, step5_plan.json, step5-s1.log, orders.jsonl.

What happened (testnet, 2026-10-29, pool 0x7cD037094A60666280E6CB389e696DED19Da5D6f):
1. G1: open at A=68156552, close at C=68156586, then 0x800 by eth_call pinned at A-5..C+15:
   all 55 reads returned 0, so G1 failed and question 1 uses live reads only.
2. step5 seed 1029, 40 cycles requested; stopped at cycle 22 (22 of 120 done): the opening rawIoc
   of close-wrongside (long) came back iocCancelRejected. Oracle 80,055.7, limit oracle+1% = 80,856,
   testnet asks around 80,948. The run stopped with pendingCloid set, as designed.
3. Manual recovery: orderStatus for that cloid = iocCancelRejected, openOrders = [], position 0
   (clearinghouseState), then acknowledge(cloid) by hand. Plan stays at done=22.
4. Close brackets: 11 closes already flat at the first live read after the receipt (bracket
   degraded), 9 flat at the next read ~2.5 s later (LIVE_POLL 2.5 s).

Questions:
(a) Is the G1 conclusion sound from g1.json (could the reads be wrong for another reason, e.g. the
    call encoding, the block range, or the RPC answering "latest" — and does that matter)?
(b) Was the manual acknowledge correct under the spec's acknowledge rule, and did resuming leave the
    plan consistent (the failed cycle's item is still next; nothing double-counted in step5.jsonl)?
(c) The open limit is oracle ±1% (the spec's "1% through" is for closes; opens reuse through()).
    The testnet book drifts >1% from the oracle at times. Options: rerun unchanged and accept stops,
    or widen only the open limit to 2%. Which, and does widening open limits affect any measured
    quantity?
(d) Does the 2.5 s live-read pace make question 1 / 3(b) unanswerable at the resolution the spec
    claims (most closes are flat at the first read)? If so, what is the smallest change that fixes
    it within the RPC limit (100 requests/min), and does the spec need to say so before session 2?
(e) Anything in step5.jsonl that contradicts the acknowledge table or the plan.

Findings with severity and evidence (row/cycle). End with VERDICT: APPROVE (session 2 may run
unchanged) or VERDICT: CHANGES.
codex
I’ll audit the specification, recorder revision, and all session artifacts against the stated recovery and measurement rules, with particular attention to the failed cycle and polling resolution.
exec
/bin/zsh -lc 'pwd && rg --files docs recorder <scratchpad>/s1 | sort' in ~/src/hyperevm-perp
 succeeded in 0ms:
~/src/hyperevm-perp
<scratchpad>/s1/g1.json
<scratchpad>/s1/orders.jsonl
<scratchpad>/s1/step5-s1.log
<scratchpad>/s1/step5.jsonl
<scratchpad>/s1/step5_plan.json
docs/design.md
docs/reviews/README.md
docs/reviews/payload-review-r1.md
docs/reviews/payload-review-r2.md
docs/reviews/payload-review-r3.md
docs/reviews/payload-review-r4.md
docs/reviews/payload-review-r5.md
docs/reviews/payload-review-r6.md
docs/reviews/payload-review-r6b.md
docs/reviews/payload-review-rec1.md
docs/reviews/payload-review-rec2.md
docs/reviews/payload-review-rec3.md
docs/reviews/payload-review-s5.md
docs/reviews/payload-review-s5b.md
docs/reviews/payload-review-s5c.md
docs/reviews/payload-review-s5d.md
docs/reviews/payload-review-s5e.md
docs/reviews/payload-review-s5f.md
docs/reviews/payload-review-s5g.md
docs/reviews/payload-review-s5h.md
docs/reviews/payload-review-s5i1.md
docs/reviews/payload-review-s5i2.md
docs/reviews/payload-review-s5i3.md
docs/reviews/payload-review-s5i4.md
docs/reviews/payload-review-s5i5.md
docs/reviews/payload-review-s5i6.md
docs/reviews/r1-poc.t.sol.txt
docs/reviews/r1.md
docs/reviews/r2-poc.t.sol.txt
docs/reviews/r2.md
docs/reviews/r3-poc.t.sol.txt
docs/reviews/r3.md
docs/reviews/r4-poc.t.sol.txt
docs/reviews/r4.md
docs/reviews/r5-poc.t.sol.txt
docs/reviews/r5.md
docs/reviews/r6-poc.t.sol.txt
docs/reviews/r6.md
docs/reviews/review-r1.out.md
docs/reviews/review-r2.out.md
docs/reviews/review-r3.out.md
docs/reviews/review-r4.out.md
docs/reviews/review-r5.out.md
docs/reviews/review-r6.out.md
docs/reviews/review-r6b.out.md
docs/reviews/review-rec1.out.md
docs/reviews/review-rec2.out.md
docs/reviews/review-rec3.out.md
docs/reviews/review-s5.out.md
docs/reviews/review-s5b.out.md
docs/reviews/review-s5c.out.md
docs/reviews/review-s5d.out.md
docs/reviews/review-s5e.out.md
docs/reviews/review-s5f.out.md
docs/reviews/review-s5g.out.md
docs/reviews/review-s5h.out.md
docs/reviews/review-s5i1.out.md
docs/reviews/review-s5i2.out.md
docs/reviews/review-s5i3.out.md
docs/reviews/review-s5i4.out.md
docs/reviews/review-s5i5.out.md
docs/reviews/review-s5i6.out.md
docs/step3-testnet.md
docs/step4-liquidation-and-rejections.md
docs/step5-close-from-evm-spec.md
recorder/orders.py

exec
/bin/zsh -lc "sed -n '1,260p' docs/step5-close-from-evm-spec.md && sed -n '1,240p' recorder/orders.py" in ~/src/hyperevm-perp
exec
/bin/zsh -lc "wc -l <scratchpad>/s1/{step5.jsonl,orders.jsonl,step5-s1.log}; sed -n '1,240p' <scratchpad>/s1/step5-s1.log" in ~/src/hyperevm-perp
 succeeded in 0ms:
      54 <scratchpad>/s1/step5.jsonl
      99 <scratchpad>/s1/orders.jsonl
      49 <scratchpad>/s1/step5-s1.log
     202 total
{"cycle": 0, "kind": "close-fill", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 0, "kind": "close-fill", "side": 1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 1, "kind": "close-tight", "side": -1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": -15}
{"cycle": 1, "kind": "close-tight", "side": -1, "label": "close-tight", "final": "iocCancelRejected", "F": 0, "class": "zero-fill", "after": -15}
{"cycle": 1, "kind": "close-tight", "side": -1, "label": "close-second", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 2, "kind": "close-fill", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 2, "kind": "close-fill", "side": 1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 3, "kind": "close-fill", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 3, "kind": "close-fill", "side": 1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 4, "kind": "close-fill", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 4, "kind": "close-fill", "side": 1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 5, "kind": "close-fill", "side": -1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": -15}
{"cycle": 5, "kind": "close-fill", "side": -1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 6, "kind": "close-fill", "side": -1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": -15}
{"cycle": 6, "kind": "close-fill", "side": -1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 7, "kind": "close-tight", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 7, "kind": "close-tight", "side": 1, "label": "close-tight", "final": "iocCancelRejected", "F": 0, "class": "zero-fill", "after": 15}
{"cycle": 7, "kind": "close-tight", "side": 1, "label": "close-second", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 8, "kind": "close-fill", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 8, "kind": "close-fill", "side": 1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 9, "kind": "close-fill", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 9, "kind": "close-fill", "side": 1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 10, "kind": "close-partial", "side": -1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": -15}
{"cycle": 10, "kind": "close-partial", "side": -1, "label": "cleanup", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 11, "kind": "close-fill", "side": -1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": -15}
{"cycle": 11, "kind": "close-fill", "side": -1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 12, "kind": "close-over", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 12, "kind": "close-over", "side": 1, "label": "close-over", "final": "filled", "F": 15, "class": "partial", "after": 0}
{"cycle": 13, "kind": "close-over", "side": -1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": -15}
{"cycle": 13, "kind": "close-over", "side": -1, "label": "close-over", "final": "filled", "F": 15, "class": "partial", "after": 0}
{"cycle": 14, "kind": "close-fill", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 14, "kind": "close-fill", "side": 1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 15, "kind": "close-tight", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 15, "kind": "close-tight", "side": 1, "label": "close-tight", "final": "iocCancelRejected", "F": 0, "class": "zero-fill", "after": 15}
{"cycle": 15, "kind": "close-tight", "side": 1, "label": "close-second", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 16, "kind": "close-wrongside", "side": -1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": -15}
{"cycle": 16, "kind": "close-wrongside", "side": -1, "label": "close-wrongside", "final": "reduceOnlyRejected", "F": 0, "class": "zero-fill", "after": -15}
{"cycle": 16, "kind": "close-wrongside", "side": -1, "label": "close-after-wrongside", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 17, "kind": "close-flat", "side": -1, "label": "close-flat", "final": "reduceOnlyRejected", "F": 0, "class": "zero-fill", "after": 0}
{"cycle": 18, "kind": "close-fill", "side": -1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": -15}
{"cycle": 18, "kind": "close-fill", "side": -1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 19, "kind": "close-fill", "side": 1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": 15}
{"cycle": 19, "kind": "close-fill", "side": 1, "label": "close", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 20, "kind": "close-wrongside", "side": -1, "label": "open", "final": "filled", "F": 15, "class": "full-fill", "after": -15}
{"cycle": 20, "kind": "close-wrongside", "side": -1, "label": "close-wrongside", "final": "reduceOnlyRejected", "F": 0, "class": "zero-fill", "after": -15}
{"cycle": 20, "kind": "close-wrongside", "side": -1, "label": "close-after-wrongside", "final": "filled", "F": 15, "class": "full-fill", "after": 0}
{"cycle": 21, "kind": "close-flat", "side": -1, "label": "close-flat", "final": "reduceOnlyRejected", "F": 0, "class": "zero-fill", "after": 0}
stopped, order left unacknowledged: expected filled, got iocCancelRejected
rc=1

 succeeded in 0ms:
# Step 5 (spec): seeing and closing a contract's Core position from the EVM

Status: spec, revised after reviews s5 to s5g (CHANGES). Nothing here has been built or sent.

Steps 3 and 4 showed that a CoreWriter order reaches a final `orderStatus` within about 2 s. Step 5
asks the next question: if a contract's Core perp position backs something on the EVM side, how far
apart are the contract's precompile view and Core's own view, and how quickly and reliably can a
contract flatten that position with reduce-only orders sent through CoreWriter.

**Scope (s5 #1).** These are measurements of CoreWriter and precompile primitives, using a
testnet-only reduce-only order. They are not measurements of `HedgedPerp`'s own path: there,
`liquidate()` only removes EVM exposure and a later `hedge()` sends a non-reduce-only IOC sized from
`coreLots()`. That path is unchanged by this step and its results do not describe it.

## Questions
1. **Position visibility after the order's last fill.** From the last fill that contributes to an
   order (the latest `time` among the `userFills` entries with its oid; for a single fill, that
   fill) to the first contract-style `0x800` read showing the order's final size. The end depends
   on a gate (see Recorder, gate G1): if `eth_call` at an explicit old block number is shown to
   return that block's `0x800` state, the first matching block is found by backfill; if not (the
   public RPC is already known to ignore block numbers for `0x807`, hl-price-guard
   docs/safe-limits.md), the end is the first live read with the final size.
   **Clocks.** Core's fill `time`, EVM block timestamps (whole seconds) and the local clock are
   different clocks with no shared calibration. Question 1 is therefore reported as a
   **cross-clock delta**, labelled as such and not as a latency bound; the local clock's NTP offset
   (`sntp`) at the start and end of each session is recorded alongside for context only.
2. **Divergence from the info API.** While a position is open, paired readings of account value
   (`0x80F` vs `clearinghouseState`) and oracle price (`0x807` vs `metaAndAssetCtxs`). These are not
   a common snapshot; the report gives the difference together with the block read, each request's
   send and receive time and their order. No claim of "precompile staleness" is drawn from them.
   (BBO `0x80E` is dropped from step 5.)
3. **Close latency, as the client observes it.** From the receipt of the transaction that sends a
   reduce-only IOC to (a) the first `orderStatus` response carrying a terminal status, bounded by
   the send and receive times of that poll and of the previous non-terminal poll (when the first
   poll is already terminal, the lower bound is the receipt's arrival), and (b) the first live
   `0x800` read with the expected size, bounded by the send/receive times of that read and of the
   last read without it. Both (a) and (b) use only the local monotonic clock (receipt arrival and
   request times), so they are defensible client-observed brackets. Block timestamps are recorded
   but not mixed into these figures.
4. **Close outcomes**, for long and short positions. Every expected status below is a thing to
   confirm, not an assumption; the recorder records whatever comes back and stops on a surprise.
   - `close-fill`: open, then reduce-only close 1% through the oracle -> expected `filled`, flat.
   - `close-tight`: reduce-only close 15% on the wrong side -> expected `iocCancelRejected`,
     unchanged; then a second close 1% through -> expected `filled`. Time to flat over two attempts.
   - `close-partial`: reduce-only close for the whole position limited at the touch, sent when the
     touch's displayed size (raw snapshot with its request times kept) is smaller than the position;
     then the residual is closed with a second reduce-only order. The attempt is classified from
     fills, not from the book. All sizes are exact integer lots (BTC: szDecimals 5, so 0.00015 =
     15 lots); `userFills` decimal `sz` strings are converted to lots exactly, without floats. Let
     P = |szi| before the close and F = the sum, in lots, of all `userFills` entries whose numeric
     exchange `oid` equals the `oid` in the terminal `orderStatus` record for this cloid (the cloid
     itself is not used to match fills). Completeness: after the terminal status, re-read
     `userFills` every 2 s until two consecutive reads give the same F and F agrees with the change
     in `0x800` (|szi before| − |szi after|), or 30 s pass. Then `partial` only if 0 < F < P,
     `zero-fill` if F = 0, `full-fill` if F = P; anything else, or no agreement within 30 s, is
     `indeterminate`. Only observed
  For the three "recorded" rows the status name is what is being confirmed, so any terminal status
  is acknowledged if the position matches; a position that does not match stops the run.
- **Gate G1 (before any runs):** with the pool holding a position opened at a known block A and
  closed at a later block C, call `0x800` by `eth_call` at block numbers before A, between A and C,
  and after C, and record the results. Historical reads are accepted only if they return the size
  each block should have had. The outcome is written into the step 5 write-up before question 1 or
  3(b) is measured.
- Live reads, always (question 3(b), and question 1's end if G1 fails): from the receipt's
  arrival, poll `0x800` at `latest` as fast as the RPC limit allows (with `eth_blockNumber` before
  and after each call), recording each request's send and receive time and result, for a fixed
  30 s (or longer, until the order's fill total F is stable after its terminal status). The target
  size is chosen afterwards from the order's row in the acknowledge table (for `close-partial`,
  s × (P − F) once F is known), and the first read matching it and the last non-matching read
  before it are selected from the recorded stream.
- Question 3(b) counts only orders that change the position (`close-fill`, the second close of
  `close-tight`, `close-partial` first and residual closes when F > 0, `close-over`, the closing
  order of `close-wrongside`). Orders whose target equals the position before them
  (`close-flat`, the first close of `close-tight`, the same-direction order of `close-wrongside`,
  `close-partial` with F = 0) are reported separately as "target already present at receipt",
  with 3(a) status timing as their measure.
- Pinned reads, only if G1 passes (question 1's end only): after each order's block B, read
  `0x800` pinned to each explicit block number from B onward (recording the block hash),
  backfilling skipped blocks, until the final size is seen or 30 s of blocks pass; record the first
  matching block and its timestamp. Run after the live stream so the two do not share the rate
  budget.
- Every `orderStatus` poll records its send and receive times (local monotonic clock) and the
  status returned; every receipt records when it arrived.
- Fill time source: `userFills` (info API) for the pool's Core account, matched by `oid`, using its
  `time` field. If a fill cannot be matched there, the record says so and question 1 excludes it
  (counted, not dropped silently).
- `lag <pool> <n>`: with a position open, n paired readings for question 2, spaced at least 15 s.
- `book <coin...>`: question 5, mainnet info API only, to `recorder/data/book.jsonl`, raw snapshot
  included.
- Kinds and sides are run in a random order (seed recorded).

## Amendments after session 1 (review s5r1)
Session 1 (2026-10-29): G1 failed (all 55 historical reads 0), so question 1 uses live reads only.
The run stopped at cycle 22 of 120 when an opening `rawIoc` 1% through the oracle found nothing:
the testnet book sat over 1% above the oracle. These apply from session 2:
- **Opens go 2% through the oracle**; every close and recovery close stays at 1% (the measured
  quantity). Each order row records `through_bps`; opening data at 1% (session 1) and 2% are
  reported apart, never pooled. Closes are unaffected; opening fill price and fees are.
- **A stopped open is recovered with `ackopen`**, the only manual acknowledgement: the pending cloid
  must be the last stopped row's cloid, that row an opening `rawIoc` that did not fill, its status
  terminal, no open orders, and the position flat (as before the order). The checks and the
  transaction go into `step5.jsonl` as a `manual_ack` row; anything else stays for a person. Session
  1's cycle-22 open was acknowledged by hand after the same checks, before this command existed; it
  is recorded as `manual_ack_retro` (transaction hash not captured) and excluded from every count.
- **Brackets.** Reads start at the receipt. When the first read already shows the target, the result
  is an upper bound from the receipt to that read, labelled "no observed post-receipt non-match",
  not a failed bracket. Otherwise the bracket is the last non-matching and the first matching read
  (about 2.5 s apart at the current pace). The pace stays at 2.5 s (three calls a read, about 72
  requests a minute against the RPC's 100).
- **Every session ends on record**: `session_end` is written on completion, a stop, or a crash, with
  the reason. The clock check uses `sntp`, or `chronyc tracking` on the AWS host.

## Runs
Testnet BTC perp (index 3), 0.00015 BTC per position (about 12 USD), same key as steps 3-4. Spread
over at least three sessions on different days, including US and Asian hours.

| Kind | n (long + short) |
|---|---|
| `close-fill` | 60 (30 + 30) |
| `close-tight` | 20 (10 + 10) |
| `close-partial` | 10 attempted (5 + 5; skips counted; a side with no observed partial gives no conclusion) |
| `close-flat` | 10 |
| `close-over` | 10 (5 + 5) |
| `close-wrongside` | 10 (5 + 5) |
| `lag` | 300 readings across the sessions |

## Book method (question 5)
- Coins: BTC, ETH, HYPE on mainnet. `l2Book` every 10 min for 7 days; each record keeps the raw
  snapshot, request send and receive times and the coin's asset index, and missed intervals are
  logged.
- Baseline: the mid of the same snapshot. Closing a long walks the bids; closing a short walks the
  asks. For 1k, 10k, 100k and 1M USD notional: walk displayed levels to that notional, take the
  VWAP, report impact = |VWAP − mid| / mid in bp. The taker fee is reported separately as the
  base-tier rate from Hyperliquid's fee schedule on the day of the write-up (dated, with the link);
  actual accounts pay less with volume tiers or discounts.
- If displayed depth runs out before the notional, the result is "insufficient displayed depth"
  with the depth that was there, not an extrapolation.
   450	        sys.exit("run `g1 %s` first: G1 comes before any step 5 run (review s5i1 #1, s5i2 #1)" % pool)
   451	    return g["passed"] is True
   452	
   453	
   454	def pinned(pool, block, target, ts_limit):
   455	    """Question 1's end when G1 passed: 0x800 pinned to each block number from the order's block,
   456	    every block read (none skipped), until the target size shows or blocks pass ts_limit."""
   457	    reads, b = [], block
   458	    while True:
   459	        latest = int(rpc("eth_blockNumber"), 16)
   460	        if b > latest:
   461	            time.sleep(1)
   462	            continue
   463	        blk = rpc("eth_getBlockByNumber", hex(b), False)
   464	        ts = int(blk["timestamp"], 16)
   465	        try:
   466	            v = read_szi(pool, hex(b))
   467	        except Exception as e:
   468	            reads.append({"block": b, "error": repr(e)[:80]})
   469	            return {"reads": reads, "match": None}
   470	        reads.append({"block": b, "hash": blk["hash"], "ts": ts, "szi": v})
   471	        if v == target:
   472	            return {"reads": reads, "match": b}
   473	        if ts > ts_limit:
   474	            return {"reads": reads, "match": None}
   475	        b += 1
   476	        time.sleep(PINNED_POLL)
   477	
   478	
   479	def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after, through_bps=None):
   480	    """One order under the acknowledge table (review s5f #2). expect_status None = record whatever
   481	    terminal status comes back; expect_after = lots after, or a function of the fill total F.
   482	    Anything unexpected stops the run with the slot locked."""
   483	    pool, env = ctx["pool"], ctx["env"]
   484	    if int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0]) != 0:
   485	        sys.exit("pendingCloid is set: resolve it by hand first")
   486	    if info({"type": "openOrders", "user": pool}):
   487	        sys.exit("pool has open orders on Core")
   488	    before = read_szi(pool)
   489	    row = {"line": "order5", "pool": pool, "chain": 998, "cycle": ctx["cycle"], "kind": ctx["kind"], "side": ctx["side"], "label": label,
   490	           "fn": fn, "is_buy": is_buy, "limit_px8": px_8, "sz_lots": sz, "before": before, "oracle": oracle(),
   491	           "through_bps": through_bps}
   492	    sig = fn + "(bool,uint64,uint64)"
   493	    stream, done = [], threading.Event()
   494	    tx, sent_at, rc = send(pool, env, sig, str(is_buy).lower(), px_8, sz * 10**(8 - SZ_DEC))
   495	    t0 = time.monotonic()  # receipt arrival, local clock
   496	    th = threading.Thread(target=live_stream, args=(pool, t0, stream, done), daemon=True)
   497	    th.start()
   498	    lg = next(l for l in rc["logs"] if l["topics"][0] in ctx["topics"])
   499	    cloid = int(lg["topics"][1], 16)
   500	    blk = int(rc["blockNumber"], 16)
   501	    row.update({"tx": tx, "sent_at": round(sent_at, 3), "receipt_wall": round(time.time(), 3), "block": blk,
   502	                "block_hash": rc["blockHash"], "cloid": "0x%032x" % cloid,
   503	                "block_ts": int(rpc("eth_getBlockByNumber", rc["blockNumber"], False)["timestamp"], 16)})
   504	    pending = int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0])
   505	    final, polls, r = track5(pool, cloid, t0)
   506	    row.update({"polls": polls, "final": final, "response": r, "pending_after_send": "0x%032x" % pending})
   507	    if final is None:
   508	        done.set(); th.join(); row["stream"] = stream
   509	        stop5(row, "no terminal status in %d s" % GIVE_UP)
   510	    o_ = r["order"]["order"]
   511	    oid = o_.get("oid")
   512	    # fill completeness (review s5c #1): equal twice in a row and agreeing with the live 0x800 change
   513	    F, fs, hist, agreed = None, [], [], False
   514	    t_end = time.monotonic() + FILLS_FOR
   515	    while time.monotonic() < t_end:
   516	        try:
   517	            Fn, fs = fills_total(pool, oid)
   518	        except Exception as e:
   519	            hist.append([round(time.monotonic() - t0, 3), "error:" + repr(e)[:60]])
   520	            time.sleep(FILLS_EVERY)
   521	            continue
   522	        last = next((x["szi"] for x in reversed(list(stream)) if "szi" in x), None)
   523	        hist.append([round(time.monotonic() - t0, 3), Fn, last])
   524	        if F is not None and Fn == F and last is not None and Fn == abs(last - before):
   525	            agreed = True
   526	            break
   527	        F = Fn
   528	        time.sleep(FILLS_EVERY)
   529	    done.set()
   530	    th.join()
   531	    after = next((x["szi"] for x in reversed(stream) if "szi" in x), None)
   532	    cls = ("indeterminate" if not agreed else "zero-fill" if F == 0 else "full-fill" if F == sz else
   533	           "partial" if 0 < F < sz else "indeterminate")
   534	    row.update({"oid": oid, "fills": fs, "F": F, "fills_hist": hist, "class": cls, "stream": stream, "after": after,
   535	                "last_fill_time": max((f["time"] for f in fs), default=None)})
   536	    want_after = expect_after(F) if callable(expect_after) else expect_after
   537	    row["want_after"] = want_after
   538	    if pending != cloid:
   539	        stop5(row, "pendingCloid after send is not this order's cloid")
   540	    if (o_.get("cloid"), o_.get("coin"), o_.get("side"), lots(o_.get("origSz", "0")), px8(o_.get("limitPx", "0"))) != \
   541	            (row["cloid"], COIN, "B" if is_buy else "A", sz, px_8):
   542	        stop5(row, "order does not match what was sent")
   543	    if expect_status is not None and final != expect_status:
   544	        stop5(row, "expected %s, got %s" % (expect_status, final))
   545	    if callable(expect_after) and cls == "indeterminate":
   546	        stop5(row, "fills indeterminate")
   547	    if after is None or after != want_after:
   548	        stop5(row, "position %s, expected %s" % (after, want_after))
   549	    if after != before:  # question 3(b) only counts position-changing orders (review s5g #2)
   550	        row["bracket"] = bracket(stream, after)
   551	    else:
   552	        row["bracket"] = "target already present at receipt"
   553	    if ctx["g1"] and after != before:
   554	        row["pinned"] = pinned(pool, blk, after, row["block_ts"] + LIVE_FOR)
   555	    if int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0]) != cloid:
   556	        stop5(row, "pendingCloid changed before acknowledgement")
   557	    write5(row)
   558	    send(pool, env, "acknowledge(uint128)", cloid)
   559	    print(json.dumps({k: row.get(k) for k in ("cycle", "kind", "side", "label", "final", "F", "class", "after")}), flush=True)
   560	    return F, after, blk
   561	
   562	
   563	def bracket(stream, target):
   564	    """First live read showing `target`, the last read before it that did not, and whether any
   565	    failed read lies between them (then the bracket is degraded, review s5i1 #3). When no read
   566	    before the hit succeeded, the result is an upper bound from the receipt to the hit, labelled
   567	    "no observed post-receipt non-match" (review s5r1 #3), not a degraded bracket."""
   568	    hit = next((i for i, x in enumerate(stream) if x.get("szi") == target), None)
   569	    if hit is None:
   570	        return {"hit": None}
   571	    miss = next((i for i in range(hit - 1, -1, -1) if "szi" in stream[i]), None)
   572	    errs = sum(1 for x in stream[(miss if miss is not None else -1) + 1:hit] if "error" in x)
   573	    return {"first_hit": stream[hit], "last_miss": stream[miss] if miss is not None else None,
   574	            "errors_between": errs, "degraded": errs > 0 and miss is not None,
   575	            "upper_bound_only": "no observed post-receipt non-match" if miss is None else None}
   576	
   577	
   578	def stop5(row, why):
   579	    row["stopped"] = why
   580	    write5(row)
   581	    sys.exit("stopped, order left unacknowledged: " + why)
   582	
   583	
   584	def through(is_buy, bps=100):
   585	    return px5(oracle() * (1 + (bps if is_buy else -bps) / 1e4)) * 10**8
   586	
   587	
   588	# Opens (rawIoc, never reduce-only) go 2% through: the testnet book sat over 1% from the oracle and
   589	# an open at 1% found nothing (session 1, cycle 22; review s5r1 #2). Closes stay at 1% through, the
   590	# measured quantity. Every order5 row records its through_bps, so 1% and 2% opens stay apart.
   591	OPEN_BPS = 200
   592	
   593	
   594	def cycle5(ctx):
   595	    """One cycle of one kind on one side. Every kind starts and ends flat."""
   596	    k, s = ctx["kind"], ctx["side"]
   597	    close_buy = s < 0
   598	    if read_szi(ctx["pool"]) != 0:
   599	        sys.exit("cycle needs a flat position: use `status` / `unwind`")
   600	
   601	    def opn():
   602	        order5(ctx, "open", "rawIoc", s > 0, through(s > 0, OPEN_BPS), LOTS, "filled", s * LOTS, OPEN_BPS)
   603	
   604	    def close(label="close", sz=LOTS):
   605	        order5(ctx, label, "rawIocReduceOnly", close_buy, through(close_buy), sz, "filled", 0, 100)
   606	
   607	    if k == "close-fill":
   608	        opn(); close()
   609	    elif k == "close-tight":
   610	        opn()
   611	        wrong = px5(oracle() * (0.85 if close_buy else 1.15)) * 10**8
   612	        order5(ctx, "close-tight", "rawIocReduceOnly", close_buy, wrong, LOTS, "iocCancelRejected", s * LOTS)
   613	        close("close-second")
   614	    elif k == "close-partial":
   615	        opn()
   616	        t = time.monotonic()
   617	        book = info({"type": "l2Book", "coin": COIN})
   618	        snap = {"line": "book5", "pool": ctx["pool"], "chain": 998, "cycle": ctx["cycle"], "send_wall": round(time.time(), 3),
   619	                "took": round(time.monotonic() - t, 3), "book": book}
   620	        side_levels = book["levels"][1 if close_buy else 0]
   621	        touch = side_levels[0] if side_levels else None
   622	        snap["touch"] = touch
   623	        write5(snap)
   624	        if touch is None or lots(touch["sz"]) >= LOTS:
   625	            write5({"line": "skip", "pool": ctx["pool"], "chain": 998, "cycle": ctx["cycle"], "kind": k, "side": s, "touch": touch})
   626	            close("cleanup")
   627	            return
   628	        # the touch is a price Core itself quotes, so it is already on BTC's tick (review s5i1 #2);
   629	        # one that cannot be represented is recorded and the position closed (review s5i2 #2)
   630	        try:
   631	            tpx = px8(touch["px"])
   632	        except ValueError as e:
   633	            write5({"line": "skip", "pool": ctx["pool"], "chain": 998, "cycle": ctx["cycle"], "kind": k, "side": s, "touch": touch, "why": str(e)})
   634	            close("cleanup")
   635	            return
   636	        F, after, _ = order5(ctx, "close-partial", "rawIocReduceOnly", close_buy, tpx, LOTS, None,
   637	                             lambda F: s * (LOTS - (F or 0)))
   638	        if after != 0:
   639	            close("close-residual", abs(after))
   640	    elif k == "close-flat":
   641	        order5(ctx, "close-flat", "rawIocReduceOnly", close_buy, through(close_buy), LOTS, None, 0, 100)
   642	    elif k == "close-over":
   643	        opn()
   644	        order5(ctx, "close-over", "rawIocReduceOnly", close_buy, through(close_buy), 2 * LOTS, None, 0, 100)
   645	    elif k == "close-wrongside":
   646	        opn()
   647	        order5(ctx, "close-wrongside", "rawIocReduceOnly", s > 0, through(s > 0), LOTS, None, s * LOTS, 100)
   648	        close("close-after-wrongside")
   649	    else:
   650	        sys.exit("unknown kind " + k)
   651	
   652	
   653	def testnet_ctx(pool):
   654	    if int(cast("chain-id", "-r", RPC)) != 998:
   655	        sys.exit("not testnet")
   656	    return {"pool": pool.lower(), "env": key_env(), "topics": raw_topics(), "g1": False}
   657	
   658	
   659	def step5(pool, cycles, seed=None):
   660	    """The next `cycles` items of a plan shuffled once with a recorded seed (spec: random order,
   661	    several sessions). The plan advances only when a cycle completes."""
   662	    if os.path.exists(PLAN_FILE):
   663	        with open(PLAN_FILE) as f:
   664	            plan = json.load(f)
   665	        if seed is not None and seed != plan["seed"]:
   666	            sys.exit("a plan with seed %s exists" % plan["seed"])
   667	        if plan.get("pool") != pool.lower() or plan.get("chain") != 998:
   668	            sys.exit("the plan belongs to pool %s: move it aside to start one for this pool (review s5i3)" % plan.get("pool"))
   669	    else:
   670	        if seed is None:
   671	            sys.exit("first session: give a seed")
   672	        items = [[k, s] for (k, s), n in sorted(PLAN.items()) for _ in range(n)]
   673	        random.Random(seed).shuffle(items)
   674	        plan = {"seed": seed, "pool": pool.lower(), "chain": 998, "items": items, "done": 0}
   675	    passed = require_g1(pool)
   676	    ctx = testnet_ctx(pool)
   677	    ctx["g1"] = passed
   678	    g = g1_result(pool)
   679	    write5({"line": "session", "start": round(time.time(), 3), "sntp": sntp(), "seed": plan["seed"],
   680	            "pool": ctx["pool"], "chain": 998, "done": plan["done"],
   681	            "g1": {"passed": g["passed"], "at": g["at"], "a": g["a"], "c": g["c"]}})
   682	    why = "completed"
   683	    try:
   684	        for _ in range(cycles):
   685	            if plan["done"] >= len(plan["items"]):
   686	                print("plan complete")
   687	                break
   688	            k, s = plan["items"][plan["done"]]
   689	            ctx.update({"cycle": plan["done"], "kind": k, "side": s})
   690	            cycle5(ctx)
   691	            plan["done"] += 1
   692	            tmp = PLAN_FILE + ".tmp"
   693	            with open(tmp, "w") as f:
   694	                json.dump(plan, f)
   695	            os.replace(tmp, PLAN_FILE)
   696	    except BaseException as e:  # a stop (SystemExit) or a crash still ends the session on record (review s5r1 #4)
   697	        why = "stopped: " + (str(e) if isinstance(e, SystemExit) else repr(e))[:200]
   698	        raise
   699	    finally:
   700	        write5({"line": "session_end", "pool": ctx["pool"], "end": round(time.time(), 3), "sntp": sntp(),
   701	                "done": plan["done"], "why": why})
   702	
   703	
   704	def ackopen(pool):
   705	    """Recovery for a stopped opening order (review s5r1 #1): acknowledge it only if the pending cloid
   706	    is the one in the last stopped row, that row is an opening rawIoc, its status is terminal, the
   707	    pool has no open orders, and the position is flat and equal to the row's position before. The
   708	    checks and the transaction are recorded in step5.jsonl. Anything else stays for a person."""
   709	    ctx = testnet_ctx(pool)
   710	    pool = ctx["pool"]
   711	    rows = [json.loads(l) for l in open(STEP5_OUT)]
   712	    last = next((r for r in reversed(rows) if r.get("line") == "order5" and r.get("pool") == pool), None)
   713	    pc = int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0])
   714	    st = info({"type": "orderStatus", "user": pool, "oid": "0x%032x" % pc}) if pc else None
   715	    final = (st or {}).get("order", {}).get("status") if (st or {}).get("status") == "order" else None
   716	    oo = info({"type": "openOrders", "user": pool})
   717	    szi = read_szi(pool)
   718	    checks = {"pending": "0x%032x" % pc, "last_stopped_cloid": (last or {}).get("cloid"),
   719	              "last_stopped": (last or {}).get("stopped"), "fn": (last or {}).get("fn"), "label": (last or {}).get("label"),
   720	              "status": final, "open_orders": len(oo), "szi": szi, "before": (last or {}).get("before")}
   721	    ok = (pc != 0 and last is not None and last.get("stopped") and last.get("cloid") == checks["pending"]
   722	          and last.get("fn") == "rawIoc" and last.get("label") == "open" and final in TERMINAL and final != "filled"
   723	          and not oo and szi == 0 and last.get("before") == 0)
   724	    rec = {"line": "manual_ack", "pool": pool, "chain": 998, "cycle": (last or {}).get("cycle"), "wall": round(time.time(), 3),
   725	           "checks": checks, "ok": bool(ok)}
   726	    if not ok:
   727	        write5(rec)
   728	        sys.exit("not acknowledged: " + json.dumps(checks))
   729	    tx, _, rc = send(pool, ctx["env"], "acknowledge(uint128)", pc)
   730	    rec.update({"tx": tx, "block": int(rc["blockNumber"], 16)})
   731	    write5(rec)
   732	    print(json.dumps(rec))
   733	
   734	
   735	def g1(pool):
<scratchpad>/s1/step5-s1.log
<scratchpad>/s1/orders.jsonl
<scratchpad>/s1/step5.jsonl
<scratchpad>/s1/g1.json
<scratchpad>/s1/step5_plan.json

exec
/bin/zsh -lc "rg -n -C 4 'Finding|VERDICT|manual|session_end|through|bracket' <scratchpad>/s5r1.out | tail -n 220; nl -ba docs/step5-close-from-evm-spec.md | sed -n '1,175p'; rg -n 'order5\\(' recorder/orders.py" in ~/src/hyperevm-perp
 succeeded in 0ms:
2683-    """Gate G1 (review s5i1 #1): open (receipt block A), close (receipt block C), then read 0x800
--
2688-    ctx = testnet_ctx(pool)
2689-    ctx.update({"cycle": "g1", "kind": "g1", "side": 1, "g1": False})
2690-    if read_szi(ctx["pool"]) != 0:
2691-        sys.exit("G1 needs a flat position")
2692:    _, _, a = order5(ctx, "g1-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
2693:    _, _, c = order5(ctx, "g1-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)
2694-    end = c + 15
2695-    while int(rpc("eth_blockNumber"), 16) <= end:
2696-        time.sleep(2)
2697-    reads = []
--
2788-    write5(row)
2789-    sys.exit("stopped, order left unacknowledged: " + why)
2790-
2791-
2792:def through(is_buy):
2793-    return px5(oracle() * (1.01 if is_buy else 0.99)) * 10**8
2794-
2795-
2796-def cycle5(ctx):
--
2800-    if read_szi(ctx["pool"]) != 0:
2801-        sys.exit("cycle needs a flat position: use `status` / `unwind`")
2802-
2803-    def opn():
2804:        order5(ctx, "open", "rawIoc", s > 0, through(s > 0), LOTS, "filled", s * LOTS)
2805-
2806-    def close(label="close", sz=LOTS):
2807:        order5(ctx, label, "rawIocReduceOnly", close_buy, through(close_buy), sz, "filled", 0)
2808-
2809-    if k == "close-fill":
2810-        opn(); close()
2811-    elif k == "close-tight":
--
2839-                             lambda F: s * (LOTS - (F or 0)))
2840-        if after != 0:
2841-            close("close-residual", abs(after))
2842-    elif k == "close-flat":
2843:        order5(ctx, "close-flat", "rawIocReduceOnly", close_buy, through(close_buy), LOTS, None, 0)
2844-    elif k == "close-over":
2845-        opn()
2846:        order5(ctx, "close-over", "rawIocReduceOnly", close_buy, through(close_buy), 2 * LOTS, None, 0)
2847-    elif k == "close-wrongside":
2848-        opn()
2849:        order5(ctx, "close-wrongside", "rawIocReduceOnly", s > 0, through(s > 0), LOTS, None, s * LOTS)
2850-        close("close-after-wrongside")
2851-    else:
2852-        sys.exit("unknown kind " + k)
2853-
--
2892-        tmp = PLAN_FILE + ".tmp"
2893-        with open(tmp, "w") as f:
2894-            json.dump(plan, f)
2895-        os.replace(tmp, PLAN_FILE)
2896:    write5({"line": "session_end", "pool": ctx["pool"], "end": round(time.time(), 3), "sntp": sntp(), "done": plan["done"]})
2897-
2898-
2899-def g1(pool):
2900-    """Gate G1 (review s5i1 #1): open (receipt block A), close (receipt block C), then read 0x800
--
2905-    ctx = testnet_ctx(pool)
2906-    ctx.update({"cycle": "g1", "kind": "g1", "side": 1, "g1": False})
2907-    if read_szi(ctx["pool"]) != 0:
2908-        sys.exit("G1 needs a flat position")
2909:    _, _, a = order5(ctx, "g1-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
2910:    _, _, c = order5(ctx, "g1-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)
2911-    end = c + 15
2912-    while int(rpc("eth_blockNumber"), 16) <= end:
2913-        time.sleep(2)
2914-    reads = []
--
2940-
2941-codex
2942-The stop itself is correctly fail-closed, but I’ve found a policy mismatch: the failed opening did not satisfy the table’s conditions for acknowledgement. I’m now checking whether the persisted rows and plan preserve enough evidence to resume without silently counting it.
2943-exec
2944:/bin/zsh -lc "jq -s '[.[] | select(type==\"object\" and .line==\"order5\" and (.after "'!= .before)) | {cycle,label,first:(.stream[0]),bracket}]'"' <scratchpad>/s1/step5.jsonl | {n:length, first_flat:(map(select(.bracket.degraded==true))|length), no_miss:(map(select(.bracket.last_miss==null))|length), errors:(map(select(.bracket.errors_between>0))|length), samples:(map(.first.recv)|{min:min,max:max})}'" in ~/src/hyperevm-perp
2945- exited 1 in 0ms:
2946-zsh:1: parse error near `)'
2947-
2948-exec
2949:/bin/zsh -lc "jq -s '{sessions:[.[]|select(type==\"object\" and (.line==\"session\" or .line==\"session_end\"))], skips:[.[]|select(type==\"object\" and .line==\"skip\")], books:[.[]|select(type==\"object\" and .line==\"book5\")|{cycle,touch,send_wall,took}], g1:[.[]|select(type==\"object\" and .line==\"g1\")]}' <scratchpad>/s1/step5.jsonl" in ~/src/hyperevm-perp
2950- succeeded in 0ms:
2951-{
2952-  "sessions": [
2953-    {
--
3228-  ]
3229-}
3230-
3231-exec
3232:/bin/zsh -lc "jq -s -c '.[] | select(type==\"object\" and .line==\"order5\") | {cycle,label,kind,side,cloid,final,before,after,want_after,F,class,stopped,stream_n:(.stream|length),bracket}' <scratchpad>/s1/step5.jsonl" in ~/src/hyperevm-perp
3233- succeeded in 0ms:
3234:{"cycle":"g1","label":"g1-open","kind":"g1","side":1,"cloid":"0x80000000000000000000000000000001","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.028,"bn_before":68156552,"bn_after":68156552,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3235:{"cycle":"g1","label":"g1-close","kind":"g1","side":1,"cloid":"0x80000000000000000000000000000002","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.027,"bn_before":68156586,"bn_after":68156586,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3236:{"cycle":0,"label":"open","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000003","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.526,"bn_before":68156827,"bn_after":68156827,"szi":15},"last_miss":{"send":0.0,"recv":0.028,"bn_before":68156825,"bn_after":68156825,"szi":0},"errors_between":0,"degraded":false}}
3237:{"cycle":0,"label":"close","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000004","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.04,"bn_before":68156860,"bn_after":68156860,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3238:{"cycle":1,"label":"open","kind":"close-tight","side":-1,"cloid":"0x80000000000000000000000000000005","final":"filled","before":0,"after":-15,"want_after":-15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.023,"bn_before":68156894,"bn_after":68156894,"szi":-15},"last_miss":null,"errors_between":0,"degraded":true}}
3239:{"cycle":1,"label":"close-tight","kind":"close-tight","side":-1,"cloid":"0x80000000000000000000000000000006","final":"iocCancelRejected","before":-15,"after":-15,"want_after":-15,"F":0,"class":"zero-fill","stopped":null,"stream_n":12,"bracket":"target already present at receipt"}
3240:{"cycle":1,"label":"close-second","kind":"close-tight","side":-1,"cloid":"0x80000000000000000000000000000007","final":"filled","before":-15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.023,"bn_before":68156962,"bn_after":68156962,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3241:{"cycle":2,"label":"open","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000008","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.029,"bn_before":68156997,"bn_after":68156997,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3242:{"cycle":2,"label":"close","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000009","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.527,"bn_before":68157036,"bn_after":68157036,"szi":0},"last_miss":{"send":0.0,"recv":0.035,"bn_before":68157034,"bn_after":68157034,"szi":15},"errors_between":0,"degraded":false}}
3243:{"cycle":3,"label":"open","kind":"close-fill","side":1,"cloid":"0x8000000000000000000000000000000a","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.045,"bn_before":68157067,"bn_after":68157067,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3244:{"cycle":3,"label":"close","kind":"close-fill","side":1,"cloid":"0x8000000000000000000000000000000b","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.027,"bn_before":68157102,"bn_after":68157102,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3245:{"cycle":4,"label":"open","kind":"close-fill","side":1,"cloid":"0x8000000000000000000000000000000c","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.024,"bn_before":68157136,"bn_after":68157136,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3246:{"cycle":4,"label":"close","kind":"close-fill","side":1,"cloid":"0x8000000000000000000000000000000d","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.025,"bn_before":68157171,"bn_after":68157171,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3247:{"cycle":5,"label":"open","kind":"close-fill","side":-1,"cloid":"0x8000000000000000000000000000000e","final":"filled","before":0,"after":-15,"want_after":-15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.502,"recv":2.525,"bn_before":68157207,"bn_after":68157207,"szi":-15},"last_miss":{"send":0.0,"recv":0.028,"bn_before":68157205,"bn_after":68157205,"szi":0},"errors_between":0,"degraded":false}}
3248:{"cycle":5,"label":"close","kind":"close-fill","side":-1,"cloid":"0x8000000000000000000000000000000f","final":"filled","before":-15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.032,"bn_before":68157240,"bn_after":68157240,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3249:{"cycle":6,"label":"open","kind":"close-fill","side":-1,"cloid":"0x80000000000000000000000000000010","final":"filled","before":0,"after":-15,"want_after":-15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.023,"bn_before":68157277,"bn_after":68157277,"szi":-15},"last_miss":null,"errors_between":0,"degraded":true}}
3250:{"cycle":6,"label":"close","kind":"close-fill","side":-1,"cloid":"0x80000000000000000000000000000011","final":"filled","before":-15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.526,"bn_before":68157313,"bn_after":68157313,"szi":0},"last_miss":{"send":0.001,"recv":0.03,"bn_before":68157311,"bn_after":68157311,"szi":-15},"errors_between":0,"degraded":false}}
3251:{"cycle":7,"label":"open","kind":"close-tight","side":1,"cloid":"0x80000000000000000000000000000012","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.023,"bn_before":68157345,"bn_after":68157345,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3252:{"cycle":7,"label":"close-tight","kind":"close-tight","side":1,"cloid":"0x80000000000000000000000000000013","final":"iocCancelRejected","before":15,"after":15,"want_after":15,"F":0,"class":"zero-fill","stopped":null,"stream_n":12,"bracket":"target already present at receipt"}
3253:{"cycle":7,"label":"close-second","kind":"close-tight","side":1,"cloid":"0x80000000000000000000000000000014","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.527,"bn_before":68157416,"bn_after":68157416,"szi":0},"last_miss":{"send":0.001,"recv":0.025,"bn_before":68157414,"bn_after":68157414,"szi":15},"errors_between":0,"degraded":false}}
3254:{"cycle":8,"label":"open","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000015","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.024,"bn_before":68157447,"bn_after":68157447,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3255:{"cycle":8,"label":"close","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000016","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.029,"bn_before":68157482,"bn_after":68157482,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3256:{"cycle":9,"label":"open","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000017","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.0,"recv":0.023,"bn_before":68157519,"bn_after":68157519,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3257:{"cycle":9,"label":"close","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000018","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.024,"bn_before":68157553,"bn_after":68157553,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3258:{"cycle":10,"label":"open","kind":"close-partial","side":-1,"cloid":"0x80000000000000000000000000000019","final":"filled","before":0,"after":-15,"want_after":-15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.529,"bn_before":68157590,"bn_after":68157590,"szi":-15},"last_miss":{"send":0.001,"recv":0.028,"bn_before":68157588,"bn_after":68157588,"szi":0},"errors_between":0,"degraded":false}}
3259:{"cycle":10,"label":"cleanup","kind":"close-partial","side":-1,"cloid":"0x8000000000000000000000000000001a","final":"filled","before":-15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.026,"bn_before":68157622,"bn_after":68157622,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3260:{"cycle":11,"label":"open","kind":"close-fill","side":-1,"cloid":"0x8000000000000000000000000000001b","final":"filled","before":0,"after":-15,"want_after":-15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.034,"bn_before":68157657,"bn_after":68157657,"szi":-15},"last_miss":null,"errors_between":0,"degraded":true}}
3261:{"cycle":11,"label":"close","kind":"close-fill","side":-1,"cloid":"0x8000000000000000000000000000001c","final":"filled","before":-15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.029,"bn_before":68157691,"bn_after":68157691,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3262:{"cycle":12,"label":"open","kind":"close-over","side":1,"cloid":"0x8000000000000000000000000000001d","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.525,"bn_before":68157728,"bn_after":68157728,"szi":15},"last_miss":{"send":0.001,"recv":0.027,"bn_before":68157726,"bn_after":68157726,"szi":0},"errors_between":0,"degraded":false}}
3263:{"cycle":12,"label":"close-over","kind":"close-over","side":1,"cloid":"0x8000000000000000000000000000001e","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"partial","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.528,"bn_before":68157765,"bn_after":68157765,"szi":0},"last_miss":{"send":0.001,"recv":0.033,"bn_before":68157761,"bn_after":68157761,"szi":15},"errors_between":0,"degraded":false}}
3264:{"cycle":13,"label":"open","kind":"close-over","side":-1,"cloid":"0x8000000000000000000000000000001f","final":"filled","before":0,"after":-15,"want_after":-15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.028,"bn_before":68157797,"bn_after":68157797,"szi":-15},"last_miss":null,"errors_between":0,"degraded":true}}
3265:{"cycle":13,"label":"close-over","kind":"close-over","side":-1,"cloid":"0x80000000000000000000000000000020","final":"filled","before":-15,"after":0,"want_after":0,"F":15,"class":"partial","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.023,"bn_before":68157832,"bn_after":68157832,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3266:{"cycle":14,"label":"open","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000021","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.031,"bn_before":68157866,"bn_after":68157866,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3267:{"cycle":14,"label":"close","kind":"close-fill","side":1,"cloid":"0x80000000000000000000000000000022","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.527,"bn_before":68157903,"bn_after":68157903,"szi":0},"last_miss":{"send":0.001,"recv":0.027,"bn_before":68157901,"bn_after":68157901,"szi":15},"errors_between":0,"degraded":false}}
3268:{"cycle":15,"label":"open","kind":"close-tight","side":1,"cloid":"0x80000000000000000000000000000023","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.023,"bn_before":68157935,"bn_after":68157935,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3269:{"cycle":15,"label":"close-tight","kind":"close-tight","side":1,"cloid":"0x80000000000000000000000000000024","final":"iocCancelRejected","before":15,"after":15,"want_after":15,"F":0,"class":"zero-fill","stopped":null,"stream_n":12,"bracket":"target already present at receipt"}
3270:{"cycle":15,"label":"close-second","kind":"close-tight","side":1,"cloid":"0x80000000000000000000000000000025","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":3.317,"bn_before":68158005,"bn_after":68158005,"szi":0},"last_miss":{"send":0.001,"recv":0.027,"bn_before":68158003,"bn_after":68158003,"szi":15},"errors_between":0,"degraded":false}}
3271:{"cycle":16,"label":"open","kind":"close-wrongside","side":-1,"cloid":"0x80000000000000000000000000000026","final":"filled","before":0,"after":-15,"want_after":-15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.024,"bn_before":68158037,"bn_after":68158037,"szi":-15},"last_miss":null,"errors_between":0,"degraded":true}}
3272:{"cycle":16,"label":"close-wrongside","kind":"close-wrongside","side":-1,"cloid":"0x80000000000000000000000000000027","final":"reduceOnlyRejected","before":-15,"after":-15,"want_after":-15,"F":0,"class":"zero-fill","stopped":null,"stream_n":12,"bracket":"target already present at receipt"}
3273:{"cycle":16,"label":"close-after-wrongside","kind":"close-wrongside","side":-1,"cloid":"0x80000000000000000000000000000028","final":"filled","before":-15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.529,"bn_before":68158108,"bn_after":68158108,"szi":0},"last_miss":{"send":0.001,"recv":0.023,"bn_before":68158106,"bn_after":68158106,"szi":-15},"errors_between":0,"degraded":false}}
3274:{"cycle":17,"label":"close-flat","kind":"close-flat","side":-1,"cloid":"0x80000000000000000000000000000029","final":"reduceOnlyRejected","before":0,"after":0,"want_after":0,"F":0,"class":"zero-fill","stopped":null,"stream_n":12,"bracket":"target already present at receipt"}
3275:{"cycle":18,"label":"open","kind":"close-fill","side":-1,"cloid":"0x8000000000000000000000000000002a","final":"filled","before":0,"after":-15,"want_after":-15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.027,"bn_before":68158175,"bn_after":68158175,"szi":-15},"last_miss":null,"errors_between":0,"degraded":true}}
3276:{"cycle":18,"label":"close","kind":"close-fill","side":-1,"cloid":"0x8000000000000000000000000000002b","final":"filled","before":-15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.501,"recv":2.527,"bn_before":68158211,"bn_after":68158211,"szi":0},"last_miss":{"send":0.001,"recv":0.024,"bn_before":68158209,"bn_after":68158209,"szi":-15},"errors_between":0,"degraded":false}}
3277:{"cycle":19,"label":"open","kind":"close-fill","side":1,"cloid":"0x8000000000000000000000000000002c","final":"filled","before":0,"after":15,"want_after":15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.025,"bn_before":68158242,"bn_after":68158242,"szi":15},"last_miss":null,"errors_between":0,"degraded":true}}
3278:{"cycle":19,"label":"close","kind":"close-fill","side":1,"cloid":"0x8000000000000000000000000000002d","final":"filled","before":15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.023,"bn_before":68158277,"bn_after":68158277,"szi":0},"last_miss":null,"errors_between":0,"degraded":true}}
3279:{"cycle":20,"label":"open","kind":"close-wrongside","side":-1,"cloid":"0x8000000000000000000000000000002e","final":"filled","before":0,"after":-15,"want_after":-15,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":0.001,"recv":0.027,"bn_before":68158314,"bn_after":68158314,"szi":-15},"last_miss":null,"errors_between":0,"degraded":true}}
3280:{"cycle":20,"label":"close-wrongside","kind":"close-wrongside","side":-1,"cloid":"0x8000000000000000000000000000002f","final":"reduceOnlyRejected","before":-15,"after":-15,"want_after":-15,"F":0,"class":"zero-fill","stopped":null,"stream_n":12,"bracket":"target already present at receipt"}
3281:{"cycle":20,"label":"close-after-wrongside","kind":"close-wrongside","side":-1,"cloid":"0x80000000000000000000000000000030","final":"filled","before":-15,"after":0,"want_after":0,"F":15,"class":"full-fill","stopped":null,"stream_n":12,"bracket":{"first_hit":{"send":2.503,"recv":2.528,"bn_before":68158385,"bn_after":68158385,"szi":0},"last_miss":{"send":0.001,"recv":0.023,"bn_before":68158383,"bn_after":68158383,"szi":-15},"errors_between":0,"degraded":false}}
3282:{"cycle":21,"label":"close-flat","kind":"close-flat","side":-1,"cloid":"0x80000000000000000000000000000031","final":"reduceOnlyRejected","before":0,"after":0,"want_after":0,"F":0,"class":"zero-fill","stopped":null,"stream_n":12,"bracket":"target already present at receipt"}
3283:{"cycle":22,"label":"open","kind":"close-wrongside","side":1,"cloid":"0x80000000000000000000000000000032","final":"iocCancelRejected","before":0,"after":0,"want_after":15,"F":0,"class":"zero-fill","stopped":"expected filled, got iocCancelRejected","stream_n":12,"bracket":null}
3284-
3285-exec
3286-/bin/zsh -lc "jq -s '[.[] | select(type==\"object\" and .line==\"order5\") | select(.stopped|not) | select((.final==null) or (.after "'!= .want_after)) | {cycle,label,final,before,after,want_after,F,class,stopped}]'"' <scratchpad>/s1/step5.jsonl; jq -s '[.[] | select(type==\"object\" and .line==\"order5\") | .cycle] | group_by(.) | map({cycle:.[0],n:length})' <scratchpad>/s1/step5.jsonl" in ~/src/hyperevm-perp
3287- succeeded in 0ms:
--
3398-  "max": 27.617
3399-}
3400-
3401-exec
3402:/bin/zsh -lc "jq -s '[.[] | select(type==\"object\" and .line==\"order5\" and .after "'!= .before) | select(.bracket|type=="object") | {cycle,label,first:.bracket.first_hit,last:.bracket.last_miss,degraded:.bracket.degraded}] | {n:length,first_at_receipt:(map(select(.last==null))|length),next_read:(map(select(.last!=null))|length),errors:(map(select(.degraded==false)|length)}'"' <scratchpad>/s1/step5.jsonl" in ~/src/hyperevm-perp
3403- exited 3 in 0ms:
3404-jq: error: syntax error, unexpected INVALID_CHARACTER (Unix shell quoting issues?) at <top-level>, line 1:
3405:[.[] | select(type=="object" and .line=="order5" and .after != .before) | select(.bracket|type=="object") | {cycle,label,first:.bracket.first_hit,last:.bracket.last_miss,degraded:.bracket.degraded}] | {n:length,first_at_receipt:(map(select(.last==null))|length),next_read:(map(select(.last!=null))|length),errors:(map(select(.degraded==false)|length)}                                                                                                                                                                                                                                                                                                                                                              
3406-jq: 1 compile error
3407-
3408-exec
3409-/bin/zsh -lc "jq -s '[.[]|select(type==\"object\" and .line==\"sent\")]|length as "'$sent | [.[]|select(type=="object" and .line=="sent" and .sig=="acknowledge(uint128)")]|length as $acks | {sent:$sent,automatic_ack_sends:$acks,nonack_sends:($sent-$acks),last_ack:([.[]|select(type=="object" and .line=="sent" and .sig=="acknowledge(uint128)")][-1])}'"' <scratchpad>/s1/orders.jsonl" in ~/src/hyperevm-perp
--
3424-  }
3425-}
3426-
3427-exec
3428:/bin/zsh -lc "jq -s '[.[] | select(type==\"object\" and .line==\"order5\" and .after "'!= .before and .cycle != "g1") | select(.label != "open") | {cycle,label,first_recv:.bracket.first_hit.recv,has_last:(.bracket.last_miss != null),degraded:.bracket.degraded}] | {n:length,first_hit_at_receipt:(map(select(.has_last|not))|length),next_sample:(map(select(.has_last))|length),values:.}'"' <scratchpad>/s1/step5.jsonl" in ~/src/hyperevm-perp
3429- succeeded in 0ms:
3430-{
3431-  "n": 20,
3432-  "first_hit_at_receipt": 11,
--
3592-  120
3593-]
3594-
3595-codex
3596:VERDICT: CHANGES
3597-
3598:1. **Medium — the manual acknowledgement was safe operationally, but not compliant with the written acknowledge rule.**  
3599:   Cycle 22’s opening row expected `filled` and `after: +15`; it got `iocCancelRejected` and `after: 0` (`cloid …32`). The recorder correctly stopped and did not automatically acknowledge it. The supplied manual checks establish that unlocking was safe, but the spec only permits acknowledgement when status and resulting position match that row. Amend the spec/recorder recovery procedure to permit a documented human acknowledgement of a terminal failed opening only after exact-pending-cloid, terminal-status, no-open-orders, and flat-position checks. Record the manual acknowledgement transaction and checks in `step5.jsonl`.
3600-
3601-2. **Medium — do not rerun unchanged; widen only non-reduce-only opens to 2%, and record the protocol change.**  
3602:   The failed open’s oracle was 80,055.7 and its 1% buy limit 80,856, while the displayed ask was about 80,948 (>1%). A 2% open limit is appropriate for this testnet operational precondition; leave all reduce-only close limits at 1% through. This does not alter close-status or close-visibility measurements, but it can affect opening fill price, fees, and any opening-order question-1 observations (and indirectly the account-value level in `lag`). Label/stratify 1% and 2% opening data; do not silently pool opening timing results.
3603-
3604:3. **Medium — clarify the first-hit bracket before session 2.**  
3605:   The 2.5 s cadence does not make questions 1 or 3(b) unanswerable. It begins immediately at receipt: 11 of 20 position-changing closes first showed flat at 23–40 ms; the other 9 were first seen at 2.526–3.317 s with a preceding non-match. The first group supports a one-sided receipt-to-first-read upper bound, not a two-read transition bracket. The spec should explicitly say: when the first live read matches, the lower endpoint is receipt arrival and it is labelled “no observed post-receipt non-match,” rather than treating it as a failed/degraded bracket. No faster polling is required or advisable: the existing three-RPC-call sample costs about 72 requests/min, leaving headroom under 100/min.
3606-
3607-4. **Low — the aborted session has no recorded end/NTP result, and the out-of-band acknowledgement is absent from the artifacts.**  
3608:   `step5.jsonl` has the session start but no `session_end`; `sntp` also recorded `FileNotFoundError`. Add a durable recovery/session-end record before resuming. NTP absence does not invalidate the local-clock 3(a)/3(b) data, but it must be disclosed for question 1’s cross-clock context.
3609-
3610-Answers to the specific checks:
3611-
3612:- **(a) G1 conclusion is sound, narrowly stated.** The historical calls cannot be accepted: all 55 explicit blocks from `A−5` through `C+15` returned zero, despite the G1 live streams reading `+15` at block 68,156,552 and `0` at 68,156,586. This strongly rules out bad calldata encoding and establishes that current/live `0x800` works. It does not prove the RPC literally substituted `latest`; it could be another historical-precompile failure. That distinction does not matter: G1 failed, so use live reads only.
3613-
3614-- **(b) Plan state is otherwise consistent.** `done` remains 22, and item 22 is still `["close-wrongside", 1]`; the failed opening is not double-counted as a completed cycle. There is exactly one stopped cycle-22 row and no subsequent cycle-22 close row. It must, however, be reported as an unexpected failed opening/exclusion.
3615-
3616:- **(e) Aside from cycle 22 and the missing manual-recovery/session-end audit records, no contradiction appears.** The prior 22 cycles conform to their rows; cycle 10 correctly records `close-partial` as skipped because touch size was 0.3 BTC, greater than the 15-lot position.
3617-tokens used
3618-69,499
3619:VERDICT: CHANGES
3620-
3621:1. **Medium — the manual acknowledgement was safe operationally, but not compliant with the written acknowledge rule.**  
3622:   Cycle 22’s opening row expected `filled` and `after: +15`; it got `iocCancelRejected` and `after: 0` (`cloid …32`). The recorder correctly stopped and did not automatically acknowledge it. The supplied manual checks establish that unlocking was safe, but the spec only permits acknowledgement when status and resulting position match that row. Amend the spec/recorder recovery procedure to permit a documented human acknowledgement of a terminal failed opening only after exact-pending-cloid, terminal-status, no-open-orders, and flat-position checks. Record the manual acknowledgement transaction and checks in `step5.jsonl`.
3623-
3624-2. **Medium — do not rerun unchanged; widen only non-reduce-only opens to 2%, and record the protocol change.**  
3625:   The failed open’s oracle was 80,055.7 and its 1% buy limit 80,856, while the displayed ask was about 80,948 (>1%). A 2% open limit is appropriate for this testnet operational precondition; leave all reduce-only close limits at 1% through. This does not alter close-status or close-visibility measurements, but it can affect opening fill price, fees, and any opening-order question-1 observations (and indirectly the account-value level in `lag`). Label/stratify 1% and 2% opening data; do not silently pool opening timing results.
3626-
3627:3. **Medium — clarify the first-hit bracket before session 2.**  
3628:   The 2.5 s cadence does not make questions 1 or 3(b) unanswerable. It begins immediately at receipt: 11 of 20 position-changing closes first showed flat at 23–40 ms; the other 9 were first seen at 2.526–3.317 s with a preceding non-match. The first group supports a one-sided receipt-to-first-read upper bound, not a two-read transition bracket. The spec should explicitly say: when the first live read matches, the lower endpoint is receipt arrival and it is labelled “no observed post-receipt non-match,” rather than treating it as a failed/degraded bracket. No faster polling is required or advisable: the existing three-RPC-call sample costs about 72 requests/min, leaving headroom under 100/min.
3629-
3630-4. **Low — the aborted session has no recorded end/NTP result, and the out-of-band acknowledgement is absent from the artifacts.**  
3631:   `step5.jsonl` has the session start but no `session_end`; `sntp` also recorded `FileNotFoundError`. Add a durable recovery/session-end record before resuming. NTP absence does not invalidate the local-clock 3(a)/3(b) data, but it must be disclosed for question 1’s cross-clock context.
3632-
3633-Answers to the specific checks:
3634-
3635:- **(a) G1 conclusion is sound, narrowly stated.** The historical calls cannot be accepted: all 55 explicit blocks from `A−5` through `C+15` returned zero, despite the G1 live streams reading `+15` at block 68,156,552 and `0` at 68,156,586. This strongly rules out bad calldata encoding and establishes that current/live `0x800` works. It does not prove the RPC literally substituted `latest`; it could be another historical-precompile failure. That distinction does not matter: G1 failed, so use live reads only.
3636-
3637-- **(b) Plan state is otherwise consistent.** `done` remains 22, and item 22 is still `["close-wrongside", 1]`; the failed opening is not double-counted as a completed cycle. There is exactly one stopped cycle-22 row and no subsequent cycle-22 close row. It must, however, be reported as an unexpected failed opening/exclusion.
3638-
3639:- **(e) Aside from cycle 22 and the missing manual-recovery/session-end audit records, no contradiction appears.** The prior 22 cycles conform to their rows; cycle 10 correctly records `close-partial` as skipped because touch size was 0.3 BTC, greater than the 15-lot position.
     1	# Step 5 (spec): seeing and closing a contract's Core position from the EVM
     2	
     3	Status: spec s5h APPROVE, built (s5i5 APPROVE); amended after testnet session 1 (review s5r1, below).
     4	
     5	Steps 3 and 4 showed that a CoreWriter order reaches a final `orderStatus` within about 2 s. Step 5
     6	asks the next question: if a contract's Core perp position backs something on the EVM side, how far
     7	apart are the contract's precompile view and Core's own view, and how quickly and reliably can a
     8	contract flatten that position with reduce-only orders sent through CoreWriter.
     9	
    10	**Scope (s5 #1).** These are measurements of CoreWriter and precompile primitives, using a
    11	testnet-only reduce-only order. They are not measurements of `HedgedPerp`'s own path: there,
    12	`liquidate()` only removes EVM exposure and a later `hedge()` sends a non-reduce-only IOC sized from
    13	`coreLots()`. That path is unchanged by this step and its results do not describe it.
    14	
    15	## Questions
    16	1. **Position visibility after the order's last fill.** From the last fill that contributes to an
    17	   order (the latest `time` among the `userFills` entries with its oid; for a single fill, that
    18	   fill) to the first contract-style `0x800` read showing the order's final size. The end depends
    19	   on a gate (see Recorder, gate G1): if `eth_call` at an explicit old block number is shown to
    20	   return that block's `0x800` state, the first matching block is found by backfill; if not (the
    21	   public RPC is already known to ignore block numbers for `0x807`, hl-price-guard
    22	   docs/safe-limits.md), the end is the first live read with the final size.
    23	   **Clocks.** Core's fill `time`, EVM block timestamps (whole seconds) and the local clock are
    24	   different clocks with no shared calibration. Question 1 is therefore reported as a
    25	   **cross-clock delta**, labelled as such and not as a latency bound; the local clock's NTP offset
    26	   (`sntp`) at the start and end of each session is recorded alongside for context only.
    27	2. **Divergence from the info API.** While a position is open, paired readings of account value
    28	   (`0x80F` vs `clearinghouseState`) and oracle price (`0x807` vs `metaAndAssetCtxs`). These are not
    29	   a common snapshot; the report gives the difference together with the block read, each request's
    30	   send and receive time and their order. No claim of "precompile staleness" is drawn from them.
    31	   (BBO `0x80E` is dropped from step 5.)
    32	3. **Close latency, as the client observes it.** From the receipt of the transaction that sends a
    33	   reduce-only IOC to (a) the first `orderStatus` response carrying a terminal status, bounded by
    34	   the send and receive times of that poll and of the previous non-terminal poll (when the first
    35	   poll is already terminal, the lower bound is the receipt's arrival), and (b) the first live
    36	   `0x800` read with the expected size, bounded by the send/receive times of that read and of the
    37	   last read without it. Both (a) and (b) use only the local monotonic clock (receipt arrival and
    38	   request times), so they are defensible client-observed brackets. Block timestamps are recorded
    39	   but not mixed into these figures.
    40	4. **Close outcomes**, for long and short positions. Every expected status below is a thing to
    41	   confirm, not an assumption; the recorder records whatever comes back and stops on a surprise.
    42	   - `close-fill`: open, then reduce-only close 1% through the oracle -> expected `filled`, flat.
    43	   - `close-tight`: reduce-only close 15% on the wrong side -> expected `iocCancelRejected`,
    44	     unchanged; then a second close 1% through -> expected `filled`. Time to flat over two attempts.
    45	   - `close-partial`: reduce-only close for the whole position limited at the touch, sent when the
    46	     touch's displayed size (raw snapshot with its request times kept) is smaller than the position;
    47	     then the residual is closed with a second reduce-only order. The attempt is classified from
    48	     fills, not from the book. All sizes are exact integer lots (BTC: szDecimals 5, so 0.00015 =
    49	     15 lots); `userFills` decimal `sz` strings are converted to lots exactly, without floats. Let
    50	     P = |szi| before the close and F = the sum, in lots, of all `userFills` entries whose numeric
    51	     exchange `oid` equals the `oid` in the terminal `orderStatus` record for this cloid (the cloid
    52	     itself is not used to match fills). Completeness: after the terminal status, re-read
    53	     `userFills` every 2 s until two consecutive reads give the same F and F agrees with the change
    54	     in `0x800` (|szi before| − |szi after|), or 30 s pass. Then `partial` only if 0 < F < P,
    55	     `zero-fill` if F = 0, `full-fill` if F = P; anything else, or no agreement within 30 s, is
    56	     `indeterminate`. Only observed
    57	     partials count toward this kind's results and bounds; the other classes are reported as
    58	     counts. Not attempted (and counted) when the touch is not smaller at send time.
    59	   - `close-flat`: reduce-only close with no position -> to confirm the status name (expected
    60	     `reduceOnlyRejected`) and that nothing opens.
    61	   - `close-over`: reduce-only close for twice the position -> to confirm that only the position is
    62	     closed.
    63	   - `close-wrongside`: reduce-only order in the same direction as the position -> to confirm it is
    64	     rejected and the position is unchanged.
    65	
    66	   `close-flat`, `close-over` and `close-wrongside` start in those states. They show what a
    67	   reduce-only order does when the position is already gone, smaller or reversed; they do **not**
    68	   exercise Core changing the position while a CoreWriter close is in flight. That race stays
    69	   untested in step 5 (see Not covered).
    70	5. **Displayed-book close estimate on mainnet (read only).** See the book method below.
    71	
    72	## Contract change
    73	`TestnetPricedPerp.rawIoc` sends `reduceOnly = false`. Add one testnet-only function:
    74	
    75	    function rawIocReduceOnly(bool isBuy, uint64 limitPx8, uint64 sz8) external onlyKeeper returns (uint128 cloid)
    76	
    77	identical to `rawIoc` (same single `pendingCloid` slot, reverts `OrderInFlight` while it is set,
    78	same cloid sequence, cleared only by `acknowledge(cloid)` with the exact pending cloid) except
    79	`reduceOnly = true`. No change to `HedgedPerp`. New testnet deployment with the big-block steps of
    80	step 3. Unit tests: the encoded action has the reduce-only flag set; the slot and acknowledge rules
    81	are identical to `rawIoc` (in-flight revert, wrong-cloid acknowledge reverts, sequence shared).
    82	
    83	Opening positions uses the existing `rawIoc`. **Every close and every recovery close uses
    84	`rawIocReduceOnly` (s5 #3).**
    85	
    86	## Recorder
    87	Extend `recorder/orders.py`:
    88	- `unwind` switches to `rawIocReduceOnly`. It still requires `pendingCloid == 0` and no open orders,
    89	  and acknowledges only on a terminal status for that exact cloid with the position then flat.
    90	- Acknowledge rule for every order: the pending cloid read from the contract equals the cloid this
    91	  client sent, `orderStatus` for that cloid returns a terminal status from the existing list, and
    92	  the status and the position after (in lots, from the live reads) match that order's row below.
    93	  Only then is it acknowledged and the next order sent. Anything else, or no terminal status within
    94	  60 s, stops the run and leaves the slot locked for `status` / manual handling. P is |szi| before
    95	  the order; s is the open direction.
    96	
    97	  | Kind, order | Expected status | Expected position after |
    98	  |---|---|---|
    99	  | any kind, opening `rawIoc` | `filled` | s × 15 |
   100	  | `close-fill`, close | `filled` | 0 |
   101	  | `close-tight`, first close | `iocCancelRejected` | unchanged (s × P) |
   102	  | `close-tight`, second close | `filled` | 0 |
   103	  | `close-partial`, first close | any terminal status; class from fills (partial / zero-fill / full-fill / indeterminate) | s × (P − F), agreeing with F; `indeterminate` stops the run |
   104	  | `close-partial`, residual close (only if position ≠ 0) | `filled` | 0 |
   105	  | `close-flat`, close | recorded (expected `reduceOnlyRejected`) | 0 |
   106	  | `close-over`, close for 2P | recorded (expected `filled`) | 0 |
   107	  | `close-wrongside`, same-direction reduce-only | recorded (expected a rejection) | unchanged (s × P) |
   108	  | `close-wrongside`, then closing reduce-only | `filled` | 0 |
   109	
   110	  For the three "recorded" rows the status name is what is being confirmed, so any terminal status
   111	  is acknowledged if the position matches; a position that does not match stops the run.
   112	- **Gate G1 (before any runs):** with the pool holding a position opened at a known block A and
   113	  closed at a later block C, call `0x800` by `eth_call` at block numbers before A, between A and C,
   114	  and after C, and record the results. Historical reads are accepted only if they return the size
   115	  each block should have had. The outcome is written into the step 5 write-up before question 1 or
   116	  3(b) is measured.
   117	- Live reads, always (question 3(b), and question 1's end if G1 fails): from the receipt's
   118	  arrival, poll `0x800` at `latest` as fast as the RPC limit allows (with `eth_blockNumber` before
   119	  and after each call), recording each request's send and receive time and result, for a fixed
   120	  30 s (or longer, until the order's fill total F is stable after its terminal status). The target
   121	  size is chosen afterwards from the order's row in the acknowledge table (for `close-partial`,
   122	  s × (P − F) once F is known), and the first read matching it and the last non-matching read
   123	  before it are selected from the recorded stream.
   124	- Question 3(b) counts only orders that change the position (`close-fill`, the second close of
   125	  `close-tight`, `close-partial` first and residual closes when F > 0, `close-over`, the closing
   126	  order of `close-wrongside`). Orders whose target equals the position before them
   127	  (`close-flat`, the first close of `close-tight`, the same-direction order of `close-wrongside`,
   128	  `close-partial` with F = 0) are reported separately as "target already present at receipt",
   129	  with 3(a) status timing as their measure.
   130	- Pinned reads, only if G1 passes (question 1's end only): after each order's block B, read
   131	  `0x800` pinned to each explicit block number from B onward (recording the block hash),
   132	  backfilling skipped blocks, until the final size is seen or 30 s of blocks pass; record the first
   133	  matching block and its timestamp. Run after the live stream so the two do not share the rate
   134	  budget.
   135	- Every `orderStatus` poll records its send and receive times (local monotonic clock) and the
   136	  status returned; every receipt records when it arrived.
   137	- Fill time source: `userFills` (info API) for the pool's Core account, matched by `oid`, using its
   138	  `time` field. If a fill cannot be matched there, the record says so and question 1 excludes it
   139	  (counted, not dropped silently).
   140	- `lag <pool> <n>`: with a position open, n paired readings for question 2, spaced at least 15 s.
   141	- `book <coin...>`: question 5, mainnet info API only, to `recorder/data/book.jsonl`, raw snapshot
   142	  included.
   143	- Kinds and sides are run in a random order (seed recorded).
   144	
   145	## Amendments after session 1 (review s5r1)
   146	Session 1 (2026-10-29): G1 failed (all 55 historical reads 0), so question 1 uses live reads only.
   147	The run stopped at cycle 22 of 120 when an opening `rawIoc` 1% through the oracle found nothing:
   148	the testnet book sat over 1% above the oracle. These apply from session 2:
   149	- **Opens go 2% through the oracle**; every close and recovery close stays at 1% (the measured
   150	  quantity). Each order row records `through_bps`; opening data at 1% (session 1) and 2% are
   151	  reported apart, never pooled. Closes are unaffected; opening fill price and fees are.
   152	- **A stopped open is recovered with `ackopen`**, the only manual acknowledgement: the pending cloid
   153	  must be the last stopped row's cloid, that row an opening `rawIoc` that did not fill, its status
   154	  terminal, no open orders, and the position flat (as before the order). The checks and the
   155	  transaction go into `step5.jsonl` as a `manual_ack` row; anything else stays for a person. Session
   156	  1's cycle-22 open was acknowledged by hand after the same checks, before this command existed; it
   157	  is recorded as `manual_ack_retro` (transaction hash not captured) and excluded from every count.
   158	- **Brackets.** Reads start at the receipt. When the first read already shows the target, the result
   159	  is an upper bound from the receipt to that read, labelled "no observed post-receipt non-match",
   160	  not a failed bracket. Otherwise the bracket is the last non-matching and the first matching read
   161	  (about 2.5 s apart at the current pace). The pace stays at 2.5 s (three calls a read, about 72
   162	  requests a minute against the RPC's 100).
   163	- **Every session ends on record**: `session_end` is written on completion, a stop, or a crash, with
   164	  the reason. The clock check uses `sntp`, or `chronyc tracking` on the AWS host.
   165	
   166	## Runs
   167	Testnet BTC perp (index 3), 0.00015 BTC per position (about 12 USD), same key as steps 3-4. Spread
   168	over at least three sessions on different days, including US and Asian hours.
   169	
   170	| Kind | n (long + short) |
   171	|---|---|
   172	| `close-fill` | 60 (30 + 30) |
   173	| `close-tight` | 20 (10 + 10) |
   174	| `close-partial` | 10 attempted (5 + 5; skips counted; a side with no observed partial gives no conclusion) |
   175	| `close-flat` | 10 |
479:def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after, through_bps=None):
602:        order5(ctx, "open", "rawIoc", s > 0, through(s > 0, OPEN_BPS), LOTS, "filled", s * LOTS, OPEN_BPS)
605:        order5(ctx, label, "rawIocReduceOnly", close_buy, through(close_buy), sz, "filled", 0, 100)
612:        order5(ctx, "close-tight", "rawIocReduceOnly", close_buy, wrong, LOTS, "iocCancelRejected", s * LOTS)
636:        F, after, _ = order5(ctx, "close-partial", "rawIocReduceOnly", close_buy, tpx, LOTS, None,
641:        order5(ctx, "close-flat", "rawIocReduceOnly", close_buy, through(close_buy), LOTS, None, 0, 100)
644:        order5(ctx, "close-over", "rawIocReduceOnly", close_buy, through(close_buy), 2 * LOTS, None, 0, 100)
647:        order5(ctx, "close-wrongside", "rawIocReduceOnly", s > 0, through(s > 0), LOTS, None, s * LOTS, 100)
745:    _, _, a = order5(ctx, "g1-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
746:    _, _, c = order5(ctx, "g1-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)
780:    order5(ctx, "lag-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
809:    order5(ctx, "lag-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)

exec
/bin/zsh -lc "nl -ba recorder/orders.py | sed -n '395,455p'; rg -n 'manual_ack_retro|cycle\":22|\"cycle\":22|session_end|\"stopped\"' <scratchpad>/s1/step5.jsonl; git diff --check; git status --short" in ~/src/hyperevm-perp
 succeeded in 0ms:
   395	    batch = [{"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []},
   396	             call_pc(POSITION_PC, szi_data(pool)),
   397	             {"jsonrpc": "2.0", "id": 3, "method": "eth_blockNumber", "params": []}]
   398	    while True:
   399	        el = time.monotonic() - t0
   400	        if el >= LIVE_MAX or (el >= LIVE_FOR and done.is_set()):
   401	            return
   402	        ts = time.monotonic()
   403	        try:
   404	            r = {x["id"]: x for x in post(RPC, batch, tries=1)}
   405	            tr = time.monotonic()
   406	            out.append({"send": round(ts - t0, 3), "recv": round(tr - t0, 3),
   407	                        "bn_before": int(r[1]["result"], 16), "bn_after": int(r[3]["result"], 16),
   408	                        "szi": word(r[2]["result"], 0, signed=True)})
   409	        except Exception as e:
   410	            out.append({"send": round(ts - t0, 3), "recv": round(time.monotonic() - t0, 3), "error": repr(e)[:80]})
   411	        time.sleep(max(0.0, LIVE_POLL - (time.monotonic() - ts)))
   412	
   413	
   414	def track5(pool, cloid, t0):
   415	    """orderStatus by cloid with each poll's send and receive time (question 3(a))."""
   416	    oid = "0x%032x" % cloid
   417	    polls = []
   418	    while time.monotonic() - t0 < GIVE_UP:
   419	        ts = time.monotonic()
   420	        try:
   421	            r = info({"type": "orderStatus", "user": pool, "oid": oid})
   422	            st = r["order"]["status"] if r.get("status") == "order" else "api:" + str(r.get("status"))
   423	        except Exception as e:
   424	            r, st = None, "error:" + repr(e)[:80]
   425	        polls.append([round(ts - t0, 3), round(time.monotonic() - t0, 3), st])
   426	        if st in TERMINAL:
   427	            return st, polls, r
   428	        time.sleep(max(0.0, POLL - (time.monotonic() - ts)))
   429	    return None, polls, None
   430	
   431	
   432	def fills_total(pool, oid):
   433	    fs = [f for f in info({"type": "userFills", "user": pool}) if f.get("oid") == oid and f.get("coin") == COIN]
   434	    return sum(lots(f["sz"]) for f in fs), fs
   435	
   436	
   437	def g1_result(pool):
   438	    """The G1 result for this pool on testnet, or None if G1 has not run for it (review s5i2 #1)."""
   439	    try:
   440	        with open(G1_FILE) as f:
   441	            g = json.load(f)
   442	    except FileNotFoundError:
   443	        return None
   444	    return g if g.get("pool") == pool.lower() and g.get("chain") == 998 else None
   445	
   446	
   447	def require_g1(pool):
   448	    g = g1_result(pool)
   449	    if g is None:
   450	        sys.exit("run `g1 %s` first: G1 comes before any step 5 run (review s5i1 #1, s5i2 #1)" % pool)
   451	    return g["passed"] is True
   452	
   453	
   454	def pinned(pool, block, target, ts_limit):
   455	    """Question 1's end when G1 passed: 0x800 pinned to each block number from the order's block,
54:{"line":"order5","pool":"0x7cd037094a60666280e6cb389e696ded19da5d6f","chain":998,"cycle":22,"kind":"close-wrongside","side":1,"label":"open","fn":"rawIoc","is_buy":true,"limit_px8":8085600000000,"sz_lots":15,"before":0,"oracle":80055.7,"tx":"0xa8b868fcd23627306bc33e331fdb8d70f430e31fcd805bc0e7d7b811f83f611b","sent_at":1793238559.202,"receipt_wall":1793238560.769,"block":68158452,"block_hash":"0x490e6f7f9dc543dcd10ed683f6b1be234e74c17d0334df49dab7da9be2a67599","cloid":"0x80000000000000000000000000000032","block_ts":1793238560,"polls":[[0.095,0.118,"iocCancelRejected"]],"final":"iocCancelRejected","response":{"status":"order","order":{"order":{"coin":"BTC","side":"B","limitPx":"80856.0","sz":"0.00015","oid":63943980793,"timestamp":1793238560400,"triggerCondition":"N/A","isTrigger":false,"triggerPx":"0.0","children":[],"isPositionTpsl":false,"reduceOnly":false,"orderType":"Limit","origSz":"0.00015","tif":"Ioc","cloid":"0x80000000000000000000000000000032"},"status":"iocCancelRejected","statusTimestamp":1793238560400}},"pending_after_send":"0x80000000000000000000000000000032","oid":63943980793,"fills":[],"F":0,"fills_hist":[[0.14,0,0],[2.167,0,0]],"class":"zero-fill","stream":[{"send":0.0,"recv":0.024,"bn_before":68158452,"bn_after":68158452,"szi":0},{"send":2.503,"recv":2.528,"bn_before":68158455,"bn_after":68158455,"szi":0},{"send":5.005,"recv":5.028,"bn_before":68158457,"bn_after":68158457,"szi":0},{"send":7.508,"recv":7.531,"bn_before":68158460,"bn_after":68158460,"szi":0},{"send":10.011,"recv":10.034,"bn_before":68158462,"bn_after":68158462,"szi":0},{"send":12.513,"recv":12.536,"bn_before":68158465,"bn_after":68158465,"szi":0},{"send":15.015,"recv":15.037,"bn_before":68158467,"bn_after":68158467,"szi":0},{"send":17.518,"recv":17.543,"bn_before":68158469,"bn_after":68158469,"szi":0},{"send":20.02,"recv":20.042,"bn_before":68158472,"bn_after":68158472,"szi":0},{"send":22.523,"recv":22.546,"bn_before":68158475,"bn_after":68158475,"szi":0},{"send":25.025,"recv":25.048,"bn_before":68158477,"bn_after":68158477,"szi":0},{"send":27.528,"recv":27.55,"bn_before":68158479,"bn_after":68158479,"szi":0}],"after":0,"last_fill_time":null,"want_after":15,"stopped":"expected filled, got iocCancelRejected"}
 M docs/step5-close-from-evm-spec.md
 M recorder/orders.py
?? docs/reviews/payload-review-s5i7.md

exec
/bin/zsh -lc "rg -n 'manual_ack_retro|manual_ack|session_end' recorder/data <scratchpad>/s1 2>/dev/null || true; nl -ba docs/step5-close-from-evm-spec.md | sed -n '86,165p'; nl -ba recorder/orders.py | sed -n '735,820p'" in ~/src/hyperevm-perp
 succeeded in 0ms:
    86	## Recorder
    87	Extend `recorder/orders.py`:
    88	- `unwind` switches to `rawIocReduceOnly`. It still requires `pendingCloid == 0` and no open orders,
    89	  and acknowledges only on a terminal status for that exact cloid with the position then flat.
    90	- Acknowledge rule for every order: the pending cloid read from the contract equals the cloid this
    91	  client sent, `orderStatus` for that cloid returns a terminal status from the existing list, and
    92	  the status and the position after (in lots, from the live reads) match that order's row below.
    93	  Only then is it acknowledged and the next order sent. Anything else, or no terminal status within
    94	  60 s, stops the run and leaves the slot locked for `status` / manual handling. P is |szi| before
    95	  the order; s is the open direction.
    96	
    97	  | Kind, order | Expected status | Expected position after |
    98	  |---|---|---|
    99	  | any kind, opening `rawIoc` | `filled` | s × 15 |
   100	  | `close-fill`, close | `filled` | 0 |
   101	  | `close-tight`, first close | `iocCancelRejected` | unchanged (s × P) |
   102	  | `close-tight`, second close | `filled` | 0 |
   103	  | `close-partial`, first close | any terminal status; class from fills (partial / zero-fill / full-fill / indeterminate) | s × (P − F), agreeing with F; `indeterminate` stops the run |
   104	  | `close-partial`, residual close (only if position ≠ 0) | `filled` | 0 |
   105	  | `close-flat`, close | recorded (expected `reduceOnlyRejected`) | 0 |
   106	  | `close-over`, close for 2P | recorded (expected `filled`) | 0 |
   107	  | `close-wrongside`, same-direction reduce-only | recorded (expected a rejection) | unchanged (s × P) |
   108	  | `close-wrongside`, then closing reduce-only | `filled` | 0 |
   109	
   110	  For the three "recorded" rows the status name is what is being confirmed, so any terminal status
   111	  is acknowledged if the position matches; a position that does not match stops the run.
   112	- **Gate G1 (before any runs):** with the pool holding a position opened at a known block A and
   113	  closed at a later block C, call `0x800` by `eth_call` at block numbers before A, between A and C,
   114	  and after C, and record the results. Historical reads are accepted only if they return the size
   115	  each block should have had. The outcome is written into the step 5 write-up before question 1 or
   116	  3(b) is measured.
   117	- Live reads, always (question 3(b), and question 1's end if G1 fails): from the receipt's
   118	  arrival, poll `0x800` at `latest` as fast as the RPC limit allows (with `eth_blockNumber` before
   119	  and after each call), recording each request's send and receive time and result, for a fixed
   120	  30 s (or longer, until the order's fill total F is stable after its terminal status). The target
   121	  size is chosen afterwards from the order's row in the acknowledge table (for `close-partial`,
   122	  s × (P − F) once F is known), and the first read matching it and the last non-matching read
   123	  before it are selected from the recorded stream.
   124	- Question 3(b) counts only orders that change the position (`close-fill`, the second close of
   125	  `close-tight`, `close-partial` first and residual closes when F > 0, `close-over`, the closing
   126	  order of `close-wrongside`). Orders whose target equals the position before them
   127	  (`close-flat`, the first close of `close-tight`, the same-direction order of `close-wrongside`,
   128	  `close-partial` with F = 0) are reported separately as "target already present at receipt",
   129	  with 3(a) status timing as their measure.
   130	- Pinned reads, only if G1 passes (question 1's end only): after each order's block B, read
   131	  `0x800` pinned to each explicit block number from B onward (recording the block hash),
   132	  backfilling skipped blocks, until the final size is seen or 30 s of blocks pass; record the first
   133	  matching block and its timestamp. Run after the live stream so the two do not share the rate
   134	  budget.
   135	- Every `orderStatus` poll records its send and receive times (local monotonic clock) and the
   136	  status returned; every receipt records when it arrived.
   137	- Fill time source: `userFills` (info API) for the pool's Core account, matched by `oid`, using its
   138	  `time` field. If a fill cannot be matched there, the record says so and question 1 excludes it
   139	  (counted, not dropped silently).
   140	- `lag <pool> <n>`: with a position open, n paired readings for question 2, spaced at least 15 s.
   141	- `book <coin...>`: question 5, mainnet info API only, to `recorder/data/book.jsonl`, raw snapshot
   142	  included.
   143	- Kinds and sides are run in a random order (seed recorded).
   144	
   145	## Amendments after session 1 (review s5r1)
   146	Session 1 (2026-10-29): G1 failed (all 55 historical reads 0), so question 1 uses live reads only.
   147	The run stopped at cycle 22 of 120 when an opening `rawIoc` 1% through the oracle found nothing:
   148	the testnet book sat over 1% above the oracle. These apply from session 2:
   149	- **Opens go 2% through the oracle**; every close and recovery close stays at 1% (the measured
   150	  quantity). Each order row records `through_bps`; opening data at 1% (session 1) and 2% are
   151	  reported apart, never pooled. Closes are unaffected; opening fill price and fees are.
   152	- **A stopped open is recovered with `ackopen`**, the only manual acknowledgement: the pending cloid
   153	  must be the last stopped row's cloid, that row an opening `rawIoc` that did not fill, its status
   154	  terminal, no open orders, and the position flat (as before the order). The checks and the
   155	  transaction go into `step5.jsonl` as a `manual_ack` row; anything else stays for a person. Session
   156	  1's cycle-22 open was acknowledged by hand after the same checks, before this command existed; it
   157	  is recorded as `manual_ack_retro` (transaction hash not captured) and excluded from every count.
   158	- **Brackets.** Reads start at the receipt. When the first read already shows the target, the result
   159	  is an upper bound from the receipt to that read, labelled "no observed post-receipt non-match",
   160	  not a failed bracket. Otherwise the bracket is the last non-matching and the first matching read
   161	  (about 2.5 s apart at the current pace). The pace stays at 2.5 s (three calls a read, about 72
   162	  requests a minute against the RPC's 100).
   163	- **Every session ends on record**: `session_end` is written on completion, a stop, or a crash, with
   164	  the reason. The clock check uses `sntp`, or `chronyc tracking` on the AWS host.
   165	
   735	def g1(pool):
   736	    """Gate G1 (review s5i1 #1): open (receipt block A), close (receipt block C), then read 0x800
   737	    pinned at every block from A - 5 to C + 15. Historical reads are accepted only if every read
   738	    succeeds and the series is exactly: 0 before A; one switch to the open size at some block in
   739	    [A, A + 10]; the open size until one switch back to 0 at some block in [C, C + 10]; 0 to the
   740	    end. An RPC that answers with the current state (0) everywhere fails, as does any other shape."""
   741	    ctx = testnet_ctx(pool)
   742	    ctx.update({"cycle": "g1", "kind": "g1", "side": 1, "g1": False})
   743	    if read_szi(ctx["pool"]) != 0:
   744	        sys.exit("G1 needs a flat position")
   745	    _, _, a = order5(ctx, "g1-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
   746	    _, _, c = order5(ctx, "g1-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)
   747	    end = c + 15
   748	    while int(rpc("eth_blockNumber"), 16) <= end:
   749	        time.sleep(2)
   750	    reads = []
   751	    for b in range(a - 5, end + 1):
   752	        try:
   753	            reads.append([b, read_szi(ctx["pool"], hex(b))])
   754	        except Exception as e:
   755	            reads.append([b, "error:" + repr(e)[:80]])
   756	        time.sleep(1.0)
   757	    vals = [v for _, v in reads]
   758	    blocks = [b for b, _ in reads]
   759	    ok = all(isinstance(v, int) for v in vals)
   760	    if ok:
   761	        up = next((b for b, v in reads if v == LOTS), None)
   762	        down = next((b for b, v in reads if up is not None and b > up and v == 0), None)
   763	        ok = (up is not None and down is not None and a <= up <= a + 10 and c <= down <= c + 10
   764	              and all(v == (LOTS if up <= b < down else 0) for b, v in reads))
   765	    res = {"passed": ok, "pool": ctx["pool"], "chain": 998, "a": a, "c": c, "reads": reads, "at": round(time.time(), 3)}
   766	    with open(G1_FILE, "w") as f:
   767	        json.dump(res, f)
   768	    write5({"line": "g1", **res})
   769	    print("G1", "passed" if ok else "failed: question 1 uses live reads only")
   770	
   771	
   772	def lag(pool, n):
   773	    """Question 2: with a position open, n paired readings of 0x80F / 0x807 and the info API,
   774	    at least 15 s apart, in alternating order, every request timed. Differences only."""
   775	    require_g1(pool)
   776	    ctx = testnet_ctx(pool)
   777	    ctx.update({"cycle": "lag", "kind": "lag", "side": 1})
   778	    if read_szi(ctx["pool"]) != 0:
   779	        sys.exit("lag needs a flat position to start")
   780	    order5(ctx, "lag-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
   781	    t0 = time.monotonic()
   782	    batch = [{"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []},
   783	             call_pc(MARGIN_PC, "0x" + enc_uint(0) + enc_addr(ctx["pool"])),
   784	             call_pc(ORACLE_PC, "0x" + enc_uint(PERP))]
   785	    for i in range(n):
   786	        ts = time.monotonic()
   787	        row = {"line": "lag", "pool": ctx["pool"], "chain": 998, "i": i, "evm_first": i % 2 == 0}
   788	
   789	        def evm():
   790	            a = time.monotonic()
   791	            r = {x["id"]: x for x in post(RPC, batch, tries=1)}
   792	            row["evm"] = {"send": round(a - t0, 3), "recv": round(time.monotonic() - t0, 3), "block": int(r[1]["result"], 16),
   793	                          "account_value": word(r[2]["result"], 0, signed=True), "oracle": word(r[3]["result"], 0)}
   794	
   795	        def api():
   796	            a = time.monotonic()
   797	            st = info({"type": "clearinghouseState", "user": ctx["pool"]})
   798	            b = time.monotonic()
   799	            meta, ctxs = info({"type": "metaAndAssetCtxs"})
   800	            row["api"] = {"send": round(a - t0, 3), "recv": round(b - t0, 3), "account_value": st["marginSummary"]["accountValue"],
   801	                          "oracle_send": round(b - t0, 3), "oracle_recv": round(time.monotonic() - t0, 3),
   802	                          "oracle": ctxs[[x["name"] for x in meta["universe"]].index(COIN)]["oraclePx"]}
   803	        try:
   804	            (evm(), api()) if row["evm_first"] else (api(), evm())
   805	        except Exception as e:
   806	            row["error"] = repr(e)[:80]
   807	        write5(row)
   808	        time.sleep(max(0.0, 15 - (time.monotonic() - ts)))
   809	    order5(ctx, "lag-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)
   810	
   811	
   812	def impact(levels, notional):
   813	    """Walk displayed levels to `notional` USD: (VWAP, None) or (None, displayed USD depth)."""
   814	    got_ntl = got_sz = 0.0
   815	    for lv in levels:
   816	        p, z = float(lv["px"]), float(lv["sz"])
   817	        take = min(z, (notional - got_ntl) / p)
   818	        got_ntl += take * p
   819	        got_sz += take
   820	        if got_ntl >= notional - 1e-9:

exec
/bin/zsh -lc "python3 - <<'PY'
for x in [80055.7, 1.0, 12345.6789, 99999.9]:
    for buy in [True, False]:
        old=x*(1.01 if buy else .99)
        new=x*(1+(100 if buy else -100)/1e4)
        print(x,buy,old==new,repr(old),repr(new))
PY
jq -r 'select(.line==\"session\" or .line==\"session_end\" or .line==\"manual_ack\" or .line==\"manual_ack_retro\") | [.line,.pool,.done,.why,.cycle] | @tsv' <scratchpad>/s1/step5.jsonl; git diff -- docs/step5-close-from-evm-spec.md recorder/orders.py" in ~/src/hyperevm-perp
 succeeded in 0ms:
zsh:1: can't create temp file for here document: operation not permitted
session	0x7cd037094a60666280e6cb389e696ded19da5d6f	0		
diff --git a/docs/step5-close-from-evm-spec.md b/docs/step5-close-from-evm-spec.md
index 06b3cc5..5b8fde2 100644
--- a/docs/step5-close-from-evm-spec.md
+++ b/docs/step5-close-from-evm-spec.md
@@ -1,6 +1,6 @@
 # Step 5 (spec): seeing and closing a contract's Core position from the EVM
 
-Status: spec, revised after reviews s5 to s5g (CHANGES). Nothing here has been built or sent.
+Status: spec s5h APPROVE, built (s5i5 APPROVE); amended after testnet session 1 (review s5r1, below).
 
 Steps 3 and 4 showed that a CoreWriter order reaches a final `orderStatus` within about 2 s. Step 5
 asks the next question: if a contract's Core perp position backs something on the EVM side, how far
@@ -142,6 +142,27 @@ Extend `recorder/orders.py`:
   included.
 - Kinds and sides are run in a random order (seed recorded).
 
+## Amendments after session 1 (review s5r1)
+Session 1 (2026-10-29): G1 failed (all 55 historical reads 0), so question 1 uses live reads only.
+The run stopped at cycle 22 of 120 when an opening `rawIoc` 1% through the oracle found nothing:
+the testnet book sat over 1% above the oracle. These apply from session 2:
+- **Opens go 2% through the oracle**; every close and recovery close stays at 1% (the measured
+  quantity). Each order row records `through_bps`; opening data at 1% (session 1) and 2% are
+  reported apart, never pooled. Closes are unaffected; opening fill price and fees are.
+- **A stopped open is recovered with `ackopen`**, the only manual acknowledgement: the pending cloid
+  must be the last stopped row's cloid, that row an opening `rawIoc` that did not fill, its status
+  terminal, no open orders, and the position flat (as before the order). The checks and the
+  transaction go into `step5.jsonl` as a `manual_ack` row; anything else stays for a person. Session
+  1's cycle-22 open was acknowledged by hand after the same checks, before this command existed; it
+  is recorded as `manual_ack_retro` (transaction hash not captured) and excluded from every count.
+- **Brackets.** Reads start at the receipt. When the first read already shows the target, the result
+  is an upper bound from the receipt to that read, labelled "no observed post-receipt non-match",
+  not a failed bracket. Otherwise the bracket is the last non-matching and the first matching read
+  (about 2.5 s apart at the current pace). The pace stays at 2.5 s (three calls a read, about 72
+  requests a minute against the RPC's 100).
+- **Every session ends on record**: `session_end` is written on completion, a stop, or a crash, with
+  the reason. The clock check uses `sntp`, or `chronyc tracking` on the AWS host.
+
 ## Runs
 Testnet BTC perp (index 3), 0.00015 BTC per position (about 12 USD), same key as steps 3-4. Spread
 over at least three sessions on different days, including US and Asian hours.
diff --git a/recorder/orders.py b/recorder/orders.py
index 534a676..919600c 100644
--- a/recorder/orders.py
+++ b/recorder/orders.py
@@ -12,6 +12,7 @@ Core's own order and status timestamps, and the position before and after.
 
 Step 5 (docs/step5-close-from-evm-spec.md), against a deployment with rawIocReduceOnly:
     python3 recorder/orders.py g1 <pool>                  # gate G1: do historical 0x800 reads work?
+    python3 recorder/orders.py ackopen <pool>             # after a stopped open: acknowledge it if flat
     python3 recorder/orders.py step5 <pool> <cycles> [seed]   # next cycles of the shuffled plan
     python3 recorder/orders.py lag <pool> <n>             # paired precompile / info API readings
     python3 recorder/orders.py book <minutes> <hours> <coin...>   # mainnet l2Book, read only
@@ -375,10 +376,16 @@ def read_szi(pool, block="latest"):
 
 
 def sntp():
-    try:
-        return subprocess.run(["sntp", "-t", "3", "time.apple.com"], capture_output=True, text=True, timeout=10).stdout.strip()
-    except Exception as e:
-        return "error:" + repr(e)[:80]
+    """The local clock against NTP: sntp where it exists (macOS), else chrony's own report (the AWS
+    host, which has no sntp; review s5r1 #4)."""
+    for cmd in (["sntp", "-t", "3", "time.apple.com"], ["chronyc", "tracking"]):
+        try:
+            return subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=True).stdout.strip()
+        except FileNotFoundError:
+            continue
+        except Exception as e:
+            return "error:" + repr(e)[:80]
+    return "error: neither sntp nor chronyc found"
 
 
 def live_stream(pool, t0, out, done):
@@ -469,7 +476,7 @@ def pinned(pool, block, target, ts_limit):
         time.sleep(PINNED_POLL)
 
 
-def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after):
+def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after, through_bps=None):
     """One order under the acknowledge table (review s5f #2). expect_status None = record whatever
     terminal status comes back; expect_after = lots after, or a function of the fill total F.
     Anything unexpected stops the run with the slot locked."""
@@ -480,7 +487,8 @@ def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after):
         sys.exit("pool has open orders on Core")
     before = read_szi(pool)
     row = {"line": "order5", "pool": pool, "chain": 998, "cycle": ctx["cycle"], "kind": ctx["kind"], "side": ctx["side"], "label": label,
-           "fn": fn, "is_buy": is_buy, "limit_px8": px_8, "sz_lots": sz, "before": before, "oracle": oracle()}
+           "fn": fn, "is_buy": is_buy, "limit_px8": px_8, "sz_lots": sz, "before": before, "oracle": oracle(),
+           "through_bps": through_bps}
     sig = fn + "(bool,uint64,uint64)"
     stream, done = [], threading.Event()
     tx, sent_at, rc = send(pool, env, sig, str(is_buy).lower(), px_8, sz * 10**(8 - SZ_DEC))
@@ -554,14 +562,17 @@ def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after):
 
 def bracket(stream, target):
     """First live read showing `target`, the last read before it that did not, and whether any
-    failed read lies between them (then the bracket is degraded, review s5i1 #3)."""
+    failed read lies between them (then the bracket is degraded, review s5i1 #3). When no read
+    before the hit succeeded, the result is an upper bound from the receipt to the hit, labelled
+    "no observed post-receipt non-match" (review s5r1 #3), not a degraded bracket."""
     hit = next((i for i, x in enumerate(stream) if x.get("szi") == target), None)
     if hit is None:
         return {"hit": None}
     miss = next((i for i in range(hit - 1, -1, -1) if "szi" in stream[i]), None)
     errs = sum(1 for x in stream[(miss if miss is not None else -1) + 1:hit] if "error" in x)
     return {"first_hit": stream[hit], "last_miss": stream[miss] if miss is not None else None,
-            "errors_between": errs, "degraded": errs > 0 or miss is None}
+            "errors_between": errs, "degraded": errs > 0 and miss is not None,
+            "upper_bound_only": "no observed post-receipt non-match" if miss is None else None}
 
 
 def stop5(row, why):
@@ -570,8 +581,14 @@ def stop5(row, why):
     sys.exit("stopped, order left unacknowledged: " + why)
 
 
-def through(is_buy):
-    return px5(oracle() * (1.01 if is_buy else 0.99)) * 10**8
+def through(is_buy, bps=100):
+    return px5(oracle() * (1 + (bps if is_buy else -bps) / 1e4)) * 10**8
+
+
+# Opens (rawIoc, never reduce-only) go 2% through: the testnet book sat over 1% from the oracle and
+# an open at 1% found nothing (session 1, cycle 22; review s5r1 #2). Closes stay at 1% through, the
+# measured quantity. Every order5 row records its through_bps, so 1% and 2% opens stay apart.
+OPEN_BPS = 200
 
 
 def cycle5(ctx):
@@ -582,10 +599,10 @@ def cycle5(ctx):
         sys.exit("cycle needs a flat position: use `status` / `unwind`")
 
     def opn():
-        order5(ctx, "open", "rawIoc", s > 0, through(s > 0), LOTS, "filled", s * LOTS)
+        order5(ctx, "open", "rawIoc", s > 0, through(s > 0, OPEN_BPS), LOTS, "filled", s * LOTS, OPEN_BPS)
 
     def close(label="close", sz=LOTS):
-        order5(ctx, label, "rawIocReduceOnly", close_buy, through(close_buy), sz, "filled", 0)
+        order5(ctx, label, "rawIocReduceOnly", close_buy, through(close_buy), sz, "filled", 0, 100)
 
     if k == "close-fill":
         opn(); close()
@@ -621,13 +638,13 @@ def cycle5(ctx):
         if after != 0:
             close("close-residual", abs(after))
     elif k == "close-flat":
-        order5(ctx, "close-flat", "rawIocReduceOnly", close_buy, through(close_buy), LOTS, None, 0)
+        order5(ctx, "close-flat", "rawIocReduceOnly", close_buy, through(close_buy), LOTS, None, 0, 100)
     elif k == "close-over":
         opn()
-        order5(ctx, "close-over", "rawIocReduceOnly", close_buy, through(close_buy), 2 * LOTS, None, 0)
+        order5(ctx, "close-over", "rawIocReduceOnly", close_buy, through(close_buy), 2 * LOTS, None, 0, 100)
     elif k == "close-wrongside":
         opn()
-        order5(ctx, "close-wrongside", "rawIocReduceOnly", s > 0, through(s > 0), LOTS, None, s * LOTS)
+        order5(ctx, "close-wrongside", "rawIocReduceOnly", s > 0, through(s > 0), LOTS, None, s * LOTS, 100)
         close("close-after-wrongside")
     else:
         sys.exit("unknown kind " + k)
@@ -662,19 +679,57 @@ def step5(pool, cycles, seed=None):
     write5({"line": "session", "start": round(time.time(), 3), "sntp": sntp(), "seed": plan["seed"],
             "pool": ctx["pool"], "chain": 998, "done": plan["done"],
             "g1": {"passed": g["passed"], "at": g["at"], "a": g["a"], "c": g["c"]}})
-    for _ in range(cycles):
-        if plan["done"] >= len(plan["items"]):
-            print("plan complete")
-            break
-        k, s = plan["items"][plan["done"]]
-        ctx.update({"cycle": plan["done"], "kind": k, "side": s})
-        cycle5(ctx)
-        plan["done"] += 1
-        tmp = PLAN_FILE + ".tmp"
-        with open(tmp, "w") as f:
-            json.dump(plan, f)
-        os.replace(tmp, PLAN_FILE)
-    write5({"line": "session_end", "pool": ctx["pool"], "end": round(time.time(), 3), "sntp": sntp(), "done": plan["done"]})
+    why = "completed"
+    try:
+        for _ in range(cycles):
+            if plan["done"] >= len(plan["items"]):
+                print("plan complete")
+                break
+            k, s = plan["items"][plan["done"]]
+            ctx.update({"cycle": plan["done"], "kind": k, "side": s})
+            cycle5(ctx)
+            plan["done"] += 1
+            tmp = PLAN_FILE + ".tmp"
+            with open(tmp, "w") as f:
+                json.dump(plan, f)
+            os.replace(tmp, PLAN_FILE)
+    except BaseException as e:  # a stop (SystemExit) or a crash still ends the session on record (review s5r1 #4)
+        why = "stopped: " + (str(e) if isinstance(e, SystemExit) else repr(e))[:200]
+        raise
+    finally:
+        write5({"line": "session_end", "pool": ctx["pool"], "end": round(time.time(), 3), "sntp": sntp(),
+                "done": plan["done"], "why": why})
+
+
+def ackopen(pool):
+    """Recovery for a stopped opening order (review s5r1 #1): acknowledge it only if the pending cloid
+    is the one in the last stopped row, that row is an opening rawIoc, its status is terminal, the
+    pool has no open orders, and the position is flat and equal to the row's position before. The
+    checks and the transaction are recorded in step5.jsonl. Anything else stays for a person."""
+    ctx = testnet_ctx(pool)
+    pool = ctx["pool"]
+    rows = [json.loads(l) for l in open(STEP5_OUT)]
+    last = next((r for r in reversed(rows) if r.get("line") == "order5" and r.get("pool") == pool), None)
+    pc = int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0])
+    st = info({"type": "orderStatus", "user": pool, "oid": "0x%032x" % pc}) if pc else None
+    final = (st or {}).get("order", {}).get("status") if (st or {}).get("status") == "order" else None
+    oo = info({"type": "openOrders", "user": pool})
+    szi = read_szi(pool)
+    checks = {"pending": "0x%032x" % pc, "last_stopped_cloid": (last or {}).get("cloid"),
+              "last_stopped": (last or {}).get("stopped"), "fn": (last or {}).get("fn"), "label": (last or {}).get("label"),
+              "status": final, "open_orders": len(oo), "szi": szi, "before": (last or {}).get("before")}
+    ok = (pc != 0 and last is not None and last.get("stopped") and last.get("cloid") == checks["pending"]
+          and last.get("fn") == "rawIoc" and last.get("label") == "open" and final in TERMINAL and final != "filled"
+          and not oo and szi == 0 and last.get("before") == 0)
+    rec = {"line": "manual_ack", "pool": pool, "chain": 998, "cycle": (last or {}).get("cycle"), "wall": round(time.time(), 3),
+           "checks": checks, "ok": bool(ok)}
+    if not ok:
+        write5(rec)
+        sys.exit("not acknowledged: " + json.dumps(checks))
+    tx, _, rc = send(pool, ctx["env"], "acknowledge(uint128)", pc)
+    rec.update({"tx": tx, "block": int(rc["blockNumber"], 16)})
+    write5(rec)
+    print(json.dumps(rec))
 
 
 def g1(pool):
@@ -820,6 +875,8 @@ if __name__ == "__main__":
         {"status": status, "unwind": unwind}[a[0]](a[1])
     elif len(a) == 4 and a[0] == "run" and a[2] in EXPECT:
         run(a[1], a[2], int(a[3]))
+    elif len(a) == 2 and a[0] == "ackopen":
+        ackopen(a[1])
     elif len(a) == 2 and a[0] == "g1":
         g1(a[1])
     elif len(a) in (3, 4) and a[0] == "step5":

codex
## Findings

1. **Medium — `ackopen` can acknowledge a partially filled / not-yet-visible open.**  
   It accepts any terminal status except `"filled"` plus `0x800 == 0` and no open orders ([orders.py:721](~/src/hyperevm-perp/recorder/orders.py:721)). It never verifies that the stopped order’s `userFills` total is stably zero. A partially executed IOC may end `iocCancelRejected`; if the position precompile has not caught up (the very visibility lag under study), `ackopen` unlocks the slot. A subsequent cycle can pass its one-time flat preflight, then the old fill becomes visible and combines with a new open.

   Terminal non-`filled` status, a currently flat precompile read, and no open orders are therefore not enough. Require stable, zero fills for that order’s `oid`—with the same repeated-read discipline used by `order5`—and preserve that evidence in `manual_ack`. The existing stopped row’s recorded zero-fill evidence should also be checked rather than ignored.

   The command does correctly reject closes (`fn == rawIoc`, `label == open`), other pools, and a different pending cloid. It selects the last `order5` row rather than explicitly the last stopped row, though the locked single-slot invariant normally makes those equivalent.

2. **Medium — `through_bps` is not populated for every order row, contrary to the new rule.**  
   The default is `None`; these calls omit it:

   - `close-tight` wrong-price close ([orders.py:612](~/src/hyperevm-perp/recorder/orders.py:612))
   - `close-partial` touch close ([orders.py:636](~/src/hyperevm-perp/recorder/orders.py:636))
   - G1 open/close and lag open/close ([orders.py:745](~/src/hyperevm-perp/recorder/orders.py:745), [orders.py:780](~/src/hyperevm-perp/recorder/orders.py:780))

   In particular, `lag-open` and `g1-open` still use 1%, despite “Opens go 2% through,” and record `through_bps: null`. The special close prices need an explicit, meaningful representation too—for example an adverse signed basis-point value for `close-tight` and a distinct `"touch"` basis for the touch-priced order—rather than null.

   Also, the supplied session-1 rows have no `through_bps` field at all, so the assertion that every order row records it is not true for the data being resumed. They need a durable backfill/annotation or an explicit session-1 manifest.

3. **Medium — a successful `ackopen` is not durably audited before it unlocks the slot.**  
   The command sends `acknowledge` before writing its successful `manual_ack` row ([orders.py:729](~/src/hyperevm-perp/recorder/orders.py:729)). A crash after broadcast or receipt but before `write5(rec)` leaves the contract unlocked and only an unlinked generic `sent` record; the required checks and manual-ack association are absent. Write the validated check record before sending, then append a receipt/result record.

4. **Low — `session_end` normally preserves the original stop and is written once, but logging can mask it.**  
   The `raise` inside the `except` preserves the original `SystemExit`, and one normal invocation executes the `finally` once. But an exception from `sntp()` or `write5()` in the `finally` replaces the original stop/crash ([orders.py:699](~/src/hyperevm-perp/recorder/orders.py:699)). Example: disk-full while appending `session_end` converts an intentional fail-closed `SystemExit` into `OSError`. It also cannot record hard termination such as `SIGKILL`; “every crash” overstates the guarantee.

5. **Low — the claimed session-1 remediation is not present in the supplied artifact.**  
   The amended spec says cycle 22 is recorded as `manual_ack_retro`, but the supplied `s1/step5.jsonl` contains neither `manual_ack_retro` nor `session_end`; it contains only the session start and stopped cycle-22 row. The diff adds no migration or append mechanism for that historical record.

The bracket change is correct: first-hit cases are now represented as a receipt-to-first-read upper bound, not degraded brackets. The ordinary 1%-through close prices and close logic remain functionally unchanged; the problem is their incomplete new metadata, not a measured-close behavior change.

VERDICT: CHANGES
tokens used
