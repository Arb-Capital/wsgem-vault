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

/// @notice ERC-4626 vault over a wsgem token — a wrapped staked currency token. One
/// deployment serves one wsgem instance.
///
/// A wsgem is a non-rebasing, NAV-accruing wrapper of an underlying currency token (the
/// "gem"): its gem value is an oracle-set NAV rather than an on-chain balance ratio.
/// `navprice()` is quoted in gem native units per whole (1e18) wsgem, so the vault is
/// agnostic to the gem's decimals. The vault holds wsgem and issues exactly one 18-decimal
/// share per wsgem; `asset()` is the gem, so the wsgem's NAV shows up as the share price.
///
/// Pricing principle: fees never touch the share price. `totalAssets()` and `convertTo*`
/// report the gross NAV of the wsgem that actually backs the shares (the held balance
/// capped at the supply, so a donation cannot inflate the price and no virtual-share offset
/// is needed). The wsgem's entry and exit fees live only in the wsgem's `mintcost()` /
/// `burncost()`, which the previews quote and the executions replicate exactly, so whoever
/// enters or exits pays them and nobody else moves. No path through the vault is ever
/// cheaper than the same action against the wsgem directly:
///   - gem in  (`deposit`/`mint`)        == `wsgem.mint()`, share for share;
///   - gem out (`redeem`/`withdraw`)     == `wsgem.redeem()`, gem for gem;
///   - wsgem in/out (`depositWsgem`/`redeemToWsgem`) are 1:1 and fee-free.
///
/// ERC-4626 split between quoting and execution:
///   - `totalAssets`, `convertTo*` and every `preview*` are pure quotes: they never revert
///     for operational reasons and never account for limits. They read the oracle live and,
///     while it is paused, fall back to the values last observed live (`lastNav` and the
///     fee units; refreshed on every state-changing call and by `sync()`). Accepted: a
///     pause does NOT make that fallback a safe price — it is whatever the last mutation or
///     `sync()` saw, which may predate the pause by any number of pokes, or be the very
///     value the pause was meant to withdraw. Integrators that must not price on it check
///     `oracleLive()` and fail closed themselves (the Pendle SY does); keepers should
///     `sync()` in the same transaction as every NAV update so the fallback never lags.
///   - `max*` never revert and report 0 while a leg is unavailable (deposits: deficit,
///     mint window closed, vault deny-listed, oracle paused, capacity exhausted; gem-out:
///     cooldown, burn window closed, vault deny-listed, oracle paused, gem liquidity, the
///     wsgem's one-whole-wsgem floor), else the largest amount that succeeds.
///   - Execution enforces every gate, always on live values, with the wsgem's own revert
///     selectors and the vault's `Insolvent`, `CooldownActive`, `InsufficientLiquidity`.
///
/// Gem redemption is atomic or nothing. `wsgem.redeem()` queues a claim and pays it inline
/// only when the wsgem's cooldown is zero, and then only up to the wsgem's current gem
/// balance; a queued or partially filled claim would be owned by this vault with no one to
/// collect it. The vault therefore refuses before calling and verifies the gem it received
/// afterwards (`FillMismatch`).
///
/// The vault is fully immutable: no owner, pause, sweep, cooldown, holding period, deposit
/// fee, or gem buffer. Its only trust assumptions are the wsgem's: the NAV oracle is
/// permissioned and non-monotonic (it can be poked down or paused to 0); every wsgem
/// transfer screens all involved addresses — including this contract — against the gem's
/// ban list; and wsgem issuers can forcibly burn wsgem from ANY holder, including this
/// vault. Such a burn leaves shares outstanding with less than 1 wsgem of backing each:
/// `deficit()` surfaces the state for monitoring, accounting marks every share down to its
/// effective backing, redemptions pay pro-rata (so no holder can front-run another out of
/// the remaining backing), and deposits fail closed until wsgem donated to the vault
/// restores full backing.
contract WsgemVault is ERC20Permit, IERC4626, IWsgemVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant WAD = 1e18;

    /// @notice The wsgem backing the shares.
    address public immutable wsgem;
    /// @notice The gem; also `asset()`.
    address public immutable gem;

    /// @inheritdoc IWsgemVault
    uint256 public lastNav;
    /// @inheritdoc IWsgemVault
    uint256 public lastMintUnit;
    /// @inheritdoc IWsgemVault
    uint256 public lastBurnUnit;

    /// @notice The wsgem must use 18 decimals: shares are 1:1 with it and quoted per 1e18.
    error WsgemDecimals(uint8 actual);

    constructor(string memory name_, string memory symbol_, address wsgem_) ERC20(name_, symbol_) ERC20Permit(name_) {
        uint8 wsgemDecimals = IERC20Metadata(wsgem_).decimals();
        if (wsgemDecimals != 18) revert WsgemDecimals(wsgemDecimals);
        wsgem = wsgem_;
        gem = IWsgem(wsgem_).gem();
        IERC20(gem).forceApprove(wsgem_, type(uint256).max);
        // The fallback values must start from a live oracle.
        if (!_sync()) revert IWsgem.InvalidPrice();
    }

    /*///////////////////////////////////////////////////////////////
                              METADATA
    //////////////////////////////////////////////////////////////*/

    /// @dev Always 18: one share per wsgem, whatever the gem's decimals.
    function decimals() public pure override(ERC20, IERC20Metadata) returns (uint8) {
        return 18;
    }

    function asset() external view returns (address) {
        return gem;
    }

    /*///////////////////////////////////////////////////////////////
                        ACCOUNTING  (never reverts)
    //////////////////////////////////////////////////////////////*/

    /// @notice Gross NAV of the wsgem backing the shares, in gem native units.
    function totalAssets() public view returns (uint256) {
        return _effectiveWsgem().mulDiv(_navRef(), WAD);
    }

    /// @dev Gross, no fee; floor.
    function convertToShares(uint256 assets) public view returns (uint256) {
        return _sharesForWsgem(assets.mulDiv(WAD, _navRef()), Math.Rounding.Down);
    }

    /// @dev Gross, no fee; floor.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _wsgemForShares(shares).mulDiv(_navRef(), WAD);
    }

    /*///////////////////////////////////////////////////////////////
                    GEM IN  (replicates wsgem.mint)
    //////////////////////////////////////////////////////////////*/

    /// @notice Largest gem deposit that would succeed right now; 0 while the leg is closed.
    /// Saturates to `type(uint256).max` when the wsgem's capacity is effectively unlimited.
    function maxDeposit(address) public view returns (uint256) {
        (uint256 assets,) = _maxDepositAssets();
        return assets;
    }

    /// @notice Largest share mint that would succeed right now; 0 while the leg is closed.
    /// Saturates to `type(uint256).max` alongside `maxDeposit`.
    function maxMint(address) public view returns (uint256) {
        (uint256 assets, uint256 unit) = _maxDepositAssets();
        if (assets == 0 || assets == type(uint256).max) return assets;
        return assets * WAD / unit;
    }

    /// @dev Shares wsgem.mint() would issue for `assets`: fee-inclusive (`mintcost()`),
    /// floor. Quotes as though the deposit were accepted; execution may still revert on
    /// the wsgem's dust floor, window, capacity, or the vault's solvency gate.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return assets.mulDiv(WAD, _mintUnitRef());
    }

    /// @dev The smallest gem amount whose wsgem.mint() yields at least `shares`; the mint
    /// may deliver slightly more wsgem than `shares` (less than one gem unit's worth), which
    /// stays in the vault as surplus backing.
    function previewMint(uint256 shares) public view returns (uint256) {
        return shares.mulDiv(_mintUnitRef(), WAD, Math.Rounding.Up);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _sync();
        if (assets != 0) {
            // Gem transfers don't move the wsgem balance, so deficit() reads the
            // pre-deposit state here. Checked BEFORE minting so that with a deficit and a
            // closed/paused/capped market the solvency gate wins. wsgem.mint() then
            // enforces window, price, dust and capacity with its own selectors, pulls the
            // gem (already here) and returns the exact amount of wsgem minted; neither
            // token has transfer hooks.
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

    /// @notice Largest gem withdrawal `owner` can make right now; 0 while the leg is closed.
    function maxWithdraw(address owner) public view returns (uint256) {
        (uint256 shares, uint256 unit) = _maxRedeemShares(owner);
        if (shares == 0) return 0;
        return _wsgemForShares(shares).mulDiv(unit, WAD);
    }

    /// @notice Largest share redemption for gem `owner` can make right now; 0 while the leg
    /// is closed or below the wsgem's one-whole-wsgem redemption floor.
    function maxRedeem(address owner) public view returns (uint256) {
        (uint256 shares,) = _maxRedeemShares(owner);
        return shares;
    }

    /// @dev Gem wsgem.redeem() would pay for the wsgem `shares` release: fee-inclusive
    /// (`burncost()`), floor. Quotes as though the redemption were accepted; execution may
    /// still revert on the wsgem's one-whole-wsgem floor, window, cooldown, or liquidity.
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return _wsgemForShares(shares).mulDiv(_burnUnitRef(), WAD);
    }

    /// @dev The fewest shares whose redemption delivers at least `assets`; ceil. While the
    /// exit unit is zero (the exit fee is the whole price) no share count delivers gem, so
    /// the quote is `type(uint256).max` — the same answer as when nothing backs the shares —
    /// rather than a revert, and `maxWithdraw` is 0.
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

    /// @dev Delivers exactly `assets`. The redemption can pay up to one gem unit more than
    /// that (rounding of the wsgem release up); the difference stays in the vault, unowned
    /// and uncounted (it is not backing and never enters the share price).
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

    function maxDepositWsgem(address) external view returns (uint256) {
        return (deficit() == 0 && IWsgem(wsgem).canPass(address(this))) ? type(uint256).max : 0;
    }

    function maxRedeemToWsgem(address owner) external view returns (uint256) {
        if (!IWsgem(wsgem).canPass(address(this))) return 0;
        uint256 balance = balanceOf(owner);
        return _wsgemForShares(balance) == 0 ? 0 : balance;
    }

    function previewDepositWsgem(uint256 wsgemIn) public pure returns (uint256) {
        return wsgemIn;
    }

    /// @dev 1:1 while fully backed; pro-rata below that.
    function previewRedeemToWsgem(uint256 shares) public view returns (uint256) {
        return _wsgemForShares(shares);
    }

    function depositWsgem(uint256 wsgemIn, address receiver) external returns (uint256 shares) {
        _sync();
        if (wsgemIn != 0) {
            // deficit() reads the pre-deposit state: full backing after the transfer means
            // balance >= existing shares + new shares, the same condition.
            _requireSolvent();
            IERC20(wsgem).safeTransferFrom(msg.sender, address(this), wsgemIn);
        }
        shares = wsgemIn;
        _mint(receiver, shares);
        emit DepositWsgem(msg.sender, receiver, wsgemIn);
    }

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

    /// @notice Shares outstanding beyond the vault's wsgem balance. Non-zero only after a
    /// privileged burn of the vault's wsgem; while non-zero, every deposit leg reverts
    /// `Insolvent`, accounting marks shares down to their effective backing, and
    /// redemptions pay pro-rata. Remediated by donating wsgem to the vault. Intended for
    /// monitoring/alerting.
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

    /// @dev Refreshes the oracle-pause fallback values from a live oracle; no-op while paused.
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

    /// @dev Quote-side NAV: live, or the last live value while the oracle is paused.
    function _navRef() internal view returns (uint256 nav) {
        nav = IWsgem(wsgem).navprice();
        if (nav == 0) nav = lastNav;
    }

    /// @dev Quote-side entry unit (gem per whole wsgem, entry fee included). mintcost() is 0
    /// exactly when the oracle is paused; the fallback is always non-zero.
    function _mintUnitRef() internal view returns (uint256) {
        IWsgem w = IWsgem(wsgem);
        return w.navprice() == 0 ? lastMintUnit : w.mintcost();
    }

    /// @dev Quote-side exit unit (gem per whole wsgem, exit fee deducted). Zero only when the
    /// exit fee is the whole price.
    function _burnUnitRef() internal view returns (uint256) {
        IWsgem w = IWsgem(wsgem);
        return w.navprice() == 0 ? lastBurnUnit : w.burncost();
    }

    /// @dev wsgem that actually backs the outstanding shares: the held balance capped at
    /// the supply (surplus never counts, so donations cannot inflate the price).
    function _effectiveWsgem() internal view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 held = IWsgem(wsgem).balanceOf(address(this));
        return held < supply ? held : supply;
    }

    /// @dev wsgem released by burning `shares`: 1:1 while fully backed, pro-rata (floor)
    /// below that.
    function _wsgemForShares(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        uint256 effective = _effectiveWsgem();
        return effective == supply ? shares : shares.mulDiv(effective, supply);
    }

    /// @dev Shares whose burn releases `wsgemAmt`: 1:1 while fully backed, pro-rata (per
    /// `rounding`) below that; `type(uint256).max` when nothing backs the shares.
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

    /// @dev Gem-out gate, on live values: the vault's own atomicity condition first, then
    /// wsgem.redeem()'s modifiers in order, then a live exit unit (0 while the oracle is
    /// paused, and when the exit fee is the whole price — never burn shares for nothing).
    function _burnGate() internal view returns (uint256 unit) {
        IWsgem w = IWsgem(wsgem);
        uint256 cd = w.cooldown();
        if (cd != 0) revert CooldownActive(cd);
        if (!w.burnable()) revert IWsgem.MarketClosed();
        if (!w.canPass(address(this))) revert IWsgem.NotAuthorized(address(this));
        unit = w.burncost();
        if (unit == 0) revert IWsgem.InvalidPrice();
    }

    /// @dev wsgem.exit() pays from the wsgem's raw gem balance, so that is the bound; less
    /// than the claim would be a partial fill owned by this vault.
    function _requireLiquidity(uint256 claim) internal view {
        uint256 available = IERC20(gem).balanceOf(wsgem);
        if (available < claim) revert InsufficientLiquidity(available, claim);
    }

    /// @dev Burns `wsgemAmt` wsgem for gem and verifies the vault received exactly `claim`.
    /// Balance-delta, so dust left by earlier withdrawals can never mask a mismatch.
    function _gemOut(uint256 wsgemAmt, uint256 claim) internal {
        uint256 before = IERC20(gem).balanceOf(address(this));
        IWsgem(wsgem).redeem(wsgemAmt);
        uint256 received = IERC20(gem).balanceOf(address(this)) - before;
        if (received != claim) revert FillMismatch(claim, received);
    }

    /// @dev Largest gem deposit that would succeed, on live values: 0 while the leg is
    /// closed, saturating when the wsgem's remaining capacity is effectively unlimited,
    /// otherwise the largest `assets` with `floor(assets * 1e18 / mintcost()) <= headroom`.
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

    /// @dev Largest share redemption for gem that would succeed, on live values: 0 while
    /// the leg is closed, else the owner's balance capped by the wsgem's gem liquidity
    /// (the largest wsgem release whose claim fits, mapped back to the largest share count
    /// that releases it) and by the one-whole-wsgem redemption floor.
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
            // The LAST share count whose pro-rata release is still `release`: in a deficit
            // several share counts map to one release, and the first of them would leave
            // redeem(max + 1) executable.
            shares = _sharesForWsgem(release + 1, Math.Rounding.Up) - 1;
        }
        if (_wsgemForShares(shares) < WAD) return (0, unit);
    }
}
