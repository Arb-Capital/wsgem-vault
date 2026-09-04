// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";

interface IERC20BalanceLike {
    function balanceOf(address) external view returns (uint256);
}

interface IERC20ApproveLike {
    function approve(address, uint256) external returns (bool);
}

/// @notice Latest-block smoke checks against the live wstGBP deployment. These assert
/// the CURRENT mainnet configuration (fees, cooldown, open market both ways, compliance,
/// gem liquidity) — a failure here means live governable parameters or liquidity moved,
/// not that the vault regressed. Deliberately separate from the pinned, deterministic fork
/// suite. Skips without an explicit RPC (see {ForkBase}).
contract WsgemVaultSmokeTest is ForkBase {
    address constant WSGEM = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address constant GEM = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;

    WsgemVault internal vault;

    function setUp() public {
        if (!_forkOrSkip(0)) return; // latest block, intentionally
        vault = new WsgemVault("Wren Staked tGBP Vault", "vwstGBP", WSGEM);
    }

    function testSmoke_LiveParameters() public onlyFork {
        IWsgem w = IWsgem(WSGEM);
        assertGt(w.navprice(), 0, "oracle paused");
        assertGe(w.mintcost(), w.navprice(), "bpsin negative?");
        assertLe(w.burncost(), w.navprice(), "bpsout negative?");
        assertGt(w.burncost(), 0, "bpsout is the whole price");
        assertTrue(w.canPass(address(vault)), "vault banned on compliance list");
        assertEq(w.cooldown(), 0, "cooldown no longer atomic; gem-out is closed");
        assertTrue(w.mintable(), "mint window closed");
        assertTrue(w.burnable(), "burn window closed; gem-out is closed");
    }

    function testSmoke_SharePriceLive() public onlyFork {
        assertEq(vault.convertToAssets(1e18), IWsgem(WSGEM).navprice());
    }

    /// @dev Operational rather than code health: gem-out needs the wsgem to hold at least
    /// one share's claim in gem, or every gem redemption through the vault reverts. The
    /// quote stands regardless (quotes never account for liquidity); max* is what reports
    /// availability, so the vault is funded with two shares to read it for a real holder.
    function testSmoke_GemOutLiquidity() public onlyFork {
        uint256 cost = IWsgem(WSGEM).burncost();
        assertGe(IERC20BalanceLike(GEM).balanceOf(WSGEM), cost, "wsgem gem liquidity below one share");
        assertEq(vault.previewRedeem(1e18), cost, "quote before any deposit");

        uint256 amt = 2 * IWsgem(WSGEM).mintcost();
        deal(GEM, address(this), amt);
        IERC20ApproveLike(GEM).approve(address(vault), amt);
        assertEq(vault.deposit(amt, address(this)), 2e18);

        assertEq(vault.previewRedeem(1e18), cost);
        assertEq(vault.maxRedeem(address(this)), 2e18, "gem-out closed or illiquid");
        assertEq(vault.maxWithdraw(address(this)), vault.previewRedeem(2e18));
    }
}
