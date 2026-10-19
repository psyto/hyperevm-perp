"""Turn big blocks on or off for the deploying address (a signed HyperCore action).

    uv run --with hyperliquid-python-sdk python -I script/big_blocks.py on|off [--mainnet]

HedgedPerp's deployment needs about 2.8M gas, over the 2M small-block limit. While big blocks
are on, every EVM transaction from the address waits for a big block (about one a minute), so
turn them off after deploying. Reads the key from KEY_FILE (default ~/.hyperevm-amm-testnet.key).
"""
import os, sys
from eth_account import Account
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants

on = {"on": True, "off": False}[sys.argv[1]]
url = constants.MAINNET_API_URL if "--mainnet" in sys.argv else constants.TESTNET_API_URL
key = open(os.path.expanduser(os.environ.get("KEY_FILE", "~/.hyperevm-amm-testnet.key"))).read().strip()
wallet = Account.from_key(key)
print("address", wallet.address, "api", url)
# empty metadata: this action needs none, and the SDK fails to parse testnet's spot list
ex = Exchange(wallet, url, meta={"universe": []}, spot_meta={"universe": [], "tokens": []}, perp_dexs=[""])
print(ex.use_big_blocks(on))
