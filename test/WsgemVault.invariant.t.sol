// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MaseerOne as Wsgem} from "maseer-one/MaseerOne.sol";
import {MaseerPrice} from "maseer-one/MaseerPrice.sol";
import {MaseerGate} from "maseer-one/MaseerGate.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {MockGem} from "./mocks/MockGem.sol";
import {VaultTestBase} from "./VaultTestBase.sol";

/// @dev Both campaigns run with `fail_on_revert = false`, so a silently-reverting handler
/// op would reduce every invariant to a vacuous truth. Each handler therefore keeps a
/// per-op success counter, and every campaign carries a deterministic
/// `test_HandlerWiring_*` that drives each op once and checks its counter moved — the
/// liveness proof lives there, never in `afterInvariant`, whose asserts get shrunk to
/// trivial sequences.

/*//////////////////////////////////////////////////////////////
                        HEALTHY REGIME
//////////////////////////////////////////////////////////////*/

/// @notice Every op is bounded to succeed in a healthy market (open windows, live oracle,
/// unlimited capacity, small fees), across all six 4626/wsgem legs of the vault.
contract VaultHandler is Test {
    uint256 internal constant WAD = 1e18;

    WsgemVault internal vault;
    Wsgem internal wsgem;
    MockGem internal gem;
    MaseerPrice internal pip;
    MaseerGate internal act;

    address[3] internal users;
    address internal donor = makeAddr("donor");

    // Ghosts the invariants compare against (never re-read from the contracts under test).
    uint256 public ghostNavprice;
    uint256 public ghostMintExcess;
    uint256 public ghostGemDust;
    uint256 public ghostDonated;

    // Violation counters.
    uint256 public maxReverted;
    uint256 public previewMismatch;

    // Op liveness counters.
    uint256 public depositGemOk;
    uint256 public mintSharesOk;
    uint256 public depositWsgemOk;
    uint256 public redeemGemOk;
    uint256 public withdrawGemOk;
    uint256 public redeemWsgemOk;
    uint256 public pokeOk;
    uint256 public setBpsoutOk;
    uint256 public setBpsinOk;
    uint256 public donateWsgemOk;
    uint256 public exerciseMaxOk;

    constructor(WsgemVault _vault, Wsgem _wsgem, MockGem _gem, MaseerPrice _pip, MaseerGate _act) {
        vault = _vault;
        wsgem = _wsgem;
        gem = _gem;
        pip = _pip;
        act = _act;
        users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2")];
        ghostNavprice = wsgem.navprice();
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % 3];
    }

    /// @dev Mints wsgem to `u` on the direct path (the one the vault must never beat).
    function _mintWsgemTo(address u, uint256 gemIn) internal returns (uint256 out) {
        gem.mint(u, gemIn);
        vm.startPrank(u);
        gem.approve(address(wsgem), gemIn);
        out = wsgem.mint(gemIn);
        vm.stopPrank();
    }

    /*//////////////////////// vault legs ////////////////////////*/

    function depositGem(uint256 seed, uint256 assets) external {
        address u = _user(seed);
        assets = bound(assets, wsgem.mintcost(), 1e24);
        gem.mint(u, assets);
        vm.startPrank(u);
        gem.approve(address(vault), assets);
        vault.deposit(assets, u);
        vm.stopPrank();
        depositGemOk++;
    }

    function mintShares(uint256 seed, uint256 shares) external {
        address u = _user(seed);
        shares = bound(shares, WAD, 1e24);
        uint256 assets = vault.previewMint(shares);
        gem.mint(u, assets);
        uint256 before = wsgem.balanceOf(address(vault));
        vm.startPrank(u);
        gem.approve(address(vault), assets);
        vault.mint(shares, u);
        vm.stopPrank();
        ghostMintExcess += wsgem.balanceOf(address(vault)) - before - shares;
        mintSharesOk++;
    }

    function depositWsgem(uint256 seed, uint256 gemIn) external {
        address u = _user(seed);
        gemIn = bound(gemIn, wsgem.mintcost(), 1e24);
        uint256 out = _mintWsgemTo(u, gemIn);
        vm.startPrank(u);
        wsgem.approve(address(vault), out);
        vault.depositWsgem(out, u);
        vm.stopPrank();
        depositWsgemOk++;
    }

    function redeemGem(uint256 seed, uint256 shares) external {
        address u = _user(seed);
        uint256 max = vault.maxRedeem(u);
        if (max < WAD) return;
        shares = bound(shares, WAD, max);
        vm.prank(u);
        vault.redeem(shares, u, u);
        redeemGemOk++;
    }

    function withdrawGem(uint256 seed, uint256 assets) external {
        address u = _user(seed);
        uint256 max = vault.maxWithdraw(u);
        uint256 unit = wsgem.burncost();
        if (max < unit) return;
        assets = bound(assets, unit, max);
        vm.prank(u);
        uint256 shares = vault.withdraw(assets, u, u);
        ghostGemDust += shares * unit / WAD - assets;
        withdrawGemOk++;
    }

    function redeemWsgem(uint256 seed, uint256 shares) external {
        address u = _user(seed);
        uint256 max = vault.maxRedeemToWsgem(u);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(u);
        vault.redeemToWsgem(shares, u, u);
        redeemWsgemOk++;
    }

    /*//////////////////////// market levers /////////////////////*/

    function poke(uint256 nav) external {
        nav = bound(nav, 0.5e18, 5e18);
        pip.poke(nav);
        ghostNavprice = nav;
        pokeOk++;
    }

    function setBpsout(uint256 bps) external {
        act.setBpsout(bound(bps, 0, 500));
        setBpsoutOk++;
    }

    function setBpsin(uint256 bps) external {
        act.setBpsin(bound(bps, 0, 500));
        setBpsinOk++;
    }

    function donateWsgem(uint256 amt) external {
        amt = bound(amt, 1, 1e24);
        // Over-fund so the mint (at mintcost) certainly covers `amt`.
        uint256 out = _mintWsgemTo(donor, amt * wsgem.mintcost() / WAD + wsgem.mintcost());
        require(out >= amt, "donor underfunded");
        vm.prank(donor);
        require(wsgem.transfer(address(vault), amt), "donation transfer");
        ghostDonated += amt;
        donateWsgemOk++;
    }

    /*//////////////////////// max* exercise /////////////////////*/

    /// @dev `x(max*())` must never revert and must deliver exactly its preview.
    function exerciseMax(uint256 seed, uint256 which) external {
        address u = _user(seed);
        which = which % 5;
        if (which == 0) {
            uint256 a = _min(vault.maxDeposit(u), 1e24);
            uint256 expected = vault.previewDeposit(a);
            gem.mint(u, a);
            vm.startPrank(u);
            gem.approve(address(vault), a);
            try vault.deposit(a, u) returns (uint256 got) {
                if (got != expected) previewMismatch++;
            } catch {
                maxReverted++;
            }
            vm.stopPrank();
        } else if (which == 1) {
            uint256 s = _min(vault.maxMint(u), 1e24);
            uint256 expected = vault.previewMint(s);
            gem.mint(u, expected);
            uint256 before = wsgem.balanceOf(address(vault));
            vm.startPrank(u);
            gem.approve(address(vault), expected);
            try vault.mint(s, u) returns (uint256 got) {
                if (got != expected) previewMismatch++;
                ghostMintExcess += wsgem.balanceOf(address(vault)) - before - s;
            } catch {
                maxReverted++;
            }
            vm.stopPrank();
        } else if (which == 2) {
            uint256 a = vault.maxWithdraw(u);
            uint256 expected = vault.previewWithdraw(a);
            uint256 unit = wsgem.burncost();
            vm.prank(u);
            try vault.withdraw(a, u, u) returns (uint256 got) {
                if (got != expected) previewMismatch++;
                ghostGemDust += got * unit / WAD - a;
            } catch {
                maxReverted++;
            }
        } else if (which == 3) {
            uint256 s = vault.maxRedeem(u);
            uint256 expected = vault.previewRedeem(s);
            vm.prank(u);
            try vault.redeem(s, u, u) returns (uint256 got) {
                if (got != expected) previewMismatch++;
            } catch {
                maxReverted++;
            }
        } else {
            uint256 s = vault.maxRedeemToWsgem(u);
            uint256 expected = vault.previewRedeemToWsgem(s);
            vm.prank(u);
            try vault.redeemToWsgem(s, u, u) returns (uint256 got) {
                if (got != expected) previewMismatch++;
            } catch {
                maxReverted++;
            }
        }
        exerciseMaxOk++;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract WsgemVaultInvariantTest is VaultTestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, wsgem, gem, pip, act);
        // Pokes are `buds`-gated and fee setters are `auth`-gated; without these the
        // lever ops would silently revert under fail_on_revert = false.
        pip.kiss(address(handler));
        act.rely(address(handler));
        targetContract(address(handler));
    }

    function invariant_VaultWsgemConservation() public view {
        assertEq(
            wsgem.balanceOf(address(vault)),
            vault.totalSupply() + handler.ghostMintExcess() + handler.ghostDonated(),
            "held wsgem != shares + mint excess + donations"
        );
    }

    function invariant_SharePriceTracksOracle() public view {
        assertEq(vault.convertToAssets(1e18), handler.ghostNavprice(), "share price != poked nav");
    }

    function invariant_TotalAssetsIsGross() public view {
        assertEq(vault.totalAssets(), vault.totalSupply() * handler.ghostNavprice() / 1e18, "totalAssets not gross");
    }

    function invariant_NoStrandedTokens() public view {
        assertEq(gem.balanceOf(address(vault)), handler.ghostGemDust(), "vault gem != withdraw dust");
    }

    function invariant_NoDanglingClaims() public view {
        assertEq(wsgem.totalPending(), 0, "queued wsgem redemption claim");
    }

    function invariant_MaxExecutableAndPreviewsExact() public view {
        assertEq(handler.maxReverted(), 0, "x(max*()) reverted");
        assertEq(handler.previewMismatch(), 0, "execution != preview");
    }

    function invariant_NoDeficit() public view {
        assertEq(vault.deficit(), 0, "deficit in healthy regime");
    }

    /// @dev Anti-vacuity: every op is reachable from the start state and moves its counter.
    function test_HandlerWiring_AllOpsSucceed() public {
        handler.depositGem(0, 5e18);
        handler.mintShares(1, 3e18);
        handler.depositWsgem(2, 4e18);
        handler.poke(1.2e18);
        handler.setBpsout(30);
        handler.setBpsin(10);
        handler.donateWsgem(1e18);
        handler.redeemGem(0, 1e18);
        handler.withdrawGem(1, 1e18);
        handler.redeemWsgem(2, 1e18);
        for (uint256 i = 0; i < 5; i++) {
            handler.exerciseMax(i, i);
        }

        assertEq(handler.depositGemOk(), 1);
        assertEq(handler.mintSharesOk(), 1);
        assertEq(handler.depositWsgemOk(), 1);
        assertEq(handler.pokeOk(), 1);
        assertEq(handler.setBpsoutOk(), 1);
        assertEq(handler.setBpsinOk(), 1);
        assertEq(handler.donateWsgemOk(), 1);
        assertEq(handler.redeemGemOk(), 1);
        assertEq(handler.withdrawGemOk(), 1);
        assertEq(handler.redeemWsgemOk(), 1);
        assertEq(handler.exerciseMaxOk(), 5);
        assertEq(handler.maxReverted(), 0);
        assertEq(handler.previewMismatch(), 0);
        assertEq(vault.convertToAssets(1e18), 1.2e18);
        assertEq(handler.ghostDonated(), 1e18);

        invariant_VaultWsgemConservation();
        invariant_SharePriceTracksOracle();
        invariant_TotalAssetsIsGross();
        invariant_NoStrandedTokens();
        invariant_NoDanglingClaims();
        invariant_NoDeficit();
    }
}

