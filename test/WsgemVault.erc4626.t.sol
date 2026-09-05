// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";
import {VaultTestBase} from "./VaultTestBase.sol";

/// @notice The a16z ERC-4626 property suite run against the vault over the real wsgem
/// stack, with zero tolerance (`_delta_ = 0`): every preview must equal its execution and
/// every round trip must hold exactly. Yield is a NAV poke, not a gem transfer, so
/// `setUpYield` is overridden to poke the oracle and settle the resulting gross NAV into the
/// wsgem's gem balance (the issuer's returns arriving as gem), and `setUpVault` bounds the
/// seeds above the wsgem's dust floor. Runs the suite rejects (any revert inside a property
/// discards the run) are the vault's minimums and the callers' funding — never a property.
///
/// The two `testFail_*` wrappers are excluded via `no_match_test` in foundry.toml (forge
/// removed `testFail`); their intent is covered by `*_WithoutAllowance_Reverts` in
/// test/WsgemVault.t.sol.
contract WsgemVaultERC4626Test is VaultTestBase, ERC4626Test {
    /// @dev Upper bound for seeded deposits and free balances, in gem native units.
    function _seedMax() internal view virtual returns (uint256) {
        return 1e27;
    }

    function setUp() public virtual override(VaultTestBase, ERC4626Test) {
        VaultTestBase.setUp();
        _underlying_ = address(gem);
        _vault_ = address(vault);
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = false;
    }

    /// @dev Same shape as the base: each user deposits `share[i]` gem (bounded into
    /// [mintcost, seedMax] so the wsgem's dust floor never rejects a seed) and holds
    /// `asset[i]` free gem.
    function setUpVault(Init memory init) public virtual override {
        uint256 unit = wsgem.mintcost();
        for (uint256 i = 0; i < N; i++) {
            address user = init.user[i];
            vm.assume(_isEOA(user));
            uint256 seed = bound(init.share[i], unit, _seedMax());
            gem.mint(user, seed);
            _approve(address(gem), user, address(vault), seed);
            vm.prank(user);
            try vault.deposit(seed, user) {}
            catch {
                vm.assume(false);
            }
            gem.mint(user, bound(init.asset[i], 0, _seedMax()));
        }
        setUpYield(init);
    }

    /// @dev Yield is a NAV move: a gain pokes the oracle up (to at most 5x), a loss pokes it
    /// down (to at least half). The wsgem's gem balance is then topped up to the new gross
    /// NAV so every redemption stays fully fillable, as it would be when the issuer's
    /// returns arrive as gem.
    function setUpYield(Init memory init) public virtual override {
        uint256 nav;
        if (init.yield >= 0) {
            nav = bound(uint256(init.yield), initNavprice, initNavprice * 5);
        } else {
            vm.assume(init.yield > type(int256).min);
            nav = bound(uint256(-init.yield), initNavprice / 2, initNavprice);
        }
        pip.poke(nav);
        uint256 need = vault.totalAssets();
        uint256 have = gem.balanceOf(address(wsgem));
        if (need > have) gem.mint(address(wsgem), need - have);
    }
}

/// @notice The same suite with a 25 bps entry fee, so `mintcost() > navprice()` and the
/// entry side of every round trip is exercised with a real spread.
contract WsgemVaultERC4626FeeInTest is WsgemVaultERC4626Test {
    function setUp() public override {
        super.setUp();
        act.setBpsin(25);
    }
}

/// @notice The same suite with no fee either way (`mintcost() == burncost() == navprice()`),
/// so every round trip runs at zero spread: the floors alone must keep a lap from gaining.
contract WsgemVaultERC4626NoFeeTest is WsgemVaultERC4626Test {
    function setUp() public override {
        super.setUp();
        act.setBpsout(0);
    }
}

/// @notice The same suite around a 6-decimal gem (NAV quoted in gem native units per whole
/// wsgem, so the seeds and bounds scale with it).
contract WsgemVaultERC4626Dec6Test is WsgemVaultERC4626Test {
    function _seedMax() internal pure override returns (uint256) {
        return 1e18; // 1e12 whole gems at 6 decimals
    }

    function setUp() public override {
        gemDecimals = 6;
        initNavprice = 1.006e6;
        super.setUp();
    }
}
