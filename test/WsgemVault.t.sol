// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {stdError} from "forge-std/Test.sol";
import {VaultTestBase} from "./VaultTestBase.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";
import {IWsgemVault} from "../src/interfaces/IWsgemVault.sol";
import {MockGem} from "./mocks/MockGem.sol";

/// @dev A wsgem stand-in with the wrong decimals, for the constructor guard.
contract SixDecimalWsgem {
    address public immutable gem;

    constructor(address gem_) {
        gem = gem_;
    }

    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @dev A gate whose one chosen fee getter burns all gas; every other getter is healthy.
contract GasBurningGate {
    bytes4 internal immutable burning;

    constructor(bytes4 burning_) {
        burning = burning_;
    }

    function mintable() external pure returns (bool) {
        return true;
    }

    function burnable() external pure returns (bool) {
        return true;
    }

    function cooldown() external pure returns (uint256) {
        return 0;
    }

    function capacity() external pure returns (uint256) {
        return type(uint256).max;
    }

    function terms() external pure returns (string memory) {
        return "";
    }

    function mintcost(uint256 price) external view returns (uint256) {
        _burnIf(this.mintcost.selector);
        return price;
    }

    function burncost(uint256 price) external view returns (uint256) {
        _burnIf(this.burncost.selector);
        return (price * 9975 + 9999) / 10_000;
    }

    function _burnIf(bytes4 selector) internal view {
        if (selector == burning) {
            while (true) {}
        }
    }
}

contract WsgemVaultTest is VaultTestBase {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event DepositWsgem(address indexed sender, address indexed owner, uint256 amount);
    event RedeemWsgem(
        address indexed sender, address indexed receiver, address indexed owner, uint256 shares, uint256 wsgemOut
    );
    event Sync(uint256 nav, uint256 mintUnit, uint256 burnUnit);

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _insolvent(uint256 d) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWsgemVault.Insolvent.selector, d);
    }

    function _dust(uint256 min) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWsgem.DustThreshold.selector, min);
    }

    function _notAuthorized(address usr) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWsgem.NotAuthorized.selector, usr);
    }

    function _marketClosed() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWsgem.MarketClosed.selector);
    }

    function _invalidPrice() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWsgem.InvalidPrice.selector);
    }

    function _exceedsCap() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWsgem.ExceedsCap.selector);
    }

    function _cooldown(uint256 cd) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWsgemVault.CooldownActive.selector, cd);
    }

    function _illiquid(uint256 available, uint256 required) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWsgemVault.InsufficientLiquidity.selector, available, required);
    }

    /// @dev wsgem.mintcost() for an arbitrary nav/bpsin, computed the wsgem's way.
    function _mintcostOf(uint256 nav, uint256 bpsin) internal pure returns (uint256) {
        return (nav * (10_000 + bpsin) + 9999) / 10_000;
    }

    /// @dev wsgem.burncost() for an arbitrary nav/bpsout, computed the wsgem's way.
    function _burncostOf(uint256 nav, uint256 bpsout) internal pure returns (uint256) {
        return (nav * (10_000 - bpsout) + 9999) / 10_000;
    }

    function _fillMismatch(uint256 expected, uint256 received) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IWsgemVault.FillMismatch.selector, expected, received);
    }

    /// @dev wsgem released by `shares` under the vault's pro-rata rule.
    function _wsgemFor(uint256 shares) internal view returns (uint256) {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return shares;
        uint256 held = wsgem.balanceOf(address(vault));
        uint256 eff = held < supply ? held : supply;
        return eff == supply ? shares : shares * eff / supply;
    }

    function _surplus() internal view returns (uint256) {
        return wsgem.balanceOf(address(vault)) - vault.totalSupply();
    }

    function _setNavAndFees(uint256 nav, uint256 bpsin, uint256 bpsout) internal {
        pip.poke(nav);
        act.setBpsin(bpsin);
        act.setBpsout(bpsout);
    }

    /// @dev Signs an EIP-2612 permit for the vault.
    function _signPermit(uint256 pk, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    /*//////////////////////////////////////////////////////////////
                    3.1 METADATA / IMMUTABILITY / VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_Metadata() public view {
        assertEq(vault.name(), "Wrapped Staked Gem Vault");
        assertEq(vault.symbol(), "vwsGEM");
        assertEq(vault.decimals(), 18);
        assertEq(vault.asset(), address(gem));
        assertEq(vault.gem(), address(gem));
        assertEq(vault.wsgem(), address(wsgem));
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.deficit(), 0);
    }

    function test_AssetReadFromWsgem() public view {
        assertEq(vault.asset(), wsgem.gem());
    }

    function test_ApprovalSetInConstructor() public view {
        assertEq(gem.allowance(address(vault), address(wsgem)), type(uint256).max);
    }

    function test_Constructor_WsgemDecimalsNot18_Reverts() public {
        SixDecimalWsgem bad = new SixDecimalWsgem(address(gem));
        vm.expectRevert(abi.encodeWithSelector(WsgemVault.WsgemDecimals.selector, uint8(6)));
        new WsgemVault("x", "x", address(bad));
    }

    function test_NoAdminSurface() public {
        bytes[7] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pendingOwner()"),
            abi.encodeWithSignature("paused()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("sweep(address,address)", address(gem), alice),
            abi.encodeWithSignature("transferOwnership(address,bool,bool)", alice, true, false)
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = address(vault).call(calls[i]);
            assertFalse(ok, "vault must have no admin surface");
        }
    }

    function test_TotalAssets_IsSupplyTimesNav() public {
        _depositGem(alice, 1000e18);
        _depositWsgem(bob, 500e18);
        assertEq(vault.totalAssets(), vault.totalSupply() * _nav() / WAD);
        assertGt(vault.totalAssets(), 0);
    }

    function test_TotalAssets_IgnoresDonatedWsgem() public {
        uint256 s = _depositGem(alice, 1000e18);
        uint256 assetsBefore = vault.totalAssets();
        uint256 priceBefore = vault.convertToAssets(WAD);
        uint256 redeemBefore = vault.previewRedeem(s);

        _donateWsgem(250e18);

        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.convertToAssets(WAD), priceBefore);
        assertEq(vault.previewRedeem(s), redeemBefore);
        assertEq(wsgem.balanceOf(address(vault)), vault.totalSupply() + 250e18);
    }

    function test_Convert_ExactVectors() public {
        uint256 nav = _nav();
        assertEq(vault.convertToAssets(WAD), nav);
        assertEq(vault.convertToShares(nav), WAD);
        assertEq(vault.convertToAssets(3), 3 * nav / WAD);
        assertEq(vault.convertToShares(1), WAD / nav); // floor(1e18 / 1.006e18) == 0
        assertEq(vault.convertToShares(1), 0);

        pip.poke(WAD + 1);
        assertEq(vault.convertToAssets(WAD), WAD + 1);
        assertEq(vault.convertToAssets(WAD - 1), (WAD - 1) * (WAD + 1) / WAD);
        assertEq(vault.convertToShares(WAD + 1), WAD);
        assertEq(vault.convertToShares(WAD), WAD * WAD / (WAD + 1));
    }

    function testFuzz_Convert_RoundTripNeverGains(uint256 a, uint256 s, uint256 nav) public {
        nav = bound(nav, 1e15, 1e27);
        a = bound(a, 0, 1e30);
        s = bound(s, 0, 1e30);
        pip.poke(nav);
        assertLe(vault.convertToAssets(vault.convertToShares(a)), a);
        assertLe(vault.convertToShares(vault.convertToAssets(s)), s);
    }

    function test_Convert_TracksPokeUpAndDown() public {
        pip.poke(1.2e18);
        assertEq(vault.convertToAssets(WAD), 1.2e18);
        pip.poke(0.9e18);
        assertEq(vault.convertToAssets(WAD), 0.9e18);
        assertEq(vault.convertToShares(0.9e18), WAD);
    }

    function test_Convert_OraclePaused_UsesFallback() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 nav = _nav();
        pip.pause();
        assertEq(vault.lastNav(), nav);
        assertEq(vault.totalAssets(), s * nav / WAD);
        assertEq(vault.convertToAssets(WAD), nav);
        assertEq(vault.convertToShares(nav), WAD);
        assertEq(vault.previewDeposit(vault.lastMintUnit()), WAD);
        assertEq(vault.previewMint(WAD), vault.lastMintUnit());
        assertEq(vault.previewRedeem(WAD), vault.lastBurnUnit());
        assertEq(vault.previewWithdraw(vault.lastBurnUnit()), WAD);
    }

    function test_Constructor_SeedsFallback() public view {
        assertEq(vault.lastNav(), initNavprice);
        assertEq(vault.lastMintUnit(), _mc());
        assertEq(vault.lastBurnUnit(), _bc());
        assertGt(vault.lastNav(), 0);
    }

    function test_Constructor_OraclePaused_Reverts() public {
        pip.pause();
        vm.expectRevert(_invalidPrice());
        new WsgemVault("V", "V", address(wsgem));
    }

    function test_Constructor_FeedReverts_Reverts() public {
        act.file("bpsout", 10_001); // burncost() underflows
        vm.expectRevert(_invalidPrice());
        new WsgemVault("V", "V", address(wsgem));
    }

    function test_Sync_RefreshesFallbackAndEmits() public {
        pip.poke(1.2e18);
        act.setBpsin(10);
        uint256 mc = _mc();
        uint256 bc = _bc();
        assertEq(vault.lastNav(), initNavprice); // stale until refreshed
        vm.expectEmit(true, true, true, true, address(vault));
        emit Sync(1.2e18, mc, bc);
        vault.sync();
        assertEq(vault.lastNav(), 1.2e18);
        assertEq(vault.lastMintUnit(), mc);
        assertEq(vault.lastBurnUnit(), bc);
        // Unchanged values do not re-emit; a second sync is a no-op.
        vm.recordLogs();
        vault.sync();
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_Sync_Paused_Reverts() public {
        pip.pause();
        vm.expectRevert(_invalidPrice());
        vault.sync();
        assertEq(vault.lastNav(), initNavprice);
    }

    function test_OracleLive_TracksPause() public {
        assertTrue(vault.oracleLive());
        pip.pause();
        assertFalse(vault.oracleLive());
        pip.poke(1.2e18);
        assertTrue(vault.oracleLive());
    }

    function test_Mutator_RefreshesFallback() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.poke(1.1e18);
        assertEq(vault.lastNav(), initNavprice);
        // The wsgem legs never read the oracle, so they never refresh.
        vm.startPrank(alice);
        vault.redeemToWsgem(s / 2, alice, alice);
        wsgem.approve(address(vault), s / 2);
        vault.depositWsgem(s / 2, alice);
        vm.stopPrank();
        assertEq(vault.lastNav(), initNavprice);
        // Every gem leg does.
        _depositGem(bob, 10e18);
        assertEq(vault.lastNav(), 1.1e18);
        pip.poke(1.3e18);
        vm.prank(alice);
        vault.redeem(WAD, alice, alice);
        assertEq(vault.lastNav(), 1.3e18);
        assertEq(vault.lastMintUnit(), _mc());
        assertEq(vault.lastBurnUnit(), _bc());
    }

    function test_Fallback_LiveValuesPreferred() public {
        _depositGem(alice, 100e18);
        pip.poke(1.2e18);
        vault.sync();
        pip.pause();
        assertEq(vault.convertToAssets(WAD), 1.2e18);
        // Un-pausing at a different price: quotes follow the live value even though the
        // fallback still says 1.2e18 until the next refresh.
        pip.poke(0.9e18);
        assertEq(vault.lastNav(), 1.2e18);
        assertEq(vault.convertToAssets(WAD), 0.9e18);
        assertEq(vault.previewDeposit(_mc()), WAD);
        assertEq(vault.previewRedeem(WAD), _bc());
        vault.sync();
        assertEq(vault.lastNav(), 0.9e18);
    }

    /*//////////////////////////////////////////////////////////////
                        3.2 DEPOSIT / MINT (GEM IN)
    //////////////////////////////////////////////////////////////*/

    function test_Deposit_SharesEqualWsgemMintOutput() public {
        uint256 amt = 1000e18;
        uint256 shares = _depositGem(alice, amt);
        assertEq(shares, amt * WAD / _mc());
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalSupply(), shares);
        assertEq(wsgem.balanceOf(address(vault)), shares);
        assertEq(gem.balanceOf(address(vault)), 0);
        assertEq(gem.balanceOf(address(wsgem)), amt);
        assertEq(gem.balanceOf(alice), 0);
    }

    function test_Deposit_ToOtherReceiver() public {
        gem.mint(alice, 100e18);
        vm.startPrank(alice);
        gem.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, bob);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), shares);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Deposit_ZeroReceiver_Reverts() public {
        gem.mint(alice, 100e18);
        vm.startPrank(alice);
        gem.approve(address(vault), 100e18);
        vm.expectRevert(bytes("ERC20: mint to the zero address"));
        vault.deposit(100e18, address(0));
        vm.stopPrank();
    }

    function test_Deposit_InsufficientAllowance_Reverts() public {
        gem.mint(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.deposit(100e18, alice);
    }

    function test_Deposit_Zero_IsNoop() public {
        act.pauseMarket();
        pip.pause();
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, alice, 0, 0);
        assertEq(vault.deposit(0, alice), 0);
        assertEq(vault.previewDeposit(0), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_Deposit_EmitsDepositEvent() public {
        uint256 amt = 100e18;
        uint256 expected = amt * WAD / _mc();
        gem.mint(alice, amt);
        vm.startPrank(alice);
        gem.approve(address(vault), amt);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, bob, amt, expected);
        vault.deposit(amt, bob);
        vm.stopPrank();
    }

    function test_PreviewDeposit_ExactVectors() public {
        pip.poke(WAD + 1);
        act.setBpsin(25);
        uint256 unit = ((WAD + 1) * 10_025 + 9999) / 10_000;
        assertEq(_mc(), unit);
        uint256 amt = 123_456_789e12;
        assertEq(vault.previewDeposit(amt), amt * WAD / unit);
        assertEq(vault.previewDeposit(unit), WAD);
        assertEq(vault.previewDeposit(2 * unit - 1), 2 * WAD - 1); // floor(2W - W/unit), W/unit < 1
    }

    function test_PreviewDeposit_BpsinApplied() public {
        act.setBpsin(25);
        uint256 unit = _mc();
        assertGt(unit, _nav());
        assertEq(vault.previewDeposit(unit), WAD);
        // Below the entry unit the quote is simply fractional; only execution has a floor.
        uint256 nav = _nav();
        assertEq(vault.previewDeposit(nav), nav * WAD / unit);
        assertLt(vault.previewDeposit(nav), WAD);
    }

    function test_Deposit_Dust_BelowMintcostReverts_AtMintcostSucceeds() public {
        uint256 unit = _mc();
        gem.mint(alice, 2 * unit);
        vm.startPrank(alice);
        gem.approve(address(vault), 2 * unit);
        assertEq(vault.previewDeposit(unit - 1), (unit - 1) * WAD / unit); // quoted, not gated
        vm.expectRevert(_dust(unit));
        vault.deposit(unit - 1, alice);
        assertEq(vault.deposit(unit, alice), WAD);
        vm.stopPrank();
    }

    function test_Deposit_MintClosed_Reverts() public {
        _closeMint();
        gem.mint(alice, 100e18);
        vm.startPrank(alice);
        gem.approve(address(vault), 100e18);
        assertEq(vault.previewDeposit(100e18), 100e18 * WAD / _mc()); // quoted, not gated
        assertEq(vault.maxDeposit(alice), 0);
        vm.expectRevert(_marketClosed());
        vault.deposit(100e18, alice);
        vm.stopPrank();
        // wsgem leg unaffected (the wsgem was minted while the window was open).
        _openMint();
        uint256 out = _mintWsgem(bob, 10e18);
        _closeMint();
        vm.startPrank(bob);
        wsgem.approve(address(vault), out);
        assertEq(vault.depositWsgem(out, bob), out);
        vm.stopPrank();
    }

    function test_Deposit_OraclePaused_Reverts() public {
        pip.pause();
        gem.mint(alice, 100e18);
        vm.startPrank(alice);
        gem.approve(address(vault), 100e18);
        assertEq(vault.previewDeposit(100e18), 100e18 * WAD / vault.lastMintUnit()); // fallback quote
        assertEq(vault.maxDeposit(alice), 0);
        vm.expectRevert(_invalidPrice());
        vault.deposit(100e18, alice);
        vm.stopPrank();
    }

    function test_Deposit_CapacityExceeded_Reverts() public {
        act.setCapacity(WAD);
        uint256 amt = 2 * _mc();
        gem.mint(alice, amt);
        vm.startPrank(alice);
        gem.approve(address(vault), amt);
        assertEq(vault.previewDeposit(amt), 2 * WAD); // quoted, not gated
        assertLt(vault.maxDeposit(alice), amt);
        vm.expectRevert(_exceedsCap());
        vault.deposit(amt, alice);
        vm.stopPrank();
    }

    /// @dev Execution-only ordering: the vault's solvency gate, then the wsgem's own
    /// order (window, screen, price, dust, capacity). Quotes never take part.
    function test_Deposit_ErrorOrdering() public {
        uint256 unit = _mc();
        gem.mint(alice, 100e18);
        vm.prank(alice);
        gem.approve(address(vault), type(uint256).max);

        // deficit + mint closed -> Insolvent
        uint256 s = _depositGem(bob, 100e18);
        _smeltVault(s / 2);
        _closeMint();
        assertEq(vault.previewDeposit(10e18), 10e18 * WAD / unit);
        vm.prank(alice);
        vm.expectRevert(_insolvent(s / 2));
        vault.deposit(10e18, alice);
        _openMint();
        _donateWsgem(s / 2);
        assertEq(vault.deficit(), 0);
        _closeMint();

        // mint closed + paused -> MarketClosed
        pip.pause();
        vm.prank(alice);
        vm.expectRevert(_marketClosed());
        vault.deposit(10e18, alice);
        _openMint();

        // paused oracle + banned vault -> gem transfer rejects the spender first
        gem.ban(address(vault));
        vm.prank(alice);
        vm.expectRevert(MockGem.AccountBanned.selector);
        vault.deposit(10e18, alice);
        gem.unban(address(vault));

        // paused + dust -> InvalidPrice
        vm.prank(alice);
        vm.expectRevert(_invalidPrice());
        vault.deposit(1, alice);
        pip.poke(initNavprice);

        // dust + cap -> DustThreshold
        act.setCapacity(wsgem.totalSupply());
        vm.prank(alice);
        vm.expectRevert(_dust(unit));
        vault.deposit(unit - 1, alice);

        // cap alone -> ExceedsCap
        assertEq(vault.previewDeposit(unit), WAD);
        vm.prank(alice);
        vm.expectRevert(_exceedsCap());
        vault.deposit(unit, alice);
    }

    /// @dev mint() needs the live entry unit before it can pull gem, so a paused oracle
    /// surfaces before the wsgem's window check there.
    function test_Mint_ErrorOrdering() public {
        uint256 unit = _mc();
        gem.mint(alice, 100e18);
        vm.prank(alice);
        gem.approve(address(vault), type(uint256).max);

        uint256 s = _depositGem(bob, 100e18);
        _smeltVault(s / 2);
        pip.pause();
        vm.prank(alice);
        vm.expectRevert(_insolvent(s / 2));
        vault.mint(WAD, alice);
        pip.poke(initNavprice);
        _donateWsgem(s / 2);

        // paused + mint closed -> InvalidPrice (unit needed before the pull)
        pip.pause();
        _closeMint();
        vm.prank(alice);
        vm.expectRevert(_invalidPrice());
        vault.mint(WAD, alice);
        pip.poke(initNavprice);

        // mint closed + banned -> gem transfer rejects the spender before wsgem.mint
        gem.ban(address(vault));
        vm.prank(alice);
        vm.expectRevert(MockGem.AccountBanned.selector);
        vault.mint(WAD, alice);
        _openMint();

        // banned + dust -> gem transfer rejects the spender first
        vm.prank(alice);
        vm.expectRevert(MockGem.AccountBanned.selector);
        vault.mint(WAD - 1, alice);
        gem.unban(address(vault));

        // dust + cap -> DustThreshold (denominated in gem: the implied deposit)
        act.setCapacity(wsgem.totalSupply());
        vm.prank(alice);
        vm.expectRevert(_dust(unit));
        vault.mint(WAD - 1, alice);

        // cap alone -> ExceedsCap
        vm.prank(alice);
        vm.expectRevert(_exceedsCap());
        vault.mint(WAD, alice);
    }

    function test_Mint_ExactShares_AssetsIsCeil() public {
        uint256 s = 1000e18 + 12_345;
        uint256 unit = _mc();
        uint256 expectedAssets = _ceilDiv(s * unit, WAD);
        assertEq(vault.previewMint(s), expectedAssets);

        gem.mint(alice, expectedAssets);
        vm.startPrank(alice);
        gem.approve(address(vault), expectedAssets);
        uint256 assets = vault.mint(s, alice);
        vm.stopPrank();

        assertEq(assets, expectedAssets);
        assertEq(gem.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), s);
        assertEq(vault.totalSupply(), s);
        uint256 excess = expectedAssets * WAD / unit - s;
        assertEq(wsgem.balanceOf(address(vault)), s + excess);
        assertEq(vault.deficit(), 0);
        assertEq(vault.convertToAssets(WAD), _nav());
    }

    function test_Mint_ExcessStaysAsSurplus() public {
        pip.poke(0.5e18);
        assertEq(_mc(), 0.5e18);
        uint256 s = WAD + 1;
        uint256 assets = vault.previewMint(s);
        assertEq(assets, 0.5e18 + 1);

        gem.mint(alice, assets);
        vm.startPrank(alice);
        gem.approve(address(vault), assets);
        vault.mint(s, alice);
        vm.stopPrank();

        assertEq(vault.totalSupply(), s);
        assertEq(wsgem.balanceOf(address(vault)), WAD + 2);
        assertEq(_surplus(), 1);
        assertEq(vault.totalAssets(), s * 0.5e18 / WAD);
        assertEq(vault.convertToAssets(WAD), 0.5e18);
    }

    function test_Mint_EmitsDepositEvent() public {
        uint256 s = 10e18;
        uint256 assets = vault.previewMint(s);
        gem.mint(alice, assets);
        vm.startPrank(alice);
        gem.approve(address(vault), assets);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, bob, assets, s);
        vault.mint(s, bob);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), s);
    }

    function test_Mint_Zero_IsNoop() public {
        act.pauseMarket();
        pip.pause();
        assertEq(vault.previewMint(0), 0);
        vm.prank(alice);
        assertEq(vault.mint(0, alice), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function test_Mint_BelowOneShare_Reverts() public {
        uint256 unit = _mc();
        assertGt(unit, WAD);
        uint256 quoted = vault.previewMint(WAD - 1);
        assertEq(quoted, _ceilDiv((WAD - 1) * unit, WAD)); // quoted, not gated
        assertLt(quoted, unit);
        gem.mint(alice, unit);
        vm.startPrank(alice);
        gem.approve(address(vault), unit);
        vm.expectRevert(_dust(unit));
        vault.mint(WAD - 1, alice);
        vm.stopPrank();
    }

    function test_Mint_MintClosed_Reverts() public {
        _closeMint();
        uint256 assets = vault.previewMint(WAD);
        assertEq(assets, _mc()); // quoted, not gated
        assertEq(vault.maxMint(alice), 0);
        gem.mint(alice, assets);
        vm.startPrank(alice);
        gem.approve(address(vault), assets);
        vm.expectRevert(_marketClosed());
        vault.mint(WAD, alice);
        vm.stopPrank();
    }

    function test_Mint_OraclePaused_Reverts() public {
        pip.pause();
        assertEq(vault.previewMint(WAD), vault.lastMintUnit()); // fallback quote
        assertEq(vault.maxMint(alice), 0);
        vm.prank(alice);
        vm.expectRevert(_invalidPrice());
        vault.mint(WAD, alice);
    }

    function test_Mint_CapacityExceeded_Reverts() public {
        act.setCapacity(WAD);
        uint256 assets = vault.previewMint(2 * WAD);
        assertEq(assets, 2 * _mc()); // quoted, not gated
        assertEq(vault.maxMint(alice), WAD);
        gem.mint(alice, assets);
        vm.startPrank(alice);
        gem.approve(address(vault), assets);
        vm.expectRevert(_exceedsCap());
        vault.mint(2 * WAD, alice);
        vm.stopPrank();
    }

    function testFuzz_PreviewDeposit_MatchesDeposit(uint256 amt, uint256 nav, uint256 bpsin) public {
        nav = bound(nav, 1e15, 1e27);
        bpsin = bound(bpsin, 0, 10_000);
        pip.poke(nav);
        act.setBpsin(bpsin);
        uint256 unit = _mc();
        assertEq(unit, _mintcostOf(nav, bpsin));
        amt = bound(amt, unit, 1e30);

        uint256 expected = amt * WAD / unit;
        assertEq(vault.previewDeposit(amt), expected);
        assertEq(_depositGem(alice, amt), expected);
        assertEq(vault.balanceOf(alice), expected);
        assertEq(wsgem.balanceOf(address(vault)), expected);
    }

    function testFuzz_PreviewMint_MatchesMint(uint256 shares, uint256 nav, uint256 bpsin) public {
        nav = bound(nav, 1e15, 1e27);
        bpsin = bound(bpsin, 0, 10_000);
        shares = bound(shares, WAD, 1e27);
        pip.poke(nav);
        act.setBpsin(bpsin);
        uint256 unit = _mc();

        uint256 preview = vault.previewMint(shares);
        assertEq(preview, _ceilDiv(shares * unit, WAD));

        gem.mint(alice, preview);
        vm.startPrank(alice);
        gem.approve(address(vault), preview);
        uint256 assets = vault.mint(shares, alice);
        vm.stopPrank();

        assertEq(assets, preview);
        assertEq(vault.balanceOf(alice), shares);
        uint256 excess = preview * WAD / unit - shares;
        assertEq(wsgem.balanceOf(address(vault)), vault.totalSupply() + excess);
        assertLt(excess, WAD / unit + 1);
    }

    function testFuzz_DepositThenRedeemToWsgem_EqualsDirectMint(uint256 amt, uint256 nav, uint256 bpsin) public {
        nav = bound(nav, 1e15, 1e27);
        bpsin = bound(bpsin, 0, 10_000);
        pip.poke(nav);
        act.setBpsin(bpsin);
        amt = bound(amt, _mc(), 1e30);

        uint256 s = _depositGem(alice, amt);
        vm.prank(alice);
        uint256 out = vault.redeemToWsgem(s, alice, alice);
        assertEq(out, s);
        assertEq(wsgem.balanceOf(alice), s);

        uint256 direct = _mintWsgem(bob, amt);
        assertEq(s, direct);
    }

    function testFuzz_Mint_NeverCheaperThanDirect(uint256 shares, uint256 nav, uint256 bpsin) public {
        nav = bound(nav, 1e15, 1e27);
        bpsin = bound(bpsin, 0, 10_000);
        shares = bound(shares, WAD, 1e27);
        pip.poke(nav);
        act.setBpsin(bpsin);
        uint256 unit = _mc();

        uint256 paid = vault.previewMint(shares);
        gem.mint(alice, paid);
        vm.startPrank(alice);
        gem.approve(address(vault), paid);
        vault.mint(shares, alice);
        vm.stopPrank();

        // One gem unit less could not have bought `shares` directly.
        assertLt((paid - 1) * WAD / unit, shares);
        // The same gem, minted directly, yields exactly what the vault holds.
        uint256 direct = _mintWsgem(bob, paid);
        assertEq(direct, wsgem.balanceOf(address(vault)));
        assertGe(direct, shares);
    }

    /*//////////////////////////////////////////////////////////////
                      3.3 REDEEM / WITHDRAW (GEM OUT)
    //////////////////////////////////////////////////////////////*/

    function test_Redeem_ClaimIsFloorSharesTimesBurncost() public {
        uint256 s = _depositGem(alice, 1000e18);
        uint256 expected = s * _bc() / WAD;
        assertEq(vault.previewRedeem(s), expected);
        assertLt(expected, 1000e18);

        vm.prank(alice);
        uint256 out = vault.redeem(s, alice, alice);

        assertEq(out, expected);
        assertEq(gem.balanceOf(alice), expected);
        assertEq(vault.totalSupply(), 0);
        assertEq(wsgem.balanceOf(address(vault)), 0);
        assertEq(gem.balanceOf(address(vault)), 0);
        assertEq(wsgem.totalPending(), 0);
        assertEq(wsgem.redemptionAmount(0), 0);
        assertEq(wsgem.redemptionAddr(0), address(vault));
    }

    function test_Redeem_FeeIsBpsout() public {
        uint256[3] memory fees = [uint256(0), 25, 100];
        for (uint256 i = 0; i < fees.length; i++) {
            act.setBpsout(fees[i]);
            uint256 s = _depositGem(alice, 100e18);
            uint256 expected = s * _burncostOf(_nav(), fees[i]) / WAD;
            assertEq(_bc(), _burncostOf(_nav(), fees[i]));
            uint256 before = gem.balanceOf(alice);
            vm.prank(alice);
            assertEq(vault.redeem(s, alice, alice), expected);
            assertEq(gem.balanceOf(alice) - before, expected);
        }
    }

    function test_Redeem_ToOtherReceiver() public {
        uint256 s = _depositGem(alice, 100e18);
        vm.prank(alice);
        uint256 out = vault.redeem(s, bob, alice);
        assertEq(gem.balanceOf(bob), out);
        assertEq(gem.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Redeem_ByOperatorWithAllowance() public {
        uint256 s = _depositGem(alice, 100e18);
        vm.prank(alice);
        vault.approve(bob, s);
        vm.prank(bob);
        uint256 out = vault.redeem(s, bob, alice);
        assertEq(gem.balanceOf(bob), out);
        assertEq(vault.allowance(alice, bob), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Redeem_ByOperatorWithoutAllowance_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        vault.redeem(s, bob, alice);
    }

    function test_Redeem_InfiniteAllowanceNotDecremented() public {
        uint256 s = _depositGem(alice, 100e18);
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);
        vm.prank(bob);
        vault.redeem(s, bob, alice);
        assertEq(vault.allowance(alice, bob), type(uint256).max);
    }

    function test_Redeem_EmitsWithdrawEvent() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 claim = vault.previewRedeem(s);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Withdraw(alice, bob, alice, claim, s);
        vault.redeem(s, bob, alice);
    }

    function test_Redeem_Zero_IsNoop() public {
        _depositGem(alice, 100e18);
        act.pauseMarket();
        pip.pause();
        assertEq(vault.previewRedeem(0), 0);
        vm.prank(bob); // no allowance needed for 0
        vm.expectEmit(true, true, true, true, address(vault));
        emit Withdraw(bob, bob, alice, 0, 0);
        assertEq(vault.redeem(0, bob, alice), 0);
    }

    function test_Redeem_BelowOneShare_Reverts() public {
        _depositGem(alice, 100e18);
        assertEq(vault.previewRedeem(WAD - 1), (WAD - 1) * _bc() / WAD); // quoted, not gated
        vm.prank(alice);
        vm.expectRevert(_dust(WAD));
        vault.redeem(WAD - 1, alice, alice);
    }

    function test_Redeem_OraclePaused_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.pause();
        assertEq(vault.previewRedeem(s), s * vault.lastBurnUnit() / WAD); // fallback quote
        assertEq(vault.maxRedeem(alice), 0);
        vm.prank(alice);
        vm.expectRevert(_invalidPrice());
        vault.redeem(s, alice, alice);
        // The wsgem leg never reads the oracle.
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(s, alice, alice), s);
    }

    function test_Redeem_BurnClosed_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        _closeBurn();
        assertEq(vault.previewRedeem(s), s * _bc() / WAD); // quoted, not gated
        assertEq(vault.maxRedeem(alice), 0);
        vm.prank(alice);
        vm.expectRevert(_marketClosed());
        vault.redeem(s, alice, alice);
        // Deposits and the wsgem legs still work.
        assertGt(_depositGem(bob, 10e18), 0);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(s, alice, alice), s);
    }

    function test_Redeem_CooldownNonZero_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 toWsgem = vault.maxRedeemToWsgem(alice);
        act.setCooldown(1);

        assertEq(vault.previewRedeem(s), s * _bc() / WAD); // quotes are unaffected
        assertEq(vault.previewWithdraw(1e18), _ceilDiv(1e18 * WAD, _bc()));
        vm.startPrank(alice);
        vm.expectRevert(_cooldown(1));
        vault.redeem(s, alice, alice);
        vm.expectRevert(_cooldown(1));
        vault.withdraw(1e18, alice, alice);
        vm.stopPrank();

        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeemToWsgem(alice), toWsgem);
        assertGt(_depositGem(bob, 10e18), 0);

        act.setCooldown(0);
        assertEq(vault.maxRedeem(alice), s);
    }

    function test_Redeem_ThinLiquidity_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 claim = vault.previewRedeem(s);

        _setLiquidity(claim - 1);
        assertEq(vault.previewRedeem(s), claim); // quoted, not gated
        assertLt(vault.maxRedeem(alice), s);
        vm.prank(alice);
        vm.expectRevert(_illiquid(claim - 1, claim));
        vault.redeem(s, alice, alice);

        _setLiquidity(claim);
        vm.prank(alice);
        assertEq(vault.redeem(s, alice, alice), claim);
        assertEq(gem.balanceOf(alice), claim);
        assertEq(wsgem.totalPending(), 0);
    }

    function test_Redeem_ThinLiquidity_PartialStillServed() public {
        uint256 s = _depositGem(alice, 1000e18);
        uint256 liquidity = vault.previewRedeem(s / 2);
        _setLiquidity(liquidity);

        uint256 expected = _ceilDiv((liquidity + 1) * WAD, _bc()) - 1;
        uint256 max = vault.maxRedeem(alice);
        assertEq(max, expected);
        assertLt(max, s);
        assertLe(vault.previewRedeem(max), liquidity);

        vm.startPrank(alice);
        vm.expectRevert(_illiquid(liquidity, (max + 1) * _bc() / WAD));
        vault.redeem(max + 1, alice, alice);
        assertEq(vault.redeem(max, alice, alice), max * _bc() / WAD);
        vm.stopPrank();
    }

    function test_Redeem_FillMismatch_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 claim = vault.previewRedeem(s);
        vm.mockCall(address(gem), abi.encodeWithSignature("balanceOf(address)", address(vault)), abi.encode(uint256(0)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWsgemVault.FillMismatch.selector, claim, 0));
        vault.redeem(s, alice, alice);
        vm.clearMockedCalls();
    }

    function test_Mint_FillMismatch_Reverts() public {
        // Unreachable through the wsgem's own arithmetic (previewMint rounds the gem up so
        // the mint always yields at least the requested shares); the wsgem's return value
        // is mocked to fall short so the defensive branch is exercised.
        uint256 shares = 5e18;
        uint256 assets = vault.previewMint(shares);
        gem.mint(alice, assets);
        vm.prank(alice);
        gem.approve(address(vault), assets);
        vm.mockCall(address(wsgem), abi.encodeWithSelector(IWsgem.mint.selector, assets), abi.encode(shares - 1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWsgemVault.FillMismatch.selector, shares, shares - 1));
        vault.mint(shares, alice);
        vm.clearMockedCalls();
    }

    function test_Redeem_LeavesNoPendingClaim() public {
        uint256 sa = _depositGem(alice, 100e18);
        uint256 sb = _depositGem(bob, 50e18);
        vm.prank(alice);
        vault.redeem(sa / 2, alice, alice);
        vm.prank(bob);
        vault.redeem(sb, bob, bob);
        vm.prank(alice);
        vault.redeem(sa - sa / 2, alice, alice);
        assertEq(wsgem.totalPending(), 0);
        assertEq(wsgem.redemptionCount(), 3);
        for (uint256 id = 0; id < 3; id++) {
            assertEq(wsgem.redemptionAmount(id), 0);
        }
    }

    /// @dev Execution-only ordering: the vault's atomicity gate, then the wsgem's own
    /// order (window, screen), then the live exit unit, the wsgem's floor, and liquidity.
    function test_Redeem_ErrorOrdering() public {
        uint256 s = _depositGem(alice, 100e18);

        // cooldown + burn closed + paused + dust -> CooldownActive
        act.setCooldown(7);
        _closeBurn();
        pip.pause();
        assertEq(vault.previewRedeem(WAD - 1), (WAD - 1) * vault.lastBurnUnit() / WAD);
        vm.prank(alice);
        vm.expectRevert(_cooldown(7));
        vault.redeem(WAD - 1, alice, alice);
        act.setCooldown(0);

        // burn closed + paused -> MarketClosed
        vm.prank(alice);
        vm.expectRevert(_marketClosed());
        vault.redeem(s, alice, alice);
        _openBurn();

        // banned vault + paused -> NotAuthorized
        gem.ban(address(vault));
        vm.prank(alice);
        vm.expectRevert(_notAuthorized(address(vault)));
        vault.redeem(s, alice, alice);
        gem.unban(address(vault));

        // paused + dust -> InvalidPrice
        vm.prank(alice);
        vm.expectRevert(_invalidPrice());
        vault.redeem(WAD - 1, alice, alice);
        pip.poke(initNavprice);

        // dust + thin -> DustThreshold
        _setLiquidity(0);
        vm.prank(alice);
        vm.expectRevert(_dust(WAD));
        vault.redeem(WAD - 1, alice, alice);

        // thin alone -> InsufficientLiquidity (the claim is quoted pro-rata after a smelt)
        _smeltVault(1);
        uint256 release = _wsgemFor(s);
        uint256 claim = release * _bc() / WAD;
        assertEq(vault.previewRedeem(s), claim);
        vm.prank(alice);
        vm.expectRevert(_illiquid(0, claim));
        vault.redeem(s, alice, alice);
    }

    function test_Withdraw_DeliversExactAssets_BurnsCeilShares() public {
        uint256 s = _depositGem(alice, 1000e18);
        uint256 a = 500e18 + 7;
        uint256 expectedShares = _ceilDiv(a * WAD, _bc());
        assertEq(vault.previewWithdraw(a), expectedShares);
        uint256 claim = expectedShares * _bc() / WAD;

        vm.prank(alice);
        uint256 shares = vault.withdraw(a, alice, alice);

        assertEq(shares, expectedShares);
        assertEq(gem.balanceOf(alice), a);
        assertEq(vault.balanceOf(alice), s - shares);
        assertEq(gem.balanceOf(alice) + gem.balanceOf(address(vault)), claim);
        assertLe(claim - a, _bc() / WAD + 1);
        assertEq(wsgem.balanceOf(address(vault)), vault.totalSupply());
    }

    function test_Withdraw_ToOtherReceiver() public {
        _depositGem(alice, 100e18);
        vm.prank(alice);
        vault.withdraw(10e18, bob, alice);
        assertEq(gem.balanceOf(bob), 10e18);
        assertEq(gem.balanceOf(alice), 0);
    }

    function test_Withdraw_ByOperatorWithAllowance() public {
        _depositGem(alice, 100e18);
        uint256 shares = vault.previewWithdraw(10e18);
        vm.prank(alice);
        vault.approve(bob, shares);
        vm.prank(bob);
        assertEq(vault.withdraw(10e18, bob, alice), shares);
        assertEq(gem.balanceOf(bob), 10e18);
        assertEq(vault.allowance(alice, bob), 0);
    }

    function test_Withdraw_ByOperatorWithoutAllowance_Reverts() public {
        _depositGem(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        vault.withdraw(10e18, bob, alice);
    }

    function test_Withdraw_EmitsWithdrawEvent() public {
        _depositGem(alice, 100e18);
        uint256 shares = vault.previewWithdraw(10e18);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Withdraw(alice, bob, alice, 10e18, shares);
        vault.withdraw(10e18, bob, alice);
    }

    function test_Withdraw_Zero_IsNoop() public {
        _depositGem(alice, 100e18);
        act.pauseMarket();
        pip.pause();
        assertEq(vault.previewWithdraw(0), 0);
        vm.prank(alice);
        assertEq(vault.withdraw(0, alice, alice), 0);
    }

    function test_Withdraw_BelowOneShare_Reverts() public {
        _depositGem(alice, 100e18);
        uint256 a = _bc() / 2;
        assertEq(vault.previewWithdraw(a), _ceilDiv(a * WAD, _bc())); // quoted, not gated
        assertLt(vault.previewWithdraw(a), WAD);
        vm.prank(alice);
        vm.expectRevert(_dust(WAD));
        vault.withdraw(a, alice, alice);
    }

    function test_Withdraw_ThinLiquidity_Reverts() public {
        _depositGem(alice, 100e18);
        uint256 a = 10e18;
        uint256 shares = _ceilDiv(a * WAD, _bc());
        uint256 claim = shares * _bc() / WAD;
        _setLiquidity(a - 1);
        assertEq(vault.previewWithdraw(a), shares); // quoted, not gated
        vm.prank(alice);
        vm.expectRevert(_illiquid(a - 1, claim));
        vault.withdraw(a, alice, alice);
        assertLt(vault.maxWithdraw(alice), a);
    }

    function test_Withdraw_ExceedsBalance_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        gem.mint(address(wsgem), 1e24); // liquidity is not the limiting factor here
        uint256 tooMuch = vault.convertToAssets(s) + 2 * _bc();
        assertGt(vault.previewWithdraw(tooMuch), s);
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20: burn amount exceeds balance"));
        vault.withdraw(tooMuch, alice, alice);
        // A bigger second holder does not change the owner's own bound.
        _depositGem(bob, 300e18);
        vm.prank(alice);
        vm.expectRevert(bytes("ERC20: burn amount exceeds balance"));
        vault.withdraw(tooMuch, alice, alice);
    }

    function test_Withdraw_NothingBacks_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        _smeltVault(s);
        assertEq(vault.deficit(), s);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.convertToShares(_nav()), type(uint256).max);
        assertEq(vault.convertToShares(0), 0);
        uint256 bc = _bc();
        assertEq(vault.previewWithdraw(bc), type(uint256).max);
        vm.startPrank(alice);
        vm.expectRevert(_insolvent(s));
        vault.withdraw(bc, alice, alice); // no external call in the args: expectRevert arms the next call
        vm.expectRevert(_dust(WAD));
        vault.redeem(s, alice, alice);
        vm.expectRevert(_insolvent(s));
        vault.redeemToWsgem(s, alice, alice);
        vm.stopPrank();
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeemToWsgem(alice), 0);
    }

    function test_Withdraw_ProRataInDeficit() public {
        uint256 s = _depositGem(alice, 1000e18);
        _smeltVault(400e18);
        uint256 held = s - 400e18;
        uint256 a = 100e18;
        uint256 needed = _ceilDiv(a * WAD, _bc());
        uint256 expectedShares = _ceilDiv(needed * s, held);
        assertEq(vault.previewWithdraw(a), expectedShares);

        vm.prank(alice);
        uint256 burned = vault.withdraw(a, alice, alice);

        assertEq(burned, expectedShares);
        assertEq(gem.balanceOf(alice), a);
        assertEq(vault.balanceOf(alice), s - burned);
        uint256 released = burned * held / s;
        assertEq(released, needed, "withdraw releases exactly the wsgem it needs");
        assertEq(wsgem.balanceOf(address(vault)), held - released);
    }

    function test_Redeem_ProRataInDeficit() public {
        uint256 s = _depositGem(alice, 1000e18);
        _smeltVault(400e18);
        uint256 held = s - 400e18;
        uint256 claim = held * _bc() / WAD;
        assertEq(vault.previewRedeem(s), claim);
        assertEq(vault.maxRedeem(alice), s);
        assertEq(vault.maxWithdraw(alice), claim);
        vm.prank(alice);
        assertEq(vault.redeem(s, alice, alice), claim);
        assertEq(gem.balanceOf(alice), claim);
        assertEq(vault.totalSupply(), 0);
        assertEq(wsgem.balanceOf(address(vault)), 0);
        assertEq(vault.deficit(), 0);
    }

    function testFuzz_PreviewRedeem_MatchesRedeem(uint256 shares, uint256 nav, uint256 bpsout) public {
        nav = bound(nav, 1e15, 1e27);
        bpsout = bound(bpsout, 0, 9999);
        shares = bound(shares, WAD, 1e26);
        _setNavAndFees(nav, 0, bpsout);
        _mintShares(alice, shares);
        uint256 excess = _surplus();

        uint256 expected = shares * _bc() / WAD;
        assertEq(_bc(), _burncostOf(nav, bpsout));
        assertEq(vault.previewRedeem(shares), expected);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), expected);
        assertEq(gem.balanceOf(alice), expected);
        assertEq(vault.totalSupply(), 0);
        assertEq(wsgem.balanceOf(address(vault)), excess);
        assertEq(wsgem.totalPending(), 0);
    }

    function testFuzz_PreviewWithdraw_MatchesWithdraw(uint256 assets, uint256 nav, uint256 bpsout) public {
        nav = bound(nav, 1e15, 1e27);
        bpsout = bound(bpsout, 0, 9999);
        _setNavAndFees(nav, 0, bpsout);
        _mintShares(alice, 1e27);
        uint256 excess = _surplus();
        uint256 unit = _bc();
        assets = bound(assets, unit, vault.maxWithdraw(alice));

        uint256 expectedShares = _ceilDiv(assets * WAD, unit);
        assertEq(vault.previewWithdraw(assets), expectedShares);
        uint256 claim = expectedShares * unit / WAD;
        assertGe(claim, assets);

        vm.prank(alice);
        assertEq(vault.withdraw(assets, alice, alice), expectedShares);
        assertEq(gem.balanceOf(alice), assets);
        assertEq(gem.balanceOf(address(vault)), claim - assets);
        assertLe(claim - assets, unit / WAD + 1);
        assertEq(wsgem.balanceOf(address(vault)), vault.totalSupply() + excess);
        assertEq(wsgem.totalPending(), 0);
    }

    function testFuzz_DepositWsgemThenRedeem_EqualsDirectRedeem(uint256 w, uint256 nav, uint256 bpsout) public {
        nav = bound(nav, 1e15, 1e27);
        bpsout = bound(bpsout, 0, 9999);
        w = bound(w, WAD, 1e26);
        _setNavAndFees(nav, 0, bpsout);
        uint256 gemIn = w * _mc() / WAD + _mc();
        uint256 outA = _mintWsgem(alice, gemIn);
        uint256 outB = _mintWsgem(bob, gemIn);
        assertGe(outA, w);
        assertGe(outB, w);

        vm.startPrank(alice);
        wsgem.approve(address(vault), w);
        vault.depositWsgem(w, alice);
        uint256 viaVault = vault.redeem(w, alice, alice);
        vm.stopPrank();

        uint256 before = gem.balanceOf(bob);
        vm.prank(bob);
        wsgem.redeem(w);
        uint256 direct = gem.balanceOf(bob) - before;

        assertEq(viaVault, direct);
        assertEq(gem.balanceOf(alice), direct);
    }

    function testFuzz_Withdraw_NeverCheaperThanDirect(uint256 a, uint256 nav, uint256 bpsout) public {
        nav = bound(nav, 1e15, 1e27);
        bpsout = bound(bpsout, 0, 9999);
        _setNavAndFees(nav, 0, bpsout);
        _mintShares(alice, 1e27);
        uint256 unit = _bc();
        a = bound(a, unit, vault.maxWithdraw(alice));
        uint256 s = vault.previewWithdraw(a);
        assertGe(s * unit / WAD, a);
        assertLt((s - 1) * unit / WAD, a);
    }

    function testFuzz_Cycle_CostsExactlyBpsout_OthersUnmoved(uint256 a, uint256 nav, uint256 bpsout) public {
        nav = bound(nav, 1e15, 1e27);
        bpsout = bound(bpsout, 0, 9999);
        _setNavAndFees(nav, 0, bpsout);
        uint256 unit = _mc();
        a = bound(a, unit, unit * 1e8);

        uint256 sb = _depositGem(bob, unit * 1e9);
        uint256 bobAssets = vault.convertToAssets(sb);
        uint256 bobRedeem = vault.previewRedeem(sb);
        uint256 bobMaxWithdraw = vault.maxWithdraw(bob);
        uint256 price = vault.convertToAssets(WAD);
        assertEq(_surplus(), 0);

        // Vault lap.
        uint256 s = _depositGem(alice, a);
        vm.prank(alice);
        uint256 g = vault.redeem(s, alice, alice);
        assertEq(g, s * _bc() / WAD);
        assertLe(g, a, "a lap never gains");

        // Direct lap with the same gem.
        uint256 w = _mintWsgem(carol, a);
        assertEq(w, s);
        vm.prank(carol);
        wsgem.redeem(w);
        assertEq(gem.balanceOf(carol), g);

        // Everyone else is exactly where they were.
        assertEq(vault.balanceOf(bob), sb);
        assertEq(vault.convertToAssets(sb), bobAssets);
        assertEq(vault.previewRedeem(sb), bobRedeem);
        assertEq(vault.maxWithdraw(bob), bobMaxWithdraw);
        assertEq(vault.convertToAssets(WAD), price);
        assertEq(_surplus(), 0);
        assertEq(gem.balanceOf(address(vault)), 0);
    }

    function test_BpsoutMax_FailsClosed() public {
        uint256 s = _depositGem(alice, 100e18);
        act.setBpsout(10_000);
        assertEq(_bc(), 0);
        assertGt(_nav(), 0);
        assertEq(vault.previewRedeem(WAD), 0); // an honest zero
        // No share count delivers gem: the impossible quote, never a revert.
        assertEq(vault.previewWithdraw(1), type(uint256).max);
        assertEq(vault.previewWithdraw(s), type(uint256).max);
        assertEq(vault.previewWithdraw(0), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        vm.startPrank(alice);
        vm.expectRevert(_invalidPrice());
        vault.redeem(s, alice, alice);
        vm.expectRevert(_invalidPrice());
        vault.withdraw(1, alice, alice);
        vm.stopPrank();
        // Gross accounting and the wsgem leg are unaffected.
        assertEq(vault.convertToAssets(WAD), _nav());
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(s, alice, alice), s);
    }

    /*//////////////////////////////////////////////////////////////
                    3.4 WSGEM LEGS (1:1, ORACLE-FREE)
    //////////////////////////////////////////////////////////////*/

    function test_DepositWsgem_OneToOne() public {
        uint256 out = _mintWsgem(alice, 1000e18);
        vm.startPrank(alice);
        wsgem.approve(address(vault), out);
        assertEq(vault.previewDepositWsgem(out), out);
        uint256 shares = vault.depositWsgem(out, alice);
        vm.stopPrank();
        assertEq(shares, out);
        assertEq(vault.balanceOf(alice), out);
        assertEq(wsgem.balanceOf(address(vault)), out);
        assertEq(wsgem.balanceOf(alice), 0);
    }

    function test_DepositWsgem_ToOtherReceiver() public {
        uint256 out = _mintWsgem(alice, 100e18);
        vm.startPrank(alice);
        wsgem.approve(address(vault), out);
        vault.depositWsgem(out, bob);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), out);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_DepositWsgem_EmitsDepositWsgemEvent() public {
        uint256 out = _mintWsgem(alice, 100e18);
        vm.startPrank(alice);
        wsgem.approve(address(vault), out);
        vm.expectEmit(true, true, true, true, address(vault));
        emit DepositWsgem(alice, bob, out);
        vault.depositWsgem(out, bob);
        vm.stopPrank();
    }

    function test_DepositWsgem_NoDustFloor() public {
        _mintWsgem(alice, 100e18);
        vm.startPrank(alice);
        wsgem.approve(address(vault), 1);
        assertEq(vault.depositWsgem(1, alice), 1);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), 1);
    }

    function test_DepositWsgem_Zero_IsNoop() public {
        act.pauseMarket();
        pip.pause();
        assertEq(vault.previewDepositWsgem(0), 0);
        vm.prank(alice);
        assertEq(vault.depositWsgem(0, alice), 0);
        assertEq(vault.totalSupply(), 0);
    }

    function _assertWsgemLegsLive(uint256 s) internal {
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxRedeemToWsgem(alice), s);
        assertEq(vault.maxDepositWsgem(alice), type(uint256).max);
        assertEq(vault.previewRedeemToWsgem(s), s);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(s, alice, alice), s);
        vm.startPrank(alice);
        wsgem.approve(address(vault), s);
        assertEq(vault.previewDepositWsgem(s), s);
        assertEq(vault.depositWsgem(s, alice), s);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), s);
    }

    function test_WsgemLegs_LiveWhileOraclePaused() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.pause();
        _assertWsgemLegsLive(s);
    }

    function test_WsgemLegs_LiveWhileMarketClosed() public {
        uint256 s = _depositGem(alice, 100e18);
        act.pauseMarket();
        assertFalse(wsgem.mintable());
        assertFalse(wsgem.burnable());
        _assertWsgemLegsLive(s);
    }

    function test_WsgemLegs_LiveWhileCooldownNonZero() public {
        uint256 s = _depositGem(alice, 100e18);
        act.setCooldown(1 days);
        assertEq(vault.maxDeposit(alice), type(uint256).max); // gem-in is not affected by cooldown
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeemToWsgem(alice), s);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(s, alice, alice), s);
    }

    function test_WsgemLegs_LiveWhileThinLiquidity() public {
        uint256 s = _depositGem(alice, 100e18);
        _setLiquidity(0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeemToWsgem(alice), s);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(s, alice, alice), s);
    }

    function test_DepositWsgem_InDeficit_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        _smeltVault(s / 4);
        uint256 out = _mintWsgem(bob, 10e18);
        vm.startPrank(bob);
        wsgem.approve(address(vault), out);
        assertEq(vault.previewDepositWsgem(out), out); // quoted, not gated
        vm.expectRevert(_insolvent(s / 4));
        vault.depositWsgem(out, bob);
        vm.stopPrank();
        assertEq(vault.maxDepositWsgem(bob), 0);
    }

    function test_RedeemToWsgem_OneToOne() public {
        uint256 s = _depositGem(alice, 100e18);
        assertEq(vault.previewRedeemToWsgem(s), s);
        vm.prank(alice);
        uint256 out = vault.redeemToWsgem(s, alice, alice);
        assertEq(out, s);
        assertEq(wsgem.balanceOf(alice), s);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(wsgem.balanceOf(address(vault)), 0);
    }

    function test_RedeemToWsgem_ToOtherReceiver() public {
        uint256 s = _depositGem(alice, 100e18);
        vm.prank(alice);
        vault.redeemToWsgem(s, bob, alice);
        assertEq(wsgem.balanceOf(bob), s);
        assertEq(wsgem.balanceOf(alice), 0);
    }

    function test_RedeemToWsgem_ByOperatorWithAllowance() public {
        uint256 s = _depositGem(alice, 100e18);
        vm.prank(alice);
        vault.approve(bob, s);
        vm.prank(bob);
        assertEq(vault.redeemToWsgem(s, bob, alice), s);
        assertEq(wsgem.balanceOf(bob), s);
        assertEq(vault.allowance(alice, bob), 0);
    }

    function test_RedeemToWsgem_ByOperatorWithoutAllowance_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        vm.prank(bob);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        vault.redeemToWsgem(s, bob, alice);
    }

    function test_RedeemToWsgem_EmitsRedeemWsgemEvent() public {
        uint256 s = _depositGem(alice, 100e18);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemWsgem(alice, bob, alice, s, s);
        vault.redeemToWsgem(s, bob, alice);
    }

    function test_RedeemToWsgem_EventCarriesProRataRelease() public {
        uint256 s = _depositGem(alice, 100e18);
        _smeltVault(10e18);
        uint256 release = _wsgemFor(s / 2);
        assertLt(release, s / 2);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit RedeemWsgem(alice, bob, alice, s / 2, release);
        vault.redeemToWsgem(s / 2, bob, alice);
    }

    function test_RedeemToWsgem_Zero_IsNoop() public {
        _depositGem(alice, 100e18);
        assertEq(vault.previewRedeemToWsgem(0), 0);
        vm.prank(bob);
        assertEq(vault.redeemToWsgem(0, bob, alice), 0);
    }

    function test_RedeemToWsgem_ProRataInDeficit() public {
        uint256 s = _depositGem(alice, 100e18);
        _smeltVault(10e18);
        uint256 held = s - 10e18;
        assertEq(vault.previewRedeemToWsgem(s), held);
        assertEq(vault.previewRedeemToWsgem(held + 1), (held + 1) * held / s);
        assertLt(vault.previewRedeemToWsgem(held + 1), held + 1);
        assertEq(vault.maxRedeemToWsgem(alice), s);
        vm.startPrank(alice);
        uint256 quarter = s / 4;
        assertEq(vault.redeemToWsgem(quarter, alice, alice), quarter * held / s);
        uint256 rest = vault.balanceOf(alice);
        uint256 heldNow = wsgem.balanceOf(address(vault));
        assertEq(vault.redeemToWsgem(rest, alice, alice), heldNow);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.deficit(), 0);
    }

    function test_MaxRedeemToWsgem_ZeroWhenReleaseRoundsToZero() public {
        uint256 s = _depositGem(bob, 100e18);
        _mintWsgem(alice, 10e18);
        vm.startPrank(alice);
        wsgem.approve(address(vault), 1);
        vault.depositWsgem(1, alice);
        vm.stopPrank();
        _smeltVault(s / 2);
        assertEq(vault.previewRedeemToWsgem(1), 0);
        assertEq(vault.maxRedeemToWsgem(alice), 0);
        assertGt(vault.maxRedeemToWsgem(bob), 0);
        vm.prank(alice);
        vm.expectRevert(_insolvent(vault.deficit()));
        vault.redeemToWsgem(1, alice, alice);
    }

    function testFuzz_PreviewDepositWsgem_MatchesDepositWsgem(uint256 amt) public {
        amt = bound(amt, 1, 1e26);
        uint256 out = _mintWsgem(alice, amt * 2 + _mc());
        assertGe(out, amt);
        vm.startPrank(alice);
        wsgem.approve(address(vault), amt);
        assertEq(vault.previewDepositWsgem(amt), amt);
        assertEq(vault.depositWsgem(amt, alice), amt);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), amt);
    }

    function testFuzz_PreviewRedeemToWsgem_MatchesRedeemToWsgem(uint256 amt) public {
        uint256 s = _depositGem(alice, 1e24);
        amt = bound(amt, 1, s);
        assertEq(vault.previewRedeemToWsgem(amt), amt);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(amt, alice, alice), amt);
        assertEq(wsgem.balanceOf(alice), amt);
        assertEq(vault.balanceOf(alice), s - amt);
    }

    /*//////////////////////////////////////////////////////////////
                       3.5 PREVIEWS NEVER LIE
    //////////////////////////////////////////////////////////////*/

    /// @dev Seeds the vault (alice holds everything) and funds carol's wsgem before the
    /// market state is applied, since the state may close minting.
    function _seedForParity(MarketState memory st) internal {
        _depositGem(alice, 1000e18);
        _depositWsgem(alice, 1000e18);
        _mintWsgem(carol, 3e24);
        vm.prank(carol);
        wsgem.approve(address(vault), type(uint256).max);
        vm.prank(carol);
        gem.approve(address(vault), type(uint256).max);
        _applyState(st);
    }

    function testFuzz_Previews_NeverLie_Deposit(MarketState memory st, uint256 amt) public {
        amt = bound(amt, 0, 1e30);
        _seedForParity(st);
        gem.mint(carol, amt);
        _assertQuoteHonest(
            address(vault),
            abi.encodeCall(vault.previewDeposit, (amt)),
            abi.encodeCall(vault.deposit, (amt, carol)),
            carol
        );
    }

    function testFuzz_Previews_NeverLie_Mint(MarketState memory st, uint256 shares) public {
        shares = bound(shares, 0, 1e30);
        _seedForParity(st);
        (bool ok, bytes memory ret) = address(vault).staticcall(abi.encodeCall(vault.previewMint, (shares)));
        if (ok) gem.mint(carol, abi.decode(ret, (uint256)));
        _assertQuoteHonest(
            address(vault),
            abi.encodeCall(vault.previewMint, (shares)),
            abi.encodeCall(vault.mint, (shares, carol)),
            carol
        );
    }

    function testFuzz_Previews_NeverLie_Withdraw(MarketState memory st, uint256 assets) public {
        assets = bound(assets, 0, 1e30);
        _seedForParity(st);
        _assertQuoteHonest(
            address(vault),
            abi.encodeCall(vault.previewWithdraw, (assets)),
            abi.encodeCall(vault.withdraw, (assets, alice, alice)),
            alice
        );
    }

    function testFuzz_Previews_NeverLie_Redeem(MarketState memory st, uint256 shares) public {
        shares = bound(shares, 0, 1e30);
        _seedForParity(st);
        _assertQuoteHonest(
            address(vault),
            abi.encodeCall(vault.previewRedeem, (shares)),
            abi.encodeCall(vault.redeem, (shares, alice, alice)),
            alice
        );
    }

    function testFuzz_Previews_NeverLie_DepositWsgem(MarketState memory st, uint256 amt) public {
        amt = bound(amt, 0, 1e24);
        _seedForParity(st);
        _assertQuoteHonest(
            address(vault),
            abi.encodeCall(vault.previewDepositWsgem, (amt)),
            abi.encodeCall(vault.depositWsgem, (amt, carol)),
            carol
        );
    }

    function testFuzz_Previews_NeverLie_RedeemToWsgem(MarketState memory st, uint256 shares) public {
        shares = bound(shares, 0, 1e30);
        _seedForParity(st);
        _assertQuoteHonest(
            address(vault),
            abi.encodeCall(vault.previewRedeemToWsgem, (shares)),
            abi.encodeCall(vault.redeemToWsgem, (shares, alice, alice)),
            alice
        );
    }

    /*//////////////////////////////////////////////////////////////
                 3.6 MAX* NEVER REVERT AND ARE TIGHT
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Max_NeverRevert(MarketState memory st, bool banVault) public {
        _depositGem(alice, 1000e18);
        _applyState(st);
        if (banVault) gem.ban(address(vault));
        uint256 md = vault.maxDeposit(alice);
        uint256 mm = vault.maxMint(alice);
        uint256 mw = vault.maxWithdraw(alice);
        uint256 mr = vault.maxRedeem(alice);
        uint256 mrw = vault.maxRedeemToWsgem(alice);
        uint256 mdw = vault.maxDepositWsgem(alice);
        if (banVault) {
            assertEq(md + mm + mw + mr + mrw + mdw, 0);
        }
        if (md == 0) assertEq(mm, 0);
        if (mr == 0) assertEq(mw, 0);
    }

    function testFuzz_MaxDeposit_ExecutableAndTight(MarketState memory st, uint256 capSeed) public {
        _depositGem(alice, 1000e18);
        _applyState(st);
        // Force a finite capacity so the bound is reachable.
        uint256 supply = wsgem.totalSupply();
        act.setCapacity(bound(capSeed, supply, supply + 1e25));

        uint256 max = vault.maxDeposit(carol);
        uint256 unit = _mc();
        assertLt(max, type(uint256).max);
        vm.startPrank(carol);
        gem.approve(address(vault), type(uint256).max);
        if (max > 0) {
            gem.mint(carol, max + 1);
            vm.expectRevert(_exceedsCap());
            vault.deposit(max + 1, carol);
            assertEq(vault.deposit(max, carol), max * WAD / unit);
        } else {
            uint256 probe = unit == 0 ? 1 : unit;
            gem.mint(carol, probe);
            vm.expectRevert();
            vault.deposit(probe, carol);
        }
        vm.stopPrank();
    }

    function testFuzz_MaxMint_ExecutableAndTight(MarketState memory st, uint256 capSeed) public {
        _depositGem(alice, 1000e18);
        _applyState(st);
        uint256 supply = wsgem.totalSupply();
        act.setCapacity(bound(capSeed, supply, supply + 1e25));

        uint256 max = vault.maxMint(carol);
        assertLt(max, type(uint256).max);
        vm.startPrank(carol);
        gem.approve(address(vault), type(uint256).max);
        if (max > 0) {
            // Execution pulls the gem before the wsgem can refuse, so the +1 probe must
            // be funded for ExceedsCap (not a balance underflow) to surface.
            gem.mint(carol, vault.previewMint(max + 1));
            vm.expectRevert(_exceedsCap());
            vault.mint(max + 1, carol);
            uint256 assets = vault.previewMint(max);
            assertEq(vault.mint(max, carol), assets);
            assertEq(vault.balanceOf(carol), max);
        } else {
            gem.mint(carol, 1e30);
            vm.expectRevert();
            vault.mint(WAD, carol);
        }
        vm.stopPrank();
    }

    function testFuzz_MaxWithdraw_ExecutableAndTight(MarketState memory st) public {
        _depositGem(alice, 1000e18);
        _depositWsgem(alice, 1000e18);
        _applyState(st);

        uint256 max = vault.maxWithdraw(alice);
        uint256 maxShares = vault.maxRedeem(alice);
        vm.startPrank(alice);
        if (max > 0) {
            assertEq(max, vault.previewRedeem(maxShares));
            // Tight in every state, a deficit's pro-rata rounding included.
            vm.expectRevert();
            vault.withdraw(max + 1, alice, alice);
            uint256 burned = vault.withdraw(max, alice, alice);
            assertLe(burned, maxShares);
            assertEq(gem.balanceOf(alice), max);
        } else {
            assertEq(maxShares, 0);
            vm.expectRevert();
            vault.withdraw(1, alice, alice);
        }
        vm.stopPrank();
    }

    function testFuzz_MaxRedeem_ExecutableAndTight(MarketState memory st) public {
        _depositGem(alice, 1000e18);
        _depositWsgem(alice, 1000e18);
        _applyState(st);

        uint256 max = vault.maxRedeem(alice);
        vm.startPrank(alice);
        if (max > 0) {
            assertGe(_wsgemFor(max), WAD);
            // Tight in every state, a deficit's pro-rata rounding included.
            vm.expectRevert();
            vault.redeem(max + 1, alice, alice);
            uint256 expected = _wsgemFor(max) * _bc() / WAD;
            uint256 out = vault.redeem(max, alice, alice);
            assertEq(out, expected);
            assertEq(gem.balanceOf(alice), out);
        } else {
            vm.expectRevert();
            vault.redeem(WAD, alice, alice);
        }
        vm.stopPrank();
    }

    function testFuzz_MaxRedeemToWsgem_ExecutableAndTight(MarketState memory st) public {
        _depositGem(alice, 1000e18);
        _depositWsgem(bob, 500e18);
        _applyState(st);

        uint256 bal = vault.balanceOf(alice);
        uint256 release = _wsgemFor(bal);
        uint256 max = vault.maxRedeemToWsgem(alice);
        assertEq(max, release == 0 ? 0 : bal);
        vm.startPrank(alice);
        vm.expectRevert();
        vault.redeemToWsgem(max + 1, alice, alice);
        if (max > 0) {
            assertEq(vault.redeemToWsgem(max, alice, alice), release);
            assertEq(wsgem.balanceOf(alice), release);
        }
        vm.stopPrank();
    }

    function test_MaxDepositMint_UnlimitedCapacity_NoOverflow() public {
        assertEq(wsgem.capacity(), type(uint256).max);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
        pip.poke(1e27); // mintcost > 1e18: (headroom+1)*unit would overflow without the guard
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxMint(alice), type(uint256).max);
        assertGt(_depositGem(alice, 1e30), 0);
    }

    function test_MaxMint_CapacityBelowSupply_IsZero() public {
        _depositGem(alice, 100e18);
        act.setCapacity(wsgem.totalSupply() - 1);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        uint256 unit = _mc();
        assertEq(vault.previewDeposit(unit), WAD); // quoted, not gated
        gem.mint(alice, unit);
        vm.startPrank(alice);
        gem.approve(address(vault), unit);
        vm.expectRevert(_exceedsCap());
        vault.deposit(unit, alice);
        vm.stopPrank();
    }

    function test_MaxMint_HeadroomBelowOneShare_IsZero() public {
        _depositGem(alice, 100e18);
        act.setCapacity(wsgem.totalSupply() + 0.5e18);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        uint256 unit = _mc();
        assertEq(vault.previewMint(0.5e18), _ceilDiv(0.5e18 * unit, WAD)); // quoted, not gated
        assertEq(vault.previewDeposit(unit), WAD);
        gem.mint(alice, 2 * unit);
        vm.startPrank(alice);
        gem.approve(address(vault), 2 * unit);
        vm.expectRevert(_dust(unit));
        vault.mint(0.5e18, alice);
        vm.expectRevert(_exceedsCap());
        vault.deposit(unit, alice);
        vm.stopPrank();
    }

    function test_MaxMint_ExactHeadroom() public {
        _depositGem(alice, 100e18);
        uint256 headroom = 5e18;
        act.setCapacity(wsgem.totalSupply() + headroom);
        uint256 unit = _mc();
        uint256 md = vault.maxDeposit(alice);
        assertEq(md, _ceilDiv((headroom + 1) * unit, WAD) - 1);
        assertLe(md * WAD / unit, headroom);
        assertGt((md + 1) * WAD / unit, headroom);
        assertEq(vault.maxMint(alice), md * WAD / unit);
    }

    function test_Max_ZeroWhenMintClosed() public {
        uint256 s = _depositGem(alice, 100e18);
        _closeMint();
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxRedeem(alice), s);
        assertEq(vault.maxDepositWsgem(alice), type(uint256).max);
    }

    function test_Max_ZeroWhenBurnClosed() public {
        uint256 s = _depositGem(alice, 100e18);
        _closeBurn();
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxRedeemToWsgem(alice), s);
    }

    function test_Max_ZeroWhenOraclePaused() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.pause();
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxRedeemToWsgem(alice), s);
        assertEq(vault.maxDepositWsgem(alice), type(uint256).max);
    }

    function test_Max_DepositSideZeroInDeficit_RedeemSideProRata() public {
        uint256 s = _depositGem(alice, 100e18);
        _smeltVault(30e18);
        uint256 held = s - 30e18;
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxDepositWsgem(alice), 0);
        // Every share is still redeemable; it just releases less.
        assertEq(vault.maxRedeem(alice), s);
        assertEq(vault.maxWithdraw(alice), held * _bc() / WAD);
        assertEq(vault.maxRedeemToWsgem(alice), s);
        assertEq(vault.previewRedeemToWsgem(s), held);
    }

    function test_Max_ZeroWhenCooldownNonZero() public {
        uint256 s = _depositGem(alice, 100e18);
        act.setCooldown(365 days);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        assertEq(vault.maxRedeemToWsgem(alice), s);
    }

    function test_MaxRedeem_BelowOneShare_IsZero() public {
        _mintWsgem(alice, 10e18);
        vm.startPrank(alice);
        wsgem.approve(address(vault), 0.9e18);
        vault.depositWsgem(0.9e18, alice);
        vm.stopPrank();
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeemToWsgem(alice), 0.9e18);
    }

    function test_MaxRedeem_LiquidityBound_Tight() public {
        uint256 s = _depositGem(alice, 1000e18);
        uint256 liquidity = 300e18;
        _setLiquidity(liquidity);
        uint256 unit = _bc();
        uint256 expected = _ceilDiv((liquidity + 1) * WAD, unit) - 1;
        assertLt(expected, s);
        assertEq(vault.maxRedeem(alice), expected);
        assertLe(expected * unit / WAD, liquidity);
        assertGt((expected + 1) * unit / WAD, liquidity);
        assertEq(vault.maxWithdraw(alice), expected * unit / WAD);
    }

    function test_MaxRedeem_DeficitProRata() public {
        uint256 s = _depositGem(alice, 1000e18);
        _smeltVault(400e18);
        assertEq(vault.maxRedeem(alice), s);
        assertEq(vault.maxRedeemToWsgem(alice), s);
        assertEq(vault.maxWithdraw(alice), (s - 400e18) * _bc() / WAD);
        assertEq(vault.previewRedeemToWsgem(s), s - 400e18);
        // The liquidity bound still applies to the pro-rata release.
        _setLiquidity((s - 400e18) * _bc() / WAD / 2);
        uint256 max = vault.maxRedeem(alice);
        assertLt(max, s);
        assertLe(vault.previewRedeem(max), gem.balanceOf(address(wsgem)));
        vm.prank(alice);
        vault.redeem(max, alice, alice);
    }

    /// @dev In a deficit more than one share count maps to the same pro-rata wsgem release,
    /// so the liquidity-bounded release must map back to the LAST share count on its
    /// plateau, not the first: otherwise redeem(maxRedeem + 1) still fits the liquidity.
    /// Swept across consecutive liquidity values so every plateau phase is hit.
    function test_MaxRedeem_DeficitLiquidityBound_Tight() public {
        uint256 s = _depositGem(alice, 1000e18);
        _smeltVault(400e18);
        uint256 base = vault.previewRedeem(s) / 2;
        for (uint256 i = 0; i < 8; i++) {
            uint256 liquidity = base + i;
            _setLiquidity(liquidity);
            uint256 max = vault.maxRedeem(alice);
            assertLt(max, s);
            assertGe(_wsgemFor(max), WAD);
            assertLe(vault.previewRedeem(max), liquidity, "maxRedeem must fit the liquidity");
            assertGt(vault.previewRedeem(max + 1), liquidity, "maxRedeem + 1 must not fit");
            assertEq(vault.maxWithdraw(alice), vault.previewRedeem(max), "maxWithdraw is the quote of maxRedeem");
        }
        uint256 liq = gem.balanceOf(address(wsgem));
        uint256 maxShares = vault.maxRedeem(alice);
        uint256 maxAssets = vault.maxWithdraw(alice);
        vm.startPrank(alice);
        vm.expectRevert(_illiquid(liq, vault.previewRedeem(vault.previewWithdraw(maxAssets + 1))));
        vault.withdraw(maxAssets + 1, alice, alice);
        vm.expectRevert(_illiquid(liq, vault.previewRedeem(maxShares + 1)));
        vault.redeem(maxShares + 1, alice, alice);
        assertEq(vault.redeem(maxShares, alice, alice), maxAssets);
        vm.stopPrank();
    }

    function test_MaxRedeem_OwnerBalanceBound() public {
        _depositGem(alice, 1000e18);
        uint256 sb = _depositGem(bob, 10e18);
        assertEq(vault.maxRedeem(bob), sb);
        assertEq(vault.maxWithdraw(bob), sb * _bc() / WAD);
        assertEq(vault.maxRedeem(carol), 0);
        assertEq(vault.maxWithdraw(carol), 0);
    }

    /*//////////////////////////////////////////////////////////////
                  3.7 SHARE PRICE INVARIANCE / INFLATION
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SharePrice_InvariantToFlows(uint8[8] memory ops, uint256[8] memory amts, uint256 nav) public {
        nav = bound(nav, 1e15, 1e27);
        pip.poke(nav);
        uint256 unit = _mc();
        _mintShares(alice, 1e24);
        _depositWsgem(bob, unit * 1000);
        vm.prank(carol);
        gem.approve(address(vault), type(uint256).max);
        vm.prank(carol);
        wsgem.approve(address(vault), type(uint256).max);

        for (uint256 i = 0; i < 8; i++) {
            uint256 op = ops[i] % 8;
            uint256 amt = amts[i];
            if (op == 0) {
                amt = bound(amt, unit, unit * 1e6);
                gem.mint(carol, amt);
                vm.prank(carol);
                vault.deposit(amt, carol);
            } else if (op == 1) {
                amt = bound(amt, WAD, 1e24);
                gem.mint(carol, vault.previewMint(amt));
                vm.prank(carol);
                vault.mint(amt, carol);
            } else if (op == 2) {
                uint256 max = vault.maxWithdraw(alice);
                if (max >= _bc()) {
                    amt = bound(amt, _bc(), max);
                    vm.prank(alice);
                    vault.withdraw(amt, alice, alice);
                }
            } else if (op == 3) {
                uint256 max = vault.maxRedeem(alice);
                if (max >= WAD) {
                    amt = bound(amt, WAD, max);
                    vm.prank(alice);
                    vault.redeem(amt, alice, alice);
                }
            } else if (op == 4) {
                amt = bound(amt, unit, unit * 1e6);
                _depositWsgem(carol, amt);
            } else if (op == 5) {
                uint256 max = vault.maxRedeemToWsgem(alice);
                if (max > 0) {
                    amt = bound(amt, 1, max);
                    vm.prank(alice);
                    vault.redeemToWsgem(amt, alice, alice);
                }
            } else if (op == 6) {
                _donateWsgem(bound(amt, 1, 1e22));
            } else {
                gem.mint(address(vault), bound(amt, 1, 1e22));
            }
            assertEq(vault.convertToAssets(WAD), nav, "price moved");
            assertEq(vault.totalAssets(), vault.totalSupply() * nav / WAD, "totalAssets not gross");
        }
    }

    function test_InflationAttack_DonationDoesNotMovePrice() public {
        uint256 w = _mintWsgem(carol, 1000e18);
        vm.startPrank(carol);
        wsgem.approve(address(vault), 1);
        vault.depositWsgem(1, carol);
        assertTrue(wsgem.transfer(address(vault), w - 1));
        vm.stopPrank();
        assertEq(vault.totalSupply(), 1);
        assertEq(wsgem.balanceOf(address(vault)), w);

        uint256 victimShares = _depositGem(alice, 1000e18);
        assertEq(victimShares, 1000e18 * WAD / _mc());
        assertEq(vault.convertToAssets(victimShares), victimShares * _nav() / WAD);
        assertEq(vault.maxRedeemToWsgem(carol), 1);
        assertEq(vault.previewRedeem(victimShares), victimShares * _bc() / WAD);
    }

    function test_DonatedGem_DoesNotMovePrice() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 assetsBefore = vault.totalAssets();
        uint256 claim = vault.previewRedeem(s);
        gem.mint(address(vault), 50e18);
        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.previewRedeem(s), claim);
        uint256 before = gem.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(s, alice, alice);
        assertEq(gem.balanceOf(alice) - before, claim);
        assertEq(gem.balanceOf(address(vault)), 50e18);
    }

    function test_Smelt_MarksAccountingDownToBacking() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 assetsBefore = vault.totalAssets();
        _smeltVault(40e18);
        uint256 held = s - 40e18;
        assertEq(vault.deficit(), 40e18);
        assertEq(vault.totalAssets(), held * _nav() / WAD);
        assertLt(vault.totalAssets(), assetsBefore);
        assertEq(vault.convertToAssets(s), held * _nav() / WAD);
        uint256 unitRelease = WAD * held / s;
        assertEq(vault.convertToAssets(WAD), unitRelease * _nav() / WAD);
        // Round trips never gain under the mark-down either.
        assertLe(vault.convertToAssets(vault.convertToShares(50e18)), 50e18);
        assertLe(vault.convertToShares(vault.convertToAssets(s)), s);
        // Donating the shortfall back restores par.
        _donateWsgem(40e18);
        assertEq(vault.totalAssets(), assetsBefore);
        assertEq(vault.convertToAssets(WAD), _nav());
    }

    function test_Deficit_RedemptionsAreProRata_NoFrontRunning() public {
        uint256 sa = _depositGem(alice, 300e18);
        uint256 sb = _depositGem(bob, 100e18);
        uint256 supply = sa + sb;
        _smeltVault(supply / 5);
        uint256 held = wsgem.balanceOf(address(vault));
        uint256 fairA = sa * held / supply;
        uint256 fairB = sb * held / supply;

        // Whoever goes first gets exactly their share; the other is left no worse off.
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(sa, alice, alice), fairA);
        vm.prank(bob);
        uint256 outB = vault.redeemToWsgem(sb, bob, bob);
        assertGe(outB, fairB);
        assertLe(outB, fairB + 1);
        assertEq(vault.totalSupply(), 0);
    }

    function testFuzz_Deficit_ProRataIsOrderIndependent(uint256 sa, uint256 sb, uint256 burnBps, bool aliceFirst)
        public
    {
        sa = bound(sa, WAD, 1e24);
        sb = bound(sb, WAD, 1e24);
        burnBps = bound(burnBps, 1, 9_999);
        uint256 ma = _mintWsgem(alice, sa * _mc() / WAD + _mc());
        uint256 mb = _mintWsgem(bob, sb * _mc() / WAD + _mc());
        assertGe(ma, sa);
        assertGe(mb, sb);
        vm.startPrank(alice);
        wsgem.approve(address(vault), sa);
        vault.depositWsgem(sa, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        wsgem.approve(address(vault), sb);
        vault.depositWsgem(sb, bob);
        vm.stopPrank();

        uint256 supply = sa + sb;
        _smeltVault(supply * burnBps / 10_000);
        uint256 held = wsgem.balanceOf(address(vault));
        uint256 fairA = sa * held / supply;
        uint256 fairB = sb * held / supply;

        uint256 outA;
        uint256 outB;
        if (aliceFirst) {
            vm.prank(alice);
            outA = vault.redeemToWsgem(sa, alice, alice);
            vm.prank(bob);
            outB = vault.redeemToWsgem(sb, bob, bob);
        } else {
            vm.prank(bob);
            outB = vault.redeemToWsgem(sb, bob, bob);
            vm.prank(alice);
            outA = vault.redeemToWsgem(sa, alice, alice);
        }
        assertGe(outA, fairA);
        assertLe(outA, fairA + 1);
        assertGe(outB, fairB);
        assertLe(outB, fairB + 1);
        assertEq(outA + outB, held);
        assertEq(vault.deficit(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                      3.8 ORACLE PAUSE / NAV DOWN
    //////////////////////////////////////////////////////////////*/

    function test_OraclePaused_GemLegsRevert_WsgemLegsLive() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 mu = vault.lastMintUnit();
        uint256 bu = vault.lastBurnUnit();
        pip.pause();
        // Quotes fall back to the last live values.
        assertEq(vault.previewDeposit(mu), WAD);
        assertEq(vault.previewMint(WAD), mu);
        assertEq(vault.previewRedeem(WAD), bu);
        assertEq(vault.previewWithdraw(bu), WAD);
        assertEq(vault.maxDeposit(alice) + vault.maxMint(alice) + vault.maxWithdraw(alice) + vault.maxRedeem(alice), 0);
        // Execution of the gem legs fails closed.
        gem.mint(alice, 2 * mu);
        vm.startPrank(alice);
        gem.approve(address(vault), 2 * mu);
        vm.expectRevert(_invalidPrice());
        vault.deposit(mu, alice);
        vm.expectRevert(_invalidPrice());
        vault.mint(WAD, alice);
        vm.expectRevert(_invalidPrice());
        vault.redeem(WAD, alice, alice);
        vm.expectRevert(_invalidPrice());
        vault.withdraw(bu, alice, alice);
        vm.stopPrank();
        _assertWsgemLegsLive(s);
        pip.poke(initNavprice);
        assertEq(vault.convertToAssets(WAD), initNavprice);
    }

    /// @dev A feed that reverts (rather than reporting 0) must not brick the oracle-free
    /// legs: `_sync()` gives up without touching the fallback, `sync()` reverts
    /// `InvalidPrice`, and the wsgem legs quote and execute 1:1. `s` is alice's whole position.
    function _assertWsgemLegsLiveUnrefreshed(uint256 s) internal {
        uint256 nav0 = vault.lastNav();
        uint256 mu0 = vault.lastMintUnit();
        uint256 bu0 = vault.lastBurnUnit();
        vm.expectRevert(_invalidPrice());
        vault.sync();
        assertEq(vault.maxRedeemToWsgem(alice), s);
        assertEq(vault.maxDepositWsgem(alice), type(uint256).max);
        assertEq(vault.previewRedeemToWsgem(s), s);
        assertEq(vault.previewDepositWsgem(s), s);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(s, alice, alice), s);
        vm.startPrank(alice);
        wsgem.approve(address(vault), s);
        assertEq(vault.depositWsgem(s, alice), s);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), s);
        assertEq(vault.lastNav(), nav0, "fallback touched");
        assertEq(vault.lastMintUnit(), mu0, "fallback touched");
        assertEq(vault.lastBurnUnit(), bu0, "fallback touched");
    }

    /// @dev `MaseerGate.file` is unbounded (unlike `setBpsout`), so governance can file a
    /// bpsout above 10000 and `burncost()` then underflows. Gem-out and its quotes revert
    /// with the wsgem's panic; gem-in never reads `burncost()` and is served.
    function test_FeedReverts_Burncost_WsgemLegsLive() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.poke(1.2e18); // a refresh would now move lastNav
        act.file("bpsout", 10_001);
        vm.expectRevert(stdError.arithmeticError);
        wsgem.burncost();

        _assertWsgemLegsLiveUnrefreshed(s);

        vm.startPrank(alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.redeem(WAD, alice, alice);
        vm.expectRevert(stdError.arithmeticError);
        vault.withdraw(WAD, alice, alice);
        vm.stopPrank();
        vm.expectRevert(stdError.arithmeticError);
        vault.previewRedeem(WAD);
        vm.expectRevert(stdError.arithmeticError);
        vault.maxRedeem(alice);
        assertEq(_depositGem(bob, _mc()), WAD);
        assertEq(vault.lastNav(), initNavprice);

        act.setBpsout(25);
        _depositGem(bob, _mc());
        assertEq(vault.lastNav(), 1.2e18);
        assertEq(vault.lastBurnUnit(), _bc());
    }

    /// @dev `file("bpsin", ...)` overflows `mintcost()` the same way: gem-in and its quotes
    /// revert, gem-out is served.
    function test_FeedReverts_Mintcost_WsgemLegsLive() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.poke(1.2e18);
        act.file("bpsin", type(uint256).max);
        vm.expectRevert(stdError.arithmeticError);
        wsgem.mintcost();

        _assertWsgemLegsLiveUnrefreshed(s);

        gem.mint(bob, 10e18);
        vm.startPrank(bob);
        gem.approve(address(vault), 10e18);
        vm.expectRevert(stdError.arithmeticError);
        vault.deposit(2e18, bob);
        vm.expectRevert(stdError.arithmeticError);
        vault.mint(WAD, bob);
        vm.stopPrank();
        vm.expectRevert(stdError.arithmeticError);
        vault.previewDeposit(WAD);
        vm.expectRevert(stdError.arithmeticError);
        vault.maxDeposit(bob);
        vm.prank(alice);
        assertEq(vault.redeem(WAD, alice, alice), _bc());
        assertEq(vault.lastNav(), initNavprice);

        act.setBpsin(0);
        vm.prank(alice);
        vault.redeem(WAD, alice, alice);
        assertEq(vault.lastNav(), 1.2e18);
        assertEq(vault.lastMintUnit(), _mc());
    }

    /// @dev A price feed that reverts outright (a broken `pip` upgrade) takes every quote
    /// and both gem legs down with it, and nothing else.
    function test_FeedReverts_Navprice_WsgemLegsLive() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.poke(1.2e18);
        bytes memory pipDown = abi.encodeWithSignature("PipDown()");
        vm.mockCallRevert(address(pip), abi.encodeWithSelector(pip.read.selector), pipDown);
        vm.expectRevert(pipDown);
        wsgem.navprice();

        _assertWsgemLegsLiveUnrefreshed(s);

        gem.mint(bob, 10e18);
        vm.startPrank(bob);
        gem.approve(address(vault), 10e18);
        vm.expectRevert(pipDown);
        vault.deposit(2e18, bob);
        vm.expectRevert(pipDown);
        vault.mint(WAD, bob);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(pipDown);
        vault.redeem(WAD, alice, alice);
        vm.expectRevert(pipDown);
        vault.withdraw(WAD, alice, alice);
        vm.stopPrank();
        vm.expectRevert(pipDown);
        vault.convertToAssets(WAD);
        vm.expectRevert(pipDown);
        vault.totalAssets();
        vm.expectRevert(pipDown);
        vault.oracleLive();

        vm.clearMockedCalls();
        _depositGem(bob, _mc());
        assertEq(vault.lastNav(), 1.2e18);
    }

    /// @dev The refresh reads each feed within a fixed gas budget, so a fee getter that burns
    /// all gas only takes down the gem leg that needs it, exactly as it does on the wsgem's
    /// own path, and the fallback tuple is left untouched.
    function test_FeedBurnsGas_Mintcost_GemOutStillServed() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 w = _mintWsgem(bob, 10e18);
        pip.poke(1.2e18); // a refresh would now move lastNav
        vm.etch(address(act), address(new GasBurningGate(act.mintcost.selector)).code);

        // The wsgem's own redemption reads only burncost and is served at an ordinary budget.
        vm.prank(bob);
        (bool direct,) = address(wsgem).call{gas: 300_000}(abi.encodeCall(wsgem.redeem, (w)));
        assertTrue(direct, "direct redeem");
        // So is the vault's.
        uint256 before = gem.balanceOf(alice);
        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call{gas: 400_000}(abi.encodeCall(vault.redeem, (WAD, alice, alice)));
        assertTrue(ok, "vault redeem");
        assertEq(abi.decode(ret, (uint256)), gem.balanceOf(alice) - before);
        assertEq(vault.lastNav(), initNavprice, "fallback touched");
        assertEq(vault.lastMintUnit(), _mintcostOf(initNavprice, 0), "fallback touched");
        assertEq(vault.lastBurnUnit(), _burncostOf(initNavprice, 25), "fallback touched");

        // Gem-in needs mintcost and fails with the wsgem.
        gem.mint(bob, 10e18);
        vm.startPrank(bob);
        gem.approve(address(vault), 10e18);
        (bool depOk,) = address(vault).call{gas: 400_000}(abi.encodeCall(vault.deposit, (2e18, bob)));
        vm.stopPrank();
        assertFalse(depOk, "gem-in served without mintcost");

        _assertWsgemLegsLiveUnrefreshed(s - WAD);
    }

    function test_FeedBurnsGas_Burncost_GemInStillServed() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.poke(1.2e18);
        vm.etch(address(act), address(new GasBurningGate(act.burncost.selector)).code);

        uint256 amt = _mc();
        gem.mint(bob, amt);
        vm.startPrank(bob);
        gem.approve(address(vault), amt);
        (bool ok, bytes memory ret) = address(vault).call{gas: 400_000}(abi.encodeCall(vault.deposit, (amt, bob)));
        vm.stopPrank();
        assertTrue(ok, "vault deposit");
        assertEq(abi.decode(ret, (uint256)), WAD);
        assertEq(vault.lastNav(), initNavprice, "fallback touched");

        vm.prank(alice);
        (bool redOk,) = address(vault).call{gas: 400_000}(abi.encodeCall(vault.redeem, (WAD, alice, alice)));
        assertFalse(redOk, "gem-out served without burncost");

        _assertWsgemLegsLiveUnrefreshed(s);
    }

    /// @dev An oversized feed response is never copied: the refresh fails closed and the gem
    /// leg that does not need that feed is served.
    function test_FeedReturnsOversized_Mintcost_GemOutStillServed() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.poke(1.2e18);
        vm.mockCall(address(wsgem), abi.encodeWithSelector(IWsgem.mintcost.selector), new bytes(65_536));
        vm.prank(alice);
        (bool ok,) = address(vault).call{gas: 400_000}(abi.encodeCall(vault.redeem, (WAD, alice, alice)));
        assertTrue(ok, "vault redeem");
        assertEq(vault.lastNav(), initNavprice, "fallback touched");
        _assertWsgemLegsLiveUnrefreshed(s - WAD);
        vm.clearMockedCalls();
    }

    /// @dev An oversized `paused()` response is never copied either: gem maxima report 0
    /// without reverting, and the wsgem leg is unaffected.
    function test_OversizedPauseResponse_MaxZeroWithoutRevert() public {
        uint256 s = _depositGem(alice, 100e18);
        vm.mockCall(address(gem), abi.encodeWithSelector(gem.paused.selector), new bytes(512 * 1024));
        bytes4[4] memory maxes =
            [vault.maxDeposit.selector, vault.maxMint.selector, vault.maxWithdraw.selector, vault.maxRedeem.selector];
        for (uint256 i = 0; i < maxes.length; i++) {
            (bool ok, bytes memory ret) =
                address(vault).staticcall{gas: 500_000}(abi.encodeWithSelector(maxes[i], alice));
            assertTrue(ok, "max* reverted");
            assertEq(abi.decode(ret, (uint256)), 0, "max* not zero");
        }
        assertFalse(vault.gemTransfersAvailable());
        assertEq(vault.maxRedeemToWsgem(alice), s);
        vm.clearMockedCalls();
        assertTrue(vault.gemTransfersAvailable());
        assertEq(vault.maxRedeem(alice), s);
    }

    function test_NavDownPoke_RepricesEverything() public {
        uint256 s = _depositGem(alice, 100e18);
        pip.poke(0.9e18);
        assertEq(vault.convertToAssets(s), s * 0.9e18 / WAD);
        assertEq(vault.previewRedeem(s), s * _burncostOf(0.9e18, 25) / WAD);
        assertEq(vault.maxWithdraw(alice), s * _burncostOf(0.9e18, 25) / WAD);
        assertEq(vault.previewDeposit(0.9e18), WAD);
        assertEq(vault.deficit(), 0);
        assertEq(vault.balanceOf(alice), s);
        assertEq(wsgem.balanceOf(address(vault)), s);
    }

    /*//////////////////////////////////////////////////////////////
                            3.9 COMPLIANCE
    //////////////////////////////////////////////////////////////*/

    function test_BannedVault_DepositGem_Reverts() public {
        gem.mint(alice, 100e18);
        vm.startPrank(alice);
        gem.approve(address(vault), 100e18);
        gem.ban(address(vault));
        assertEq(vault.previewDeposit(100e18), 100e18 * WAD / _mc()); // quoted, not gated
        vm.expectRevert(MockGem.AccountBanned.selector);
        vault.deposit(100e18, alice);
        vm.expectRevert(MockGem.AccountBanned.selector);
        vault.mint(WAD, alice);
        vm.stopPrank();
    }

    function test_BannedVault_DepositWsgem_Reverts() public {
        uint256 out = _mintWsgem(alice, 100e18);
        vm.prank(alice);
        wsgem.approve(address(vault), out);
        gem.ban(address(vault));
        vm.startPrank(alice);
        assertEq(vault.previewDepositWsgem(out), out); // quoted, not gated
        vm.expectRevert(_notAuthorized(address(vault)));
        vault.depositWsgem(out, alice);
        vm.stopPrank();
    }

    function test_BannedVault_Redeem_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        gem.ban(address(vault));
        assertEq(vault.previewRedeem(s), s * _bc() / WAD); // quoted, not gated
        assertEq(vault.previewWithdraw(1e18), _ceilDiv(1e18 * WAD, _bc()));
        vm.startPrank(alice);
        vm.expectRevert(_notAuthorized(address(vault)));
        vault.redeem(s, alice, alice);
        vm.expectRevert(_notAuthorized(address(vault)));
        vault.withdraw(1e18, alice, alice);
        vm.stopPrank();
    }

    function test_BannedVault_RedeemToWsgem_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        gem.ban(address(vault));
        assertEq(vault.previewRedeemToWsgem(s), s); // quoted, not gated
        vm.prank(alice);
        vm.expectRevert(_notAuthorized(address(vault)));
        vault.redeemToWsgem(s, alice, alice);
    }

    function test_BannedVault_Unban_Restores() public {
        uint256 s = _depositGem(alice, 100e18);
        gem.ban(address(vault));
        assertEq(vault.maxRedeem(alice), 0);
        gem.unban(address(vault));
        assertEq(vault.maxRedeem(alice), s);
        assertEq(vault.previewRedeem(s), s * _bc() / WAD);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(s / 2, alice, alice), s / 2);
    }

    function test_BannedVault_MaxZero_QuotesUnaffected() public {
        uint256 s = _depositGem(alice, 100e18);
        gem.ban(address(vault));
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxRedeemToWsgem(alice), 0);
        assertEq(vault.maxDepositWsgem(alice), 0);
        assertEq(vault.previewDeposit(_mc()), WAD);
        assertEq(vault.previewMint(WAD), _mc());
        assertEq(vault.previewRedeem(s), s * _bc() / WAD);
        assertEq(vault.previewWithdraw(_bc()), WAD);
        assertEq(vault.previewDepositWsgem(1), 1);
        assertEq(vault.previewRedeemToWsgem(1), 1);
        assertEq(vault.convertToAssets(WAD), _nav());
        assertEq(vault.totalAssets(), s * _nav() / WAD);
    }

    function test_BannedUser_DepositWsgem_Reverts() public {
        uint256 out = _mintWsgem(alice, 100e18);
        vm.prank(alice);
        wsgem.approve(address(vault), out);
        gem.ban(alice);
        // Previews are caller-independent: the ban is not previewed.
        assertEq(vault.previewDepositWsgem(out), out);
        vm.prank(alice);
        vm.expectRevert(_notAuthorized(alice));
        vault.depositWsgem(out, alice);
    }

    function test_BannedUser_DepositGem_GemRejects() public {
        gem.mint(alice, 100e18);
        vm.prank(alice);
        gem.approve(address(vault), 100e18);
        gem.ban(alice);
        vm.prank(alice);
        vm.expectRevert(MockGem.AccountBanned.selector);
        vault.deposit(100e18, alice);
    }

    function test_RedeemToWsgem_BannedReceiver_Reverts() public {
        uint256 s = _depositGem(alice, 100e18);
        gem.ban(bob);
        assertEq(vault.previewRedeemToWsgem(s), s);
        vm.prank(alice);
        vm.expectRevert(_notAuthorized(bob));
        vault.redeemToWsgem(s, bob, alice);
    }

    function test_Redeem_BannedReceiver_GemRejects() public {
        uint256 s = _depositGem(alice, 100e18);
        gem.ban(bob);
        vm.prank(alice);
        vm.expectRevert(MockGem.AccountBanned.selector);
        vault.redeem(s, bob, alice);
        assertEq(vault.balanceOf(alice), s);
        assertEq(gem.balanceOf(bob), 0);
    }

    function test_BannedHolder_VaultSharesStillTransferable() public {
        uint256 s = _depositGem(alice, 100e18);
        gem.ban(alice);
        vm.prank(alice);
        assertTrue(vault.transfer(bob, s));
        assertEq(vault.balanceOf(bob), s);
        vm.prank(bob);
        assertEq(vault.redeemToWsgem(s, bob, bob), s);
    }

    /*//////////////////////////////////////////////////////////////
                          3.10 SMELT / DEFICIT
    //////////////////////////////////////////////////////////////*/

    function test_Deficit_ZeroInNormalOperation() public {
        assertEq(vault.deficit(), 0);
        uint256 s = _depositGem(alice, 100e18);
        _depositWsgem(bob, 50e18);
        assertEq(vault.deficit(), 0);
        vm.prank(alice);
        vault.redeem(s / 2, alice, alice);
        vm.prank(alice);
        vault.redeemToWsgem(s - s / 2, alice, alice);
        assertEq(vault.deficit(), 0);
    }

    function test_IssuerSmelt_CreatesDeficit_BlocksAllDeposits() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 out = _mintWsgem(bob, 10e18);
        gem.mint(bob, 100e18);
        vm.startPrank(bob);
        wsgem.approve(address(vault), out);
        gem.approve(address(vault), 100e18);
        vm.stopPrank();

        _smeltVault(40e18);
        uint256 held = s - 40e18;
        assertEq(vault.deficit(), 40e18);

        // Quotes stay honest quotes; execution fails closed on every deposit leg.
        assertEq(vault.previewDeposit(10e18), 10e18 * WAD / _mc());
        assertEq(vault.previewMint(WAD), _mc());
        assertEq(vault.previewDepositWsgem(out), out);
        vm.startPrank(bob);
        vm.expectRevert(_insolvent(40e18));
        vault.deposit(10e18, bob);
        vm.expectRevert(_insolvent(40e18));
        vault.mint(WAD, bob);
        vm.expectRevert(_insolvent(40e18));
        vault.depositWsgem(out, bob);
        vm.stopPrank();
        assertEq(vault.maxDeposit(bob), 0);
        assertEq(vault.maxMint(bob), 0);
        assertEq(vault.maxDepositWsgem(bob), 0);

        // Redemptions stay live, pro-rata: every share is redeemable for its share of
        // what is left.
        assertEq(vault.previewRedeem(s), held * _bc() / WAD);
        assertEq(vault.previewRedeemToWsgem(s), held);
        assertEq(vault.maxRedeem(alice), s);
        assertEq(vault.maxRedeemToWsgem(alice), s);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(s, alice, alice), held);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.deficit(), 0);
        assertEq(wsgem.balanceOf(address(vault)), 0);
    }

    function test_Insolvent_WinsOverMarketErrors() public {
        uint256 s = _depositGem(alice, 100e18);
        uint256 out = _mintWsgem(bob, 10e18);
        _smeltVault(s / 2);
        act.pauseMarket();
        pip.pause();
        act.setCapacity(0);
        gem.mint(bob, 10e18);
        vm.startPrank(bob);
        gem.approve(address(vault), 10e18);
        wsgem.approve(address(vault), out);
        vm.expectRevert(_insolvent(s / 2));
        vault.deposit(10e18, bob);
        vm.expectRevert(_insolvent(s / 2));
        vault.mint(WAD, bob);
        vm.expectRevert(_insolvent(s / 2));
        vault.depositWsgem(out, bob);
        vm.stopPrank();
    }

    function test_Deficit_ClearedRestoresDeposits() public {
        uint256 s = _depositGem(alice, 100e18);
        _smeltVault(30e18);
        assertEq(vault.deficit(), 30e18);
        assertEq(vault.previewDeposit(10e18), 10e18 * WAD / _mc()); // still quoted
        gem.mint(bob, 10e18);
        vm.startPrank(bob);
        gem.approve(address(vault), 10e18);
        vm.expectRevert(_insolvent(30e18));
        vault.deposit(10e18, bob);
        vm.stopPrank();
        assertLt(vault.previewRedeemToWsgem(s), s);

        _donateWsgem(30e18);
        assertEq(vault.deficit(), 0);
        assertEq(vault.previewDeposit(10e18), 10e18 * WAD / _mc());
        assertGt(_depositGem(bob, 10e18), 0);
        assertEq(vault.previewRedeemToWsgem(s), s);
    }

    function test_MintExcess_CountsTowardHealing() public {
        pip.poke(0.5e18);
        _mintShares(alice, WAD + 1);
        assertEq(_surplus(), 1);
        _smeltVault(1);
        assertEq(vault.deficit(), 0);
        _smeltVault(1);
        assertEq(vault.deficit(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                              3.11 PERMIT
    //////////////////////////////////////////////////////////////*/

    function test_Permit_SetsAllowanceAndNonce() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitter");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, owner, bob, 123e18, 0, deadline);
        vault.permit(owner, bob, 123e18, deadline, v, r, s);
        assertEq(vault.allowance(owner, bob), 123e18);
        assertEq(vault.nonces(owner), 1);
    }

    function test_Permit_Expired_Reverts() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitter");
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, owner, bob, 1e18, 0, deadline);
        vm.expectRevert(bytes("ERC20Permit: expired deadline"));
        vault.permit(owner, bob, 1e18, deadline, v, r, s);
    }

    function test_Permit_InvalidSigner_Reverts() public {
        (address owner,) = makeAddrAndKey("permitter");
        (, uint256 otherPk) = makeAddrAndKey("someone-else");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(otherPk, owner, bob, 1e18, 0, deadline);
        vm.expectRevert(bytes("ERC20Permit: invalid signature"));
        vault.permit(owner, bob, 1e18, deadline, v, r, s);
    }

    function test_Permit_Replay_Reverts() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitter");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, owner, bob, 1e18, 0, deadline);
        vault.permit(owner, bob, 1e18, deadline, v, r, s);
        vm.expectRevert(bytes("ERC20Permit: invalid signature"));
        vault.permit(owner, bob, 1e18, deadline, v, r, s);
    }

    function test_Permit_EnablesOperatorRedeem() public {
        (address owner, uint256 pk) = makeAddrAndKey("permitter");
        uint256 shares = _depositGem(owner, 100e18);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, owner, bob, shares, 0, deadline);
        vm.startPrank(bob);
        vault.permit(owner, bob, shares, deadline, v, r, s);
        uint256 out = vault.redeem(shares, bob, owner);
        vm.stopPrank();
        assertEq(gem.balanceOf(bob), out);
        assertEq(vault.balanceOf(owner), 0);
        assertEq(vault.allowance(owner, bob), 0);
    }
}
