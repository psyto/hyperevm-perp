# Review s5i7: fixes for review s5r1, before step 5 session 2

Adversarial review of the diff below against review s5r1's four findings (its output is in
<scratchpad>/s5r1.out; session 1 data in <scratchpad>/s1/). Read the whole of recorder/orders.py and the spec's new
"Amendments after session 1" section.

s5r1 findings: #1 manual acknowledgement outside the written rule -> new `ackopen` command and a
spec rule; #2 widen only opens to 2%, label it -> `OPEN_BPS`, `through_bps` in every order5 row;
#3 first-read matches are an upper bound, not a failed bracket -> `bracket()` labels them; #4
session end not recorded on a stop, sntp missing on the AWS host -> `session_end` in a finally
with the reason, `chronyc tracking` fallback.

Check in particular: can `ackopen` acknowledge anything it should not (a close, a filled or partly
filled open, an order whose position effect is still pending, another pool's row, a cloid that is
not the stopped one, a stop for a reason other than the status)? Is a terminal non-filled status plus
flat position plus no open orders enough, given orderStatus can lag fills? Does the finally block
mask or alter the exit status, or write session_end twice? Does through_bps reach every order5 call
(including close-tight's wrong-price close and close-partial's touch close, which pass none)? Did
any measured close behaviour change?

Findings with severity and a failing scenario. End with VERDICT: APPROVE or VERDICT: CHANGES.

## Diff
```diff
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
```
