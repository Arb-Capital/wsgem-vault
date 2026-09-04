// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MaseerOne as Wsgem} from "maseer-one/MaseerOne.sol";
import {MaseerPrice} from "maseer-one/MaseerPrice.sol";
import {MaseerGate} from "maseer-one/MaseerGate.sol";
import {MaseerGuardOZ} from "maseer-one/MaseerGuardOZ.sol";
import {MaseerTreasury} from "maseer-one/MaseerTreasury.sol";

/// @dev MaseerTreasury is proxy-only upstream (no self-rely constructor, unlike
/// MaseerPrice/MaseerGate); this harness adds the same deployer-rely the siblings have
/// so it can be used directly in tests.
contract TreasuryHarness is MaseerTreasury {
    constructor() {
        _rely(msg.sender);
    }
}

import {WsgemVault} from "../src/WsgemVault.sol";
import {MockGem} from "./mocks/MockGem.sol";

/// @notice Deploys the real wsgem stack (token, oracle, gate, guard) around a mock gem,
/// configured to mirror the first live instance: bpsin 0, bpsout 25, cooldown 0, capacity
/// max, windows open indefinitely, navprice ~1.006 WAD — then the ERC-4626 vault over it.
abstract contract VaultTestBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant INIT_NAVPRICE = 1.006e18;

    // Overridable before super.setUp() — the decimals suite deploys the same stack
    // around a low-decimal gem (navprice is quoted in gem native units per whole
    // wsgem, so it must be rescaled alongside).
    uint8 internal gemDecimals = 18;
    uint256 internal initNavprice = INIT_NAVPRICE;

    MockGem internal gem;
    MaseerPrice internal pip;
    MaseerGate internal act;
    MaseerGuardOZ internal cop;
    TreasuryHarness internal adm;
    Wsgem internal wsgem;
    WsgemVault internal vault;

    address internal issuer = makeAddr("issuer");
    address internal flo = makeAddr("flo");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev A fuzzable snapshot of every governable wsgem lever plus the vault's two
    /// adversarial states (thin gem liquidity, a privileged burn). Applied by _applyState.
    struct MarketState {
        uint256 nav;
        uint256 bpsin;
        uint256 bpsout;
        bool mintOpen;
        bool burnOpen;
        uint256 cooldown;
        uint256 capacity;
        uint256 liquidity;
        uint256 smelt;
    }

    function setUp() public virtual {
        gem = new MockGem(gemDecimals);

        pip = new MaseerPrice();
        pip.kiss(address(this));
        pip.poke(initNavprice);

        act = new MaseerGate();
        act.setOpenMint(block.timestamp);
        act.setOpenBurn(block.timestamp);
        // setHaltMint/setHaltBurn cap at now+365d; file() is how the live deployment
        // set the windows to be open indefinitely.
        act.file("haltmint", type(uint256).max);
        act.file("haltburn", type(uint256).max);
        act.setBpsin(0);
        act.setBpsout(25);
        act.setCooldown(0);
        act.setCapacity(type(uint256).max);

        cop = new MaseerGuardOZ(address(gem));

        adm = new TreasuryHarness();
        adm.bestow(issuer);

        wsgem = new Wsgem(
            address(gem), address(pip), address(act), address(adm), address(cop), flo, "Wrapped Staked Gem", "wsGEM"
        );

        vault = new WsgemVault("Wrapped Staked Gem Vault", "vwsGEM", address(wsgem));
    }

    /*//////////////////////////////////////////////////////////////
                              FUNDING
    //////////////////////////////////////////////////////////////*/

    function _mintGem(address usr, uint256 amt) internal {
        gem.mint(usr, amt);
    }

    /// @dev Mints wsgem to `usr` directly against the wsgem (the "direct" path the vault
    /// must never beat). Returns the wsgem minted.
    function _mintWsgem(address usr, uint256 gemIn) internal returns (uint256 out) {
        gem.mint(usr, gemIn);
        vm.startPrank(usr);
        gem.approve(address(wsgem), gemIn);
        out = wsgem.mint(gemIn);
        vm.stopPrank();
    }

    /// @dev Funds `usr` with `assets` gem and deposits them into the vault for shares.
    function _depositGem(address usr, uint256 assets) internal returns (uint256 shares) {
        gem.mint(usr, assets);
        vm.startPrank(usr);
        gem.approve(address(vault), assets);
        shares = vault.deposit(assets, usr);
        vm.stopPrank();
    }

    /// @dev Funds `usr` with exactly the gem `vault.mint(shares)` needs and mints.
    function _mintShares(address usr, uint256 shares) internal returns (uint256 assets) {
        assets = vault.previewMint(shares);
        gem.mint(usr, assets);
        vm.startPrank(usr);
        gem.approve(address(vault), assets);
        vault.mint(shares, usr);
        vm.stopPrank();
    }

    /// @dev Mints wsgem to `usr` against `gemIn` gem and deposits all of it via the 1:1 leg.
    function _depositWsgem(address usr, uint256 gemIn) internal returns (uint256 shares) {
        uint256 out = _mintWsgem(usr, gemIn);
        vm.startPrank(usr);
        wsgem.approve(address(vault), out);
        shares = vault.depositWsgem(out, usr);
        vm.stopPrank();
    }

    /// @dev Transfers `amt` freshly minted wsgem into the vault without minting shares.
    function _donateWsgem(uint256 amt) internal {
        // Fund exactly what `amt` wsgem costs at mintcost, plus one whole unit of slack.
        uint256 unit = wsgem.mintcost();
        uint256 out = _mintWsgem(carol, (amt * unit + WAD - 1) / WAD + unit);
        assertGe(out, amt, "donation underfunded");
        vm.prank(carol);
        assertTrue(wsgem.transfer(address(vault), amt), "donation transfer");
    }

    /*//////////////////////////////////////////////////////////////
                            MARKET LEVERS
    //////////////////////////////////////////////////////////////*/

    // mintable()/burnable() are `now <= halt`; halt 0 closes, halt max opens.
    function _closeMint() internal {
        act.file("haltmint", 0);
    }

    function _openMint() internal {
        act.file("haltmint", type(uint256).max);
    }

    function _closeBurn() internal {
        act.file("haltburn", 0);
    }

    function _openBurn() internal {
        act.file("haltburn", type(uint256).max);
    }

    /// @dev Sets the wsgem's raw gem balance — the pool wsgem.exit() pays redemptions from —
    /// to exactly `amount`. settle() forwards everything not reserved for pending claims to
    /// `flo` (an EOA here; at cooldown 0 nothing is ever pending), then the balance is
    /// refilled.
    function _setLiquidity(uint256 amount) internal {
        wsgem.settle();
        assertEq(gem.balanceOf(address(wsgem)), 0, "liquidity not drained");
        if (amount > 0) gem.mint(address(wsgem), amount);
    }

    /// @dev Privileged burn of `amt` wsgem from the vault: the only way to create a deficit.
    function _smeltVault(uint256 amt) internal {
        vm.prank(issuer);
        wsgem.smelt(address(vault), amt);
    }

    /// @dev Bounds every field into its legal range and applies it. Zero-ish seeds land on
    /// the interesting edge (paused oracle, cooldown 0, unlimited capacity) often enough for
    /// fuzzing to exercise every branch. Smelt is capped at what the vault holds.
    function _applyState(MarketState memory s) internal {
        s.nav = (s.nav % 16 == 0) ? 0 : bound(s.nav, 1, 1e27);
        if (s.nav == 0) pip.pause();
        else pip.poke(s.nav);

        s.bpsin = bound(s.bpsin, 0, 10_000);
        act.setBpsin(s.bpsin);
        s.bpsout = bound(s.bpsout, 0, 10_000);
        act.setBpsout(s.bpsout);

        if (s.mintOpen) _openMint();
        else _closeMint();
        if (s.burnOpen) _openBurn();
        else _closeBurn();

        s.cooldown = (s.cooldown % 4 == 0) ? 0 : bound(s.cooldown, 1, 365 days);
        act.setCooldown(s.cooldown);

        s.capacity = (s.capacity % 4 == 0) ? type(uint256).max : bound(s.capacity, 0, 1e30);
        act.setCapacity(s.capacity);

        s.liquidity = bound(s.liquidity, 0, 1e30);
        _setLiquidity(s.liquidity);

        uint256 held = wsgem.balanceOf(address(vault));
        s.smelt = bound(s.smelt, 0, held);
        if (s.smelt > 0) _smeltVault(s.smelt);
    }

    /*//////////////////////////////////////////////////////////////
                              PRICING
    //////////////////////////////////////////////////////////////*/

    function _nav() internal view returns (uint256) {
        return wsgem.navprice();
    }

    function _mc() internal view returns (uint256) {
        return wsgem.mintcost();
    }

    function _bc() internal view returns (uint256) {
        return wsgem.burncost();
    }

    /// @dev The wsgem's own mint math: shares for `assets` gem.
    function _sharesFor(uint256 assets) internal view returns (uint256) {
        return assets * WAD / _mc();
    }

    /// @dev The wsgem's own redeem math: gem for `shares`.
    function _claimFor(uint256 shares) internal view returns (uint256) {
        return shares * _bc() / WAD;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /*//////////////////////////////////////////////////////////////
                             QUOTE HONESTY
    //////////////////////////////////////////////////////////////*/

    /// @dev Quotes never lie, ERC-4626 style: a preview is a pure quote that never reverts,
    /// and whenever its execution (as `caller`) succeeds the result equals the quote.
    /// Execution may revert while the quote stands — that is what `max*` and the execution
    /// gates are for.
    function _assertQuoteHonest(address target, bytes memory previewCall, bytes memory execCall, address caller)
        internal
    {
        (bool pOk, bytes memory pRet) = target.staticcall(previewCall);
        assertTrue(pOk, "quote reverted");
        vm.prank(caller);
        (bool eOk, bytes memory eRet) = target.call(execCall);
        if (eOk) {
            assertEq(abi.decode(eRet, (uint256)), abi.decode(pRet, (uint256)), "execution differs from quote");
        }
    }
}
