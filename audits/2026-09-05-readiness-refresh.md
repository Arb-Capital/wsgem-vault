# Deployment-readiness refresh

Reviewed 2026-09-05 (America/New_York), against clean commit
`f689003746d3d71916e97f16af1219bb09701442`. Live observations below were collected
on 2026-09-06 UTC. The intended deployment is the pinned Ethereum mainnet
wstGBP/tGBP instance.

## Assessment

**The vault is ready for final release validation; production sign-off is incomplete.**
This fresh source review and test run did not identify a new unprivileged asset-loss
exploit or a new high/medium-severity vault finding within the documented token model.
The earlier actionable availability and verification findings remain resolved.

Two small repository follow-ups remain: the default fork command mixes historical and
latest state, and one README paragraph incorrectly says wsgem operations refresh the
cache. More consequential release evidence is still needed: the complete historical
baseline using an archive-capable endpoint, the intended-account deployment simulation,
final artifact verification, and validation of the downstream integration and its
operating controls. A successful keyless simulation alone does not complete these steps.

Only this report was added. Contracts, deployment scripts, configuration, and tests were
left unchanged. No transaction was broadcast and no explorer verification was submitted.
This is a source review with executable validation, not formal verification.

## Findings and follow-ups

### L-01 — The default deterministic fork command includes a latest-state suite