/*//////////////////////////////////////////////////////////////
                       ADVERSARIAL REGIME
//////////////////////////////////////////////////////////////*/

/// @notice Adds every governable and privileged lever (smelt, oracle pause, market pause,
/// cooldown, capacity, liquidity drain) and scores every deposit/redeem op for QUOTE
/// HONESTY, ERC-4626 style: a quote never reverts for operational reasons (the one
/// exception is previewWithdraw while the exit unit is zero, and then execution must
/// revert too), execution may revert on a gate while the quote stands, and whenever
/// execution succeeds its result equals the quote. Violations are counted, never asserted
/// inside the handler, so a sequence keeps running after a breach and the invariant sees it.
contract VaultAdversarialHandler is Test {
    uint256 internal constant WAD = 1e18;

    WsgemVault internal vault;
    Wsgem internal wsgem;
    MockGem internal gem;
    MaseerPrice internal pip;
    MaseerGate internal act;
    address internal issuer;

    address[3] internal users;
    address internal donor = makeAddr("adonor");

    // Ghosts.
    uint256 public ghostNavprice; // last non-zero poke
    bool public ghostPaused;
    uint256 public ghostSmelted; // wsgem burned out of the vault by the issuer
    uint256 public ghostHealed; // wsgem donated back into the vault
    uint256 public ghostWsgemIn; // wsgem that entered through the deposit legs (incl. mint excess)
    uint256 public ghostWsgemOut; // wsgem that left through the redemption legs
    uint256 public lastRelease; // wsgem released by the last successful redemption

    // Violation counters (must all stay 0).
    uint256 public quoteReverted;
    uint256 public executionDiverged;
    uint256 public depositAcceptedInDeficit;
    uint256 public redeemOverdrawn;
    uint256 public maxReverted;
    uint256 public claimDangling;
    uint256 public priceMovedOffPoke;
    uint256 public syncLagged;

    // Op liveness counters (op ran to its end, whatever the outcome).
    uint256 public depositGemOps;
    uint256 public mintSharesOps;
    uint256 public depositWsgemOps;
    uint256 public redeemGemOps;
    uint256 public withdrawGemOps;
    uint256 public redeemWsgemOps;
    uint256 public exerciseMaxOps;
    uint256 public smeltOps;
    uint256 public healOps;
    uint256 public settleOps;
    uint256 public refillLiquidityOps;
    uint256 public setCooldownOps;
    uint256 public clearCooldownOps;
    uint256 public pauseOracleOps;
    uint256 public unpauseOracleOps;
    uint256 public syncOracleOps;
    uint256 public pauseMarketOps;
    uint256 public reopenMarketOps;
    uint256 public setCapacityOps;
    uint256 public clearCapacityOps;
    uint256 public pokeOps;

    // Outcome counters (how often each state actually bit; for the wiring test).
    uint256 public depositsBlocked;
    uint256 public redeemsBlocked;
    uint256 public depositsServed;
    uint256 public redeemsServed;

    constructor(WsgemVault _vault, Wsgem _wsgem, MockGem _gem, MaseerPrice _pip, MaseerGate _act, address _issuer) {
        vault = _vault;
        wsgem = _wsgem;
        gem = _gem;
        pip = _pip;
        act = _act;
        issuer = _issuer;
        users = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2")];
        ghostNavprice = wsgem.navprice();
    }

    /// @dev A non-oracle op must never move the share price while the vault is fully backed
    /// before and after, and must never lower it otherwise (pro-rata rounding leaves dust
    /// in the vault, which can only lift the price; healing lifts it).
    modifier priceStable() {
        bool live = wsgem.navprice() > 0;
        uint256 p0 = live ? vault.convertToAssets(WAD) : 0;
        bool solvent0 = vault.deficit() == 0;
        _;
        if (live && wsgem.navprice() > 0) {
            uint256 p1 = vault.convertToAssets(WAD);
            if (solvent0 && vault.deficit() == 0) {
                if (p1 != p0) priceMovedOffPoke++;
            } else if (p1 < p0) {
                priceMovedOffPoke++;
            }
        }
    }

    /// @dev Accounts every wsgem that crosses the vault's balance through its own legs.
    modifier trackHeld() {
        uint256 heldBefore = wsgem.balanceOf(address(vault));
        _;
        uint256 heldAfter = wsgem.balanceOf(address(vault));
        if (heldAfter > heldBefore) ghostWsgemIn += heldAfter - heldBefore;
        else ghostWsgemOut += heldBefore - heldAfter;
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % 3];
    }

    function user(uint256 seed) external view returns (address) {
        return _user(seed);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev The quote-side exit unit: live burncost, or the cached one while paused.
    function _burnUnitRef() internal view returns (uint256) {
        return wsgem.navprice() == 0 ? vault.lastBurnUnit() : wsgem.burncost();
    }

    /// @dev Quote first, execute second (as `caller`), and score the pair for honesty. A
    /// quote may revert only when `quoteMayRevert` (previewWithdraw with a zero exit unit)
    /// and then execution must revert too; a standing quote must equal a successful
    /// execution's result. Returns the amount on success.
    function _quoted(bytes memory previewCall, bytes memory execCall, address caller, bool quoteMayRevert)
        internal
        returns (bool ok, uint256 value)
    {
        (bool pOk, bytes memory pRet) = address(vault).staticcall(previewCall);
        vm.prank(caller);
        (bool eOk, bytes memory eRet) = address(vault).call(execCall);
        if (!pOk) {
            if (!quoteMayRevert || eOk) quoteReverted++;
            return (false, 0);
        }
        if (!eOk) return (false, 0);
        uint256 pv = abi.decode(pRet, (uint256));
        uint256 ev = abi.decode(eRet, (uint256));
        if (pv != ev) executionDiverged++;
        return (true, ev);
    }

    /// @dev Mints wsgem to `u` directly; returns 0 (and does nothing) when the wsgem's own
    /// mint is closed, so the op degrades to a no-op rather than reverting.
    function _tryMintWsgemTo(address u, uint256 gemIn) internal returns (uint256 out) {
        gem.mint(u, gemIn);
        vm.startPrank(u);
        gem.approve(address(wsgem), gemIn);
        try wsgem.mint(gemIn) returns (uint256 o) {
            out = o;
        } catch {}
        vm.stopPrank();
    }

    function _scoreDeposit(bool ok, bool wasInDeficit) internal {
        if (ok) {
            depositsServed++;
            if (wasInDeficit) depositAcceptedInDeficit++;
        } else {
            depositsBlocked++;
        }
    }

    /// @dev A served redemption may never release more wsgem than the shares it burned
    /// (1:1 is the ceiling; pro-rata is below it) nor more than the vault held.
    function _scoreRedeem(bool ok, uint256 shares, uint256 heldBefore, bool gemLeg) internal {
        if (ok) {
            redeemsServed++;
            uint256 released = heldBefore - wsgem.balanceOf(address(vault));
            lastRelease = released;
            if (released > shares || released > heldBefore) redeemOverdrawn++;
            if (gemLeg && wsgem.totalPending() != 0) claimDangling++;
        } else {
            redeemsBlocked++;
        }
    }

    /*//////////////////////// vault legs (quoted) ///////////////*/

    function depositGem(uint256 seed, uint256 assets) external priceStable trackHeld {
        address u = _user(seed);
        assets = bound(assets, 1, 1e24);
        gem.mint(u, assets);
        vm.prank(u);
        gem.approve(address(vault), type(uint256).max);
        bool inDeficit = vault.deficit() != 0;
        (bool ok,) = _quoted(
            abi.encodeCall(vault.previewDeposit, (assets)), abi.encodeCall(vault.deposit, (assets, u)), u, false
        );
        _scoreDeposit(ok, inDeficit);
        depositGemOps++;
    }

    function mintShares(uint256 seed, uint256 shares) external priceStable trackHeld {
        address u = _user(seed);
        shares = bound(shares, 1, 1e24);
        // Quotes never revert: fund exactly what the quote says.
        gem.mint(u, vault.previewMint(shares));
        vm.prank(u);
        gem.approve(address(vault), type(uint256).max);
        bool inDeficit = vault.deficit() != 0;
        (bool ok,) =
            _quoted(abi.encodeCall(vault.previewMint, (shares)), abi.encodeCall(vault.mint, (shares, u)), u, false);
        _scoreDeposit(ok, inDeficit);
        mintSharesOps++;
    }

    function depositWsgem(uint256 seed, uint256 gemIn) external priceStable trackHeld {
        address u = _user(seed);
        gemIn = bound(gemIn, 1, 1e24);
        uint256 amt = _tryMintWsgemTo(u, gemIn);
        if (amt == 0) {
            depositWsgemOps++;
            return;
        }
        vm.prank(u);
        wsgem.approve(address(vault), type(uint256).max);
        bool inDeficit = vault.deficit() != 0;
        (bool ok,) = _quoted(
            abi.encodeCall(vault.previewDepositWsgem, (amt)), abi.encodeCall(vault.depositWsgem, (amt, u)), u, false
        );
        _scoreDeposit(ok, inDeficit);
        depositWsgemOps++;
    }

    function redeemGem(uint256 seed, uint256 shares) external priceStable trackHeld {
        address u = _user(seed);
        uint256 bal = vault.balanceOf(u);
        if (bal == 0) {
            redeemGemOps++;
            return;
        }
        shares = bound(shares, 1, bal);
        uint256 held = wsgem.balanceOf(address(vault));
        (bool ok,) = _quoted(
            abi.encodeCall(vault.previewRedeem, (shares)), abi.encodeCall(vault.redeem, (shares, u, u)), u, false
        );
        _scoreRedeem(ok, shares, held, true);
        redeemGemOps++;
    }

    function withdrawGem(uint256 seed, uint256 assets) external priceStable trackHeld {
        address u = _user(seed);
        uint256 bal = vault.balanceOf(u);
        if (bal == 0) {
            withdrawGemOps++;
            return;
        }
        // Bound to what the balance quotes for so a failure is a vault gate, not "burn
        // amount exceeds balance".
        uint256 cap = vault.previewRedeem(bal);
        assets = bound(assets, 1, cap == 0 ? 1 : cap);
        uint256 held = wsgem.balanceOf(address(vault));
        (bool ok, uint256 burned) = _quoted(
            abi.encodeCall(vault.previewWithdraw, (assets)),
            abi.encodeCall(vault.withdraw, (assets, u, u)),
            u,
            _burnUnitRef() == 0
        );
        _scoreRedeem(ok, burned, held, true);
        withdrawGemOps++;
    }

    function redeemWsgem(uint256 seed, uint256 shares) external priceStable trackHeld {
        address u = _user(seed);
        uint256 bal = vault.balanceOf(u);
        if (bal == 0) {
            redeemWsgemOps++;
            return;
        }
        shares = bound(shares, 1, bal);
        uint256 held = wsgem.balanceOf(address(vault));
        (bool ok,) = _quoted(
            abi.encodeCall(vault.previewRedeemToWsgem, (shares)),
            abi.encodeCall(vault.redeemToWsgem, (shares, u, u)),
            u,
            false
        );
        _scoreRedeem(ok, shares, held, false);
        redeemWsgemOps++;
    }

    /*//////////////////////// max* exercise /////////////////////*/

    /// @dev `x(max*())` must never revert in ANY state — including a closed leg, where the
    /// max is 0 and the mutator must be a harmless no-op — and must deliver its quote.
    function exerciseMax(uint256 seed, uint256 which) external priceStable trackHeld {
        address u = _user(seed);
        which = which % 5;
        if (which == 0) {
            uint256 a = _min(vault.maxDeposit(u), 1e24);
            uint256 expected = vault.previewDeposit(a);
            gem.mint(u, a);
            vm.startPrank(u);
            gem.approve(address(vault), type(uint256).max);
            try vault.deposit(a, u) returns (uint256 got) {
                if (got != expected) executionDiverged++;
            } catch {
                maxReverted++;
            }
            vm.stopPrank();
        } else if (which == 1) {
            uint256 s = _min(vault.maxMint(u), 1e24);
            uint256 expected = vault.previewMint(s);
            gem.mint(u, expected);
            vm.startPrank(u);
            gem.approve(address(vault), type(uint256).max);
            try vault.mint(s, u) returns (uint256 got) {
                if (got != expected) executionDiverged++;
            } catch {
                maxReverted++;
            }
            vm.stopPrank();
        } else if (which == 2) {
            uint256 a = vault.maxWithdraw(u);
            uint256 expected = a == 0 ? 0 : vault.previewWithdraw(a);
            vm.prank(u);
            try vault.withdraw(a, u, u) returns (uint256 got) {
                if (got != expected) executionDiverged++;
            } catch {
                maxReverted++;
            }
        } else if (which == 3) {
            uint256 s = vault.maxRedeem(u);
            uint256 expected = vault.previewRedeem(s);
            vm.prank(u);
            try vault.redeem(s, u, u) returns (uint256 got) {
                if (got != expected) executionDiverged++;
            } catch {
                maxReverted++;
            }
        } else {
            uint256 s = vault.maxRedeemToWsgem(u);
            uint256 expected = vault.previewRedeemToWsgem(s);
            vm.prank(u);
            try vault.redeemToWsgem(s, u, u) returns (uint256 got) {
                if (got != expected) executionDiverged++;
            } catch {
                maxReverted++;
            }
        }
        if (wsgem.totalPending() != 0) claimDangling++;
        exerciseMaxOps++;
    }

    /*//////////////////////// privileged & governable levers ////*/

    /// @dev The one non-oracle lever that lowers the price: it marks every share down.
    function smelt(uint256 amt) external {
        uint256 held = wsgem.balanceOf(address(vault));
        if (held == 0) {
            smeltOps++;
            return;
        }
        amt = bound(amt, 1, held);
        bool live = wsgem.navprice() > 0;
        uint256 p0 = live ? vault.convertToAssets(WAD) : 0;
        vm.prank(issuer);
        wsgem.smelt(address(vault), amt);
        ghostSmelted += amt;
        if (live && vault.convertToAssets(WAD) > p0) priceMovedOffPoke++;
        smeltOps++;
    }

    /// @dev Donating wsgem back is the deficit-remediation path.
    function heal(uint256 amt) external priceStable {
        uint256 d = vault.deficit();
        if (d == 0) {
            healOps++;
            return;
        }
        amt = bound(amt, 1, d);
        uint256 unit = wsgem.mintcost();
        uint256 out = unit == 0 ? 0 : _tryMintWsgemTo(donor, amt * unit / WAD + unit);
        if (out < amt) {
            healOps++; // mint window closed or oracle paused: nothing to heal with
            return;
        }
        vm.prank(donor);
        require(wsgem.transfer(address(vault), amt), "heal transfer");
        ghostHealed += amt;
        healOps++;
    }

    /// @dev Drains every gem not reserved for queued claims out of the wsgem (to `flo`).
    function settle() external priceStable {
        wsgem.settle();
        settleOps++;
    }

    function refillLiquidity(uint256 amt) external priceStable {
        gem.mint(address(wsgem), bound(amt, 1, 1e24));
        refillLiquidityOps++;
    }

    function setCooldown(uint256 cd) external priceStable {
        act.setCooldown(bound(cd, 1, 365 days));
        setCooldownOps++;
    }

    function clearCooldown() external priceStable {
        act.setCooldown(0);
        clearCooldownOps++;
    }

    function pauseOracle() external {
        pip.pause();
        ghostPaused = true;
        pauseOracleOps++;
    }

    function unpauseOracle() external {
        pip.poke(ghostNavprice);
        ghostPaused = false;
        unpauseOracleOps++;
    }

    /// @dev Refreshes the oracle-pause fallback from a live oracle; afterwards the cache
    /// must equal the live NAV. A no-op while paused (sync() reverts then, by design).
    function syncOracle() external priceStable {
        if (wsgem.navprice() == 0) {
            syncOracleOps++;
            return;
        }
        vault.sync();
        if (vault.lastNav() != wsgem.navprice()) syncLagged++;
        syncOracleOps++;
    }

    function poke(uint256 nav) external {
        nav = bound(nav, 0.5e18, 5e18);
        pip.poke(nav);
        ghostNavprice = nav;
        ghostPaused = false;
        pokeOps++;
    }

    function pauseMarket() external priceStable {
        act.pauseMarket();
        pauseMarketOps++;
    }

    function reopenMarket() external priceStable {
        act.setOpenMint(block.timestamp);
        act.setOpenBurn(block.timestamp);
        act.file("haltmint", type(uint256).max);
        act.file("haltburn", type(uint256).max);
        reopenMarketOps++;
    }

    function setCapacity(uint256 cap) external priceStable {
        act.setCapacity(bound(cap, 0, 1e30));
        setCapacityOps++;
    }

    function clearCapacity() external priceStable {
        act.setCapacity(type(uint256).max);
        clearCapacityOps++;
    }
}

