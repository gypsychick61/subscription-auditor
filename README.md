# Subscription Auditor — MCP Server

An MCP server for the [Prometheus Protocol](https://prometheusprotocol.org) app store: every
recurring charge you have — the ones a vendor bills you for and the ones an agent pays through
an ICRC-2 allowance — in one registry your agent can read, keyed to your principal.

## Why this exists

Two problems, one registry.

The old one: nobody knows what they actually pay per year. Subscriptions are designed to be
forgettable — a trial that converts quietly, a price that goes up $2, a service you stopped
opening in March.

The new one: agents have started granting standing ICRC-2 allowances on their owners' behalf.
An allowance is a permission that outlives the service it was granted for, and nothing on the
store shows you the ones still pointed at your account. Cancelling the subscription does not
revoke the allowance.

## What it will not do

**It cannot cancel anything.** No canister can reach your Netflix account — there is no
credential and no browser here. `cancel_subscription` records your decision and hands back the
steps; the vendor never hears from this server.

**It cannot revoke an allowance either.** Only the account owner can call `icrc2_approve` on
their own account. What this server can do is *read* the live allowance off the ledger and hand
your wallet agent the exact call to make. Where money is concerned it is strictly read-only: it
never approves, transfers, or holds.

Both limits are stated in the tool descriptions and in every response that touches them, so an
agent reading this server cannot come away thinking it cancelled something.

## Tools

| Tool | What it does |
|------|--------------|
| `add_subscription` | Record a recurring charge: price, cycle, next renewal. Pass a `spender` principal to register it as allowance-backed |
| `update_subscription` | Change price, cycle, renewal date, status, category, notes — a price change lands in the price history |
| `list_subscriptions` | Your subscriptions with monthly and annual equivalents, filtered by status, category, or on-chain/off-chain |
| `get_subscription` | One subscription in full: price history, event log, allowance link, and how to cancel it |
| `mark_used` | Record that you actually used it, which is what makes "unused for 60 days" a fact rather than a guess |
| `cancel_subscription` | Mark it cancelled, record the annual saving, return the real cancellation steps |
| `audit` | The sweep: totals, spend by category, renewals ahead, trials converting, price increases, unused, overlap, and zombie allowances |
| `check_allowances` | Read live ICRC-2 allowances off the ledger — what each spender may still pull, and what changed since last check |
| `delete_subscription` | Remove a record and its history (for mistakes; use `cancel_subscription` for real cancellations) |

All nine are free — there is no metering on this server.

## What the audit actually checks

Deliberately boring thresholds, stated out loud rather than tuned in secret:

- **Renewing soon** — anything charging inside your horizon (default 30 days).
- **Trials converting** — a trial whose conversion date is 14 days out or nearer, with what it
  starts costing.
- **Price increases** — current price above the first price recorded, with the percentage and
  the extra per year.
- **Unused** — 60+ days since `mark_used`, or since you started it if it was never marked used
  at all.
- **Category overlap** — two or more live subscriptions sharing a category, with the combined
  annual spend.
- **Standing allowances on cancelled subscriptions** — the on-chain failure mode: you stopped
  the service and left the permission behind.

Annualization uses 365.25 days a year, so leap years don't quietly shave a day off every figure.
Monthly, quarterly, and yearly cycles advance by calendar month with the day clamped, so a
subscription billing on the 31st renews on the 28th in February and back on the 31st in March.

## Privacy model

All data is partitioned per principal. Tool calls require authentication (`x-api-key` header);
each key is bound to the principal that minted it, and every read and write only touches that
principal's partition.

Note what that does and does not mean: your registry is private *to your principal*, not
encrypted against node providers. Don't put card numbers in the notes field — this is a public
chain.

One more principal subtlety: the identity your MCP session authenticates as may not be the
identity your wallet uses. `add_subscription` takes an explicit `account` for on-chain
subscriptions and defaults to your calling principal — set it explicitly if they differ, or
`check_allowances` will read an allowance nobody granted and report zero.

## Getting an API key

```bash
dfx canister call subscription_auditor create_my_api_key '("my key", vec {})'
```

The returned key goes in the `x-api-key` header. It is shown only once.

## Local development

```bash
mops install
dfx start --background
dfx deploy
```

MCP endpoint: `http://<canister-id>.localhost:4943/mcp` (or `http://127.0.0.1:4943/mcp` with a
`Host: <canister-id>.localhost` header).

To exercise `check_allowances` locally you need something answering `icrc2_allowance`,
`icrc1_symbol`, and `icrc1_decimals` — a stub canister with those three methods is enough, and
the tool's error path (a ledger that doesn't answer) is worth seeing too.

## Mainnet

Canister `yi33e-byaaa-aaaab-agz4q-cai` — MCP endpoint
`https://yi33e-byaaa-aaaab-agz4q-cai.icp0.io/mcp`.

Deploys happen automatically: **ICForge builds from `icp.yaml` and upgrades the canister on
push to `main`.** ICForge is the sole controller, so `dfx deploy --network ic` and
`dfx canister --network ic status` will both be rejected (IC0542) — pushing is the only way
to ship.

The store listing is a BYOC (bring-your-own-canister) binding, not a registry-published
version. After a deploy that changes the module hash, refresh the binding so the store
tracks the live build:

```bash
export DFX_WARNING=-mainnet_plaintext_identity
dfx identity use debate-voter-3          # the only authorized namespace controller
app-store-cli byoc register yi33e-byaaa-aaaab-agz4q-cai
dfx identity use default
```

`byoc register` reads the canister's live module hash and re-uploads the `submission:` block
from `prometheus.yml`. `app-store-cli update --hash …` does *not* touch a BYOC listing.
