// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice The non-ERC-4626 surface of a wsgem vault. Everything ERC-4626 is reached through
/// any `IERC4626`; this interface adds the fee-free wsgem legs, the vault's own errors and
/// events, the oracle-pause fallback, and the solvency monitor. It deliberately does not
/// extend an `IERC4626` so callers can pair it with whichever `IERC4626` they already use.
interface IWsgemVault {
    /// @notice Deposits are refused while outstanding shares exceed the wsgem backing (a
    /// deposit would dilute the depositor into the hole), and a redemption that would
    /// release no wsgem at all is refused. Only reachable after a privileged burn of the
    /// vault's wsgem. `deficit` is the wsgem shortfall.
    error Insolvent(uint256 deficit);

    /// @notice The wsgem's redemption cooldown is non-zero, so a gem redemption would be
    /// queued as a claim owned by the vault instead of paid atomically.
    error CooldownActive(uint256 cooldown);

    /// @notice The wsgem holds less gem than the redemption claim, so its payout would be
    /// partial and leave a dangling claim owned by the vault.
    error InsufficientLiquidity(uint256 available, uint256 required);

    /// @notice A wsgem call delivered an amount other than the quote: less wsgem than the
    /// requested shares on `mint` (more is kept as surplus backing), or any gem amount other
    /// than the claim on redemption. Defensive; unreachable through the wsgem's own
    /// arithmetic.
    error FillMismatch(uint256 expected, uint256 received);

    /// @dev Shares minted == `amount` of wsgem (always 1:1 on the way in).
    event DepositWsgem(address indexed sender, address indexed owner, uint256 amount);
    /// @dev `wsgemOut` == `shares` while the vault is fully backed; pro-rata below that.
    event RedeemWsgem(
        address indexed sender, address indexed receiver, address indexed owner, uint256 shares, uint256 wsgemOut
    );
    /// @dev The oracle-pause fallback values were refreshed from a live oracle.
    event Sync(uint256 nav, uint256 mintUnit, uint256 burnUnit);

    function wsgem() external view returns (address);
    /// @notice The underlying currency token; identical to `IERC4626.asset()`.
    function gem() external view returns (address);
    /// @notice Shares outstanding beyond the vault's wsgem balance (0 in normal operation).
    function deficit() external view returns (uint256);

    /// @notice The wsgem's NAV and fee-adjusted entry/exit units as last observed while the
    /// oracle was live. Views fall back to them only while the oracle is paused; execution
    /// never uses them.
    function lastNav() external view returns (uint256);
    function lastMintUnit() external view returns (uint256);
    function lastBurnUnit() external view returns (uint256);
    /// @notice Refresh the fallback values from the live oracle. Permissionless; reverts
    /// `InvalidPrice` while the oracle is paused. Every state-changing call also refreshes.
    function sync() external;

    function maxDepositWsgem(address receiver) external view returns (uint256 maxWsgemIn);
    function maxRedeemToWsgem(address owner) external view returns (uint256 maxShares);
    function previewDepositWsgem(uint256 wsgemIn) external view returns (uint256 shares);
    function previewRedeemToWsgem(uint256 shares) external view returns (uint256 wsgemOut);
    function depositWsgem(uint256 wsgemIn, address receiver) external returns (uint256 shares);
    function redeemToWsgem(uint256 shares, address receiver, address owner) external returns (uint256 wsgemOut);
}
