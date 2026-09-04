// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {DeployWsgemVault} from "./DeployWsgemVault.s.sol";

/// @notice The wstGBP vault deployment: every parameter of the live Ethereum mainnet
/// instance, pinned in code. Nothing has to be exported to run it — that is the point.
/// Deploy and health-check behaviour is inherited wholesale from {DeployWsgemVault}; only
/// the configuration is fixed here. The vault has no owner, so there is nothing to hand over.
///
/// WSGEM / EXPECTED_GEM / VAULT_NAME / VAULT_SYMBOL are pinned, not read: a value exported
/// for another instance is refused rather than silently ignored. Use the generic
/// {DeployWsgemVault} for any other wsgem.
///
/// Usage:
///   forge script script/DeployWstGbpVault.s.sol --rpc-url mainnet -vvv           (dry run)
///   forge script script/DeployWstGbpVault.s.sol --rpc-url mainnet --broadcast --verify -vvv
///   forge script script/DeployWstGbpVault.s.sol --sig "check(address)" <VAULT_ADDR> \
///     --rpc-url mainnet -vvv                                    (post-broadcast/health)
///
/// Or through the Makefile, which drives this script by default:
///   make deploy-dry / make deploy / make check VAULT=0x...
///
/// Manual verification fallback (constructor args are the pinned values):
///   forge verify-contract <ADDR> src/WsgemVault.sol:WsgemVault --chain mainnet \
///     --compiler-version 0.8.28 --num-of-optimizations 1000000 \
///     --constructor-args $(cast abi-encode "constructor(string,string,address)" \
///       "Wren Staked tGBP Vault" "vwstGBP" 0x57C3571f10767E49C9d7b60feb6c67804783B7aE)
contract DeployWstGbpVault is DeployWsgemVault {
    /// @notice wstGBP ("Wren Staked tGBP") on Ethereum mainnet — the wsgem being wrapped.
    address public constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;

    /// @notice tGBP on Ethereum mainnet — the gem backing wstGBP, cross-checked against
    /// `wstGBP.gem()` before anything is deployed.
    address public constant TGBP = 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;

    /// @notice Vault share ERC20 metadata, mirroring the wrapped token ("Wren Staked tGBP" /
    /// "wstGBP"). Immutable once constructed.
    string public constant VAULT_NAME = "Wren Staked tGBP Vault";
    string public constant VAULT_SYMBOL = "vwstGBP";

    function target() public view override returns (address wsgem, address expectedGem) {
        _requirePinned("WSGEM", WSTGBP);
        _requirePinned("EXPECTED_GEM", TGBP);
        return (WSTGBP, TGBP);
    }

    function naming() public view override returns (string memory name, string memory symbol) {
        _requirePinned("VAULT_NAME", VAULT_NAME);
        _requirePinned("VAULT_SYMBOL", VAULT_SYMBOL);
        return (VAULT_NAME, VAULT_SYMBOL);
    }
}
