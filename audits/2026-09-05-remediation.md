# WsgemVault audit remediation review

Reviewed 2026-09-05 against the working tree based on `3555ea8fbf7871b71f4cf7189f18b036744beafc`.
The user's existing changes, including the zero-fee ERC-4626 suite and expanded feed-failure
tests/invariants, were reviewed and preserved. The [original audit](2026-09-05-production-readiness.md)
remains the historical finding record.

## Finding disposition

| Finding | Status | Implementation |
|---|---|---|
| M-01: feed failures prevent wsgem exits | Resolved for the reviewed token stack | Optional refresh uses bounded, fixed-output static calls and commits its cached tuple only after all three reads succeed. |
| L-01: false gem maxima and healthy status during token shutdowns | Resolved for tGBP and the documented compatibility model | Gem availability checks pause state and both vault/wsgem compliance; maxima return zero and health checks fail during a global restriction. |
| L-02: verification can resume a transaction broadcast | Resolved | `make verify VAULT=...` uses `forge verify-contract` and has no broadcast/resume/signing path. |

The original ordinary-revert fix used Solidity `try/catch` and refreshed all cached values
together. I retained that behavior and hardened the external-call boundary: each read is
limited to 50,000 gas, only one 32-byte word is copied, and a wrong return length is rejected.
Gas exhaustion, malformed ABI data, and excessive return data therefore cause the optional
refresh to give up without preventing the wsgem leg. Explicit `sync()` still reverts
`InvalidPrice` when refresh fails. Price-dependent quotes and gem execution continue to
fail closed on their required broken feeds; this change does not introduce stale-price
execution on gem paths.

The gem's optional `paused()` capability is detected once at construction and exposed as
`gemPausable()`. Once detected, a failed or malformed pause read disables gem maxima.
`gemTransfersAvailable()` also checks the vault and wsgem through the existing compliance
interface. The pinned wstGBP script requires pause detection to have succeeded. Non-pausable
ERC20s remain supported without changing constructor arguments; they must not acquire pause
semantics later without a new vault or adapter. This limitation is explicit in the interface
and README. Exact transfers and the reviewed callback/compliance semantics remain required.

The shared mock now enforces tGBP-like sender, recipient, and spender bans and transfer
pauses. Old tests that expected a banned gem sender/receiver to be accepted now expect the
gem's rejection and check transaction rollback. Test funding remains unrestricted.

## Additional release changes

- Pinned wstGBP deployment and health-check paths require Ethereum chain ID 1 and the pinned
  token pair, including direct calls to the shared public deployment/check entry points.
- Explicit `make test-fork` and `make test-smoke` set `REQUIRE_FORK=true` and fail on absent RPC
  configuration. Ordinary offline tests retain their intentional skip behavior. Successful
  forks log their block number and require mainnet chain ID.
- CI pins Foundry v1.7.1 and the existing checkout/toolchain actions to exact revisions. A
  manually requested `release_checks` job requires an archive RPC secret, a positive
  historical block, the deterministic fork suite, and latest-state smoke checks.
- `make verify` requires a mined `VAULT` address and explorer API key, extracts constructor
  arguments from on-chain creation code, and waits for verification. `CHAIN` defaults to
  mainnet. No deployment wallet is required. The legacy transaction-resuming recipe was
  removed.
- README and environment examples describe the new commands, availability predicates,
  compatibility limits, bounded refresh, NAV freshness limitation, and exact rounding bound.

## Validation

| Check | Result |
|---|---|
| Full offline suite | **351 passed**, 0 failed; 16 network-dependent tests intentionally skipped |
| Audit regression suite | **13 passed**, including 1,024 malformed-return fuzz runs |
| Combined mainnet fork/smoke check | **16 passed**, 0 failed, 0 skipped |
| Updated `make test-fork`, `FORK_BLOCK=0` | **13 passed**, 0 failed, 0 skipped, at block **25,913,642** |
| Updated `make test-smoke` | **3 passed**, 0 failed, 0 skipped, at block **25,913,665** |
| Missing-RPC required-fork probe | Failed with the intended configuration error, with no skipped tests |
| Verification recipe | Dry-run confirms `forge verify-contract`; no `--broadcast`, `--resume`, or signing-wallet invocation |
| Workflow syntax | YAML parsed successfully; release job present |
| Optimized build | Runtime **18,145 bytes**; initcode **21,403 bytes**, both within limits |
| Formatting and whitespace | `forge fmt --check` and `git diff --check` passed |

The regressions exercise normal revert, gas-burning oracle code, invalid return lengths for
all three price selectors, an oversized return, an invalid exit fee, immutable pause
capability detection, failed/malformed pause reads, real tGBP pauses/bans on a fork, and
wrong-chain deployment/check rejection. The original audit reproductions have been renamed
and inverted to assert the fixes. The stale nonzero NAV test remains a test of an explicit
integration constraint, not a claim that `oracleLive()` provides freshness.

The original audit's 100% coverage measurement predates these changes. No new coverage
percentage is claimed here. The full test suite and targeted adversarial regressions were
used to validate remediation.

## Remaining production responsibilities

The three actionable findings are resolved locally. This is not a blanket production
sign-off: upstream issuer/oracle/compliance/upgrade authority, NAV freshness, transfer
semantics, redemption minimums, and liquidity constraints remain part of the design.
Downstream adapters must be validated against those constraints.

The GitHub release job still needs the repository's `ETH_RPC_URL` secret and can optionally
use `WSGEM_FORK_BLOCK` (default 25589900). It was added and syntax-checked locally, not
dispatched remotely. Mainnet execution checks in this follow-up used latest state through
the public RPC; the archive-backed release baseline must be recorded using the release RPC.

No production vault address was supplied, so actual explorer verification, deployed-runtime
comparison, post-deployment checks, and funding were not performed. The verification recipe
was inspected through a dry run; no explorer write or blockchain transaction was submitted.
