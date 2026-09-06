// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {VaultTestBase} from "./VaultTestBase.sol";

/// @notice View facts that hold in every reachable state of every campaign: accounting
/// identities, the oracle-pause fallback, quote ordering, zero quotes, round trips that
/// never gain, `max*` gating and sum-of-claims. Each campaign calls `_checkSpec` from its
/// own `invariant_Spec` with its actor set. `exitFeedLive` is false only while a reverting
/// `burncost()` feed takes the gem-out quotes and maxima down with it (README, quotes and
/// limits): those reads are skipped then, everything else must still stand.
abstract contract InvariantBase is VaultTestBase {
    uint256 internal constant MAX = type(uint256).max;

    function _checkSpec(address[3] memory actors, bool exitFeedLive) internal view {
        _checkAccountingIdentities();
        _checkFallbackTriple();
        _checkQuoteOrdering(exitFeedLive);
        _checkZeroQuotes(exitFeedLive);
        _checkRoundTrips(exitFeedLive);
        _checkMaxGating(actors, exitFeedLive);
        _checkSumOfClaims(actors);
    }

    /// @dev `deficit`, `totalAssets`, `convertToAssets(supply)` and the wsgem claim of the
    /// whole supply are one function of `min(held, supply)`.
    function _checkAccountingIdentities() internal view {
        uint256 supply = vault.totalSupply();
        uint256 held = wsgem.balanceOf(address(vault));
        uint256 effective = held < supply ? held : supply;
        assertEq(vault.deficit(), supply > held ? supply - held : 0, "deficit != supply - held");
        assertEq(vault.totalAssets(), vault.convertToAssets(supply), "totalAssets != convertToAssets(supply)");
        assertEq(vault.previewRedeemToWsgem(supply), effective, "supply claim != effective backing");
        assertEq(vault.oracleLive(), wsgem.navprice() != 0, "oracleLive != nonzero nav");
    }

    /// @dev The fallback triple is seeded by the constructor and only ever rewritten from
    /// one live read, so it is never empty and its units bracket its NAV.
    function _checkFallbackTriple() internal view {
        uint256 nav = vault.lastNav();
        assertGt(nav, 0, "lastNav is 0");
        assertLe(vault.lastBurnUnit(), nav, "lastBurnUnit above lastNav");
        assertGe(vault.lastMintUnit(), nav, "lastMintUnit below lastNav");
    }

    /// @dev Fees only ever cut against the caller: the entry quotes sit at or above gross,
    /// the exit quotes at or below it (both sides may be the `previewWithdraw` sentinel).
    function _checkQuoteOrdering(bool exitFeedLive) internal view {
        assertGe(vault.previewMint(WAD), vault.convertToAssets(WAD), "previewMint below gross");
        assertLe(vault.previewDeposit(WAD), vault.convertToShares(WAD), "previewDeposit above gross");
        if (!exitFeedLive) return;
        assertLe(vault.previewRedeem(WAD), vault.convertToAssets(WAD), "previewRedeem above gross");
        assertGe(vault.previewWithdraw(WAD), vault.convertToShares(WAD), "previewWithdraw below gross");
    }

    /// @dev Zero quotes as zero in every state; `previewWithdraw(0)` is 0, not the sentinel.
    function _checkZeroQuotes(bool exitFeedLive) internal view {
        assertEq(vault.convertToShares(0), 0, "convertToShares(0)");
        assertEq(vault.convertToAssets(0), 0, "convertToAssets(0)");
        assertEq(vault.previewDeposit(0), 0, "previewDeposit(0)");
        assertEq(vault.previewMint(0), 0, "previewMint(0)");
        assertEq(vault.previewWithdraw(0), 0, "previewWithdraw(0)");
        assertEq(vault.previewDepositWsgem(0), 0, "previewDepositWsgem(0)");
        assertEq(vault.previewRedeemToWsgem(0), 0, "previewRedeemToWsgem(0)");
        if (exitFeedLive) assertEq(vault.previewRedeem(0), 0, "previewRedeem(0)");
    }

    /// @dev No quote pair gains on a round trip, in deficit and while paused included:
    /// pro-rata flooring never fabricates shares or gem.
    function _checkRoundTrips(bool exitFeedLive) internal view {
        uint256[3] memory shares = [uint256(1), WAD, vault.totalSupply()];
        for (uint256 i = 0; i < 3; i++) {
            uint256 s = shares[i];
            assertLe(vault.convertToShares(vault.convertToAssets(s)), s, "convert round trip gained shares");
            assertGe(vault.previewDeposit(vault.previewMint(s)), s, "mint then deposit quote lost shares");
            if (exitFeedLive) {
                assertLe(vault.previewWithdraw(vault.previewRedeem(s)), s, "redeem then withdraw quote gained");
            }
        }
        uint256[2] memory assets = [uint256(1), WAD];
        for (uint256 i = 0; i < 2; i++) {
            uint256 a = assets[i];
            uint256 sh = vault.convertToShares(a);
            if (sh != MAX) assertLe(vault.convertToAssets(sh), a, "convert round trip gained assets");
            assertLe(vault.previewMint(vault.previewDeposit(a)), a, "deposit then mint quote gained");
            if (exitFeedLive) {
                uint256 pw = vault.previewWithdraw(a);
                if (pw != MAX) assertGe(vault.previewRedeem(pw), a, "withdraw then redeem quote lost");
            }
        }
    }

    struct Gates {
        bool pass; // wsgem compliance for the vault
        bool solvent;
        bool entryOpen;
        bool exitOpen;
        bool exitFeedLive;
    }

    /// @dev `max*` are 0 exactly when their leg is unavailable, ignore the receiver, never
    /// exceed the balance, and agree with the previews.
    function _checkMaxGating(address[3] memory actors, bool exitFeedLive) internal view {
        Gates memory g;
        g.pass = wsgem.canPass(address(vault));
        g.solvent = vault.deficit() == 0;
        g.exitFeedLive = exitFeedLive;
        bool gemOk = vault.gemTransfersAvailable();
        bool live = wsgem.navprice() != 0;
        g.entryOpen = g.solvent && wsgem.mintable() && gemOk && live;
        g.exitOpen = wsgem.cooldown() == 0 && wsgem.burnable() && gemOk && live;
        if (exitFeedLive && wsgem.burncost() == 0) g.exitOpen = false;
        for (uint256 i = 0; i < 3; i++) {
            _checkEntryMax(actors[i], actors[0], g);
            _checkExitMax(actors[i], g);
        }
    }

    function _checkEntryMax(address u, address ref, Gates memory g) internal view {
        uint256 md = vault.maxDeposit(u);
        uint256 mm = vault.maxMint(u);
        uint256 mdw = vault.maxDepositWsgem(u);
        if (!g.entryOpen) {
            assertEq(md, 0, "maxDeposit while gem-in unavailable");
            assertEq(mm, 0, "maxMint while gem-in unavailable");
        }
        assertEq(mdw, g.solvent && g.pass ? MAX : 0, "maxDepositWsgem gating");
        assertEq(md, vault.maxDeposit(ref), "maxDeposit depends on the receiver");
        assertEq(mm, vault.maxMint(ref), "maxMint depends on the receiver");
        assertEq(mdw, vault.maxDepositWsgem(ref), "maxDepositWsgem depends on the receiver");
        if (md == MAX) assertEq(mm, MAX, "maxMint not saturated with maxDeposit");
        else assertEq(mm, vault.previewDeposit(md), "maxMint != previewDeposit(maxDeposit)");
    }

    function _checkExitMax(address u, Gates memory g) internal view {
        uint256 bal = vault.balanceOf(u);
        assertEq(
            vault.maxRedeemToWsgem(u),
            g.pass && vault.previewRedeemToWsgem(bal) != 0 ? bal : 0,
            "maxRedeemToWsgem gating"
        );
        if (!g.exitFeedLive) return;
        uint256 mr = vault.maxRedeem(u);
        uint256 mw = vault.maxWithdraw(u);
        if (!g.exitOpen) {
            assertEq(mr, 0, "maxRedeem while gem-out unavailable");
            assertEq(mw, 0, "maxWithdraw while gem-out unavailable");
        }
        assertLe(mr, bal, "maxRedeem above balance");
        assertEq(mw, vault.previewRedeem(mr), "maxWithdraw != previewRedeem(maxRedeem)");
    }

    /// @dev The actors hold every share, and what they could claim separately never exceeds
    /// what backs them together.
    function _checkSumOfClaims(address[3] memory actors) internal view {
        uint256 supply = vault.totalSupply();
        uint256 held = wsgem.balanceOf(address(vault));
        uint256 sumBal;
        uint256 sumAssets;
        uint256 sumClaims;
        for (uint256 i = 0; i < 3; i++) {
            uint256 bal = vault.balanceOf(actors[i]);
            sumBal += bal;
            sumAssets += vault.convertToAssets(bal);
            sumClaims += vault.previewRedeemToWsgem(bal);
        }
        assertEq(sumBal, supply, "shares held outside the actors");
        assertLe(sumAssets, vault.totalAssets(), "per-account assets exceed totalAssets");
        assertLe(sumClaims, held < supply ? held : supply, "per-account wsgem claims exceed backing");
    }
}
