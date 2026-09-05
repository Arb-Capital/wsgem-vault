// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWsgem} from "./interfaces/IWsgem.sol";
import {IWsgemVault} from "./interfaces/IWsgemVault.sol";

/// @title WsgemVault
/// @notice Immutable ERC-4626 vault over a wsgem token. Holds wsgem, issues one 18-decimal
/// share per wsgem, and reports the wsgem's gem as `asset()`; the share price is the wsgem's
/// `navprice()` (gem native units per whole wsgem).
/// @dev `deposit`/`mint` replicate `wsgem.mint()` at `mintcost()`; `redeem`/`withdraw`
/// replicate `wsgem.redeem()` at `burncost()`. The wsgem legs are fee-free and 1:1 while
/// fully backed. Fees affect previews and execution, but `totalAssets` and `convertTo*` are
/// gross. Quotes use the values last observed live while `navprice()` is 0. `max*` return 0
/// while a leg is unavailable. Gem redemption requires cooldown 0 and the full claim in gem.
/// Backing is the held wsgem capped at the share supply; while `deficit()` is non-zero,
/// deposits revert `Insolvent` and redemptions pay pro-rata.
contract WsgemVault is ERC20Permit, IERC4626, IWsgemVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant WAD = 1e18;

    /// @inheritdoc IWsgemVault
    address public immutable wsgem;
    /// @inheritdoc IWsgemVault
    address public immutable gem;

    /// @inheritdoc IWsgemVault
    uint256 public lastNav;
    /// @inheritdoc IWsgemVault
    uint256 public lastMintUnit;
    /// @inheritdoc IWsgemVault
    uint256 public lastBurnUnit;

    /// @notice The wsgem must have 18 decimals.
    error WsgemDecimals(uint8 actual);

    constructor(string memory name_, string memory symbol_, address wsgem_) ERC20(name_, symbol_) ERC20Permit(name_) {
        uint8 wsgemDecimals = IERC20Metadata(wsgem_).decimals();
        if (wsgemDecimals != 18) revert WsgemDecimals(wsgemDecimals);
        wsgem = wsgem_;
        gem = IWsgem(wsgem_).gem();
        IERC20(gem).forceApprove(wsgem_, type(uint256).max);
        if (!_sync()) revert IWsgem.InvalidPrice();
    }

    /*///////////////////////////////////////////////////////////////
                              METADATA
    //////////////////////////////////////////////////////////////*/

    /// @dev Always 18: one share per wsgem.
    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return 18;
    }

    function asset() external view returns (address) {
        return gem;
    }

    /*///////////////////////////////////////////////////////////////
                              ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Gross NAV of the wsgem backing the shares, in gem native units.
    function totalAssets() public view returns (uint256) {
        return _effectiveWsgem().mulDiv(_navRef(), WAD);
    }

    /// @dev Gross, no fee; rounds down.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _sharesForWsgem(assets.mulDiv(WAD, _navRef()), Math.Rounding.Down);
    }

    /// @dev Gross, no fee; rounds down.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _wsgemForShares(shares).mulDiv(_navRef(), WAD);
    }

    /*///////////////////////////////////////////////////////////////
                    GEM IN  (replicates wsgem.mint)
    //////////////////////////////////////////////////////////////*/

    /// @notice Largest gem deposit that succeeds now; 0 while the leg is unavailable,
    /// `type(uint256).max` while wsgem capacity is effectively unlimited.
    function maxDeposit(address) public view returns (uint256) {
        (uint256 assets,) = _maxDepositAssets();
        return assets;
    }

    /// @notice Largest share mint that succeeds now; 0 or `type(uint256).max` as `maxDeposit`.
    function maxMint(address) public view returns (uint256) {
        (uint256 assets, uint256 unit) = _maxDepositAssets();
        if (assets == 0 || assets == type(uint256).max) return assets;
        return assets * WAD / unit;
    }

    /// @dev Shares `wsgem.mint()` issues for `assets` at `mintcost()`; rounds down.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(WAD, _mintUnitRef());
    }

    /// @dev Gem `wsgem.mint()` needs to issue at least `shares`; rounds up. Wsgem minted
    /// beyond `shares` stays in the vault as surplus backing.
    function previewMint(uint256 shares) public view returns (uint256) {
        return shares.mulDiv(_mintUnitRef(), WAD, Math.Rounding.Up);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _sync();
        if (assets != 0) {
            _requireSolvent();
            IERC20(gem).safeTransferFrom(msg.sender, address(this), assets);
            shares = IWsgem(wsgem).mint(assets);
        }
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        _sync();
        if (shares != 0) {
            _requireSolvent();
            uint256 unit = IWsgem(wsgem).mintcost();
            if (unit == 0) revert IWsgem.InvalidPrice();
            assets = shares.mulDiv(unit, WAD, Math.Rounding.Up);
            IERC20(gem).safeTransferFrom(msg.sender, address(this), assets);
            uint256 minted = IWsgem(wsgem).mint(assets);
            if (minted < shares) revert FillMismatch(shares, minted);
        }
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /*///////////////////////////////////////////////////////////////
                   GEM OUT  (replicates wsgem.redeem)
    //////////////////////////////////////////////////////////////*/

    /// @notice Largest gem withdrawal `owner` can make now; 0 while the leg is unavailable.
    function maxWithdraw(address owner) public view returns (uint256) {
        (uint256 shares, uint256 unit) = _maxRedeemShares(owner);
        if (shares == 0) return 0;
        return _wsgemForShares(shares).mulDiv(unit, WAD);
    }

    /// @notice Largest share redemption for gem `owner` can make now; 0 while the leg is
    /// unavailable or below the wsgem's one-whole-wsgem floor.
    function maxRedeem(address owner) public view returns (uint256) {
        (uint256 shares,) = _maxRedeemShares(owner);
        return shares;
    }

    /// @dev Gem `wsgem.redeem()` pays for the wsgem released by `shares` at `burncost()`;
    /// rounds down.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _wsgemForShares(shares).mulDiv(_burnUnitRef(), WAD);
    }

    /// @dev Fewest shares whose redemption delivers at least `assets`; rounds up.
    /// `type(uint256).max` while the exit unit is 0 or nothing backs the shares.
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        if (assets == 0) return 0;
        uint256 unit = _burnUnitRef();
        if (unit == 0) return type(uint256).max;
        return _sharesForWsgem(assets.mulDiv(WAD, unit, Math.Rounding.Up), Math.Rounding.Up);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        _sync();
        uint256 wsgemOut;
        if (shares != 0) {
            uint256 unit = _burnGate();
            wsgemOut = _wsgemForShares(shares);
            if (wsgemOut < WAD) revert IWsgem.DustThreshold(WAD);
            assets = wsgemOut.mulDiv(unit, WAD);
            _requireLiquidity(assets);
        }
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        if (shares != 0) {
            _gemOut(wsgemOut, assets);
            IERC20(gem).safeTransfer(receiver, assets);
        }
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Delivers exactly `assets`; gem received above that stays in the vault.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        _sync();
        uint256 wsgemOut;
        uint256 claim;
        if (assets != 0) {
            uint256 unit = _burnGate();
            uint256 needed = assets.mulDiv(WAD, unit, Math.Rounding.Up);
            if (needed < WAD) revert IWsgem.DustThreshold(WAD);
            shares = _sharesForWsgem(needed, Math.Rounding.Up);
            if (shares == type(uint256).max) revert Insolvent(deficit());
            wsgemOut = _wsgemForShares(shares);
            claim = wsgemOut.mulDiv(unit, WAD);
            _requireLiquidity(claim);
        }
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        if (assets != 0) {
            _gemOut(wsgemOut, claim);
            IERC20(gem).safeTransfer(receiver, assets);
        }
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /*///////////////////////////////////////////////////////////////
                     WSGEM LEGS  (1:1, fee-free)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IWsgemVault
    function maxDepositWsgem(address) external view returns (uint256) {
        return (deficit() == 0 && IWsgem(wsgem).canPass(address(this))) ? type(uint256).max : 0;
    }

    /// @inheritdoc IWsgemVault
    function maxRedeemToWsgem(address owner) external view returns (uint256) {
        if (!IWsgem(wsgem).canPass(address(this))) return 0;
        uint256 balance = balanceOf(owner);
        return _wsgemForShares(balance) == 0 ? 0 : balance;
    }

    /// @inheritdoc IWsgemVault
    function previewDepositWsgem(uint256 wsgemIn) public pure returns (uint256) {
        return wsgemIn;
    }

    /// @inheritdoc IWsgemVault
    function previewRedeemToWsgem(uint256 shares) public view returns (uint256) {
        return _wsgemForShares(shares);
    }

    /// @inheritdoc IWsgemVault
    function depositWsgem(uint256 wsgemIn, address receiver) external returns (uint256 shares) {
        _sync();
        if (wsgemIn != 0) {
            _requireSolvent();
            IERC20(wsgem).safeTransferFrom(msg.sender, address(this), wsgemIn);
        }
        shares = wsgemIn;
        _mint(receiver, shares);
        emit DepositWsgem(msg.sender, receiver, wsgemIn);
    }

    /// @inheritdoc IWsgemVault
    function redeemToWsgem(uint256 shares, address receiver, address owner) external returns (uint256 wsgemOut) {
        _sync();
        wsgemOut = _wsgemForShares(shares);
        if (shares != 0 && wsgemOut == 0) revert Insolvent(deficit());
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        if (wsgemOut != 0) IERC20(wsgem).safeTransfer(receiver, wsgemOut);
        emit RedeemWsgem(msg.sender, receiver, owner, shares, wsgemOut);
    }

    /*///////////////////////////////////////////////////////////////
                         SOLVENCY AND ORACLE FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IWsgemVault
    function deficit() public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 bal = IWsgem(wsgem).balanceOf(address(this));
        return bal < supply ? supply - bal : 0;
    }

    /// @inheritdoc IWsgemVault
    function sync() external {
        if (!_sync()) revert IWsgem.InvalidPrice();
    }

    /// @inheritdoc IWsgemVault
    function oracleLive() public view returns (bool) {
        return IWsgem(wsgem).navprice() != 0;
    }

    /// @dev Refreshes the fallback values from a live oracle; returns false while paused.
    function _sync() internal returns (bool live) {
        IWsgem w = IWsgem(wsgem);
        uint256 nav = w.navprice();
        if (nav == 0) return false;
        uint256 mintUnit = w.mintcost();
        uint256 burnUnit = w.burncost();
        if (nav != lastNav || mintUnit != lastMintUnit || burnUnit != lastBurnUnit) {
            lastNav = nav;
            lastMintUnit = mintUnit;
            lastBurnUnit = burnUnit;
            emit Sync(nav, mintUnit, burnUnit);
        }
        return true;
    }

    /*///////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Live NAV, or `lastNav` while the oracle is paused.
    function _navRef() internal view returns (uint256 nav) {
        nav = IWsgem(wsgem).navprice();
        if (nav == 0) nav = lastNav;
    }

    /// @dev Live `mintcost()`, or `lastMintUnit` while the oracle is paused.
    function _mintUnitRef() internal view returns (uint256) {
        IWsgem w = IWsgem(wsgem);
        return w.navprice() == 0 ? lastMintUnit : w.mintcost();
    }

    /// @dev Live `burncost()`, or `lastBurnUnit` while the oracle is paused.
    function _burnUnitRef() internal view returns (uint256) {
        IWsgem w = IWsgem(wsgem);
        return w.navprice() == 0 ? lastBurnUnit : w.burncost();
    }

    /// @dev Held wsgem capped at the share supply.
    function _effectiveWsgem() internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 held = IWsgem(wsgem).balanceOf(address(this));
        return held < supply ? held : supply;
    }

    /// @dev Wsgem released by `shares`: 1:1 while fully backed, pro-rata (down) otherwise.
    function _wsgemForShares(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        uint256 effective = _effectiveWsgem();
        return effective == supply ? shares : shares.mulDiv(effective, supply);
    }

    /// @dev Shares that release `wsgemAmt`: 1:1 while fully backed, pro-rata (per
    /// `rounding`) otherwise; `type(uint256).max` when nothing backs the shares.
    function _sharesForWsgem(uint256 wsgemAmt, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return wsgemAmt;
        uint256 effective = _effectiveWsgem();
        if (effective == supply) return wsgemAmt;
        if (effective == 0) return wsgemAmt == 0 ? 0 : type(uint256).max;
        return wsgemAmt.mulDiv(supply, effective, rounding);
    }

    function _requireSolvent() internal view {
        uint256 shortfall = deficit();
        if (shortfall != 0) revert Insolvent(shortfall);
    }

    /// @dev Gem-out gate on live values; returns the live exit unit.
    function _burnGate() internal view returns (uint256 unit) {
        IWsgem w = IWsgem(wsgem);
        uint256 cd = w.cooldown();
        if (cd != 0) revert CooldownActive(cd);
        if (!w.burnable()) revert IWsgem.MarketClosed();
        if (!w.canPass(address(this))) revert IWsgem.NotAuthorized(address(this));
        unit = w.burncost();
        if (unit == 0) revert IWsgem.InvalidPrice();
    }

    /// @dev Reverts unless the wsgem holds `claim` in gem.
    function _requireLiquidity(uint256 claim) internal view {
        uint256 available = IERC20(gem).balanceOf(wsgem);
        if (available < claim) revert InsufficientLiquidity(available, claim);
    }

    /// @dev Burns `wsgemAmt` wsgem for gem and verifies exactly `claim` was received.
    function _gemOut(uint256 wsgemAmt, uint256 claim) internal {
        uint256 before = IERC20(gem).balanceOf(address(this));
        IWsgem(wsgem).redeem(wsgemAmt);
        uint256 received = IERC20(gem).balanceOf(address(this)) - before;
        if (received != claim) revert FillMismatch(claim, received);
    }

    /// @dev Largest gem deposit that succeeds on live values: 0 while the leg is unavailable,
    /// `type(uint256).max` while capacity headroom is effectively unlimited, else the largest
    /// `assets` with `floor(assets * 1e18 / mintcost()) <= headroom`.
    function _maxDepositAssets() internal view returns (uint256 assets, uint256 unit) {
        IWsgem w = IWsgem(wsgem);
        if (deficit() != 0 || !w.mintable() || !w.canPass(address(this))) return (0, 0);
        unit = w.mintcost();
        if (unit == 0) return (0, 0);
        uint256 supply = w.totalSupply();
        uint256 cap = w.capacity();
        if (cap <= supply) return (0, unit);
        uint256 headroom = cap - supply;
        if (headroom < WAD) return (0, unit);
        if (headroom >= type(uint256).max / unit) return (type(uint256).max, unit);
        assets = Math.ceilDiv((headroom + 1) * unit, WAD) - 1;
    }

    /// @dev Largest share redemption for gem on live values: 0 while the leg is unavailable,
    /// else the owner's balance capped by the wsgem's gem liquidity and the one-whole-wsgem
    /// floor.
    function _maxRedeemShares(address owner) internal view returns (uint256 shares, uint256 unit) {
        IWsgem w = IWsgem(wsgem);
        if (w.cooldown() != 0 || !w.burnable() || !w.canPass(address(this))) return (0, 0);
        unit = w.burncost();
        if (unit == 0) return (0, 0);
        shares = balanceOf(owner);
        uint256 release = _wsgemForShares(shares);
        uint256 liquidity = IERC20(gem).balanceOf(wsgem);
        if (release.mulDiv(unit, WAD) > liquidity) {
            release = (liquidity + 1).mulDiv(WAD, unit, Math.Rounding.Up) - 1;
            // Last share count whose release is still `release`.
            shares = _sharesForWsgem(release + 1, Math.Rounding.Up) - 1;
        }
        if (_wsgemForShares(shares) < WAD) return (0, unit);
    }
}
