// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {VaultTestBase} from "./VaultTestBase.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {DeployWsgemVault} from "../script/DeployWsgemVault.s.sol";
import {DeployWstGbpVault} from "../script/DeployWstGbpVault.s.sol";

/// @notice Regression tests for the audit's availability and deployment findings.
contract WsgemVaultAuditTest is VaultTestBase {
    function test_Audit_InvalidExitFeeDoesNotBlockWsgemExit() public {
        uint256 shares = _depositGem(alice, 100e18);
        uint256 outside = _mintWsgem(alice, 10e18);

        // The generic admin setter bypasses setBpsout's upper bound.
        act.file("bpsout", 10_001);
        assertEq(vault.maxRedeemToWsgem(alice), shares);

        vm.prank(alice);
        assertEq(vault.redeemToWsgem(shares, alice, alice), shares);

        vm.prank(alice);
        assertTrue(wsgem.transfer(bob, outside));
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Audit_RevertingOracleAllowsWsgemExitAndKeepsQuotesFailClosed() public {
        uint256 shares = _depositGem(alice, 100e18);
        uint256 outside = _mintWsgem(alice, 10e18);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "oracle unavailable");
        vm.mockCallRevert(address(pip), abi.encodeWithSignature("read()"), reason);

        assertEq(vault.maxRedeemToWsgem(alice), shares);
        assertEq(vault.previewRedeemToWsgem(shares), shares);
        assertGt(vault.lastNav(), 0);
        vm.expectRevert(reason);
        vault.totalAssets();

        vm.prank(alice);
        assertEq(vault.redeemToWsgem(shares, alice, alice), shares);

        vm.prank(alice);
        assertTrue(wsgem.transfer(bob, outside));
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_Audit_RevertingFeeFeedAllowsWsgemDeposits() public {
        uint256 outside = _mintWsgem(alice, 10e18);
        vm.prank(alice);
        wsgem.approve(address(vault), outside);
        act.file("bpsout", 10_001);

        assertEq(vault.maxDepositWsgem(alice), type(uint256).max);
        vm.prank(alice);
        assertEq(vault.depositWsgem(outside, alice), outside);
    }

    function _assertEscapeAndCache(uint256 shares) internal {
        uint256 nav = vault.lastNav();
        uint256 mintUnit = vault.lastMintUnit();
        uint256 burnUnit = vault.lastBurnUnit();
        vm.startPrank(alice);
        assertEq(vault.redeemToWsgem{gas: 250_000}(shares, alice, alice), shares);
        wsgem.approve(address(vault), shares);
        assertEq(vault.depositWsgem{gas: 250_000}(shares, alice), shares);
        vm.stopPrank();
        assertEq(vault.lastNav(), nav);
        assertEq(vault.lastMintUnit(), mintUnit);
        assertEq(vault.lastBurnUnit(), burnUnit);
    }

    function testFuzz_Audit_MalformedPriceReturnDoesNotBlockEscape(uint8 which, uint8 size) public {
        uint256 shares = _depositGem(alice, 100e18);
        pip.poke(1.2e18);
        bytes4[3] memory selectors = [IWsgem.navprice.selector, IWsgem.mintcost.selector, IWsgem.burncost.selector];
        uint256 length = uint256(size) % 65;
        if (length == 32) length = 31;
        vm.mockCall(address(wsgem), abi.encodeWithSelector(selectors[which % 3]), new bytes(length));
        _assertEscapeAndCache(shares);
    }

    function test_Audit_GasBurningOracleDoesNotBlockEscape() public {
        uint256 shares = _depositGem(alice, 100e18);
        // Infinite loop in the price feed; the wrapper must bound its optional reads.
        vm.etch(address(pip), hex"5b600056");
        _assertEscapeAndCache(shares);
    }

    function test_Audit_OversizedReturnDoesNotBlockEscape() public {
        uint256 shares = _depositGem(alice, 100e18);
        vm.mockCall(address(wsgem), abi.encodeWithSelector(IWsgem.burncost.selector), new bytes(65_536));
        _assertEscapeAndCache(shares);
    }

    function _assertGemUnavailable() internal view {
        assertFalse(vault.gemTransfersAvailable());
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_Audit_GemPauseMakesLimitsZeroAndHealthCheckFail() public {
        uint256 shares = _depositGem(alice, 100e18);
        gem.pause();
        assertTrue(vault.gemPausable());
        _assertGemUnavailable();
        DeployWsgemVault deployer = new DeployWsgemVault();
        vm.expectRevert("gem transfers unavailable");
        deployer.check(address(vault), address(wsgem), address(gem), alice);
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(shares, alice, alice), shares);
        gem.unpause();
        assertTrue(vault.gemTransfersAvailable());
    }

    function test_Audit_BannedWsgemMakesLimitsZeroAndKeepsEscapeLive() public {
        uint256 shares = _depositGem(alice, 100e18);
        gem.ban(address(wsgem));
        _assertGemUnavailable();
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(shares, alice, alice), shares);
        gem.unban(address(wsgem));
        assertTrue(vault.gemTransfersAvailable());
    }

    function test_Audit_PauseGetterFailureFailsClosedAfterDetection() public {
        uint256 shares = _depositGem(alice, 100e18);
        vm.mockCallRevert(address(gem), abi.encodeWithSelector(gem.paused.selector), hex"deadbeef");
        _assertGemUnavailable();
        vm.prank(alice);
        assertEq(vault.redeemToWsgem(shares, alice, alice), shares);
    }

    function test_Audit_MalformedPauseFlagFailsClosed() public {
        _depositGem(alice, 100e18);
        vm.mockCall(address(gem), abi.encodeWithSelector(gem.paused.selector), abi.encode(uint256(2)));
        _assertGemUnavailable();
    }

    function test_Audit_NonPausableGemRemainsSupported() public {
        vm.mockCallRevert(address(gem), abi.encodeWithSelector(gem.paused.selector), hex"");
        WsgemVault other = new WsgemVault("Non-pausable gem vault", "vNP", address(wsgem));
        assertFalse(other.gemPausable());
        assertTrue(other.gemTransfersAvailable());
    }

    function test_Audit_PinnedDeploymentRejectsWrongChainOnDirectPaths() public {
        DeployWstGbpVault deployer = new DeployWstGbpVault();
        vm.chainId(10);
        vm.expectRevert("Ethereum mainnet required");
        deployer.target();
        vm.expectRevert("Ethereum mainnet required");
        deployer.deploy(address(wsgem), "Wrong chain", "WRONG", address(gem));
        vm.expectRevert("Ethereum mainnet required");
        deployer.check(address(vault), address(wsgem), address(gem), alice);
    }

    /// @dev The direct deploy entry point is as pinned as run(): metadata is refused before
    /// any external read, so this holds offline with no code at the pinned addresses.
    function test_Audit_PinnedDeploymentRejectsWrongMetadataOnDirectPath() public {
        DeployWstGbpVault deployer = new DeployWstGbpVault();
        address wstgbp = deployer.WSTGBP();
        address tgbp = deployer.TGBP();
        string memory name = deployer.VAULT_NAME();
        string memory symbol = deployer.VAULT_SYMBOL();
        vm.chainId(1);
        vm.expectRevert("wrong pinned metadata");
        deployer.deploy(wstgbp, "Wrong name", symbol, tgbp);
        vm.expectRevert("wrong pinned metadata");
        deployer.deploy(wstgbp, name, "WRONG", tgbp);
    }

    function test_Audit_OracleLiveDoesNotDetectStaleNonzeroNav() public {
        uint256 before = vault.convertToAssets(WAD);
        vm.warp(block.timestamp + 365 days);
        assertTrue(vault.oracleLive());
        assertEq(vault.convertToAssets(WAD), before);
    }
}
