// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {DeployWstGbpVault} from "../script/DeployWstGbpVault.s.sol";
import {WsgemVault} from "../src/WsgemVault.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";

interface IERC20MetaLike {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

/// @notice Validates the pinned wstGBP deploy script against the live Ethereum mainnet
/// instance it hardcodes — the only place its constants can actually be wrong. The
/// generic deploy/check machinery is covered offline in DeployWsgemVaultTest; here we
/// prove the pinned values name the real wstGBP/tGBP pair and that the script deploys
/// and self-checks against live state. Skips without an explicit RPC (see {ForkBase}).
contract DeployWstGbpVaultForkTest is ForkBase {
    /// @dev Same baseline as WsgemVaultForkTest: wsgem market open, cooldown 0.
    uint256 constant PINNED_BLOCK = 25_589_900;

    DeployWstGbpVault internal deployer;

    function setUp() public {
        if (!_forkOrSkip(vm.envOr("FORK_BLOCK", uint256(PINNED_BLOCK)))) return;
        deployer = new DeployWstGbpVault();
    }

    /// @dev A typo in either pinned address is unrecoverable after broadcast: the wrong
    /// wsgem is wrapped forever, and the gem cross-check would be validating the wrong
    /// pair. Both are checked against the live tokens' own metadata.
    function testFork_PinnedAddressesAreTheLiveInstance() public onlyFork {
        assertEq(IERC20MetaLike(deployer.WSTGBP()).symbol(), "wstGBP");
        assertEq(IERC20MetaLike(deployer.TGBP()).symbol(), "tGBP");
        assertEq(IWsgem(deployer.WSTGBP()).gem(), deployer.TGBP());
    }

    /// @dev The share metadata is immutable once constructed and mirrors the live wsgem
    /// it wraps rather than drifting from it.
    function testFork_PinnedMetadataMirrorsLiveToken() public onlyFork {
        assertEq(deployer.VAULT_NAME(), string.concat(IERC20MetaLike(deployer.WSTGBP()).name(), " Vault"));
        assertEq(deployer.VAULT_SYMBOL(), string.concat("v", IERC20MetaLike(deployer.WSTGBP()).symbol()));
    }

    /// @dev The run() path end to end, minus the broadcast: pinned configuration in, live
    /// deployment out, and the script's own sanity battery green on the fresh instance.
    /// Note this reads WSGEM / EXPECTED_GEM / VAULT_NAME / VAULT_SYMBOL from the
    /// environment only to refuse contradicting values, so a stale export for another
    /// instance fails here exactly as it would at deploy time — which is the intent.
    function testFork_DeploysAndSelfChecks() public onlyFork {
        (address wsgem, address expectedGem) = deployer.target();
        (string memory name, string memory symbol) = deployer.naming();
        assertEq(wsgem, deployer.WSTGBP());
        assertEq(expectedGem, deployer.TGBP());

        WsgemVault vault = deployer.deploy(wsgem, name, symbol, expectedGem);
        assertEq(vault.name(), deployer.VAULT_NAME());
        assertEq(vault.symbol(), deployer.VAULT_SYMBOL());
        assertEq(vault.wsgem(), deployer.WSTGBP());
        assertEq(vault.asset(), deployer.TGBP());
        assertEq(vault.decimals(), 18);

        deployer.check(address(vault), wsgem, expectedGem, address(0));
    }
}
