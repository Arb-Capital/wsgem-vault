# WsgemVault security and production-readiness audit

Reviewed 2026-09-05. Target commit: `3555ea8fbf7871b71f4cf7189f18b036744beafc`.

**Remediation follow-up:** M-01, L-01, and L-02 have been addressed in the working tree.
See the [fix review and validation record](2026-09-05-remediation.md). The original findings,
test counts, reproduction names, and assessment below are preserved as historical audit
evidence; the audit test files now assert the corrected behavior.

## Deployment assessment

**Recommendation: address the findings below before an immutable production release.** The accounting design is coherent, and this review did not identify an unprivileged asset-theft exploit against the inspected wstGBP/tGBP implementations. However, an avoidable dependency can lock the underlying-token exit, and the advertised ERC-4626 limits and deployment health checks miss real token-wide shutdown conditions. These matter particularly for automated redemption and liquidation integrations.

The principal code finding is **M-01, medium severity**. Two additional findings are **low severity**: L-01, inaccurate availability reporting; and L-02, a verification command capable of submitting transactions. The upstream authority and price risks are assessed separately rather than counted as newly discovered vault exploits.

This is a source review with executable tests and mainnet reads, not a formal verification or a guarantee against all vulnerabilities. No production contracts, deployment scripts, configuration, or existing tests were changed. The only additions are this report and two audit reproduction files. No transactions were broadcast.

## Scope and evidence

Reviewed:

- `src/WsgemVault.sol`, both first-party interfaces, both deployment scripts, the Makefile, Foundry configuration, CI, README, and test architecture.
- Relevant underlying implementation paths: Maseer mint/redeem/exit, token transfers, privileged issue/smelt, pricing, market gates, compliance, and proxy administration.
- The published wstGBP source and the live tGBP implementation's transfer, pause, ban, owner, and upgrade behavior. The token's cross-chain system and its off-chain backing were not comprehensively audited.

The repository was clean at the start. Dependencies were pinned to:

| Dependency | Revision |
|---|---|
| OpenZeppelin contracts | `fd81a96f01cc42ef1c9a5399364968d0e07e9e90` / v4.9.3 |
| Maseer framework, used by tests | `07eb992dbf1db78c1928fc0f79687eac7772b1db` |
| forge-std | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` / v1.16.2 |

The published `MaseerOne.sol` and `MaseerToken.sol` differ from the vendored versions only in a license URL comment and trailing newline. This is a source comparison, not an independently reproduced bytecode match. The explorer reports wstGBP was compiled with Solidity 0.8.34, Prague, and 21,000 optimizer runs; the vault uses 0.8.28, Cancun, and 1,000,000 runs. [Published wstGBP source](https://eth.blockscout.com/api/v2/smart-contracts/0x57C3571f10767E49C9d7b60feb6c67804783B7aE).

| Verification | Result |
|---|---|
| Existing offline suite, before audit additions | **310 passed**, 0 failed; 13 network-dependent tests skipped |
| Existing fork and smoke suites, latest state | **13 passed**, 0 failed |
| New offline audit reproductions | **4 passed**, 0 failed |
| New mainnet-fork audit reproductions | **3 passed**, 0 failed |
| User's subsequent `make test-fork` and `make test-smoke` runs | **13 fork + 3 smoke passed**, 0 failed, 0 skipped; includes all three audit fork reproductions |
| Coverage run, including audit additions | **314 passed**, 0 failed; 16 network-dependent tests skipped |
| Vault coverage | Lines 210/210; statements 292/292; branches 48/48; functions 40/40 |
| Formatting and whitespace checks | Passed |
| Optimized vault build | Runtime 17,880 bytes; initcode 21,177 bytes, within deployment limits |

Foundry version was 1.7.1, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`. Default fuzz runs are 1,024; invariant campaigns use 128 runs with depth 64. Coverage disables optimization and is a separate measurement from the optimized test runs.

My historical fork attempts using PublicNode returned HTTP 403 for archive storage/account requests, both at the repository's original block `25,589,900` and at an intermediate block `25,911,325`. Setting `FORK_BLOCK=0` allowed all existing integration tests to pass against latest state.