Locations: [audit fork setup](../test/WsgemVault.audit.fork.t.sol#L26),
[Makefile](../Makefile#L74), [release workflow](../.github/workflows/test.yml#L50).

`make test-fork` selects all three `ForkTest` contracts. The vault and deployment suites
default to block 25,589,900, while the audit suite defaults to block 0 (latest).
Consequently, an invocation described as deterministic can depend on current token
ownership, upgrades, and operating state. It can also be green without exercising all
historical dependencies needed by the release job.

This was observed directly: the default command passed 10 tests at 25,589,900 and three
audit tests at 25,915,413. Setting `FORK_BLOCK=25589900` explicitly then passed those 10
tests but failed the audit suite's setup because PublicNode rejected an uncached tGBP
storage read with HTTP 403, requiring an archive token. This is an infrastructure
limitation, not a reproduced contract regression. Cached historical state can make a
partial run succeed without establishing complete archive access.

Use a shared historical default for all fork regression suites and keep latest-state
checks in the smoke target. Until then, always set `FORK_BLOCK` explicitly for release
evidence. The manual release workflow already does this and fails on missing RPC
configuration; this finding does not imply that the workflow silently falls back to latest.

### I-01 — The README still describes a removed cache-refresh behavior

Locations: [README](../README.md#L35),
[wsgem operations](../src/WsgemVault.sol#L263),
[cache implementation](../src/WsgemVault.sol#L304).

The README says `depositWsgem` and `redeemToWsgem` attempt a bounded refresh. Neither
function calls `_sync()` in the reviewed revision. Only construction, gem operations,
and explicit `sync()` refresh the tuple. Later README text and the interface correctly
describe the current implementation.

Correct the stale paragraph so keepers and integrators do not assume frequent wsgem
activity keeps the fallback price current. The historical remediation report describes
an earlier intermediate implementation, including its former 50,000-gas budget; it
should remain historical evidence rather than be treated as current API documentation.
The current budget is 100,000 gas per optional read.

## Validation

| Check | Result |
|---|---|
| `make test` | **375 passed**, 0 failed; 16 network tests intentionally skipped |
| `forge fmt --check` | Passed |
| `forge build --sizes` | Passed; runtime **18,128 bytes**, creation bytecode **21,387 bytes** |
| Default `make test-fork` with PublicNode | **13 passed**, 0 skipped; mixed blocks as described above |
| Explicit `FORK_BLOCK=25589900 make test-fork` | **10 passed**; audit setup blocked by RPC archive-access HTTP 403 |
| Explicit `FORK_BLOCK=25915414 make test-fork` | **13 passed**, 0 failed, 0 skipped; all suites at one recorded block |
| `make test-smoke` with PublicNode | **3 passed**, 0 failed, 0 skipped, at block **25,915,414** |
| `make deploy-dry` | Mainnet simulation passed; one CREATE transaction, no broadcast |
| Required-fork invocation without RPC variables | Failed with the intended missing-RPC error |
| `make -n verify VAULT=... ETHERSCAN_API_KEY=...` | Uses `forge verify-contract --guess-constructor-args --watch`; no signing, broadcast, or resume path |

The offline tests use 1,024 fuzz cases per fuzz test and invariant campaigns configured
for 128 runs at depth 64. The newer solvency campaigns cover rounding ledgers, operator
flows, donations, deficits, and preservation of remaining holders' backing. Their
deterministic handler tests also check that important operations execute and that
modeled violations are not discarded by `fail_on_revert=false`. These campaigns improve
evidence within their bounded model; they do not authenticate arbitrary replacement
tokens or downstream adapters. No new coverage percentage is claimed.

The build uses Foundry **1.7.1** (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`),
Solidity **0.8.28**, Cancun, 1,000,000 optimizer runs, and `via_ir=false`. The OpenZeppelin,
Maseer, and forge-std submodules match the revisions recorded in `foundry.lock`.

The official compiler registry lists three issues whose version ranges include 0.8.28.
The two 2026 issues require the IR pipeline, which this build disables. The remaining
storage-array issue requires a layout crossing the end of storage; no triggering layout
was identified here. The reviewed OpenZeppelin advisory list did not identify an
applicable issue in the vault's imported ERC20/Permit, SafeERC20, or Math paths.
[Solidity registry](https://github.com/ethereum/solidity/blob/develop/docs/bugs.json),
[OpenZeppelin advisories](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories).

## Accounting and dependency review

The accounting remains coherent for exact-transfer, non-rebasing tokens without receiver
callbacks. Effective backing is capped at share supply, so donations do not inflate
solvent share pricing. Deposits stop during a deficit; both exits release backing
pro-rata, rounding down. `withdraw` rounds required backing and shares up, while `mint`
rounds its required gem payment up. The reviewed boundaries did not reveal a way for an
ordinary holder to extract another holder's backing through rounding.

Gem exits require zero cooldown and the full individual claim in liquid gem, and verify
the actual received gem delta. A failed transfer or fill rolls back the share burn and
allowance consumption. The wsgem operations now contain no price/feed refresh calls, so
the previous escape-path dependency has been removed completely. Compliance remains an
intentional dependency of the underlying transfers.

Gem maxima account for detected pause behavior and both vault/wsgem compliance. Required
price, gate, or compliance calls can still revert; a nonzero oracle reading can still be
arbitrarily old. These are documented integration constraints, not proof of unconditional
ERC-4626 availability. Passing the vendored property suite does not establish every
integration assumption: the standard separately requires non-reverting maxima and
accounting getters in its specified circumstances.
[ERC-4626 specification](https://eips.ethereum.org/EIPS/eip-4626).

## Current-state evidence

All following reads use Ethereum block **25,915,414**, timestamp
**2026-09-06 02:48:47 UTC**, hash
`0x4183fed57fc902787491f2d02afa490a468177ffc809539b7be78452ed4295a5`.

| Parameter | Observed value |
|---|---|
| NAV / mint cost | `1010734022032097021` gem wei per whole wstGBP |
| Burn cost | `1008207186977016779` gem wei per whole wstGBP |
| wstGBP supply | `71236522586849475987490` wei |
| tGBP held by wstGBP | `72093494547112817819593` wei |
| Pending redemption claims | 0 |
| Cooldown | 0 |
| Capacity | `type(uint256).max` |
| Settlement conduit | wstGBP itself |
| tGBP paused | false |
| Oracle implementation | `0x44BFEB1110bA6091034DBaAb450eF1e7469fF072` |
| Gate implementation | `0x635dbb7841c27c74b6bDbf1BEd548aAe2C6C9D77` |
| tGBP implementation | `0x94321D80d3C5cdaC63B75F723AE64Ca7F94bE547` |
| tGBP proxy administrator | `0x666b8f67969a22a4015d6d523d8671ee714b114f` |
| tGBP owner / proxy-administrator owner | `0xAF4fCE2984Fb307a368f3Ff01f900909956595C0`; no code at that address |

Liquid gem was approximately **100.3792%** of aggregate supply valued at burn cost, with
zero pending claims. This is an on-chain liquidity snapshot, not evidence of off-chain
reserves or guaranteed future liquidity. These sampled values and implementations agree
with the earlier audit. This pass did not re-enumerate every upstream authorization,
Safe module, bridge authority, or historical grant.

## Release completion criteria

1. **Record the complete historical baseline.** Run the explicit 25,589,900 fork suite
   using the release archive RPC, then latest-state smoke tests. The current-block run
   passed, but does not replace the configured historical baseline. The remote release
   workflow was not dispatched and its secret configuration was not inspected here.
2. **Simulate the final deployment account and preserve its artifacts.** This keyless
   simulation used Foundry's default sender
   `0x1804c8ab1f12e6bbf3894d4083f33e07309d1f38`, nonce 0, rather than an identified release
   account. Its planned address is not a production deployment. Reproduce the final
   constructor transaction with the intended sender, nonce, metadata, and dependency
   state before signing. The dry-run transaction contains 21,611 bytes including
   constructor arguments; the script's buffered gas estimate was 5,430,482.
3. **Authenticate the release, then check the mined contract before funding.** Preserve
   compiler settings and dependency revisions; compare reviewed dependency code and
   implementation identities. After broadcast, validate the receipt, chain, constructor
   arguments, vault runtime with immutables, metadata, token bindings, permit domain,
   compliance, and live route availability. `make check` is a behavior/health check; it
   does not compare bytecode or inspect share metadata. Its warnings also permit deployment
   with closed market windows or nonzero cooldown by design. No mined vault address was
   supplied for this pass.
4. **Complete integration and operating evidence.** Test the actual downstream adapter
   against fees, dust minimums, insufficient gem liquidity, zero/stale/downward NAV,
   dependency failures, and smelt deficits. Accept the issuer/upgrade/compliance trust
   model and establish alerts and a response for these events. The repo contains no
   downstream adapter or monitoring deployment to validate. NAV changes and fees are
   governable; the README's claim that a NAV step is smaller than the exit fee is an
   operating assumption, not a contract-enforced bound.

For build identification, SHA-256 of the compiled creation bytecode (without constructor
arguments) is `a01d96a70b3e42ae53cb2a283d19d76ca6a6f9f2827eed0dc4f9155c13e494d2`.
The compiler's runtime template hash is
`b3fd002246c48b95a58ab010f878f496c08091f77641f1e7bf6bcee2024ee34b`; it contains immutable
placeholders and is **not** a deployed-runtime code hash.

Reproduce the live checks using an explicitly selected block:

```sh
make test
ETH_RPC_URL=https://ethereum-rpc.publicnode.com FORK_BLOCK=25915414 make test-fork
ETH_RPC_URL=https://ethereum-rpc.publicnode.com make test-smoke
make deploy-dry
```

PublicNode may require archive credentials as the recorded block ages. Use the configured
archive-capable release endpoint for the historical baseline and long-term reproduction.
