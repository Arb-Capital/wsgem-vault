// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {VaultTestBase} from "./VaultTestBase.sol";
import {DeployWsgemVault} from "../script/DeployWsgemVault.s.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {MaseerOne as Wsgem} from "maseer-one/MaseerOne.sol";
import {MockGem} from "./mocks/MockGem.sol";

/// @notice Executes the generic deploy script end to end against the local wsgem stack —
/// no instance-specific addresses, so it runs offline. Keeps every script path executable:
/// the pre-deploy refusals and the whole post-deploy sanity battery in every market state.
/// The script is driven through deploy()/check() directly (run() only resolves the
/// accessors over them, and vm.setEnv races across parallel tests, so env parsing stays
/// untested by design). The pinned wstGBP subclass is validated against live state in
/// DeployWstGbpVault.fork.t.sol.
contract DeployWsgemVaultTest is VaultTestBase {
    DeployWsgemVault internal deployer;

    function setUp() public override {
        super.setUp();
        deployer = new DeployWsgemVault();
    }

    function _deploy() internal returns (WsgemVault dv) {
        dv = deployer.deploy(address(wsgem), "Wrapped Staked Gem Vault", "vwsGEM", address(gem));
    }

    /// @dev Deposits `gemIn` worth of wsgem into the script's vault via the 1:1 leg.
    function _depositWsgemInto(WsgemVault dv, address usr, uint256 gemIn) internal returns (uint256 shares) {
        uint256 amt = _mintWsgem(usr, gemIn);
        vm.startPrank(usr);
        wsgem.approve(address(dv), amt);
        shares = dv.depositWsgem(amt, usr);
        vm.stopPrank();
    }

    function _depositGemInto(WsgemVault dv, address usr, uint256 gemIn) internal returns (uint256 shares) {
        gem.mint(usr, gemIn);
        vm.startPrank(usr);
        gem.approve(address(dv), gemIn);
        shares = dv.deposit(gemIn, usr);
        vm.stopPrank();
    }

    function _check(WsgemVault dv) internal view {
        deployer.check(address(dv), address(wsgem), address(gem), address(0));
    }

    function _check(WsgemVault dv, address holder) internal view {
        deployer.check(address(dv), address(wsgem), address(gem), holder);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPLOY
    //////////////////////////////////////////////////////////////*/

    function test_Deploy_FreshInstancePassesSanity() public {
        WsgemVault dv = _deploy();
        assertEq(dv.name(), "Wrapped Staked Gem Vault");
        assertEq(dv.symbol(), "vwsGEM");
        assertEq(dv.decimals(), 18);
        assertEq(dv.wsgem(), address(wsgem));
        assertEq(dv.asset(), address(gem));
        assertEq(dv.gem(), address(gem));
        assertEq(dv.totalSupply(), 0);
        assertEq(dv.deficit(), 0);
        assertEq(gem.allowance(address(dv), address(wsgem)), type(uint256).max);
    }

    function test_Deploy_RequiresExplicitName() public {
        vm.expectRevert("VAULT_NAME required");
        deployer.deploy(address(wsgem), "", "vwsGEM", address(gem));
    }

    function test_Deploy_RequiresExplicitSymbol() public {
        vm.expectRevert("VAULT_SYMBOL required");
        deployer.deploy(address(wsgem), "Wrapped Staked Gem Vault", "", address(gem));
    }

    function test_Deploy_RequiresWsgem() public {
        vm.expectRevert("WSGEM required");
        deployer.deploy(address(0), "Wrapped Staked Gem Vault", "vwsGEM", address(gem));
    }

    function test_Deploy_RequiresExpectedGem() public {
        vm.expectRevert("EXPECTED_GEM required");
        deployer.deploy(address(wsgem), "Wrapped Staked Gem Vault", "vwsGEM", address(0));
    }

    function test_Deploy_GemMismatchAborts() public {
        vm.expectRevert("wsgem.gem() != EXPECTED_GEM");
        deployer.deploy(address(wsgem), "Wrapped Staked Gem Vault", "vwsGEM", makeAddr("wrongGem"));
    }

    function test_Deploy_OraclePausedAborts() public {
        pip.pause();
        vm.expectRevert("oracle paused");
        _deploy();
    }

    function test_Deploy_GemPausedAborts() public {
        // Construction succeeds (approval is not pause-gated), so the post-deploy battery is
        // what refuses; under --broadcast that failure aborts the simulation before any send.
        gem.pause();
        vm.expectRevert("gem transfers unavailable");
        _deploy();
    }

    function test_Deploy_MintWindowClosed_StillDeploys() public {
        // Gem-in checks reduce to the closed-market mirror (with a warning); deployment
        // itself must not depend on the window.
        _closeMint();
        WsgemVault dv = _deploy();
        assertEq(dv.maxDeposit(address(this)), 0);
    }

    function test_Deploy_BurnWindowClosed_StillDeploys() public {
        _closeBurn();
        WsgemVault dv = _deploy();
        assertEq(dv.wsgem(), address(wsgem));
    }

    function test_Deploy_CooldownNonZero_StillDeploys() public {
        act.setCooldown(1 days);
        WsgemVault dv = _deploy();
        assertEq(dv.maxRedeem(address(this)), 0);
    }

    function test_Deploy_MarketPaused_StillDeploys() public {
        act.pauseMarket();
        WsgemVault dv = _deploy();
        assertEq(dv.maxDeposit(address(this)), 0);
        assertEq(dv.maxRedeem(address(this)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                CHECK
    //////////////////////////////////////////////////////////////*/

    function test_Check_FreshInstance() public {
        _check(_deploy());
    }

    /// @dev The live-mainnet shape: the wsgem already holds plenty of gem, the burn window
    /// is open, and the vault is brand new (holds no wsgem). Quotes never account for the
    /// vault's balance, so the battery sees every quote at par.
    function test_Check_FreshInstanceWithLiquidity() public {
        WsgemVault dv = _deploy();
        gem.mint(address(wsgem), 1e24);
        _check(dv);
    }

    /// @dev What the battery asserts on a fresh vault: fee-inclusive quotes at par, with or
    /// without gem liquidity in the wsgem and with nothing held.
    function test_Check_QuotesAtParOnFreshVault() public {
        WsgemVault dv = _deploy();
        uint256 unit = wsgem.mintcost();
        uint256 cost = wsgem.burncost();
        assertEq(dv.previewDeposit(unit), 1e18);
        assertEq(dv.previewMint(1e18), unit);
        assertEq(dv.previewRedeem(1e18), cost);
        assertEq(dv.previewRedeem(1e18 - 1), (1e18 - 1) * cost / 1e18, "sub-share quote");
        assertEq(dv.previewWithdraw(cost), 1e18);
        assertEq(dv.previewRedeemToWsgem(5e18), 5e18, "wsgem leg at par with nothing held");
        assertEq(dv.maxRedeem(alice), 0, "nothing to redeem yet");
        _check(dv);
        gem.mint(address(wsgem), 1e24);
        _check(dv);
    }

    /// @dev The oracle-pause fallback is seeded by the constructor, so "fallback unseeded"
    /// cannot trip on a real deploy; what can happen is a lag after a poke with no vault
    /// activity, which the battery warns about (and passes), and sync() clears.
    function test_Check_WarnsWhenFallbackLags() public {
        WsgemVault dv = _deploy();
        assertEq(dv.lastNav(), wsgem.navprice(), "seeded by the constructor");
        pip.poke(1.5e18);
        assertTrue(dv.lastNav() != wsgem.navprice(), "lags until refreshed");
        _check(dv); // WARN path, still healthy
        dv.sync();
        assertEq(dv.lastNav(), wsgem.navprice());
        assertEq(dv.lastMintUnit(), wsgem.mintcost());
        assertEq(dv.lastBurnUnit(), wsgem.burncost());
        _check(dv);
    }

    /// @dev For a real holder the battery ties maxWithdraw to the quote of maxRedeem.
    function test_Check_MaxWithdrawIsQuoteOfMaxRedeem() public {
        WsgemVault dv = _deploy();
        _depositGemInto(dv, alice, 25e18);
        assertEq(dv.maxRedeem(alice), dv.balanceOf(alice));
        assertEq(dv.maxWithdraw(alice), dv.previewRedeem(dv.maxRedeem(alice)));
        _check(dv, alice);
        // Liquidity-bounded: still tied.
        _setLiquidity(dv.previewRedeem(10e18));
        assertLt(dv.maxRedeem(alice), dv.balanceOf(alice));
        assertEq(dv.maxWithdraw(alice), dv.previewRedeem(dv.maxRedeem(alice)));
        _check(dv, alice);
    }

    function test_Check_BelowOneShareHeld() public {
        WsgemVault dv = _deploy();
        gem.mint(address(wsgem), 1e24);
        // Half a share held (the wsgem's own dust floor forbids minting less than one, so
        // mint two shares' worth and deposit half of one): quotes at par, max* zero.
        _mintWsgem(alice, 2e18);
        vm.startPrank(alice);
        wsgem.approve(address(dv), 5e17);
        dv.depositWsgem(5e17, alice);
        vm.stopPrank();
        _check(dv);
        _check(dv, alice);
        _closeBurn();
        _check(dv, alice);
    }

    function test_Check_ActiveInstance() public {
        WsgemVault dv = _deploy();
        _depositWsgemInto(dv, alice, 25e18);
        _depositGemInto(dv, alice, 10e18);
        _check(dv);
        _check(dv, alice);
        // A holder with no position is fine too.
        _check(dv, bob);
    }

    function test_Check_FlagsDeficit() public {
        WsgemVault dv = _deploy();
        uint256 shares = _depositWsgemInto(dv, alice, 25e18);

        vm.prank(issuer);
        wsgem.smelt(address(dv), shares / 2);

        vm.expectRevert("deficit != 0");
        _check(dv);
    }

    function test_Check_FlagsBannedVault() public {
        WsgemVault dv = _deploy();
        gem.ban(address(dv));
        vm.expectRevert("vault fails compliance screen");
        _check(dv);
    }

    function test_Check_FlagsPausedOracle() public {
        WsgemVault dv = _deploy();
        pip.pause();
        vm.expectRevert("oracle paused");
        _check(dv);
    }

    function test_Check_RejectsWrongVault() public {
        // A perfectly healthy vault bound to a DIFFERENT wsgem must not pass a check that
        // expects ours: the expected wsgem comes from outside, never from the vault under
        // check.
        MockGem gem2 = new MockGem(18);
        Wsgem wsgem2 = new Wsgem(address(gem2), address(pip), address(act), address(adm), address(cop), flo, "W2", "W2");
        WsgemVault other = deployer.deploy(address(wsgem2), "V2", "V2", address(gem2));

        vm.expectRevert("vault wsgem");
        _check(other);
    }

    function test_Check_RequiresExpectedGem() public {
        WsgemVault dv = _deploy();
        vm.expectRevert("EXPECTED_GEM required");
        deployer.check(address(dv), address(wsgem), address(0), address(0));
    }

    function test_Check_GemMismatchAborts() public {
        WsgemVault dv = _deploy();
        vm.expectRevert("wsgem.gem() != EXPECTED_GEM");
        deployer.check(address(dv), address(wsgem), makeAddr("wrongGem"), address(0));
    }

    function test_Check_WarnsWhenMintClosed() public {
        WsgemVault dv = _deploy();
        _depositWsgemInto(dv, alice, 25e18);
        _closeMint();
        _check(dv);
        _check(dv, alice);
    }

    function test_Check_WarnsWhenCapacityExhausted() public {
        WsgemVault dv = _deploy();
        _depositWsgemInto(dv, alice, 25e18);
        act.setCapacity(wsgem.totalSupply());
        _check(dv);
        _check(dv, alice);
    }

    function test_Check_WarnsWhenGemOutClosed() public {
        WsgemVault dv = _deploy();
        _depositWsgemInto(dv, alice, 25e18);

        act.setCooldown(1);
        _check(dv);
        _check(dv, alice);
        act.setCooldown(0);

        _closeBurn();
        _check(dv);
        _check(dv, alice);
        _openBurn();

        _setLiquidity(wsgem.burncost() - 1);
        _check(dv);
        _check(dv, alice);

        act.setBpsout(10_000);
        _check(dv);
        _check(dv, alice);
    }
}
