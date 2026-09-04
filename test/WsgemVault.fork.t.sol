// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";
import {IWsgemVault} from "../src/interfaces/IWsgemVault.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface IWsgemQueueLike {
    function totalPending() external view returns (uint256);
}

/// @notice Deterministic mainnet-fork suite exercising the vault against the live wstGBP
/// deployment (the first wsgem instance) at a PINNED block, so results never drift with
/// live state and RPC responses cache. Skips without an explicit RPC (see {ForkBase}).
/// Latest-state checks live in WsgemVault.smoke.t.sol.
contract WsgemVaultForkTest is ForkBase {
    // Live instance under test: wstGBP / tGBP on Ethereum mainnet.
    address constant WSGEM = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address constant GEM = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;

    /// @dev 2026-07-22. The wsgem market is open both ways with cooldown 0 at this block;
    /// bump deliberately (or via FORK_BLOCK) when a new baseline is wanted. Historical
    /// state needs an archive-capable RPC — any Alchemy/Infura endpoint qualifies.
    uint256 constant PINNED_BLOCK = 25_589_900;

    WsgemVault internal vault;
    address internal alice = makeAddr("alice");

    function setUp() public {
        if (!_forkOrSkip(vm.envOr("FORK_BLOCK", uint256(PINNED_BLOCK)))) return;
        // Deploying at all proves the constructor's reads and the gem infinite-approve
        // succeed against the live tokens.
        vault = new WsgemVault("Wren Staked tGBP Vault", "vwstGBP", WSGEM);
    }

    function _depositGem(uint256 amt) internal returns (uint256 shares) {
        deal(GEM, alice, amt);
        vm.startPrank(alice);
        IERC20Like(GEM).approve(address(vault), amt);
        shares = vault.deposit(amt, alice);
        vm.stopPrank();
    }

    function testFork_LiveMetadata() public onlyFork {
        assertEq(vault.asset(), GEM);
        assertEq(vault.wsgem(), WSGEM);
        assertEq(vault.gem(), GEM);
        assertEq(vault.decimals(), 18);
        assertEq(IERC20Like(GEM).decimals(), 18);
        assertEq(IERC20Like(WSGEM).name(), "Wren Staked tGBP");
        assertEq(IERC20Like(WSGEM).symbol(), "wstGBP");
    }

    function testFork_SharePrice_EqualsNavprice() public onlyFork {
        uint256 nav = IWsgem(WSGEM).navprice();
        assertGt(nav, 0);
        assertEq(vault.convertToAssets(1e18), nav);
        assertEq(vault.convertToShares(nav), 1e18);
    }

    function testFork_DepositGem_E2E_PreviewParity() public onlyFork {
        uint256 amt = 10_000e18;
        uint256 preview = vault.previewDeposit(amt);
        assertEq(preview, amt * 1e18 / IWsgem(WSGEM).mintcost());

        uint256 shares = _depositGem(amt);

        assertEq(shares, preview);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(IERC20Like(WSGEM).balanceOf(address(vault)), shares);
        assertEq(IERC20Like(GEM).balanceOf(address(vault)), 0);
        assertEq(vault.deficit(), 0);
    }

    function testFork_DepositWsgem_RedeemRoundTrip() public onlyFork {
        // Acquire wsgem the canonical way: gem -> wsgem.mint().
        uint256 amt = 5_000e18;
        deal(GEM, alice, amt);
        vm.startPrank(alice);
        IERC20Like(GEM).approve(WSGEM, amt);
        uint256 wamt = IWsgem(WSGEM).mint(amt);

        IERC20Like(WSGEM).approve(address(vault), wamt);
        uint256 shares = vault.depositWsgem(wamt, alice);
        assertEq(shares, wamt);

        uint256 out = vault.redeemToWsgem(shares, alice, alice);
        vm.stopPrank();

        assertEq(out, wamt);
        assertEq(IERC20Like(WSGEM).balanceOf(alice), wamt);
        assertEq(vault.totalSupply(), 0);
    }

    function testFork_RedeemGem_E2E() public onlyFork {
        uint256 amt = 10_000e18;
        uint256 shares = _depositGem(amt);

        uint256 preview = vault.previewRedeem(shares);
        assertEq(preview, shares * IWsgem(WSGEM).burncost() / 1e18);
        assertEq(vault.maxRedeem(alice), shares);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);

        assertEq(out, preview);
        assertEq(IERC20Like(GEM).balanceOf(alice), out);
        assertLt(out, amt); // the wsgem's exit fee, paid by the redeemer
        assertEq(IWsgemQueueLike(WSGEM).totalPending(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(IERC20Like(GEM).balanceOf(address(vault)), 0);
    }

    /// @dev On the live instance the wsgem's settlement conduit is the wsgem itself, so
    /// settle() cannot thin its gem; the balance is set directly instead. The quote stands
    /// (quotes never account for liquidity); execution fails closed and max* says so.
    function testFork_ThinLiquidity_FailsClosed() public onlyFork {
        uint256 shares = _depositGem(1_000e18);

        uint256 claim = vault.previewRedeem(shares);
        deal(GEM, WSGEM, claim - 1);

        assertEq(vault.previewRedeem(shares), claim, "quote unchanged by liquidity");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IWsgemVault.InsufficientLiquidity.selector, claim - 1, claim));
        vault.redeem(shares, alice, alice);
        assertLt(vault.maxRedeem(alice), shares);
        assertEq(vault.maxWithdraw(alice), vault.previewRedeem(vault.maxRedeem(alice)));

        // The wsgem leg is unaffected.
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(shares, alice, alice), shares);
        assertEq(IERC20Like(WSGEM).balanceOf(alice), shares);
    }

    /// @dev The oracle-pause fallback is seeded by the constructor from the live oracle.
    function testFork_FallbackSeededFromLiveOracle() public onlyFork {
        IWsgem w = IWsgem(WSGEM);
        assertEq(vault.lastNav(), w.navprice());
        assertEq(vault.lastMintUnit(), w.mintcost());
        assertEq(vault.lastBurnUnit(), w.burncost());
        vault.sync(); // live: a no-op refresh
        assertEq(vault.lastNav(), w.navprice());
    }
}
