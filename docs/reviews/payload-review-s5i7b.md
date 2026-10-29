# Review s5i7b: fixes for review s5i7

Your s5i7 review (CHANGES) is in docs/reviews/review-s5i7.out.md (its last block has the five
findings). The diff below is the whole change since 2e62211 (s5r1 + s5i7 fixes). Session 1 data
with the three appended records (session1_manifest, session_end_retro, manual_ack_retro) is in
<scratchpad>/s1/step5.jsonl.

What changed for s5i7: #1 ackopen now requires the stopped row's reason to be exactly the status
mismatch, its F == 0 / class zero-fill / oid equal, and two reads FILLS_EVERY apart with zero
userFills for the oid, flat position and no open orders; #3 the manual_ack row (checks) is written
before sending, manual_ack_sent after; #2 through_bps is a required parameter on order5, with
-1500 for close-tight, "touch" for close-partial, g1/lag opens at OPEN_BPS; session 1 rows covered
by the manifest row; #4 the finally block cannot replace the stop, SIGKILL caveat in the spec;
#5 retro records appended.

Verify each finding is closed and look for anything the fixes broke. End with VERDICT: APPROVE or
VERDICT: CHANGES.

## Diff
```diff
diff --git a/docs/step5-close-from-evm-spec.md b/docs/step5-close-from-evm-spec.md
index 06b3cc5..bfe403f 100644
--- a/docs/step5-close-from-evm-spec.md
+++ b/docs/step5-close-from-evm-spec.md
@@ -1,6 +1,6 @@
 # Step 5 (spec): seeing and closing a contract's Core position from the EVM
 
-Status: spec, revised after reviews s5 to s5g (CHANGES). Nothing here has been built or sent.
+Status: spec s5h APPROVE, built (s5i5 APPROVE); amended after testnet session 1 (review s5r1, below).
 
 Steps 3 and 4 showed that a CoreWriter order reaches a final `orderStatus` within about 2 s. Step 5
 asks the next question: if a contract's Core perp position backs something on the EVM side, how far
@@ -142,6 +142,35 @@ Extend `recorder/orders.py`:
   included.
 - Kinds and sides are run in a random order (seed recorded).
 
+## Amendments after session 1 (review s5r1)
+Session 1 (2026-10-29): G1 failed (all 55 historical reads 0), so question 1 uses live reads only.
+The run stopped at cycle 22 of 120 when an opening `rawIoc` 1% through the oracle found nothing:
+the testnet book sat over 1% above the oracle. These apply from session 2:
+- **Opens go 2% through the oracle** (`open`, `g1-open`, `lag-open`); every close and recovery
+  close stays at 1% (the measured quantity). Every order row records `through_bps`: 200 for opens,
+  100 for closes, -1500 for close-tight's first close (15% the wrong way), `"touch"` for
+  close-partial's touch-priced close. Session 1 rows have no such field; all of them ran at 100
+  (recorder 2e62211), which a `session1_manifest` row in `step5.jsonl` states. Opening data at 1%
+  and 2% are reported apart, never pooled. Closes are unaffected; opening fill price and fees are.
+- **A stopped open is recovered with `ackopen`**, the only manual acknowledgement. It requires: the
+  pending cloid is the last order row's cloid; that row is an opening `rawIoc`, stopped only because
+  its status was not `filled`, with a zero-fill, agreed fill count and a flat position before; the
+  status is terminal; and two reads `FILLS_EVERY` s apart each show zero `userFills` for its oid, a
+  flat position and no open orders. The checks are written to `step5.jsonl` (`manual_ack`) before
+  the acknowledgement is sent, and the transaction after (`manual_ack_sent`). Anything else stays for
+  a person. Session 1's cycle-22 open was acknowledged by hand after the status, open-order and
+  position checks (the zero fill count is in its stopped row), before this command existed; it is
+  recorded as `manual_ack_retro` (transaction hash not captured) and excluded from every count.
+- **Brackets.** Reads start at the receipt. When the first read already shows the target, the result
+  is an upper bound from the receipt to that read, labelled "no observed post-receipt non-match",
+  not a failed bracket. Otherwise the bracket is the last non-matching and the first matching read
+  (about 2.5 s apart at the current pace). The pace stays at 2.5 s (three calls a read, about 72
+  requests a minute against the RPC's 100).
+- **Sessions end on record**: `session_end` is written on completion, a stop, or an exception, with
+  the reason, and a failure to write it never replaces the stop being reported. A killed process
+  (SIGKILL, power loss) leaves none. Session 1 ended before this; its end is recorded as
+  `session_end_retro`. The clock check uses `sntp`, or `chronyc tracking` on the AWS host.
+
 ## Runs
 Testnet BTC perp (index 3), 0.00015 BTC per position (about 12 USD), same key as steps 3-4. Spread
 over at least three sessions on different days, including US and Asian hours.
diff --git a/recorder/orders.py b/recorder/orders.py
index 534a676..5f3d167 100644
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
@@ -469,10 +476,11 @@ def pinned(pool, block, target, ts_limit):
         time.sleep(PINNED_POLL)
 
 
-def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after):
+def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after, through_bps):
     """One order under the acknowledge table (review s5f #2). expect_status None = record whatever
     terminal status comes back; expect_after = lots after, or a function of the fill total F.
-    Anything unexpected stops the run with the slot locked."""
+    Anything unexpected stops the run with the slot locked. through_bps: the limit's distance from
+    the oracle in bp, positive through and negative away (close-tight's -1500), or "touch"."""
     pool, env = ctx["pool"], ctx["env"]
     if int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0]) != 0:
         sys.exit("pendingCloid is set: resolve it by hand first")
@@ -480,7 +488,8 @@ def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after):
         sys.exit("pool has open orders on Core")
     before = read_szi(pool)
     row = {"line": "order5", "pool": pool, "chain": 998, "cycle": ctx["cycle"], "kind": ctx["kind"], "side": ctx["side"], "label": label,
-           "fn": fn, "is_buy": is_buy, "limit_px8": px_8, "sz_lots": sz, "before": before, "oracle": oracle()}
+           "fn": fn, "is_buy": is_buy, "limit_px8": px_8, "sz_lots": sz, "before": before, "oracle": oracle(),
+           "through_bps": through_bps}
     sig = fn + "(bool,uint64,uint64)"
     stream, done = [], threading.Event()
     tx, sent_at, rc = send(pool, env, sig, str(is_buy).lower(), px_8, sz * 10**(8 - SZ_DEC))
@@ -554,14 +563,17 @@ def order5(ctx, label, fn, is_buy, px_8, sz, expect_status, expect_after):
 
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
@@ -570,8 +582,14 @@ def stop5(row, why):
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
@@ -582,17 +600,17 @@ def cycle5(ctx):
         sys.exit("cycle needs a flat position: use `status` / `unwind`")
 
     def opn():
-        order5(ctx, "open", "rawIoc", s > 0, through(s > 0), LOTS, "filled", s * LOTS)
+        order5(ctx, "open", "rawIoc", s > 0, through(s > 0, OPEN_BPS), LOTS, "filled", s * LOTS, OPEN_BPS)
 
     def close(label="close", sz=LOTS):
-        order5(ctx, label, "rawIocReduceOnly", close_buy, through(close_buy), sz, "filled", 0)
+        order5(ctx, label, "rawIocReduceOnly", close_buy, through(close_buy), sz, "filled", 0, 100)
 
     if k == "close-fill":
         opn(); close()
     elif k == "close-tight":
         opn()
         wrong = px5(oracle() * (0.85 if close_buy else 1.15)) * 10**8
-        order5(ctx, "close-tight", "rawIocReduceOnly", close_buy, wrong, LOTS, "iocCancelRejected", s * LOTS)
+        order5(ctx, "close-tight", "rawIocReduceOnly", close_buy, wrong, LOTS, "iocCancelRejected", s * LOTS, -1500)
         close("close-second")
     elif k == "close-partial":
         opn()
@@ -617,17 +635,17 @@ def cycle5(ctx):
             close("cleanup")
             return
         F, after, _ = order5(ctx, "close-partial", "rawIocReduceOnly", close_buy, tpx, LOTS, None,
-                             lambda F: s * (LOTS - (F or 0)))
+                             lambda F: s * (LOTS - (F or 0)), "touch")
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
@@ -662,19 +680,73 @@ def step5(pool, cycles, seed=None):
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
+        # never replaces the stop or crash being reported (review s5i7 #4); a SIGKILL leaves no record
+        try:
+            write5({"line": "session_end", "pool": ctx["pool"], "end": round(time.time(), 3), "sntp": sntp(),
+                    "done": plan["done"], "why": why})
+        except Exception as e:
+            print("session_end not written: " + repr(e)[:120], file=sys.stderr)
+
+
+def ackopen(pool):
+    """Recovery for a stopped opening order (reviews s5r1 #1, s5i7 #1): acknowledge it only if the
+    pending cloid is the last stopped row's cloid, that row is an opening rawIoc that stopped on its
+    status alone with a zero-fill, agreed fill count, the status is terminal and not filled, the pool
+    has no open orders, and both userFills for its oid and the position read 0 twice, FILLS_EVERY s
+    apart. The checks are written before the acknowledgement is sent, the result after."""
+    ctx = testnet_ctx(pool)
+    pool = ctx["pool"]
+    rows = [json.loads(l) for l in open(STEP5_OUT)]
+    last = next((r for r in reversed(rows) if r.get("line") == "order5" and r.get("pool") == pool), None) or {}
+    pc = int(cast("call", "-r", RPC, pool, "pendingCloid()(uint128)").split()[0])
+    st = info({"type": "orderStatus", "user": pool, "oid": "0x%032x" % pc}) if pc else {}
+    final = st.get("order", {}).get("status") if st.get("status") == "order" else None
+    oid = st.get("order", {}).get("order", {}).get("oid") if final else None
+    reads = []
+    for i in range(2):
+        if i:
+            time.sleep(FILLS_EVERY)
+        F, _ = fills_total(pool, oid) if oid is not None else (None, None)
+        reads.append({"t": round(time.time(), 3), "fills": F, "szi": read_szi(pool),
+                      "open_orders": len(info({"type": "openOrders", "user": pool}))})
+    checks = {"pending": "0x%032x" % pc, "row_cloid": last.get("cloid"), "row_stopped": last.get("stopped"),
+              "row_fn": last.get("fn"), "row_label": last.get("label"), "row_before": last.get("before"),
+              "row_F": last.get("F"), "row_class": last.get("class"), "row_oid": last.get("oid"),
+              "status": final, "oid": oid, "reads": reads}
+    ok = (pc != 0 and checks["row_cloid"] == checks["pending"] and last.get("fn") == "rawIoc"
+          and last.get("label") in ("open", "g1-open", "lag-open")
+          and last.get("stopped") == "expected filled, got %s" % final
+          and last.get("F") == 0 and last.get("class") == "zero-fill" and last.get("before") == 0
+          and final in TERMINAL and final != "filled" and oid is not None and oid == last.get("oid")
+          and all(r["fills"] == 0 and r["szi"] == 0 and r["open_orders"] == 0 for r in reads))
+    rec = {"line": "manual_ack", "pool": pool, "chain": 998, "cycle": last.get("cycle"), "wall": round(time.time(), 3),
+           "checks": checks, "ok": bool(ok)}
+    write5(rec)
+    if not ok:
+        sys.exit("not acknowledged: " + json.dumps(checks))
+    tx, _, rc = send(pool, ctx["env"], "acknowledge(uint128)", pc)
+    done = {"line": "manual_ack_sent", "pool": pool, "chain": 998, "cycle": last.get("cycle"), "cloid": checks["pending"],
+            "tx": tx, "block": int(rc["blockNumber"], 16)}
+    write5(done)
+    print(json.dumps(done))
 
 
 def g1(pool):
@@ -687,8 +759,8 @@ def g1(pool):
     ctx.update({"cycle": "g1", "kind": "g1", "side": 1, "g1": False})
     if read_szi(ctx["pool"]) != 0:
         sys.exit("G1 needs a flat position")
-    _, _, a = order5(ctx, "g1-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
-    _, _, c = order5(ctx, "g1-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)
+    _, _, a = order5(ctx, "g1-open", "rawIoc", True, through(True, OPEN_BPS), LOTS, "filled", LOTS, OPEN_BPS)
+    _, _, c = order5(ctx, "g1-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0, 100)
     end = c + 15
     while int(rpc("eth_blockNumber"), 16) <= end:
         time.sleep(2)
@@ -722,7 +794,7 @@ def lag(pool, n):
     ctx.update({"cycle": "lag", "kind": "lag", "side": 1})
     if read_szi(ctx["pool"]) != 0:
         sys.exit("lag needs a flat position to start")
-    order5(ctx, "lag-open", "rawIoc", True, through(True), LOTS, "filled", LOTS)
+    order5(ctx, "lag-open", "rawIoc", True, through(True, OPEN_BPS), LOTS, "filled", LOTS, OPEN_BPS)
     t0 = time.monotonic()
     batch = [{"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []},
              call_pc(MARGIN_PC, "0x" + enc_uint(0) + enc_addr(ctx["pool"])),
@@ -751,7 +823,7 @@ def lag(pool, n):
             row["error"] = repr(e)[:80]
         write5(row)
         time.sleep(max(0.0, 15 - (time.monotonic() - ts)))
-    order5(ctx, "lag-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0)
+    order5(ctx, "lag-close", "rawIocReduceOnly", False, through(False), LOTS, "filled", 0, 100)
 
 
 def impact(levels, notional):
@@ -820,6 +892,8 @@ if __name__ == "__main__":
         {"status": status, "unwind": unwind}[a[0]](a[1])
     elif len(a) == 4 and a[0] == "run" and a[2] in EXPECT:
         run(a[1], a[2], int(a[3]))
+    elif len(a) == 2 and a[0] == "ackopen":
+        ackopen(a[1])
     elif len(a) == 2 and a[0] == "g1":
         g1(a[1])
     elif len(a) in (3, 4) and a[0] == "step5":
```
