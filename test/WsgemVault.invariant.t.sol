// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MaseerOne as Wsgem} from "maseer-one/MaseerOne.sol";
import {MaseerPrice} from "maseer-one/MaseerPrice.sol";
import {MaseerGate} from "maseer-one/MaseerGate.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {MockGem} from "./mocks/MockGem.sol";
import {InvariantBase} from "./InvariantBase.sol";

/// @dev Both campaigns run with `fail_on_revert = false`, so a silently-reverting handler
/// op would reduce every invariant to a vacuous truth. Each handler therefore keeps a
/// per-op success counter, and every campaign carries a deterministic
/// `test_HandlerWiring_*` that drives each op once and checks its counter moved — the
/// liveness proof lives there, never in `afterInvariant`, whose asserts get shrunk to
/// trivial sequences. The view facts shared by every campaign live in InvariantBase.

/*//////////////////////////////////////////////////////////////
                        HEALTHY REGIME
//////////////////////////////////////////////////////////////*/

/// @notice Every op is bounded to succeed in a healthy market (open windows, live oracle,
/// unlimited capacity, small fees), across all six 4626/wsgem legs of the vault, plus
/// share transfers and a gem gift to the vault.
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
    uint256 public ghostGemDonated;

    // Violation counters.
    uint256 public maxReverted;
    uint256 public maxNotTight;
    uint256 public previewMismatch;
    uint256 public surplusExceeded;

    // Op liveness counters.
    uint256 public depositGemOk;
    uint256 public mintSharesOk;
    uint256 public depositWsgemOk;
    uint256 public redeemGemOk;
    uint256 public withdrawGemOk;
    uint256 public redeemWsgemOk;
    uint256 public transferOk;
    uint256 public pokeOk;
    uint256 public setBpsoutOk;
    uint256 public setBpsinOk;
    uint256 public donateWsgemOk;
    uint256 public donateGemOk;
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

    function user(uint256 seed) external view returns (address) {
        return _user(seed);
    }

    /// @dev Mints wsgem to `u` on the direct path (the one the vault must never beat).
    function _mintWsgemTo(address u, uint256 gemIn) internal returns (uint256 out) {
        gem.mint(u, gemIn);
        vm.startPrank(u);
        gem.approve(address(wsgem), gemIn);
        out = wsgem.mint(gemIn);
        vm.stopPrank();
    }

    /// @dev Books the wsgem a mint left beyond its shares against the README bound: less
    /// than one gem wei's worth of wsgem, `ceil(1e18 / mintcost) - 1`.
    function _bookSurplus(uint256 excess, uint256 unit) internal {
        ghostMintExcess += excess;
        if (excess > _ceilDiv(WAD, unit) - 1) surplusExceeded++;
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
        uint256 unit = wsgem.mintcost();
        gem.mint(u, assets);
        uint256 before = wsgem.balanceOf(address(vault));
        vm.startPrank(u);
        gem.approve(address(vault), assets);
        vault.mint(shares, u);
        vm.stopPrank();
        _bookSurplus(wsgem.balanceOf(address(vault)) - before - shares, unit);
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

    /// @dev Shares are a plain ERC20: a transfer moves a balance and nothing else.
    function transferShares(uint256 seed, uint256 seed2, uint256 amt) external {
        address a = _user(seed);
        address b = _user(seed2);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        vm.prank(a);
        require(vault.transfer(b, amt), "share transfer");
        transferOk++;
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

    /// @dev Gem given to the vault is stranded: it never enters a quote or a payout.
    function donateGem(uint256 amt) external {
        amt = bound(amt, 1, 1e24);
        gem.mint(address(vault), amt);
        ghostGemDonated += amt;
        donateGemOk++;
    }

    /*//////////////////////// max* exercise /////////////////////*/

    /// @dev `x(max*())` must never revert and must deliver exactly its preview; where the
    /// max is finite and below what the actor could otherwise ask, `x(max*() + 1)` must
    /// revert first (probed before, so the tightness check sees the quoted state).
    function exerciseMax(uint256 seed, uint256 which) external {
        address u = _user(seed);
        which = which % 6;
        if (which == 0) _maxDeposit(u);
        else if (which == 1) _maxMint(u);
        else if (which == 2) _maxWithdraw(u);
        else if (which == 3) _maxRedeem(u);
        else if (which == 4) _maxRedeemToWsgem(u);
        else _maxDepositWsgem(u, seed);
        exerciseMaxOk++;
    }

    function _maxDeposit(address u) internal {
        uint256 m = vault.maxDeposit(u);
        uint256 a = _min(m, 1e24);
        uint256 expected = vault.previewDeposit(a);
        gem.mint(u, a + 1);
        vm.startPrank(u);
        gem.approve(address(vault), type(uint256).max);
        if (m < 1e24) {
            try vault.deposit(m + 1, u) {
                maxNotTight++;
            } catch {}
        }
        try vault.deposit(a, u) returns (uint256 got) {
            if (got != expected) previewMismatch++;
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    function _maxMint(address u) internal {
        uint256 m = vault.maxMint(u);
        uint256 s = _min(m, 1e24);
        uint256 expected = vault.previewMint(s);
        uint256 unit = wsgem.mintcost();
        gem.mint(u, 2 * vault.previewMint(s + 1));
        vm.startPrank(u);
        gem.approve(address(vault), type(uint256).max);
        if (m < 1e24) {
            uint256 before = wsgem.balanceOf(address(vault));
            try vault.mint(m + 1, u) {
                maxNotTight++;
                _bookSurplus(wsgem.balanceOf(address(vault)) - before - (m + 1), unit);
            } catch {}
        }
        uint256 held = wsgem.balanceOf(address(vault));
        try vault.mint(s, u) returns (uint256 got) {
            if (got != expected) previewMismatch++;
            _bookSurplus(wsgem.balanceOf(address(vault)) - held - s, unit);
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    function _maxWithdraw(address u) internal {
        uint256 m = vault.maxWithdraw(u);
        uint256 expected = vault.previewWithdraw(m);
        uint256 unit = wsgem.burncost();
        vm.startPrank(u);
        try vault.withdraw(m + 1, u, u) returns (uint256 got) {
            maxNotTight++;
            ghostGemDust += got * unit / WAD - (m + 1);
        } catch {}
        try vault.withdraw(m, u, u) returns (uint256 got) {
            if (got != expected) previewMismatch++;
            ghostGemDust += got * unit / WAD - m;
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    function _maxRedeem(address u) internal {
        uint256 m = vault.maxRedeem(u);
        uint256 expected = vault.previewRedeem(m);
        uint256 bal = vault.balanceOf(u);
        vm.startPrank(u);
        if (m < bal) {
            try vault.redeem(m + 1, u, u) {
                maxNotTight++;
            } catch {}
        }
        try vault.redeem(m, u, u) returns (uint256 got) {
            if (got != expected) previewMismatch++;
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    function _maxRedeemToWsgem(address u) internal {
        uint256 m = vault.maxRedeemToWsgem(u);
        uint256 expected = vault.previewRedeemToWsgem(m);
        uint256 bal = vault.balanceOf(u);
        vm.startPrank(u);
        if (m < bal) {
            try vault.redeemToWsgem(m + 1, u, u) {
                maxNotTight++;
            } catch {}
        }
        try vault.redeemToWsgem(m, u, u) returns (uint256 got) {
            if (got != expected) previewMismatch++;
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    /// @dev `maxDepositWsgem` is 0 or unlimited: at 0 a zero deposit must still be a
    /// harmless no-op, at unlimited a bounded deposit must go through.
    function _maxDepositWsgem(address u, uint256 seed) internal {
        uint256 m = vault.maxDepositWsgem(u);
        uint256 amt;
        if (m == type(uint256).max) {
            amt = _mintWsgemTo(u, bound(seed, wsgem.mintcost(), 1e24));
            vm.prank(u);
            wsgem.approve(address(vault), amt);
        }
        uint256 expected = vault.previewDepositWsgem(amt);
        vm.prank(u);
        try vault.depositWsgem(amt, u) returns (uint256 got) {
            if (got != expected) previewMismatch++;
        } catch {
            maxReverted++;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}

contract WsgemVaultInvariantTest is InvariantBase {
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

    function _users() internal view returns (address[3] memory) {
        return [handler.user(0), handler.user(1), handler.user(2)];
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
        assertEq(
            gem.balanceOf(address(vault)),
            handler.ghostGemDust() + handler.ghostGemDonated(),
            "vault gem != withdraw dust + gem gifts"
        );
    }

    function invariant_NoDanglingClaims() public view {
        assertEq(wsgem.totalPending(), 0, "queued wsgem redemption claim");
    }

    function invariant_MaxExecutableAndPreviewsExact() public view {
        assertEq(handler.maxReverted(), 0, "x(max*()) reverted");
        assertEq(handler.maxNotTight(), 0, "x(max*() + 1) succeeded");
        assertEq(handler.previewMismatch(), 0, "execution != preview");
        assertEq(handler.surplusExceeded(), 0, "mint surplus above bound");
    }

    function invariant_NoDeficit() public view {
        assertEq(vault.deficit(), 0, "deficit in healthy regime");
    }

    function invariant_Spec() public view {
        _checkSpec(_users(), true);
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

        // A share transfer moves exactly the balance; a gem gift moves nothing.
        address u1 = handler.user(1);
        uint256 bal1 = vault.balanceOf(u1);
        handler.transferShares(0, 1, 1e18);
        assertEq(vault.balanceOf(u1), bal1 + 1e18, "transfer did not move the balance");
        uint256 price = vault.convertToAssets(1e18);
        uint256 assets = vault.totalAssets();
        handler.donateGem(2e18);
        assertEq(vault.convertToAssets(1e18), price, "gem gift moved the price");
        assertEq(vault.totalAssets(), assets, "gem gift moved totalAssets");
        assertEq(gem.balanceOf(address(vault)), 2e18, "gem gift not held");

        handler.redeemGem(0, 1e18);
        handler.withdrawGem(1, 1e18);
        handler.redeemWsgem(2, 1e18);
        for (uint256 i = 0; i < 6; i++) {
            handler.exerciseMax(i, i);
        }

        assertEq(handler.depositGemOk(), 1);
        assertEq(handler.mintSharesOk(), 1);
        assertEq(handler.depositWsgemOk(), 1);
        assertEq(handler.pokeOk(), 1);
        assertEq(handler.setBpsoutOk(), 1);
        assertEq(handler.setBpsinOk(), 1);
        assertEq(handler.donateWsgemOk(), 1);
        assertEq(handler.donateGemOk(), 1);
        assertEq(handler.transferOk(), 1);
        assertEq(handler.redeemGemOk(), 1);
        assertEq(handler.withdrawGemOk(), 1);
        assertEq(handler.redeemWsgemOk(), 1);
        assertEq(handler.exerciseMaxOk(), 6);
        assertEq(handler.maxReverted(), 0);
        assertEq(handler.maxNotTight(), 0);
        assertEq(handler.previewMismatch(), 0);
        assertEq(handler.surplusExceeded(), 0);
        assertEq(vault.convertToAssets(1e18), 1.2e18);
        assertEq(handler.ghostDonated(), 1e18);
        assertEq(handler.ghostGemDonated(), 2e18);

        invariant_VaultWsgemConservation();
        invariant_SharePriceTracksOracle();
        invariant_TotalAssetsIsGross();
        invariant_NoStrandedTokens();
        invariant_NoDanglingClaims();
        invariant_MaxExecutableAndPreviewsExact();
        invariant_NoDeficit();
        invariant_Spec();
    }
}

/*//////////////////////////////////////////////////////////////
                       ADVERSARIAL REGIME
//////////////////////////////////////////////////////////////*/

/// @notice Adds every governable and privileged lever (smelt, oracle pause, market pause,
/// one-sided windows, cooldown, capacity, liquidity drain, zero exit unit, reverting feed)
/// and scores every deposit/redeem op for QUOTE HONESTY, ERC-4626 style: a quote never
/// reverts, execution may revert on a gate while the quote stands, and whenever execution
/// succeeds its result equals the quote. Every gem-leg call is also scored for what it did
/// to the oracle-pause fallback. Violations are counted, never asserted inside the
/// handler, so a sequence keeps running after a breach and the invariant sees it.
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

    struct Triple {
        uint256 nav;
        uint256 mintUnit;
        uint256 burnUnit;
    }

    // Ghosts.
    uint256 public ghostNavprice; // last non-zero poke
    bool public ghostPaused;
    bool public ghostFeedBroken; // a wsgem feed currently reverts (bpsout filed above 10000)
    bool public ghostZeroExit; // burncost() reads as 0 (bpsout set to exactly 10000)
    uint256 public ghostSmelted; // wsgem burned out of the vault by the issuer
    uint256 public ghostHealed; // wsgem donated back into the vault
    uint256 public ghostWsgemIn; // wsgem that entered through the deposit legs (incl. mint excess)
    uint256 public ghostWsgemOut; // wsgem that left through the redemption legs
    uint256 public ghostGemDonated; // gem given to the vault outside any leg
    uint256 public lastRelease; // wsgem released by the last successful redemption

    // Violation counters (must all stay 0).
    uint256 public quoteReverted;
    uint256 public executionDiverged;
    uint256 public depositAcceptedInDeficit;
    uint256 public redeemOverdrawn;
    uint256 public gemOutServedAtZeroUnit;
    uint256 public maxReverted;
    uint256 public maxNotTight;
    uint256 public maxQuoteReverted;
    uint256 public claimDangling;
    uint256 public priceMovedOffPoke;
    uint256 public syncLagged;
    uint256 public syncOnBrokenFeed;
    uint256 public syncWhilePaused;
    uint256 public fallbackTouched;

    // Info counters (accepted behaviour, checked for reachability by the wiring test).
    uint256 public maxRevertedOnBrokenFeed;

    // Op liveness counters (op ran to its end, whatever the outcome).
    uint256 public depositGemOps;
    uint256 public mintSharesOps;
    uint256 public depositWsgemOps;
    uint256 public redeemGemOps;
    uint256 public withdrawGemOps;
    uint256 public redeemWsgemOps;
    uint256 public transferOps;
    uint256 public exerciseMaxOps;
    uint256 public smeltOps;
    uint256 public healOps;
    uint256 public donateGemOps;
    uint256 public settleOps;
    uint256 public refillLiquidityOps;
    uint256 public setCooldownOps;
    uint256 public clearCooldownOps;
    uint256 public pauseOracleOps;
    uint256 public unpauseOracleOps;
    uint256 public syncOracleOps;
    uint256 public pauseMarketOps;
    uint256 public reopenMarketOps;
    uint256 public setMintWindowOps;
    uint256 public setBurnWindowOps;
    uint256 public setCapacityOps;
    uint256 public clearCapacityOps;
    uint256 public pokeOps;
    uint256 public zeroExitOps;
    uint256 public breakFeedOps;
    uint256 public repairFeedOps;

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

    /// @dev `previewRedeem(shares)`, or 0 while its feed reverts.
    function _previewRedeemOrZero(uint256 shares) internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(vault).staticcall(abi.encodeCall(vault.previewRedeem, (shares)));
        return ok ? abi.decode(ret, (uint256)) : 0;
    }

    /// @dev A `max*` read that may revert (only a reverting feed is allowed to take it down).
    function _maxOf(bytes memory call) internal view returns (bool ok, uint256 value) {
        bytes memory ret;
        (ok, ret) = address(vault).staticcall(call);
        if (ok) value = abi.decode(ret, (uint256));
    }

    function _triple() internal view returns (Triple memory t) {
        t.nav = vault.lastNav();
        t.mintUnit = vault.lastMintUnit();
        t.burnUnit = vault.lastBurnUnit();
    }

    /// @dev The fallback triple after an op: equal to the live triple when a gem leg ran to
    /// completion on a live, non-reverting oracle (`refreshed`), untouched in every other
    /// case (wsgem leg, reverted execution, paused oracle, reverting feed).
    function _scoreSync(Triple memory before, bool refreshed) internal {
        Triple memory now_ = _triple();
        if (refreshed) {
            if (!_same(now_, wsgem.navprice(), wsgem.mintcost(), wsgem.burncost())) syncLagged++;
        } else if (!_same(now_, before.nav, before.mintUnit, before.burnUnit)) {
            fallbackTouched++;
        }
    }

    function _same(Triple memory t, uint256 nav, uint256 mintUnit, uint256 burnUnit) internal pure returns (bool) {
        return t.nav == nav && t.mintUnit == mintUnit && t.burnUnit == burnUnit;
    }

    /// @dev Quote first, execute second (as `caller`), and score the pair for honesty: a
    /// quote never reverts, and a standing quote must equal a successful execution's
    /// result. A `feedFree` quote must stand even while a feed reverts; the others may
    /// revert with the feed. The fallback triple is scored around the execution. Returns
    /// the amount on success.
    function _quoted(bytes memory previewCall, bytes memory execCall, address caller, bool feedFree)
        internal
        returns (bool ok, uint256 value)
    {
        Triple memory t0 = _triple();
        (bool pOk, bytes memory pRet) = address(vault).staticcall(previewCall);
        vm.prank(caller);
        (bool eOk, bytes memory eRet) = address(vault).call(execCall);
        _scoreSync(t0, eOk && !feedFree && wsgem.navprice() != 0 && !ghostFeedBroken);
        if (!pOk) {
            if (feedFree || !ghostFeedBroken) quoteReverted++;
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
    /// (1:1 is the ceiling; pro-rata is below it) nor more than the vault held, and a gem
    /// leg may never be served while the exit unit is 0 (paused oracle or bpsout 10000).
    function _scoreRedeem(bool ok, uint256 shares, uint256 heldBefore, bool gemLeg) internal {
        if (ok) {
            redeemsServed++;
            uint256 released = heldBefore - wsgem.balanceOf(address(vault));
            lastRelease = released;
            if (released > shares || released > heldBefore) redeemOverdrawn++;
            if (gemLeg && wsgem.totalPending() != 0) claimDangling++;
            if (gemLeg && (ghostZeroExit || ghostPaused)) gemOutServedAtZeroUnit++;
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
            abi.encodeCall(vault.previewDepositWsgem, (amt)), abi.encodeCall(vault.depositWsgem, (amt, u)), u, true
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
        uint256 cap = _previewRedeemOrZero(bal);
        assets = bound(assets, 1, cap == 0 ? 1 : cap);
        uint256 held = wsgem.balanceOf(address(vault));
        (bool ok, uint256 burned) = _quoted(
            abi.encodeCall(vault.previewWithdraw, (assets)), abi.encodeCall(vault.withdraw, (assets, u, u)), u, false
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
            true
        );
        _scoreRedeem(ok, shares, held, false);
        redeemWsgemOps++;
    }

    /// @dev Shares are a plain ERC20: a transfer moves a balance and neither backing nor
    /// price.
    function transferShares(uint256 seed, uint256 seed2, uint256 amt) external priceStable trackHeld {
        address a = _user(seed);
        address b = _user(seed2);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) {
            transferOps++;
            return;
        }
        amt = bound(amt, 1, bal);
        vm.prank(a);
        require(vault.transfer(b, amt), "share transfer");
        transferOps++;
    }

    /*//////////////////////// max* exercise /////////////////////*/

    /// @dev `x(max*())` must never revert in ANY state — including a closed leg, where the
    /// max is 0 and the mutator must be a harmless no-op — and must deliver its quote;
    /// `x(max*() + 1)` must revert wherever the max is finite and below what the actor
    /// could otherwise ask. A `max*` read may revert only while a feed reverts (README:
    /// a reverting getter takes the maxima reading it down with it), and the op still runs
    /// to its end then.
    function exerciseMax(uint256 seed, uint256 which) external priceStable trackHeld {
        address u = _user(seed);
        which = which % 6;
        Triple memory t0 = _triple();
        bool executed;
        if (which == 0) executed = _maxDeposit(u);
        else if (which == 1) executed = _maxMint(u);
        else if (which == 2) executed = _maxWithdraw(u);
        else if (which == 3) executed = _maxRedeem(u);
        else if (which == 4) _maxRedeemToWsgem(u);
        else _maxDepositWsgem(u, seed);
        _scoreSync(t0, executed && wsgem.navprice() != 0 && !ghostFeedBroken);
        if (wsgem.totalPending() != 0) claimDangling++;
        exerciseMaxOps++;
    }

    /// @dev A gem-out max that reverted: accepted under a reverting feed, a violation otherwise.
    function _scoreMaxRevert() internal {
        if (ghostFeedBroken) maxRevertedOnBrokenFeed++;
        else maxQuoteReverted++;
    }

    function _maxDeposit(address u) internal returns (bool executed) {
        (bool ok, uint256 m) = _maxOf(abi.encodeCall(vault.maxDeposit, (u)));
        if (!ok) {
            maxQuoteReverted++; // never reads the exit feed
            return false;
        }
        uint256 a = _min(m, 1e24);
        uint256 expected = vault.previewDeposit(a);
        gem.mint(u, a + 1);
        vm.startPrank(u);
        gem.approve(address(vault), type(uint256).max);
        if (m < 1e24) {
            try vault.deposit(m + 1, u) {
                maxNotTight++;
            } catch {}
        }
        try vault.deposit(a, u) returns (uint256 got) {
            executed = true;
            if (got != expected) executionDiverged++;
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    function _maxMint(address u) internal returns (bool executed) {
        (bool ok, uint256 m) = _maxOf(abi.encodeCall(vault.maxMint, (u)));
        if (!ok) {
            maxQuoteReverted++; // never reads the exit feed
            return false;
        }
        uint256 s = _min(m, 1e24);
        uint256 expected = vault.previewMint(s);
        gem.mint(u, 2 * vault.previewMint(s + 1));
        vm.startPrank(u);
        gem.approve(address(vault), type(uint256).max);
        if (m < 1e24) {
            try vault.mint(m + 1, u) {
                maxNotTight++;
            } catch {}
        }
        try vault.mint(s, u) returns (uint256 got) {
            executed = true;
            if (got != expected) executionDiverged++;
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    function _maxWithdraw(address u) internal returns (bool executed) {
        (bool ok, uint256 m) = _maxOf(abi.encodeCall(vault.maxWithdraw, (u)));
        if (!ok) {
            _scoreMaxRevert();
            return false;
        }
        uint256 expected = m == 0 ? 0 : vault.previewWithdraw(m);
        vm.startPrank(u);
        try vault.withdraw(m + 1, u, u) {
            maxNotTight++;
        } catch {}
        try vault.withdraw(m, u, u) returns (uint256 got) {
            executed = true;
            if (got != expected) executionDiverged++;
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    function _maxRedeem(address u) internal returns (bool executed) {
        (bool ok, uint256 m) = _maxOf(abi.encodeCall(vault.maxRedeem, (u)));
        if (!ok) {
            _scoreMaxRevert();
            return false;
        }
        uint256 expected = m == 0 ? 0 : vault.previewRedeem(m);
        uint256 bal = vault.balanceOf(u);
        vm.startPrank(u);
        if (m < bal) {
            try vault.redeem(m + 1, u, u) {
                maxNotTight++;
            } catch {}
        }
        try vault.redeem(m, u, u) returns (uint256 got) {
            executed = true;
            if (got != expected) executionDiverged++;
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    function _maxRedeemToWsgem(address u) internal {
        uint256 m = vault.maxRedeemToWsgem(u);
        uint256 expected = vault.previewRedeemToWsgem(m);
        uint256 bal = vault.balanceOf(u);
        vm.startPrank(u);
        if (m < bal) {
            try vault.redeemToWsgem(m + 1, u, u) {
                maxNotTight++;
            } catch {}
        }
        try vault.redeemToWsgem(m, u, u) returns (uint256 got) {
            if (got != expected) executionDiverged++;
        } catch {
            maxReverted++;
        }
        vm.stopPrank();
    }

    /// @dev `maxDepositWsgem` is 0 or unlimited: at 0 a zero deposit must still be a
    /// harmless no-op, at unlimited a bounded deposit must go through (when the wsgem's
    /// own mint can fund it; otherwise the zero path is taken).
    function _maxDepositWsgem(address u, uint256 seed) internal {
        uint256 m = vault.maxDepositWsgem(u);
        uint256 amt;
        if (m == type(uint256).max) {
            uint256 unit = wsgem.mintcost();
            if (unit != 0) amt = _tryMintWsgemTo(u, bound(seed, unit, 1e24));
            if (amt != 0) {
                vm.prank(u);
                wsgem.approve(address(vault), amt);
            }
        }
        uint256 expected = vault.previewDepositWsgem(amt);
        vm.prank(u);
        try vault.depositWsgem(amt, u) returns (uint256 got) {
            if (got != expected) executionDiverged++;
        } catch {
            maxReverted++;
        }
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

    /// @dev Gem given to the vault is stranded: it never enters a quote or a payout.
    function donateGem(uint256 amt) external priceStable {
        amt = bound(amt, 1, 1e24);
        gem.mint(address(vault), amt);
        ghostGemDonated += amt;
        donateGemOps++;
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
    /// must equal the live triple. `sync()` must revert while paused and while a feed
    /// reverts, leaving the cache alone; a zero exit unit is a valid read and is cached.
    function syncOracle() external priceStable {
        if (wsgem.navprice() == 0) {
            try vault.sync() {
                syncWhilePaused++;
            } catch {}
            syncOracleOps++;
            return;
        }
        if (ghostFeedBroken) {
            // sync() must fail closed rather than refresh from a reverting feed.
            try vault.sync() {
                syncOnBrokenFeed++;
            } catch {}
            syncOracleOps++;
            return;
        }
        vault.sync();
        if (
            vault.lastNav() != wsgem.navprice() || vault.lastMintUnit() != wsgem.mintcost()
                || vault.lastBurnUnit() != wsgem.burncost()
        ) syncLagged++;
        syncOracleOps++;
    }

    function poke(uint256 nav) external {
        nav = bound(nav, 0.5e18, 5e18);
        pip.poke(nav);
        ghostNavprice = nav;
        ghostPaused = false;
        pokeOps++;
    }

    /// @dev The bounded setter's ceiling: `burncost()` reads as 0, an honest quote of
    /// nothing. Gem-out must fail closed on it, gem-in and the wsgem legs stay live.
    function zeroExitUnit() external priceStable {
        act.setBpsout(10_000);
        ghostZeroExit = true;
        ghostFeedBroken = false;
        zeroExitOps++;
    }

    /// @dev `MaseerGate.file` is unbounded, so governance can file a bpsout above 10000 and
    /// `burncost()` then underflows: every read of it reverts until repaired.
    function breakFeed() external priceStable {
        act.file("bpsout", 10_001);
        ghostFeedBroken = true;
        ghostZeroExit = false;
        breakFeedOps++;
    }

    function repairFeed(uint256 bps) external priceStable {
        act.setBpsout(bound(bps, 0, 500));
        ghostFeedBroken = false;
        ghostZeroExit = false;
        repairFeedOps++;
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

    /// @dev The mint and burn windows are independent gates (the open timestamps are
    /// never in the future, so the halt alone decides).
    function setMintWindow(bool open) external priceStable {
        act.file("haltmint", open ? type(uint256).max : 0);
        setMintWindowOps++;
    }

    function setBurnWindow(bool open) external priceStable {
        act.file("haltburn", open ? type(uint256).max : 0);
        setBurnWindowOps++;
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

contract WsgemVaultAdversarialInvariantTest is InvariantBase {
    VaultAdversarialHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultAdversarialHandler(vault, wsgem, gem, pip, act, issuer);
        pip.kiss(address(handler)); // poke
        pip.rely(address(handler)); // pause
        act.rely(address(handler)); // gate setters
        targetContract(address(handler));
    }

    function _users() internal view returns (address[3] memory) {
        return [handler.user(0), handler.user(1), handler.user(2)];
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
        assertEq(handler.gemOutServedAtZeroUnit(), 0, "gem-out served at a zero exit unit");
        assertEq(handler.maxReverted(), 0, "x(max*()) reverted");
        assertEq(handler.maxNotTight(), 0, "x(max*() + 1) succeeded");
        assertEq(handler.maxQuoteReverted(), 0, "max* reverted without a reverting feed");
        assertEq(handler.claimDangling(), 0, "queued claim owned by vault");
        assertEq(handler.priceMovedOffPoke(), 0, "share price moved without a poke");
        assertEq(handler.syncLagged(), 0, "a refresh left the fallback lagging");
        assertEq(handler.syncOnBrokenFeed(), 0, "sync() refreshed from a reverting feed");
        assertEq(handler.syncWhilePaused(), 0, "sync() succeeded while paused");
        assertEq(handler.fallbackTouched(), 0, "fallback moved without a live refresh");
    }

    function invariant_NoDanglingClaims() public view {
        assertEq(wsgem.totalPending(), 0, "queued wsgem redemption claim");
    }

    /// @dev Gem given to the vault is never paid out: a payout is at most the claim the
    /// vault just received.
    function invariant_DonatedGemStranded() public view {
        assertGe(gem.balanceOf(address(vault)), handler.ghostGemDonated(), "gem gift paid out");
    }

    function invariant_OracleLiveMatchesGhost() public view {
        assertEq(vault.oracleLive(), !handler.ghostPaused(), "oracleLive != !paused");
    }

    /// @dev Accounting marks shares down to their effective backing: the share price is
    /// nav * min(held, supply) / supply (two floors, so within nav/1e18 + 1 of the exact
    /// value), and totalAssets never exceeds the fully-backed value. While the oracle is
    /// paused the same holds on the cached NAV.
    function invariant_ProRataMarkdown() public view {
        uint256 nav = wsgem.navprice();
        if (nav == 0) nav = vault.lastNav();
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

    /// @dev Quotes and limits never revert in any reachable state, except that a reverting
    /// exit feed takes exactly the reads of it down with it; everything else stands.
    function invariant_QuotesNeverRevert() public view {
        address[3] memory u = _users();
        vault.previewRedeemToWsgem(1e18);
        vault.previewDepositWsgem(1e18);
        vault.totalAssets();
        vault.convertToShares(1e18);
        vault.convertToAssets(1e18);
        vault.previewDeposit(1e18);
        vault.previewMint(1e18);
        for (uint256 i = 0; i < 3; i++) {
            vault.maxDeposit(u[i]);
            vault.maxMint(u[i]);
            vault.maxDepositWsgem(u[i]);
            vault.maxRedeemToWsgem(u[i]);
        }
        if (handler.ghostFeedBroken()) return;
        vault.previewRedeem(1e18);
        vault.previewWithdraw(1e18);
        for (uint256 i = 0; i < 3; i++) {
            vault.maxRedeem(u[i]);
            vault.maxWithdraw(u[i]);
        }
    }

    /// @dev A zero exit unit (bpsout 10000 live, or cached into a pause) is quoted honestly:
    /// `previewRedeem` is 0, `previewWithdraw` is the sentinel, the gem-out maxima are 0,
    /// and the wsgem exit is gated by compliance alone.
    function invariant_ZeroExitUnitFailsClosed() public view {
        if (handler.ghostFeedBroken()) return;
        bool live = wsgem.navprice() != 0;
        if (handler.ghostZeroExit() && live) assertEq(wsgem.burncost(), 0, "zero exit lever did not bite");
        uint256 unitRef = live ? wsgem.burncost() : vault.lastBurnUnit();
        if (unitRef != 0) return;
        assertEq(vault.previewRedeem(1e18), 0, "previewRedeem at a zero unit");
        assertEq(vault.previewWithdraw(1), type(uint256).max, "previewWithdraw(1) at a zero unit");
        assertEq(vault.previewWithdraw(0), 0, "previewWithdraw(0) at a zero unit");
        address[3] memory u = _users();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(vault.maxRedeem(u[i]), 0, "maxRedeem at a zero unit");
            assertEq(vault.maxWithdraw(u[i]), 0, "maxWithdraw at a zero unit");
            uint256 bal = vault.balanceOf(u[i]);
            assertEq(
                vault.maxRedeemToWsgem(u[i]),
                wsgem.canPass(address(vault)) && vault.previewRedeemToWsgem(bal) != 0 ? bal : 0,
                "wsgem exit gated by the exit unit"
            );
        }
    }

    function invariant_Spec() public view {
        _checkSpec(_users(), !handler.ghostFeedBroken());
    }

    /// @dev Anti-vacuity: a deterministic walk through every adversarial state, checking
    /// that each lever actually bit (blocked/served counters move), that the pro-rata
    /// markdown and payout show up in a deficit, and that no violation counter ever moves.
    function test_HandlerWiring_FullLifecycle() public {
        address u0 = handler.user(0);
        address u1 = handler.user(1);

        // Seed positions through every deposit leg.
        handler.depositGem(0, 10e18);
        handler.mintShares(1, 5e18);
        handler.depositWsgem(2, 8e18);
        assertEq(handler.depositsServed(), 3, "seed deposits");
        assertEq(handler.depositsBlocked(), 0);
        uint256 nav = wsgem.navprice();
        assertEq(vault.convertToAssets(1e18), nav, "fully backed prices at nav");

        // A share transfer moves exactly the balance; a gem gift moves nothing.
        uint256 bal1 = vault.balanceOf(u1);
        handler.transferShares(0, 1, 1e18);
        assertEq(vault.balanceOf(u1), bal1 + 1e18, "transfer did not move the balance");
        uint256 assets = vault.totalAssets();
        handler.donateGem(3e18);
        assertEq(vault.convertToAssets(1e18), nav, "gem gift moved the price");
        assertEq(vault.totalAssets(), assets, "gem gift moved totalAssets");
        assertEq(gem.balanceOf(address(vault)), 3e18, "gem gift not held");

        // Smelt -> deficit -> price marked down, every deposit leg fails closed, the wsgem
        // leg pays pro-rata, maxDepositWsgem is 0 and its zero deposit a no-op -> heal ->
        // reopened at par with maxDepositWsgem unlimited and a real deposit served.
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
        assertEq(vault.maxDepositWsgem(u0), 0, "maxDepositWsgem in deficit");
        uint256 supply = vault.totalSupply();
        handler.exerciseMax(0, 5);
        assertEq(vault.totalSupply(), supply, "zero wsgem deposit minted shares");
        handler.heal(type(uint256).max);
        assertEq(vault.deficit(), 0, "deficit not healed");
        assertEq(vault.convertToAssets(1e18), nav, "price not restored");
        served = handler.depositsServed();
        handler.depositGem(0, 2e18);
        assertEq(handler.depositsServed(), served + 1, "deposit after heal");
        assertEq(vault.maxDepositWsgem(u1), type(uint256).max, "maxDepositWsgem after heal");
        bal1 = vault.balanceOf(u1);
        handler.exerciseMax(1, 5);
        assertGt(vault.balanceOf(u1), bal1, "unlimited wsgem deposit not served");

        // Oracle pause: quotes stand on the cache, gem legs blocked, wsgem legs live, sync()
        // fails closed.
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
        handler.syncOracle(); // reverts inside; scored by syncWhilePaused
        handler.unpauseOracle();
        assertGt(wsgem.navprice(), 0);

        // Cooldown: gem-out blocked and max* zero; cleared afterwards.
        handler.setCooldown(1 days);
        assertEq(vault.maxRedeem(u0), 0, "maxRedeem during cooldown");
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

        // Zero exit unit (bpsout 10000): an honest zero, the sentinel, zero gem-out maxima;
        // gem-out fails closed, the wsgem legs and gem-in are served, the zero is a valid
        // read that the refresh caches and a pause keeps.
        handler.zeroExitUnit();
        assertEq(wsgem.burncost(), 0, "zero exit unit not set");
        assertEq(vault.previewRedeem(1e18), 0, "previewRedeem at zero unit");
        assertEq(vault.previewWithdraw(1), type(uint256).max, "previewWithdraw at zero unit");
        assertEq(vault.maxRedeem(u0), 0, "maxRedeem at zero unit");
        assertEq(vault.maxWithdraw(u0), 0, "maxWithdraw at zero unit");
        blocked = handler.redeemsBlocked();
        handler.redeemGem(0, 1e18);
        handler.withdrawGem(1, 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 2, "gem-out not blocked at zero unit");
        assertEq(handler.gemOutServedAtZeroUnit(), 0);
        served = handler.redeemsServed();
        handler.redeemWsgem(2, 1e18);
        assertEq(handler.redeemsServed(), served + 1, "wsgem leg not live at zero unit");
        served = handler.depositsServed();
        handler.depositGem(0, 2e18);
        assertEq(handler.depositsServed(), served + 1, "gem-in not live at zero unit");
        assertEq(vault.lastBurnUnit(), 0, "gem-in did not cache the zero exit unit");
        handler.syncOracle();
        assertEq(vault.lastBurnUnit(), 0, "sync did not keep the zero exit unit");
        handler.exerciseMax(0, 2);
        handler.exerciseMax(0, 3);
        handler.pauseOracle();
        assertEq(vault.previewWithdraw(1), type(uint256).max, "cache lost the zero exit unit");
        assertEq(vault.previewRedeem(1e18), 0, "cache lost the zero exit quote");
        invariant_ZeroExitUnitFailsClosed();
        handler.unpauseOracle();
        handler.repairFeed(25);
        handler.syncOracle();
        assertGt(vault.lastBurnUnit(), 0, "repair not cached");

        // Reverting feed (bpsout filed above 10000): gem-out, its maxima and sync() fail
        // closed, the wsgem legs and gem-in are served, the fallback is untouched; then
        // repaired.
        uint256 navCache = vault.lastNav();
        handler.breakFeed();
        blocked = handler.redeemsBlocked();
        handler.redeemGem(0, 1e18);
        handler.withdrawGem(0, 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 2, "gem-out not blocked by a reverting feed");
        handler.syncOracle(); // reverts inside; scored by syncOnBrokenFeed
        served = handler.redeemsServed();
        handler.redeemWsgem(0, 1e18);
        assertEq(handler.redeemsServed(), served + 1, "wsgem leg not live under a reverting feed");
        served = handler.depositsServed();
        handler.depositWsgem(0, 2e18);
        handler.depositGem(0, 2e18);
        assertEq(handler.depositsServed(), served + 2, "deposit legs not live under a reverting feed");
        uint256 onBroken = handler.maxRevertedOnBrokenFeed();
        handler.exerciseMax(0, 2);
        handler.exerciseMax(0, 3);
        assertEq(handler.maxRevertedOnBrokenFeed(), onBroken + 2, "gem-out maxima did not follow the feed");
        handler.exerciseMax(0, 0); // gem-in maximum stands and executes
        assertEq(vault.lastNav(), navCache, "fallback touched by a reverting feed");
        handler.repairFeed(25);

        // One-sided windows: each closes only its own leg and maxima.
        handler.setMintWindow(false);
        assertFalse(wsgem.mintable());
        assertTrue(wsgem.burnable());
        assertEq(vault.maxDeposit(u0), 0, "maxDeposit with mint closed");
        assertGt(vault.maxRedeem(u0), 0, "maxRedeem with only mint closed");
        blocked = handler.depositsBlocked();
        handler.depositGem(0, 2e18);
        assertEq(handler.depositsBlocked(), blocked + 1, "deposit not blocked with mint closed");
        served = handler.redeemsServed();
        handler.redeemGem(0, 1e18);
        assertEq(handler.redeemsServed(), served + 1, "redeem not served with only mint closed");
        handler.setMintWindow(true);
        handler.setBurnWindow(false);
        assertTrue(wsgem.mintable());
        assertFalse(wsgem.burnable());
        assertEq(vault.maxRedeem(u0), 0, "maxRedeem with burn closed");
        blocked = handler.redeemsBlocked();
        handler.redeemGem(0, 1e18);
        assertEq(handler.redeemsBlocked(), blocked + 1, "redeem not blocked with burn closed");
        served = handler.depositsServed();
        handler.depositGem(0, 2e18);
        assertEq(handler.depositsServed(), served + 1, "deposit not served with only burn closed");
        handler.setBurnWindow(true);

        // Market pause / reopen, capacity set / clear, poke + sync, and max* in every state.
        handler.pauseMarket();
        blocked = handler.depositsBlocked();
        handler.depositGem(0, 2e18);
        assertEq(handler.depositsBlocked(), blocked + 1, "deposit not blocked while market paused");
        for (uint256 i = 0; i < 6; i++) {
            handler.exerciseMax(i, i);
        }
        handler.reopenMarket();
        handler.setCapacity(1e30);
        handler.clearCapacity();
        handler.poke(1.1e18);
        assertTrue(vault.lastNav() != 1.1e18, "poke alone must not touch the cache");
        handler.syncOracle();
        assertEq(vault.lastNav(), 1.1e18, "sync did not refresh the cache");
        for (uint256 i = 0; i < 6; i++) {
            handler.exerciseMax(i, i);
        }

        // Every op ran.
        assertEq(handler.depositGemOps(), 8);
        assertEq(handler.mintSharesOps(), 2);
        assertEq(handler.depositWsgemOps(), 3);
        assertEq(handler.redeemGemOps(), 8);
        assertEq(handler.withdrawGemOps(), 3);
        assertEq(handler.redeemWsgemOps(), 4);
        assertEq(handler.transferOps(), 1);
        assertEq(handler.exerciseMaxOps(), 19);
        assertEq(handler.smeltOps(), 1);
        assertEq(handler.healOps(), 1);
        assertEq(handler.donateGemOps(), 1);
        assertEq(handler.settleOps(), 1);
        assertEq(handler.refillLiquidityOps(), 1);
        assertEq(handler.setCooldownOps(), 1);
        assertEq(handler.clearCooldownOps(), 1);
        assertEq(handler.pauseOracleOps(), 2);
        assertEq(handler.unpauseOracleOps(), 2);
        assertEq(handler.syncOracleOps(), 6);
        assertEq(handler.pauseMarketOps(), 1);
        assertEq(handler.reopenMarketOps(), 1);
        assertEq(handler.setMintWindowOps(), 2);
        assertEq(handler.setBurnWindowOps(), 2);
        assertEq(handler.setCapacityOps(), 1);
        assertEq(handler.clearCapacityOps(), 1);
        assertEq(handler.pokeOps(), 1);
        assertEq(handler.zeroExitOps(), 1);
        assertEq(handler.breakFeedOps(), 1);
        assertEq(handler.repairFeedOps(), 2);
        assertEq(handler.maxRevertedOnBrokenFeed(), 2);

        // And nothing was ever violated.
        invariant_FailClosedEnforced();
        invariant_BackingConservation();
        invariant_NoDanglingClaims();
        invariant_DonatedGemStranded();
        invariant_OracleLiveMatchesGhost();
        invariant_ProRataMarkdown();
        invariant_QuotesNeverRevert();
        invariant_ZeroExitUnitFailsClosed();
        invariant_Spec();
    }
}
