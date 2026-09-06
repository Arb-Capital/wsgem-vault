// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

/// @title IWsgem
/// @notice Minimal interface of a wsgem token (a wrapped staked currency token over a gem).
/// Errors mirror the wsgem's own so the vault reverts with identical selectors.
interface IWsgem {
    error MarketClosed();
    error InvalidPrice();
    error ExceedsCap();
    error DustThreshold(uint256 min);
    error NotAuthorized(address usr);

    /// @notice Deposits `amt` gem for wsgem at `mintcost()`; returns the wsgem minted.
    function mint(uint256 amt) external returns (uint256 _out);

    /// @notice Burns `amt` wsgem (at least 1e18) for gem at `burncost()`; returns a
    /// redemption id. The claim is paid inline only while `cooldown()` is 0, and at most
    /// the wsgem's current gem balance.
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
