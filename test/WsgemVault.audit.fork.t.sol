// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {DeployWstGbpVault} from "../script/DeployWstGbpVault.s.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";

interface AuditGem {
    function owner() external view returns (address);
    function pause() external;
    function ban(address account) external;
    function isBanned(address account) external view returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Mainnet-fork-only fault injection; never broadcasts transactions.
/// Regression tests for the audit fixes on the real underlying contracts.
contract WsgemVaultAuditForkTest is ForkBase {
    address internal constant WSGEM = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant GEM = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;
    address internal alice = makeAddr("audit-alice");
    WsgemVault internal vault;
    uint256 internal shares;

    function setUp() public {
        if (!_forkOrSkip(vm.envOr("FORK_BLOCK", uint256(0)))) return;
        vault = new WsgemVault("Wren Staked tGBP Vault", "vwstGBP", WSGEM);
        deal(GEM, alice, 200e18);
        vm.startPrank(alice);
        AuditGem(GEM).approve(address(vault), type(uint256).max);
        shares = vault.deposit(100e18, alice);
        vm.stopPrank();
    }

    function _assertGemUnavailable() internal {
        assertTrue(vault.gemPausable());
        assertFalse(vault.gemTransfersAvailable());
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);

        vm.startPrank(alice);
        vm.expectRevert();
        vault.withdraw(2e18, alice, alice);
        vm.expectRevert();
        vault.redeem(shares, alice, alice);
        vm.expectRevert();
        vault.deposit(10e18, alice);
        vm.expectRevert();
        vault.mint(2e18, alice);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_Audit_GemPauseMakesMaximaZeroAndHealthCheckFail() public onlyFork {
        address tokenOwner = AuditGem(GEM).owner();
        vm.prank(tokenOwner);
        AuditGem(GEM).pause();

        _assertGemUnavailable();
        DeployWstGbpVault deployer = new DeployWstGbpVault();
        vm.expectRevert("gem transfers unavailable");
        deployer.check(address(vault), WSGEM, GEM, alice);

        vm.prank(alice);
        assertEq(vault.redeemToWsgem(shares, alice, alice), shares);
    }

    function test_Audit_BannedWsgemMakesMaximaZeroAndHealthCheckFail() public onlyFork {
        address tokenOwner = AuditGem(GEM).owner();
        vm.prank(tokenOwner);
        AuditGem(GEM).ban(WSGEM);
        assertTrue(AuditGem(GEM).isBanned(WSGEM));
        assertTrue(IWsgem(WSGEM).canPass(address(vault)));

        _assertGemUnavailable();
        DeployWstGbpVault deployer = new DeployWstGbpVault();
        vm.expectRevert("gem transfers unavailable");
        deployer.check(address(vault), WSGEM, GEM, alice);

        vm.prank(alice);
        assertEq(vault.redeemToWsgem(shares, alice, alice), shares);
    }

    function test_Audit_LiveGemScreensBannedReceiver() public onlyFork {
        address bannedReceiver = makeAddr("audit-banned-receiver");
        address tokenOwner = AuditGem(GEM).owner();
        vm.prank(tokenOwner);
        AuditGem(GEM).ban(bannedReceiver);
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(shares, bannedReceiver, alice);
    }
}
