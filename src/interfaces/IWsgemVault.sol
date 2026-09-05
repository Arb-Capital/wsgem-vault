// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @title IWsgemVault
/// @notice The non-ERC-4626 surface of a wsgem vault: the fee-free wsgem legs (1:1 while
/// fully backed), the oracle fallback values, the solvency monitor, and the vault's own
/// errors and events.
interface IWsgemVault {
    /// @notice Outstanding shares exceed the wsgem backing by `deficit`. Deposits revert
    /// with this, as does a redemption that would release no wsgem.
    error Insolvent(uint256 deficit);

    /// @notice The wsgem's redemption cooldown is non-zero, so a gem redemption would not
    /// be paid atomically.
    error CooldownActive(uint256 cooldown);

    /// @notice The wsgem holds less gem than the redemption claim.
    error InsufficientLiquidity(uint256 available, uint256 required);

    /// @notice A wsgem call delivered an amount other than expected.
    error FillMismatch(uint256 expected, uint256 received);

    /// @notice `amount` wsgem deposited for `amount` shares.
    event DepositWsgem(address indexed sender, address indexed owner, uint256 amount);
    /// @notice `shares` burned for `wsgemOut` wsgem.
    event RedeemWsgem(
        address indexed sender, address indexed receiver, address indexed owner, uint256 shares, uint256 wsgemOut
    );
    /// @notice Fallback values refreshed from the live oracle.
    event Sync(uint256 nav, uint256 mintUnit, uint256 burnUnit);

    /// @notice The wsgem backing the shares.
    function wsgem() external view returns (address);
    /// @notice The gem; identical to `IERC4626.asset()`.
    function gem() external view returns (address);
    /// @notice Whether the gem exposed a valid `paused()` getter at construction.
    /// Gems without this interface must be non-pausable. Adding pause semantics later
    /// is an incompatible token upgrade requiring a new vault or an integration adapter.
    function gemPausable() external view returns (bool);
    /// @notice Whether the gem's detected pause state and compliance checks for both the
    /// vault and wsgem permit gem transfers. Excludes prices, markets, and user screening.
    /// A detected pause getter that subsequently fails is treated as unavailable.
    function gemTransfersAvailable() external view returns (bool);
    /// @notice Shares outstanding beyond the vault's wsgem balance. Non-zero only after a
    /// privileged burn of the vault's wsgem; while non-zero, deposits revert `Insolvent` and
    /// redemptions pay pro-rata. Cleared by transferring wsgem to the vault.
    function deficit() external view returns (uint256);

    /// @notice `navprice()` last observed live; used by quotes while the oracle is paused.
    function lastNav() external view returns (uint256);
    /// @notice `mintcost()` last observed live; used by quotes while the oracle is paused.
    function lastMintUnit() external view returns (uint256);
    /// @notice `burncost()` last observed live; used by quotes while the oracle is paused.
    function lastBurnUnit() external view returns (uint256);
    /// @notice Refreshes the fallback values from the live oracle; reverts `InvalidPrice`
    /// while paused or while a feed reverts. Every state-changing call also refreshes them
    /// when it can; failed, malformed, or over-budget reads leave the cached tuple untouched.
    function sync() external;
    /// @notice True while quotes read the live oracle rather than the fallback values.
    /// Fallback freshness is not guaranteed; integrations requiring live pricing should
    /// check this and fail closed.
    function oracleLive() external view returns (bool);

    /// @notice `type(uint256).max` while wsgem deposits are available, else 0.
    function maxDepositWsgem(address receiver) external view returns (uint256 maxWsgemIn);
    /// @notice Largest share redemption to wsgem `owner` can make now; 0 while unavailable.
    function maxRedeemToWsgem(address owner) external view returns (uint256 maxShares);
    /// @notice Shares for `wsgemIn`: 1:1.
    function previewDepositWsgem(uint256 wsgemIn) external view returns (uint256 shares);
    /// @notice Wsgem for `shares`: 1:1 while fully backed, pro-rata otherwise.
    function previewRedeemToWsgem(uint256 shares) external view returns (uint256 wsgemOut);
    /// @notice Deposits `wsgemIn` wsgem for `wsgemIn` shares.
    function depositWsgem(uint256 wsgemIn, address receiver) external returns (uint256 shares);
    /// @notice Burns `shares` for wsgem.
    function redeemToWsgem(uint256 shares, address receiver, address owner) external returns (uint256 wsgemOut);
}
