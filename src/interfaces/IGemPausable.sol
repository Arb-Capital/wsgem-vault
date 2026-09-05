// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

/// @notice Optional pause interface for supported gems, including tGBP.
/// A pausable gem must expose this getter when the vault is constructed.
interface IGemPausable {
    function paused() external view returns (bool);
}
