# wsgem-vault

An [ERC-4626](https://eips.ethereum.org/EIPS/eip-4626) vault over a **wsgem** token — a
wrapped staked currency such as wstGBP ("Wren Staked tGBP") or wstCAD — turning the wsgem's
oracle-set NAV into a standard vault share price that yield-tokenisation and vault venues
(Pendle, Spectra, Napier, Superform, Balancer boosted pools, Morpho) know how to read.

A wsgem is a non-rebasing wrapper of an underlying currency token (the "gem") whose gem
value is an oracle-set NAV (`navprice()`, quoted in gem native units per whole wsgem) that
accrues upward over time under normal operation. `WsgemVault` holds wsgem, issues exactly
one 18-decimal share per wsgem, and reports the gem as `asset()`.

The vault is **fully immutable**: no owner, pause, sweep, cooldown, holding period, deposit
fee, or gem buffer. One deployment serves one wsgem instance.

Pendle integration lives in a separate repo (`wstgbp-pendle`): its SY is Pendle's ERC-4626
template over this vault, and this repo is the prerequisite it pins.

## Legs

```
gem   ──deposit / mint      (at mintcost, bpsin)──────────►┐
wsgem ──depositWsgem        (1:1, fee-free)───────────────►│  WsgemVault
                                                           │  asset = gem
gem   ◄─redeem / withdraw   (at burncost, bpsout;          │  1 share = 1 wsgem (18 dec)
        cooldown 0 and full gem liquidity only)────────────┤  share price = navprice
wsgem ◄─redeemToWsgem       (1:1, fee-free)───────────────┘  no admin
```

- **Share price = wsgem NAV.** `totalAssets()` is the gross NAV of the wsgem that backs the
  shares (the held balance capped at the supply), so `convertToAssets(1e18) == navprice()`
  while the vault is fully backed, which is every state short of a privileged burn.
- **Gem in** (`deposit`, `mint`) replicates `wsgem.mint()` share for share; **gem out**
  (`redeem`, `withdraw`) replicates `wsgem.redeem()` gem for gem.
- **wsgem legs** (`depositWsgem`, `redeemToWsgem`, with their `preview*` / `max*`) are 1:1,
  fee-free, and never read the oracle. Their errors and events live in `IWsgemVault`.
- The stack is agnostic to gem decimals (they live inside the oracle price scaling).

## Pricing principles

**Fees never touch the share price.** `totalAssets`, `convertToShares` and `convertToAssets`
report the gross NAV, with no fee. The wsgem's entry fee (`bpsin`, inside `mintcost()`) and
exit fee (`bpsout`, inside `burncost()`) appear only in `previewDeposit`/`previewMint` and
`previewRedeem`/`previewWithdraw`, and are paid by whoever enters or exits. The fee rates are
never hard-coded — every quote reads the wsgem's live `mintcost()` / `burncost()`. Because
the backing counted by `totalAssets` is capped at `totalSupply()`, a donation of wsgem
cannot move the share price, and no virtual-share offset is needed to defeat
first-depositor inflation.

**No path through the vault is ever cheaper than the same action against the wsgem.**

| Through the vault | Equals |
|---|---|
| `deposit(gem)` / `mint(shares)` then `redeemToWsgem` | a plain `wsgem.mint()` |
| `depositWsgem` then `redeem(shares)` / `withdraw(gem)` | a plain `wsgem.redeem()` |
| `depositWsgem` then `redeemToWsgem` | the identity, 1:1 |

A full deposit→redeem lap costs the cycler exactly the wsgem's `bpsin + bpsout` and leaves
every other holder's `convertToAssets`, `previewRedeem` and `maxWithdraw` unchanged. That
also covers rate-update sniping: one NAV step is far smaller than the exit fee, and exiting
via the wsgem leg instead is just a plain mint.

**Quotes, limits and execution are split the ERC-4626 way.** `totalAssets`, `convertTo*`
and every `preview*` are pure quotes: they never revert for operational reasons, never
account for limits, and a successful execution always returns exactly its quote. `max*`
never revert and are tight: they report 0 while a leg is unavailable (deficit, closed
window, deny-listed vault, paused oracle or exhausted capacity for gem-in; cooldown, closed
window, deny-listed vault, paused oracle, gem liquidity or the wsgem's one-whole-wsgem floor
for gem-out), else the largest amount that succeeds — `deposit(maxDeposit)`,
`mint(maxMint)`, `withdraw(maxWithdraw)` and `redeem(maxRedeem)` always succeed, and one
unit more always reverts. The one exception is unlimited wsgem capacity, where
`maxDeposit`/`maxMint` saturate to `type(uint256).max` (EIP-4626's "no limit" value) rather
than to a depositable amount. Execution enforces every gate on live values, with the wsgem's
own selectors (`MarketClosed`, `InvalidPrice`, `DustThreshold`, `ExceedsCap`,
`NotAuthorized`) plus the vault's `Insolvent`, `CooldownActive` and
`InsufficientLiquidity`. The vendored a16z ERC-4626 property suite passes with zero
tolerance (`_delta_ = 0`), with and without an entry fee, at 18 and 6 gem decimals.

## Contracts

| Contract | Path |
|---|---|
| `WsgemVault` (ERC-4626 vault, immutable) | `src/WsgemVault.sol` |
| `IWsgemVault` (the vault's non-4626 surface, errors, events) | `src/interfaces/IWsgemVault.sol` |
| `IWsgem` (minimal wsgem interface, mirrored errors) | `src/interfaces/IWsgem.sol` |
| Deploy script (wstGBP, fully pinned) | `script/DeployWstGbpVault.s.sol` |
| Deploy script (generic pattern, env-driven) | `script/DeployWsgemVault.s.sol` |

Built on OpenZeppelin 4.9.3 (`ERC20Permit`, `IERC4626`, `SafeERC20`, `Math`). Not OZ's
`ERC4626` base: every hook and all four public mutators would be overridden anyway (OZ's
`require(assets <= maxDeposit)` string gates would replace the wsgem's own selectors on
execution), leaving only dead virtual-share code — so the vault is an explicit `IERC4626`
implementation where every function is visibly a replica of the wsgem's own math.

### Live wsgem instances (Ethereum mainnet)

| Instance | wsgem | gem | Current params | Vault |
|---|---|---|---|---|
| wstGBP | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` | tGBP `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` | `bpsin` 0, `bpsout` 25, `cooldown` 0, capacity unlimited, NAV poked ~weekly | not yet deployed |

All market parameters are governable per instance.

## Behavior notes for integrators

- **Nothing on the quoting side reverts during a NAV pause.** While `navprice()` is 0,
  `totalAssets`, `convertTo*` and the previews use the NAV and fee units last observed from
  a live oracle (`lastNav`, `lastMintUnit`, `lastBurnUnit`, refreshed on every
  state-changing call and by the permissionless `sync()`), so integrators keep a price
  rather than a revert or a zero. `max*` report 0 for the gem legs (the wsgem's own
  mint/redeem are frozen) and execution of those legs reverts `InvalidPrice`; the wsgem
  legs stay live. Accepted: a pause does **not** make that fallback a safe price — it is
  whatever the last mutation or `sync()` saw, which may predate the pause by any number of
  pokes, or be the very value the pause was meant to withdraw. Integrators that must not
  price on it check `oracleLive()` and fail closed themselves (the Pendle SY does); keepers
  should `sync()` in the same transaction as every NAV update so the fallback never lags.
- **`convertToAssets` overvalues shares by `bpsout` relative to a gem exit.** Anything that
  prices shares off `convertToAssets` (PT oracles, LTVs) is 25 bps above what a gem
  redemption pays right now; at that size it is absorbed by any sane LTV or liquidation
  bonus, and liquidators can take the wsgem leg instead. Older ERC-4626 integrators that
  assume `previewRedeem == convertToAssets` will see the gap; test against them before
  listing.
- **Minimums are not expressible through `max*` or previews.** Gem deposits below
  `mintcost()` (about one gem per share) and gem redemptions or withdrawals releasing less
  than one whole wsgem (`1e18`) revert `DustThreshold` on execution; the previews still
  quote them, and `maxRedeem`/`maxWithdraw` return 0 below the floor. The wsgem legs have
  no minimum. `mint(shares)` for less than roughly one whole share reverts `DustThreshold`
  denominated in gem, because that is the wsgem's error for the implied deposit.
- **Gem-out is atomic or nothing.** `wsgem.redeem()` queues a claim and pays it inline only
  when the wsgem's cooldown is zero, and then only up to the wsgem's current gem balance; a
  queued or partially filled claim would be owned by the vault with no one to collect it. The
  vault therefore reverts `CooldownActive` while the wsgem's cooldown is non-zero and
  `InsufficientLiquidity` when the wsgem holds less gem than the full claim, `maxRedeem`/
  `maxWithdraw` report 0 or the liquidity-bounded amount, and a defensive post-call check
  (`FillMismatch`) verifies the gem received. The wsgem legs are unaffected by either condition.
- **Rounding residue.** `withdraw` delivers exactly the requested gem and may leave up to one
  gem wei per call in the vault (zero for gems with fewer than 18 decimals); `mint` mints
  exactly the requested shares and may leave less than one gem unit's worth of wsgem in the
  vault as surplus backing. Neither is recoverable, neither enters the share price, and the
  surplus only ever offsets a future deficit. `redeem` and `deposit` are exact.
- **Compliance is an execution gate, not a quote.** Every wsgem transfer screens all
  involved addresses against the gem's deny list, including the vault: if the vault is ever
  deny-listed, every leg's execution reverts `NotAuthorized` and every `max*` returns 0,
  while the quotes are unaffected. Per-address screening of callers and receivers is never
  previewed. Vault shares are a plain ERC20 (with EIP-2612 permit) and are not gated.
- **NAV is permissioned and non-monotonic**: the oracle can be poked down or paused to 0.
  NAV moves are discrete steps, so repricing around a poke is sandwichable in principle —
  inherent to any discretely-updated NAV oracle; the exit fee makes cycling through the vault
  to capture a step uneconomic.
- **Privileged smelt is an explicit trust assumption.** wsgem issuers can forcibly burn
  wsgem from any holder (`smelt(address,uint256)`) — including the vault, which would leave
  shares outstanding with less than 1 wsgem of backing each. The vault surfaces this via
  `deficit()` (shares beyond backing; wire it into monitoring/alerting), **marks every share
  down to its effective backing** (`totalAssets` and `convertToAssets` reflect the deficit,
  so integrators pricing off the vault see the loss immediately), **pays redemptions
  pro-rata** on both the wsgem and the gem legs (no holder can front-run another out of the
  remaining backing), and **fails closed on every deposit leg** (`Insolvent`) while the
  deficit persists. Donating wsgem to the vault restores full backing and 1:1 quotes for
  everyone remaining.
- **No admin surface at all.** The vault's only trust assumptions are the wsgem's
  (permissioned NAV, privileged smelt, upgradeable gate/oracle/guard feeds).
- **Token compatibility assumptions**: the wsgem must follow the Maseer wsgem interface,
  use 18 decimals (enforced at construction), and transfer exact requested amounts. The gem
  may use any decimals, but it must also transfer exact requested amounts. Fee-on-transfer
  and rebasing tokens are unsupported: the vault's balance-delta checks would trip and its
  rounding residue could be consumed.
- **Gem decimals only quantize, never break, the math.** navprice/mintcost/burncost are
  quoted in gem native units per whole wsgem, so the share math is decimals-agnostic (tested
  at 2, 6, 8, and 18); low-decimal gems simply round values to their coarser smallest unit.

## Development

```shell
make test        # offline dev loop: unit + fuzz + ERC-4626 property + invariant + deploy-script + decimals suites
make test-fork   # deterministic fork suite (pinned block; archive-capable RPC)
make test-smoke  # latest-block live-parameter smoke checks (incl. gem-out liquidity)
make test-all    # everything the configured RPC allows
make coverage    # summary coverage of the src/ surface
make gen-report  # HTML coverage report -> docs/coverage-report/ (view via make serve-report)
```

Copy `.env.example` to `.env` for configuration. RPC precedence everywhere (make targets
and direct `forge test` alike): explicit `ETH_RPC_URL`, else an endpoint composed from
`ALCHEMY_API_KEY`, else — for the deploy/check targets only — a public fallback.
`make test` and `make coverage` strip the RPC vars so the dev loop stays deterministic
even with an RPC configured.

Fork suites run only when an explicit RPC is configured (`ETH_RPC_URL`, or
`ALCHEMY_API_KEY` to compose one) and **skip otherwise**, so plain offline `forge test`
stays green. The fork suite pins a block for determinism (override with `FORK_BLOCK`;
historical state needs an archive-capable RPC — any Alchemy/Infura endpoint qualifies).
The smoke suite intentionally forks latest: it asserts current governable parameters
(fees, cooldown, market windows both ways, compliance) and the wsgem's gem liquidity, so a
failure there means live config or liquidity moved, not a code regression.

### Deploy

```shell
make deploy-dry            # keyless simulation against live mainnet state — run first
make deploy                # keystore-signed broadcast + inline Etherscan verify
make check VAULT=0x...     # re-run the sanity battery against the mined vault (keyless)
make verify                # resume-verify a broadcast whose inline verification hiccuped
```

`make deploy` signs from an encrypted keystore (`ETH_FROM` + `ETH_KEYSTORE`; forge
prompts for the password — no raw private key anywhere) and needs `ETHERSCAN_API_KEY`
for verification. The vault has no owner, so there is no ownership step.

There are two deploy scripts, one behaviour:

- **`script/DeployWstGbpVault.s.sol`** — the wstGBP deployment, with the wsgem address,
  the gem to cross-check, and the share name/symbol all pinned in code. Needs no
  configuration; it is what the `make` targets above drive. A `WSGEM`, `EXPECTED_GEM`,
  `VAULT_NAME`, or `VAULT_SYMBOL` left exported for a different instance is **refused**,
  not silently ignored.
- **`script/DeployWsgemVault.s.sol`** — the generic pattern for any other wsgem, and the
  deploy/check machinery both share. It defaults **nothing**: `WSGEM`, `EXPECTED_GEM`,
  `VAULT_NAME`, and `VAULT_SYMBOL` must all be set, because a wrong name, symbol, or
  unchecked underlying is permanent on an immutable contract. Drive it with
  `make deploy-dry SCRIPT=script/DeployWsgemVault.s.sol` (same for `deploy` / `check` /
  `verify`). For a recurring instance, subclass it as the wstGBP script does — override
  `target()` and `naming()` and everything else comes along.

The script asserts the full post-deploy state (bindings, decimals, `convertToAssets(1e18)
== navprice()`, previews on every leg, `max*`, compliance pass, gem approval, `deficit() ==
0`) before reporting the address; checks that need an open mint or burn window, cooldown 0,
or gem liquidity are reduced to their closed-state mirror with a warning otherwise. Re-run
the same battery against the mined instance — or any time later as a health check — with
`make check VAULT=0x...`. It takes the expected wsgem and gem from the script's own pinned or
env-supplied configuration rather than trusting the vault under check (otherwise any healthy
vault would pass, including one bound to the wrong wsgem).

### Dependencies (pinned submodules)

| Lib | Rev |
|---|---|
| `forge-std` | `v1.16.2` |
| `openzeppelin-contracts` | `v4.9.3` (also vendors the a16z `erc4626-tests` property suite used in `test/`) |
| `maseer-one` (wsgem framework source, **test-only**, BUSL-1.1) | `07eb992` |

## License

[GPL-3.0-or-later](LICENSE). The `maseer-one` submodule is BUSL-1.1 and is a test-only
dependency; nothing in `src/` links against it.
