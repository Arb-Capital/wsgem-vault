// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Generic deployment pattern for {WsgemVault}, plus the deploy/check machinery
/// every instance shares. Nothing here is instance-specific: every parameter comes from the
/// environment and NOTHING is defaulted, because there is nothing sensible to default to —
/// a wrong name, symbol, or unchecked underlying is permanent on an immutable contract.
///
/// For a recurring deployment, subclass instead of exporting env vars by hand: pin the
/// configuration by overriding {target} and {naming}, and the deploy, check, and Makefile
/// paths come along unchanged. `script/DeployWstGbpVault.s.sol` is the worked example; copy
/// it for the next instance.
///
/// Env vars:
///   WSGEM         wsgem token address        (required)
///   EXPECTED_GEM  assert wsgem.gem() matches (required)
///   VAULT_NAME    vault share token name     (required)
///   VAULT_SYMBOL  vault share token symbol   (required)
///
/// Usage:
///   forge script script/DeployWsgemVault.s.sol --rpc-url mainnet -vvv            (dry run)
///   forge script script/DeployWsgemVault.s.sol --rpc-url mainnet --broadcast --verify -vvv
///
/// Post-broadcast: re-run the sanity battery against the mined instance (and any time
/// after — it doubles as a health check: it requires deficit() == 0 and a live oracle, and
/// reports whether each leg is open). It reads the expected wsgem / gem from {target},
/// deliberately not from the vault under check:
///   forge script script/DeployWsgemVault.s.sol --sig "check(address)" <VAULT_ADDR> \
///     --rpc-url mainnet -vvv
///
/// Manual verification fallback:
///   forge verify-contract <ADDR> src/WsgemVault.sol:WsgemVault --chain mainnet \
///     --compiler-version 0.8.28 --num-of-optimizations 1000000 \
///     --constructor-args $(cast abi-encode "constructor(string,string,address)" \
///       "<VAULT_NAME>" "<VAULT_SYMBOL>" <WSGEM>)
contract DeployWsgemVault is Script {
    /// @notice The wsgem to wrap and the gem it must be backed by. Shared by {run} and
    /// {check}: the check path needs exactly these, which is why the share metadata lives
    /// apart in {naming} — a health check must not require branding it never inspects.
    function target() public view virtual returns (address wsgem, address expectedGem) {
        return (vm.envAddress("WSGEM"), vm.envAddress("EXPECTED_GEM"));
    }

    /// @notice The vault share's ERC20 metadata. Deploy-path only: burned into the constructor.
    function naming() public view virtual returns (string memory name, string memory symbol) {
        return (vm.envString("VAULT_NAME"), vm.envString("VAULT_SYMBOL"));
    }

    function run() external returns (WsgemVault vault) {
        (address wsgem, address expectedGem) = target();
        (string memory name, string memory symbol) = naming();
        vault = deploy(wsgem, name, symbol, expectedGem);
    }

    function deploy(address wsgem, string memory name, string memory symbol, address expectedGem)
        public
        returns (WsgemVault vault)
    {
        _validateNaming(name, symbol);
        _validateTarget(wsgem, expectedGem);

        // Pre-deploy sanity: oracle alive.
        require(IWsgem(wsgem).navprice() > 0, "oracle paused");

        vm.startBroadcast();
        vault = new WsgemVault(name, symbol, wsgem);
        vm.stopBroadcast();

        _sanity(vault, wsgem, address(0));
        console.log("WsgemVault deployed:", address(vault));
        console.log("  name:   ", vault.name());
        console.log("  symbol: ", vault.symbol());
        console.log("  wsgem:  ", wsgem);
        console.log("  gem:    ", vault.asset());
    }

    /// @notice Re-runs the full sanity battery against a live vault. The expected wsgem and
    /// gem come from {target}, NOT from the vault under check — reading them from the
    /// target would reduce the battery to self-consistency and let any healthy vault pass,
    /// including one bound to the wrong wsgem.
    function check(address vaultAddr) external view {
        (address wsgem, address expectedGem) = target();
        check(vaultAddr, wsgem, expectedGem, address(0));
    }

    /// @param holder an account whose `max*` are exercised against its balance, or
    /// address(0) for the balance-independent checks only.
    function check(address vaultAddr, address wsgem, address expectedGem, address holder) public view {
        _validateTarget(wsgem, expectedGem);
        _sanity(WsgemVault(vaultAddr), wsgem, holder);
    }

    /// @dev Share metadata is permanent on an immutable contract, so it is validated before
    /// anything else; pinned subclasses refuse anything but their own.
    function _validateNaming(string memory name, string memory symbol) internal view virtual {
        require(bytes(name).length != 0, "VAULT_NAME required");
        require(bytes(symbol).length != 0, "VAULT_SYMBOL required");
    }

    function _validateTarget(address wsgem, address expectedGem) internal view virtual {
        require(wsgem != address(0), "WSGEM required");
        require(expectedGem != address(0), "EXPECTED_GEM required");
        require(IWsgem(wsgem).gem() == expectedGem, "wsgem.gem() != EXPECTED_GEM");
    }

    /*//////////////////////////////////////////////////////////////
                              BATTERY
    //////////////////////////////////////////////////////////////*/

    function _sanity(WsgemVault vault, address wsgem, address holder) internal view virtual {
        IWsgem w = IWsgem(wsgem);
        address gem = w.gem();

        // The wrong-instance detector comes first: a vault over another wsgem fails here,
        // not on a downstream symptom.
        require(vault.wsgem() == wsgem, "vault wsgem");
        require(vault.decimals() == 18, "vault decimals");
        require(vault.asset() == gem, "vault asset");
        require(vault.gem() == gem, "vault gem");
        if (!vault.gemPausable()) {
            console.log("WARN: gem exposed no paused() getter at construction; confirm the gem is non-pausable");
        }
        // Operational checks are distinct from the price quotes.
        require(w.canPass(address(vault)), "vault fails compliance screen");
        require(vault.gemTransfersAvailable(), "gem transfers unavailable");
        require(vault.deficit() == 0, "deficit != 0");

        uint256 nav = w.navprice();
        require(nav > 0, "oracle paused");
        require(vault.convertToAssets(1e18) == nav, "convertToAssets");
        require(vault.convertToShares(nav) == 1e18, "convertToShares");
        require(vault.totalAssets() == vault.totalSupply() * nav / 1e18, "totalAssets");
        require(IERC20(gem).allowance(address(vault), wsgem) >= type(uint96).max / 2, "gem approval");

        _sanityFallback(vault, w);
        _sanityWsgemLegs(vault, w, holder);
        _sanityGemIn(vault, w, holder);
        _sanityGemOut(vault, w, gem, holder);
    }

    function _sanityWsgemLegs(WsgemVault vault, IWsgem w, address holder) internal view {
        // Quotes never revert and are 1:1 while fully backed (deficit == 0 above), so any
        // size — held or not — quotes at par.
        uint256 held = w.balanceOf(address(vault));
        require(vault.previewDepositWsgem(1e18) == 1e18, "previewDepositWsgem");
        require(vault.previewRedeemToWsgem(held + 1e18) == held + 1e18, "previewRedeemToWsgem");
        require(vault.maxDepositWsgem(holder) == type(uint256).max, "maxDepositWsgem");
        if (holder != address(0)) {
            require(vault.maxRedeemToWsgem(holder) == vault.balanceOf(holder), "maxRedeemToWsgem");
        }
    }

    function _sanityGemIn(WsgemVault vault, IWsgem w, address holder) internal view {
        // Quotes are fee-inclusive and never account for the window or capacity.
        uint256 unit = w.mintcost();
        require(vault.previewDeposit(unit) == 1e18, "previewDeposit gem");
        require(vault.previewMint(1e18) == unit, "previewMint gem");
        if (!w.mintable()) {
            console.log("WARN: wsgem mint window closed; gem-in is unavailable");
            require(vault.maxDeposit(holder) == 0 && vault.maxMint(holder) == 0, "max* must be 0 while mint closed");
            return;
        }
        if (vault.maxMint(holder) < 1e18) {
            console.log("WARN: wsgem capacity exhausted; gem-in is unavailable");
            return;
        }
        require(vault.maxDeposit(holder) >= unit && vault.maxMint(holder) >= 1e18, "maxDeposit");
    }

    function _sanityGemOut(WsgemVault vault, IWsgem w, address gem, address holder) internal view {
        uint256 cost = w.burncost();
        uint256 liq = IERC20(gem).balanceOf(address(w));
        bool open = w.burnable() && w.cooldown() == 0 && cost > 0;
        // Quotes are fee-inclusive, 1:1 in wsgem while fully backed, and never account for
        // the window, cooldown, liquidity, or the one-whole-wsgem floor.
        require(vault.previewRedeem(1e18) == cost, "previewRedeem gem");
        require(vault.previewRedeem(1e18 - 1) == (1e18 - 1) * cost / 1e18, "previewRedeem sub-share");
        if (cost > 0) {
            require(vault.previewWithdraw(cost) == 1e18, "previewWithdraw gem");
        }
        if (open && liq >= cost) {
            if (holder != address(0)) {
                uint256 bal = vault.balanceOf(holder);
                require(vault.maxRedeem(holder) <= bal, "maxRedeem bound");
                require(vault.maxWithdraw(holder) <= vault.convertToAssets(bal), "maxWithdraw bound");
                require(vault.maxWithdraw(holder) == vault.previewRedeem(vault.maxRedeem(holder)), "maxWithdraw quote");
            }
            return;
        }
        if (!w.burnable()) console.log("WARN: wsgem burn window closed; gem-out is unavailable");
        else if (w.cooldown() != 0) console.log("WARN: wsgem cooldown non-zero; gem-out is unavailable");
        else if (cost == 0) console.log("WARN: wsgem burncost is zero; gem-out is unavailable");
        else console.log("WARN: wsgem gem liquidity below one share's claim; gem-out is unavailable");
        require(vault.maxRedeem(holder) == 0 && vault.maxWithdraw(holder) == 0, "max* must be 0 while gem-out closed");
    }

    function _sanityFallback(WsgemVault vault, IWsgem w) internal view {
        // The oracle-pause fallback must have been seeded by the constructor; it refreshes
        // on every gem-leg call and on sync(), so it may lag on a quiet vault.
        require(vault.lastNav() > 0 && vault.lastMintUnit() > 0, "fallback unseeded");
        if (vault.lastNav() != w.navprice()) {
            console.log("WARN: oracle-pause fallback lags the live NAV; call sync() to refresh");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                ENV
    //////////////////////////////////////////////////////////////*/

    /// @dev For instance-pinned subclasses: refuse an env var that contradicts a pinned
    /// value. A `WSGEM`/`VAULT_NAME`/... left exported for a different instance must not be
    /// silently ignored — the operator who set it believes it is in force.
    function _requirePinned(string memory key, address pinned) internal view {
        require(vm.envOr(key, pinned) == pinned, string.concat(key, " contradicts this script's pinned instance"));
    }

    function _requirePinned(string memory key, string memory pinned) internal view {
        require(
            keccak256(bytes(vm.envOr(key, pinned))) == keccak256(bytes(pinned)),
            string.concat(key, " contradicts this script's pinned instance")
        );
    }
}