The user subsequently supplied successful `make test-fork` output with all 13 fork tests passing, followed by all 3 smoke tests passing. This establishes that the complete network test workflow succeeds in the user's configuration; archive access is not an outstanding environment blocker for that run. The pasted output does not print the effective `FORK_BLOCK`, so this report does not attribute it to a specific historical block. Record the effective block and RPC configuration in release evidence.

The audit tests intentionally assert the undesirable current behavior. **Their passing means the findings reproduce, not that the findings are fixed.** After remediation, replace the relevant expectations with assertions of the intended behavior.

## M-01 — Oracle and fee-feed failures block the underlying-token escape path

**Severity: Medium.** Availability failure, requiring an upstream fault, upgrade, or privileged misconfiguration. No permissionless trigger was established.

Locations: [depositWsgem](../src/WsgemVault.sol#L245), [redeemToWsgem](../src/WsgemVault.sol#L257), [_sync](../src/WsgemVault.sol#L289).

Every wsgem deposit and redemption begins with `_sync()`. With a nonzero NAV, that function calls `navprice()`, `mintcost()`, and `burncost()` without handling failures. A failure in any of these calls aborts an operation whose accounting and token transfer otherwise require no price or market information.

A zero-valued oracle pause is handled, but a reverting oracle or fee feed is not. A concrete reachable example in the real framework is `MaseerGate.file("bpsout", 10001)`: unlike `setBpsout`, the generic setter does not enforce the 10,000-bps bound. `burncost()` then underflows. This makes `redeemToWsgem` revert even though ordinary wsgem transfers remain available. Because gem redemptions also need `burncost()`, holders have no working vault exit until the upstream condition is corrected.

The advertised escape-path availability becomes misleading too: `maxRedeemToWsgem(owner)` still returns the holder's positive share balance, and `previewRedeemToWsgem` remains valid. A reverting oracle also makes `totalAssets()` revert despite a populated fallback cache, since the fallback only handles a returned zero.

Reproductions in [WsgemVault.audit.t.sol](../test/WsgemVault.audit.t.sol):

- `test_Audit_InvalidExitFeeBlocksWsgemExitAlthoughTransfersWork` deposits, sets the invalid fee through the real gate, observes the blocked vault exit and successful direct transfer, then restores the fee and exits successfully.
- `test_Audit_RevertingOracleBlocksWsgemExitAndFallback` injects a reverting oracle read and demonstrates the same exit failure and unusable accounting fallback.
- `test_Audit_RevertingFeeFeedAlsoBlocksWsgemDeposits` demonstrates the corresponding wsgem entry failure despite an unlimited advertised maximum.

**Remediation:** remove mandatory pricing calls from both wsgem legs. Refresh cached pricing through explicit `sync()` and operations that actually need prices, or make refresh on these legs bounded and best effort without partially updating the cached tuple. Preserve live-price enforcement on gem operations. A merely reverting, malformed, or gas-consuming oracle/fee implementation should not prevent an otherwise authorized transfer of held wsgem.

Acceptance criteria: with each price/fee getter failing in turn, underlying-token deposits and withdrawals execute at their backing-based quote while direct wsgem transfers remain possible; legitimate compliance bans still prevent transfers; existing zero-price and deficit tests continue to pass. Treat reverting-oracle valuation policy separately from escape-path liveness.

## L-01 — Token-wide shutdowns are absent from maxima and health checks

**Severity: Low.** Confirmed ERC-4626 availability/integration defect. Execution fails atomically, so the reproduced scenarios do not lose vault assets.

Locations: [_maxDepositAssets](../src/WsgemVault.sol#L385), [_maxRedeemShares](../src/WsgemVault.sol#L402), deployment [_sanity](../script/DeployWsgemVault.s.sol#L105), and [MockGem](../test/mocks/MockGem.sol#L40).

The gem-side availability predicates check the market, price, cooldown, capacity/liquidity, deficit, and whether the vault passes wsgem compliance. They do not check a global pause on tGBP or a tGBP ban on the wstGBP contract that must send and receive the gem.

The live tGBP implementation exposes both of these restrictions. Under either condition, all four gem operations revert, while `maxDeposit` and `maxMint` remain positive and a funded holder's `maxWithdraw`/`maxRedeem` remain positive. The complete deployment health-check battery also succeeds, including its holder-specific checks. This can mislead release checks and integrations choosing between redemption routes. ERC-4626 specifies that maxima must not overstate accepted amounts and must reflect global shutdown conditions. [ERC-4626 specification](https://eips.ethereum.org/EIPS/eip-4626#maxwithdraw).

Reproductions against actual mainnet contracts in [WsgemVault.audit.fork.t.sol](../test/WsgemVault.audit.fork.t.sol):

- `test_Audit_GemPauseLeavesMaximaAndHealthCheckGreen` impersonates the real token owner on the local fork, pauses tGBP, proves the false maxima and successful health check, then exits successfully through wsgem.
- `test_Audit_BannedWsgemLeavesMaximaAndHealthCheckGreen` repeats this with a tGBP ban on wstGBP.
- `test_Audit_LiveGemScreensBannedReceiverUnlikeMockGem` confirms that the real token rejects a banned gem receiver, whereas the mock's transfers do not consult its ban mapping.

The mock mismatch explains why tests named `test_BannedUser_DepositGem_Unscreened` and `test_Redeem_BannedReceiver_Unscreened` are not assertions of live tGBP behavior. They establish that the vault adds no independent user screen; the real gem still enforces its own screen. `MockGem` also has no pause mechanism. The healthy-path fork tests did not inject either global shutdown before this audit.

**Remediation:** make known gem-wide restrictions visible in the wstGBP integration's availability checks and deployment/monitoring checks, and test with a token model that enforces the actual pause and ban semantics. For a generic wsgem vault, use an explicit compatibility interface or an instance-specific adapter rather than assuming all ERC20s expose the same administrative methods. Keep the wsgem exit available when only gem transfers are paused. Integrators should still simulate execution and handle state changes between quote and inclusion.

Acceptance criteria: a tGBP pause or ban on wstGBP makes gem maxima zero and produces an unhealthy/unavailable status; the same state leaves valid wsgem exits available. Live-token tests should cover sender, receiver, spender, vault, and wstGBP bans separately.

## L-02 — `make verify` can submit transactions

**Severity: Low, operational.** Static review and installed CLI semantics; the command was not executed during this audit.

Location: [Makefile verify target](../Makefile#L126).

The target describes itself as sending nothing because every transaction in its broadcast record is assumed to be mined. It actually invokes `forge script --broadcast --resume --verify` with a signing wallet. The installed Foundry CLI describes `--resume` as resuming submission of transactions that failed or timed out. The target contains no receipt-completeness or intended-deployment check enforcing its stated assumption.

If an operator runs this verification target against an incomplete or unintended broadcast record, it can submit the deployment transaction instead of only verifying already deployed code. This is a release-workflow surprise, not a public attacker path through the vault.

**Remediation:** use `forge verify-contract` with an explicit deployed address and constructor arguments for verification. If retaining a resume workflow, name it as a transaction-submitting recovery action, validate the record, chain, sender, intended contract, and receipts, and remove the unconditional no-send claim.

## Upstream trust and integration constraints

### R-01 — The immutable vault still inherits powerful upgrade and issuer authorities

Latest-state reads during this audit showed:

| Authority | Observed control |
|---|---|
| `0xa73c94969dE90Edb159D29922C42fF24beDFA085` | Safe reporting threshold 3 and 5 owners |
| Same Safe | `wards == 1` and `wardsProxy == 1` on the wstGBP price, gate, treasury, and compliance proxies |
| Same Safe | Authorized oracle updater (`bud == 1`) and issuer (`issuer == true`) |
| tGBP owner | `0xAF4fCE2984Fb307a368f3Ff01f900909956595C0`; `eth_getCode` returned `0x` |
| tGBP proxy administrator | `0x666b8f67969a22a4015d6d523d8671ee714b114f`; its `owner()` returned the same tGBP owner |
| tGBP implementation | ERC-1967 slot points to `0x94321D80d3C5cdaC63B75F723AE64Ca7F94bE547` |

The published tGBP implementation permits its owner to pause transfers, ban accounts, mint tokens, and authorize UUPS upgrades. Its transparent-proxy administrator has an additional upgrade route, controlled by the same observed owner. The address with no code has no visible contract-enforced multisig threshold; this observation does not establish how the operator safeguards or distributes its key. [Published tGBP implementation](https://eth.blockscout.com/api/v2/smart-contracts/0x94321D80d3C5cdaC63B75F723AE64Ca7F94bE547), [published proxy](https://eth.blockscout.com/api/v2/smart-contracts/0x27f6c8289550fCE67f6B50BeD1F519966aFE5287).

The wstGBP issuer can forcibly smelt vault backing, and the oracle/gate/proxy authorities can change price, fees, liquidity availability, and dependency behavior. The vault's pro-rata response to smelt limits first-exiter advantage but cannot prevent the loss. Similarly, tGBP upgrade authority can invalidate exact-transfer and compliance assumptions. Compromise of these controls can have total-loss impact without exploiting the vault itself.

For production risk approval, record these authorities, the operational key safeguards, and the intended upgrade/response process. Prefer contract-enforced threshold control for the tGBP owner/admin as an upstream improvement; the vault cannot implement that change. Do not represent the stack as removing issuer or upgrade trust because the wrapper has no administrator. Safe modules, guards, every historical authorization grant, and all bridge administrators were not exhaustively enumerated; a 3-of-5 owner setting alone does not prove every execution path requires three signatures.

### R-02 — `oracleLive()` means nonzero, not fresh or economically sound

The README explicitly accepts stale fallback valuation during a zero-price pause. Additionally, a nonzero price can remain unchanged indefinitely while `oracleLive()` returns true. `test_Audit_OracleLiveDoesNotDetectStaleNonzeroNav` demonstrates this after a year of elapsed time.

Do not use `oracleLive()` as the only freshness predicate for lending or yield-token pricing. A timestamp on `sync()` alone would only prove that someone recently read the same potentially stale oracle. Integrations need the underlying NAV update time, an explicit age policy, and handling for downward NAV updates, fee changes, illiquidity, and pauses. No external Pendle/Spectra/Morpho adapter was supplied or audited here; README claims about another repository's behavior were not independently established.

`convertToAssets` is gross NAV, whereas a gem redemption pays the fee-adjusted burn value and additionally requires liquidity. At the sampled 25-bps exit fee, the net claim is 99.75% of gross before rounding; gross is approximately 25.06 bps above net when measured against net. The fee is governable, so the gap must not be hard-coded. The existing claim that a NAV step is always smaller than the exit fee is an operating assumption, not an enforced invariant: update size and fees can change. Routers need user-defined slippage and deadline protection.

### R-03 — Liquidity and minimum size constrain generic ERC-4626 integrations

Atomic gem exits require zero cooldown and the entire individual claim in liquid gem. The underlying's outstanding claims and future administrative actions remain relevant to liquidity. The vault correctly refuses partial fills; it has no claim-collection mechanism for queued redemption.

The underlying requires at least one whole wsgem for gem redemption, and roughly one whole wsgem's purchase cost for entry. ERC-4626 previews do not communicate these minimums. A router that only knows `asset()`, `deposit`, and `redeem` cannot automatically use the custom wsgem escape path. Before listing, test the actual adapter's behavior for dust, deficits, paused or stale NAV, fee changes, insufficient liquidity, and an unavailable gem leg. The wrapper's successful property tests do not establish compatibility with every venue listed in the README.

### R-04 — Exact-transfer and no-callback assumptions need a narrow deployment scope

The inspected wstGBP transfer implementation has no user token-receiver hook, and the reviewed tGBP ERC20 transfer path has no arbitrary receiver callback. Under these implementations, this review did not establish a reentrant double-withdrawal path. The vault nevertheless has no reentrancy guard, and its entry paths trust the wsgem mint return value or the requested transfer amount rather than verifying every incoming backing delta.

The generic constructor's decimals/interface checks do not authenticate arbitrary tokens. Rebasing, transfer fees, fabricated mint returns, or newly introduced callbacks are outside the proven model. In particular, the README's reference to balance-delta checks should not be read as protection of every deposit path: the strict observed-delta check is on gem redemption, and mint's check compares a returned amount. Limit deployment to reviewed instances. If broader token support is intended, add explicit received-balance checks and assess callbacks and transient accounting states before claiming compatibility.

## Accounting and security properties that held

The effective backing is `min(wsgem.balanceOf(vault), totalSupply)`. While solvent, shares exchange 1:1 with wsgem, and donating either wsgem or gem cannot inflate the quoted share price. This removes the usual donation/first-depositor inflation mechanism. Donations and rounding surplus remain unclaimable under the deliberate cap; they can offset a later backing deficit.

After a privileged backing burn, deposits stop and both redemption paths distribute the remaining wsgem pro-rata with rounding down. The existing tests cover both withdrawal orderings; I did not find a way for an ordinary holder to redeem more than their calculated backing. A total loss leaves outstanding claims without an ordinary vault reset mechanism, consistent with the immutable design.

For gem entry, deposit rounds received shares down and mint rounds required assets up. For gem exit, redeem rounds the claim down and withdraw rounds both required wsgem and the corresponding deficit-adjusted shares up. In a deficit, effective backing divided by share supply is at most one; this makes that upward share conversion sufficient to release the required integral wsgem amount. The existing finite-capacity and liquidity-bound tests exercise maxima at the boundary and one unit above.

Redemption checks cooldown and complete claim liquidity, verifies the gem balance delta, and reverts the whole transaction on mismatch. Share burning, allowance consumption, and token movement therefore roll back on the reproduced failures. Owner/operator allowance paths and permit deadline, signature, nonce, and replay behavior passed the suite.

Coverage is excellent for the modeled state space, but the findings expose model omissions. The adversarial campaigns use well-behaved price/gate calls and a simplified gem; they did not previously generate reverting dependencies, actual gem pauses, or actual gem transfer-level bans. Inputs are also bounded rather than an exhaustive exploration of all uint256 values or arbitrary governance upgrades.

## Mainnet observations

The following accounting values were read at block **25,911,325**, timestamp **2026-09-05 13:07:59 UTC**, block hash `0xc728314ca6a56c1d1c6c8bfd34c2d2b0dbd931ef7ae09a589e87bc3999fdcb73`:

| Parameter | Observed value |
|---|---|
| wstGBP | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` |
| tGBP | `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` |
| NAV / mint cost | `1010734022032097021` tGBP wei per whole wstGBP |
| Burn cost | `1008207186977016779` tGBP wei per whole wstGBP |
| Entry / exit fee | 0 / 25 bps |
| Cooldown | 0 |
| Capacity | `type(uint256).max` |
| wstGBP total supply | `71236522586849475987490` wei, about 71,236.5226 wstGBP |
| tGBP held by wstGBP | `72093494547112817819593` wei, about 72,093.4945 tGBP |
| Outstanding redemption claims | 0 |
| Settlement conduit | wstGBP itself |

At these values, aggregate supply valued at burn cost is approximately 71,821.1740 tGBP; observed gem liquidity is approximately 100.3791% of that amount. This is a token-liquidity snapshot, not an attestation of off-chain reserves or continuing liquidity. The later latest-state smoke tests also found both market windows open and sufficient liquidity for their exercised exits.

The wstGBP dependency addresses were:

| Component | Address |
|---|---|
| Oracle proxy | `0x6A79dCe61A12aa4b75449e0B03746260765D07dF` |
| Gate proxy | `0xB59cB4d3075a8ce5013C78e8Bd7aDA3Fd1300f7f` |
| Treasury / issuer control | `0xa8F5bE8457D6ed5c659647fa8d107C3F2086626A` |
| Compliance proxy | `0x794cF5948444b14105587455EbE96Caace036d52` |
| Oracle implementation at sampled block | `0x44BFEB1110bA6091034DBaAb450eF1e7469fF072` |
| Gate implementation at sampled block | `0x635dbb7841c27c74b6bDbf1BEd548aAe2C6C9D77` |

Authority and tGBP implementation/admin reads in R-01 used later `latest` requests during the same audit and should not be mistaken for historical assertions at block 25,911,325.

## Build and release requirements

The vault is below runtime and initcode size limits. Its compiler, EVM target, and dependency commits are explicit. `via_ir` is false. The reviewed Solidity alerts involving transient-storage clearing and recursive IR memory spilling therefore do not apply to this build; the code also does not use transient storage. The known storage-array boundary-overflow issue lacks a plausible triggering layout here. Preserve these settings in release artifacts rather than changing compiler pipelines without review. [Solidity bug registry](https://github.com/ethereum/solidity/blob/develop/docs/bugs.json), [IR recursion advisory](https://www.soliditylang.org/blog/2026/07/09/unsound-spill-in-mutual-recursion-bug/).

The reviewed OpenZeppelin advisories did not reveal an applicable issue in this vault's ERC20, ERC20Permit, SafeERC20, and Math paths. Several published advisories concern modules this vault does not use. Dependency age by itself is not evidence of an exploitable defect; any dependency upgrade should be separately reviewed and rebuilt. [OpenZeppelin security advisories](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories).

Before release:

1. Resolve M-01 and L-01, and turn the audit reproductions into regression tests for the intended behavior. Resolve the misleading verification workflow in L-02.
2. Make the pinned mainnet deployment script check `block.chainid == 1`. It currently pins addresses and metadata but no chain ID. Compare expected underlying code/implementation identity and the final deployed vault runtime against the release artifacts; getter checks alone do not authenticate bytecode.
3. Add an archive-backed release test that fails if its required fork suites skip. CI currently supplies no RPC and can remain green while all mainnet tests skip. Keep latest-state smoke checks separate from the deterministic regression baseline.
4. Pin the Foundry toolchain version and CI actions to reviewed revisions for reproducible release builds. The current workflow uses moving action tags and does not choose a Foundry version.
5. Record and explicitly accept the upstream owner, proxy, issuer, compliance, oracle, and cross-chain trust assumptions. Validate each intended venue's actual adapter and price/liquidation policy.
6. Simulate the exact final constructor transaction from the intended deployment account. After deployment, verify its receipt, chain, constructor arguments, runtime, immutable bindings, compliance status, and current route availability before funding. The fork deployment tests passed, but no final production address or signed deployment transaction was supplied or checked.
7. Establish alerts for `deficit()`, NAV pause/update age and large changes, fee/window/cooldown changes, gem liquidity relative to net liabilities and pending claims, tGBP pause/bans, dependency implementation changes, and authority changes. A wrapper with no pause or upgrade function needs an external integration response plan for these events.

These are completion criteria for a release decision, not actions performed during this audit. The most consequential unresolved controls are escape-path independence, truthful availability reporting, upstream authority acceptance, and demonstrated behavior of the actual downstream integration.

## Reproducing the evidence

Run the local reproductions:

```sh
env -u ETH_RPC_URL -u ALCHEMY_API_KEY forge test --match-contract '^WsgemVaultAuditTest$' -vv
```

Run only the new mainnet fault-injection tests on a local fork:

```sh
ETH_RPC_URL=https://ethereum-rpc.publicnode.com FORK_BLOCK=0 forge test \
  --match-path test/WsgemVault.audit.fork.t.sol -vv
```

Run all mainnet suites against latest state:

```sh
ETH_RPC_URL=https://ethereum-rpc.publicnode.com FORK_BLOCK=0 forge test \
  --match-contract 'ForkTest$|SmokeTest$' -vv
```

For release reproducibility, replace the public endpoint with an archive-capable RPC and select a recorded block. The tests use local funding and privileged impersonation strictly inside the fork. None of these commands broadcasts a transaction.
