// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {VaultTestBase} from "./VaultTestBase.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";

/// @notice The vault is agnostic to the gem's decimals: navprice/mintcost/burncost are
/// quoted in gem native units per whole (1e18) wsgem, shares are always 18-decimal, and
/// low-decimal gems only quantise values to their coarser smallest unit. The same
/// assertions run around a 2-, 6-, and 8-decimal gem.
abstract contract WsgemDecimalsTest is VaultTestBase {
    function _decimals() internal pure virtual returns (uint8);

    function _one() internal pure returns (uint256) {
        return 10 ** _decimals();
    }

    function setUp() public virtual override {
        gemDecimals = _decimals();
        // ~1.006 gem per wsgem, quantised to the gem's smallest unit (100 at 2 decimals).
        initNavprice = 1006 * _one() / 1000;
        super.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                              METADATA
    //////////////////////////////////////////////////////////////*/

    function test_VaultDecimalsAlways18() public view {
        assertEq(gem.decimals(), _decimals(), "gem decimals");
        assertEq(vault.decimals(), 18, "vault decimals");
        assertEq(vault.asset(), address(gem));
    }

    function test_SharePrice_IsGemNativeUnits() public view {
        assertEq(vault.convertToAssets(1e18), initNavprice, "vault rate");
        assertEq(vault.totalAssets(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            QUANTISATION
    //////////////////////////////////////////////////////////////*/

    function test_ConvertQuantises() public view {
        uint256 nav = _nav();
        assertEq(vault.convertToAssets(1e18), nav);
        assertEq(vault.convertToAssets(1e18 - 1), nav - 1, "floor below one share");
        assertEq(vault.convertToShares(nav), 1e18);
        assertEq(vault.convertToShares(1), 1e18 / nav, "shares per smallest gem unit");
        assertLe(vault.convertToAssets(vault.convertToShares(1)), 1, "round trip never gains");
        assertEq(vault.convertToAssets(vault.convertToShares(nav)), nav, "whole-share round trip exact");
    }

    function test_DepositGem_MintcostMintsOneWholeShare() public {
        uint256 unit = _mc();
        assertEq(vault.previewDeposit(unit), 1e18, "vault preview");
        assertEq(_depositGem(alice, unit), 1e18, "vault deposit");
        assertEq(vault.balanceOf(alice), 1e18);
        assertEq(wsgem.balanceOf(address(vault)), 1e18, "vault holds one wsgem");
        assertEq(vault.totalAssets(), _nav(), "one share is worth one navprice");
    }

    function test_PreviewRedeem_OneShare_IsBurncost() public {
        // One share's redemption; the deposit self-funds the wsgem's gem liquidity.
        _depositGem(alice, _mc());
        uint256 cost = _bc();
        // The fee is inside burncost() and may round away entirely at low decimals
        // (2 decimals: ceil(100 * 0.9975) == 100 == navprice); assert via burncost only.
        assertLe(cost, _nav(), "burncost never above nav");
        assertGt(cost, 0);
        assertEq(vault.previewRedeem(1e18), cost, "vault preview");

        uint256 before = gem.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(1e18, alice, alice);
        assertEq(out, cost, "vault redeem");
        assertEq(gem.balanceOf(alice) - before, cost, "gem delivered");
    }

    /// @dev withdraw(1): the smallest gem unit needs ceil(1e18 / burncost) shares, which is
    /// below the wsgem's one-whole-wsgem redemption floor for every gem whose burncost is
    /// above one native unit — i.e. every realistic gem. The quote still stands (quotes
    /// never account for the floor); execution reverts DustThreshold(1e18).
    function test_Withdraw_OneUnit() public {
        _depositGem(alice, _mc() * 4);
        uint256 cost = _bc();
        uint256 sharesNeeded = _ceilDiv(1e18, cost);
        // At every decimals tested here burncost > 1 native unit, so the floor applies.
        assertLt(sharesNeeded, 1e18, "one gem unit is below one whole wsgem");
        assertEq(vault.previewWithdraw(1), sharesNeeded, "quote ignores the floor");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWsgem.DustThreshold.selector, 1e18));
        vault.withdraw(1, alice, alice);
    }

    /// @dev mint() rounds the gem amount up to the wsgem's granularity; the wsgem then mints
    /// floor(assets * 1e18 / mintcost) which can exceed the requested shares by less than
    /// one gem unit's worth of wsgem. The excess stays in the vault as surplus backing.
    function test_Mint_ExcessBelowOneGemUnit() public {
        uint256 unit = _mc();
        uint256 shares = 1e18 + 1;
        uint256 assets = _mintShares(alice, shares);
        assertEq(assets, _ceilDiv(shares * unit, 1e18), "ceil assets");
        assertEq(vault.balanceOf(alice), shares, "exact shares");
        uint256 held = wsgem.balanceOf(address(vault));
        uint256 excess = held - vault.totalSupply();
        assertEq(excess, assets * 1e18 / unit - shares, "excess is the wsgem's rounding");
        assertLt(excess * unit, 1e18, "excess below one gem unit's worth");
        assertEq(vault.deficit(), 0);
        assertEq(vault.totalAssets(), shares * _nav() / 1e18, "surplus never enters the price");
    }

    function test_DepositRedeemWsgem_OneToOne() public {
        uint256 shares = _depositWsgem(alice, _mc() * 3);
        assertEq(shares, wsgem.balanceOf(address(vault)), "vault: 1:1 in");
        assertEq(vault.balanceOf(alice), shares);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(shares, alice, alice), shares, "vault: 1:1 out");
        assertEq(wsgem.balanceOf(alice), shares);
        assertEq(vault.totalSupply(), 0);
    }

    /// @dev Below the wsgem's dust floor the quote still stands (a fraction of a share);
    /// execution reverts with the wsgem's own DustThreshold(mintcost).
    function test_Dust_BelowMintcostReverts() public {
        uint256 unit = _mc();
        uint256 quote = vault.previewDeposit(unit - 1);
        assertEq(quote, (unit - 1) * 1e18 / unit, "quote ignores the floor");
        assertLt(quote, 1e18);

        gem.mint(alice, unit - 1);
        vm.startPrank(alice);
        gem.approve(address(vault), unit - 1);
        vm.expectRevert(abi.encodeWithSelector(IWsgem.DustThreshold.selector, unit));
        vault.deposit(unit - 1, alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PreviewDepositGem_MatchesDeposit(uint256 amt) public {
        uint256 unit = _mc();
        amt = bound(amt, unit, 1e12 * _one());
        uint256 preview = vault.previewDeposit(amt);
        assertEq(preview, amt * 1e18 / unit, "wsgem mint math");
        assertEq(_depositGem(alice, amt), preview, "vault parity");
        assertEq(vault.balanceOf(alice), preview);
        assertEq(wsgem.balanceOf(address(vault)), preview, "fully backed");
    }

    function testFuzz_PreviewRedeem_MatchesRedeem(uint256 amt, uint256 part) public {
        amt = bound(amt, _mc() * 2, 1e12 * _one());
        uint256 shares = _depositGem(alice, amt);
        part = bound(part, 1e18, shares);
        uint256 preview = vault.previewRedeem(part);
        assertEq(preview, part * _bc() / 1e18, "wsgem redeem math");
        uint256 before = gem.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(part, alice, alice);
        assertEq(out, preview, "parity");
        assertEq(gem.balanceOf(alice) - before, out, "delivered");
        assertEq(wsgem.balanceOf(address(vault)), vault.totalSupply(), "still fully backed");
    }

    function testFuzz_PreviewWithdraw_MatchesWithdraw(uint256 assets) public {
        uint256 cost = _bc();
        assets = bound(assets, cost, 1e12 * _one());
        // Fund twice over: shares for ceil(assets/burncost) and gem liquidity for the claim.
        _depositGem(alice, assets * 2 + _mc() * 2);
        uint256 preview = vault.previewWithdraw(assets);
        assertEq(preview, _ceilDiv(assets * 1e18, cost), "ceil shares");
        assertGe(preview, 1e18);
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 gemBefore = gem.balanceOf(alice);
        vm.prank(alice);
        uint256 burned = vault.withdraw(assets, alice, alice);
        assertEq(burned, preview, "parity");
        assertEq(sharesBefore - vault.balanceOf(alice), burned, "shares burned");
        assertEq(gem.balanceOf(alice) - gemBefore, assets, "exactly assets delivered");
    }

    /// @dev A full lap loses at most the exit fee plus quantisation: one gem unit on the
    /// share floor, one on the claim floor, one for the fee's own rounding.
    function testFuzz_RoundTrip_LossBoundedByFeePlusQuantization(uint256 amt) public {
        amt = bound(amt, _mc(), 1e12 * _one());
        uint256 shares = _depositGem(alice, amt);
        vm.prank(alice);
        uint256 back = vault.redeem(shares, alice, alice);
        assertEq(back, shares * _bc() / 1e18, "wsgem redeem math");
        assertLe(back, amt, "never gains");
        uint256 bpsout = act.bpsout();
        assertLe(amt - back, amt * bpsout / 10_000 + 3, "loss bounded by fee + quantisation");
    }

    function testFuzz_Withdraw_DustBounded(uint256 assets) public {
        uint256 cost = _bc();
        assets = bound(assets, cost, 1e12 * _one());
        _depositGem(alice, assets * 2 + _mc() * 2);
        uint256 vaultGemBefore = gem.balanceOf(address(vault));
        vm.prank(alice);
        uint256 burned = vault.withdraw(assets, alice, alice);
        uint256 claim = burned * cost / 1e18;
        assertGe(claim, assets);
        uint256 dust = gem.balanceOf(address(vault)) - vaultGemBefore;
        assertEq(dust, claim - assets, "dust is the claim's rounding");
        assertLe(dust, cost / 1e18 + 1, "dust bounded by burncost / 1e18 + 1");
    }
}

contract WsgemDecimals2Test is WsgemDecimalsTest {
    function _decimals() internal pure override returns (uint8) {
        return 2;
    }
}

contract WsgemDecimals6Test is WsgemDecimalsTest {
    function _decimals() internal pure override returns (uint8) {
        return 6;
    }
}

contract WsgemDecimals8Test is WsgemDecimalsTest {
    function _decimals() internal pure override returns (uint8) {
        return 8;
    }
}