contract WsgemVaultAdversarialInvariantTest is VaultTestBase {
    VaultAdversarialHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultAdversarialHandler(vault, wsgem, gem, pip, act, issuer);
        pip.kiss(address(handler)); // poke
        pip.rely(address(handler)); // pause
        act.rely(address(handler)); // gate setters
        targetContract(address(handler));
    }

    /// @dev Exact flow identity: every wsgem that ever entered the vault is still held,
    /// was burned by the issuer, or left through a redemption leg.
    function invariant_BackingConservation() public view {
        assertEq(
            wsgem.balanceOf(address(vault)) + handler.ghostSmelted() + handler.ghostWsgemOut(),
            handler.ghostWsgemIn() + handler.ghostHealed(),
            "wsgem backing not conserved"
        );
    }

    function invariant_FailClosedEnforced() public view {
        assertEq(handler.quoteReverted(), 0, "quote reverted");
        assertEq(handler.executionDiverged(), 0, "execution diverged from quote");
        assertEq(handler.depositAcceptedInDeficit(), 0, "deposit accepted in deficit");
        assertEq(handler.redeemOverdrawn(), 0, "redeem overdrew backing");
        assertEq(handler.maxReverted(), 0, "x(max*()) reverted");
        assertEq(handler.claimDangling(), 0, "queued claim owned by vault");
        assertEq(handler.priceMovedOffPoke(), 0, "share price moved without a poke");
        assertEq(handler.syncLagged(), 0, "sync() left the fallback lagging");
    }

    function invariant_NoDanglingClaims() public view {
        assertEq(wsgem.totalPending(), 0, "queued wsgem redemption claim");
    }

    /// @dev Accounting marks shares down to their effective backing: the share price is
    /// nav * min(held, supply) / supply (two floors, so within nav/1e18 + 1 of the exact
    /// value), and totalAssets never exceeds the fully-backed value.
    function invariant_ProRataMarkdown() public view {
        uint256 nav = wsgem.navprice();
        if (nav == 0) return;
        uint256 supply = vault.totalSupply();
        uint256 held = wsgem.balanceOf(address(vault));
        uint256 price = vault.convertToAssets(1e18);
        if (supply == 0) {
            assertEq(price, nav, "empty vault prices at nav");
        } else {
            uint256 effective = held < supply ? held : supply;
            assertApproxEqAbs(price, nav * effective / supply, nav / 1e18 + 1, "share price != marked-down nav");
        }
        assertLe(vault.totalAssets(), supply * nav / 1e18, "totalAssets above full backing");
        if (held >= supply) assertEq(price, nav, "fully backed prices at nav");
    }

    /// @dev Quotes never revert in any reachable state (previewWithdraw excepted while the
    /// exit unit is zero).
    function invariant_QuotesNeverRevert() public view {
        vault.totalAssets();
        vault.convertToShares(1e18);
        vault.convertToAssets(1e18);
        vault.previewDeposit(1e18);
        vault.previewMint(1e18);
        vault.previewRedeem(1e18);
        vault.previewRedeemToWsgem(1e18);
        vault.previewDepositWsgem(1e18);
        uint256 unit = wsgem.navprice() == 0 ? vault.lastBurnUnit() : wsgem.burncost();
        if (unit != 0) vault.previewWithdraw(1e18);
    }

    /// @dev Anti-vacuity: a deterministic walk through every adversarial state, checking
    /// that each lever actually bit (blocked/served counters move), that the pro-rata
    /// markdown and payout show up in a deficit, and that no violation counter ever moves.
    function test_HandlerWiring_FullLifecycle() public {
        // Seed positions through every deposit leg.
        handler.depositGem(0, 10e18);
        handler.mintShares(1, 5e18);
        handler.depositWsgem(2, 8e18);
        assertEq(handler.depositsServed(), 3, "seed deposits");
        assertEq(handler.depositsBlocked(), 0);
        uint256 nav = wsgem.navprice();
        assertEq(vault.convertToAssets(1e18), nav, "fully backed prices at nav");

        // Smelt -> deficit -> price marked down, every deposit leg fails closed, the wsgem
        // leg pays pro-rata -> heal -> reopened at par.
        handler.smelt(3e18);
        assertGt(vault.deficit(), 0, "deficit after smelt");
        assertLt(vault.convertToAssets(1e18), nav, "price not marked down");
        uint256 blocked = handler.depositsBlocked();
        handler.depositGem(0, 2e18);
        handler.mintShares(1, 1e18);
        handler.depositWsgem(2, 2e18); // >= mintcost so the direct wsgem mint feeding the leg succeeds
        assertEq(handler.depositsBlocked(), blocked + 3, "deposits not blocked in deficit");
        uint256 served = handler.redeemsServed();
        handler.redeemWsgem(2, 1e18);
        assertEq(handler.redeemsServed(), served + 1, "wsgem leg not live in deficit");
        assertLt(handler.lastRelease(), 1e18, "wsgem leg not pro-rata in deficit");
        assertGt(handler.lastRelease(), 0);
        handler.heal(type(uint256).max);
        assertEq(vault.deficit(), 0, "deficit not healed");
        assertEq(vault.convertToAssets(1e18), nav, "price not restored");
        served = handler.depositsServed();
        handler.depositGem(0, 2e18);
        assertEq(handler.depositsServed(), served + 1, "deposit after heal");

        // Oracle pause: quotes stand on the cache, gem legs blocked, wsgem legs live.
        handler.syncOracle();
        handler.pauseOracle();
        assertEq(vault.convertToAssets(1e18), nav, "quote did not fall back to the cache");
        blocked = handler.redeemsBlocked();
        served = handler.redeemsServed();
        handler.redeemGem(0, 1e18);
        handler.withdrawGem(1, 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 2, "gem-out not blocked while paused");
        handler.redeemWsgem(2, 1e18);
        assertEq(handler.redeemsServed(), served + 1, "wsgem leg not live while paused");
        handler.syncOracle(); // no-op while paused
        handler.unpauseOracle();
        assertGt(wsgem.navprice(), 0);

        // Cooldown: gem-out blocked and max* zero; cleared afterwards.
        handler.setCooldown(1 days);
        assertEq(vault.maxRedeem(handlerUser(0)), 0, "maxRedeem during cooldown");
        blocked = handler.redeemsBlocked();
        handler.redeemGem(0, 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 1, "gem-out not blocked in cooldown");
        handler.clearCooldown();

        // Thin liquidity: settle drains the wsgem, gem-out reverts InsufficientLiquidity,
        // refill restores it.
        handler.settle();
        assertEq(gem.balanceOf(address(wsgem)), 0, "settle did not drain");
        blocked = handler.redeemsBlocked();
        handler.redeemGem(0, 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 1, "gem-out not blocked when thin");
        handler.refillLiquidity(1e24);
        served = handler.redeemsServed();
        handler.redeemGem(0, 1e18);
        assertEq(handler.redeemsServed(), served + 1, "gem-out after refill");

        // Market pause / reopen, capacity set / clear, poke + sync, and max* in every state.
        handler.pauseMarket();
        blocked = handler.depositsBlocked();
        handler.depositGem(0, 2e18);
        assertEq(handler.depositsBlocked(), blocked + 1, "deposit not blocked while market paused");
        for (uint256 i = 0; i < 5; i++) {
            handler.exerciseMax(i, i);
        }
        handler.reopenMarket();
        handler.setCapacity(1e30);
        handler.clearCapacity();
        handler.poke(1.1e18);
        assertTrue(vault.lastNav() != 1.1e18, "poke alone must not touch the cache");
        handler.syncOracle();
        assertEq(vault.lastNav(), 1.1e18, "sync did not refresh the cache");
        for (uint256 i = 0; i < 5; i++) {
            handler.exerciseMax(i, i);
        }

        // Every op ran.
        assertEq(handler.depositGemOps(), 4);
        assertEq(handler.mintSharesOps(), 2);
        assertEq(handler.depositWsgemOps(), 2);
        assertEq(handler.redeemGemOps(), 4);
        assertEq(handler.withdrawGemOps(), 1);
        assertEq(handler.redeemWsgemOps(), 2);
        assertEq(handler.exerciseMaxOps(), 10);
        assertEq(handler.smeltOps(), 1);
        assertEq(handler.healOps(), 1);
        assertEq(handler.settleOps(), 1);
        assertEq(handler.refillLiquidityOps(), 1);
        assertEq(handler.setCooldownOps(), 1);
        assertEq(handler.clearCooldownOps(), 1);
        assertEq(handler.pauseOracleOps(), 1);
        assertEq(handler.unpauseOracleOps(), 1);
        assertEq(handler.syncOracleOps(), 3);
        assertEq(handler.pauseMarketOps(), 1);
        assertEq(handler.reopenMarketOps(), 1);
        assertEq(handler.setCapacityOps(), 1);
        assertEq(handler.clearCapacityOps(), 1);
        assertEq(handler.pokeOps(), 1);

        // And nothing was ever violated.
        invariant_FailClosedEnforced();
        invariant_BackingConservation();
        invariant_NoDanglingClaims();
        invariant_ProRataMarkdown();
        invariant_QuotesNeverRevert();
    }

    /// @dev The handler's user for `seed`, for assertions that need a real holder.
    function handlerUser(uint256 seed) internal view returns (address) {
        return handler.user(seed);
    }
}
