// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice Minimal interface for a wsgem token — a wrapped staked currency token, backed
/// by an underlying currency token (the "gem").
/// Errors are mirrored from the wsgem implementation so that preview reverts carry
/// selectors identical to the reverts of the real wsgem.mint() / wsgem.redeem() paths.
interface IWsgem {
    error MarketClosed();
    error InvalidPrice();
    error ExceedsCap();
    error DustThreshold(uint256 min);
    error NotAuthorized(address usr);

    /// @notice Deposit `amt` of gem, receive wsgem at mintcost(). Returns the exact minted amount.
    function mint(uint256 amt) external returns (uint256 _out);

    /// @notice Burn `amt` of wsgem (at least one whole wsgem) for gem at burncost(). Returns a
    /// redemption id, not an amount: the claim is queued and paid out by `exit(id)`, which the
    /// wsgem calls inline only when `cooldown()` is zero, and which pays at most the wsgem's
    /// current gem balance (partial fills leave the remainder claimable later).
    function redeem(uint256 amt) external returns (uint256 _id);

    function gem() external view returns (address);
    function navprice() external view returns (uint256);
    function mintcost() external view returns (uint256);
    function burncost() external view returns (uint256);
    function mintable() external view returns (bool);
    function burnable() external view returns (bool);
    function capacity() external view returns (uint256);
    function cooldown() external view returns (uint256);
    function canPass(address usr) external view returns (bool);
    function totalSupply() external view returns (uint256);
    function balanceOf(address usr) external view returns (uint256);
}
