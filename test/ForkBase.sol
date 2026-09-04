// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Fork-test gating: suites run only when an explicit RPC is configured
/// (`ETH_RPC_URL`, or `ALCHEMY_API_KEY` to compose one) and skip otherwise, so plain
/// offline `forge test` stays green and never leans on a rate-limited public endpoint.
abstract contract ForkBase is Test {
    bool internal skipFork;

    modifier onlyFork() {
        vm.skip(skipFork);
        _;
    }

    /// @dev Fork at `blockNumber` (0 = latest) when an explicit RPC is configured;
    /// otherwise flag the suite to skip. Returns whether the fork was created.
    function _forkOrSkip(uint256 blockNumber) internal returns (bool) {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            string memory key = vm.envOr("ALCHEMY_API_KEY", string(""));
            if (bytes(key).length > 0) {
                url = string.concat("https://eth-mainnet.g.alchemy.com/v2/", key);
            }
        }
        if (bytes(url).length == 0) {
            skipFork = true;
            return false;
        }
        if (blockNumber == 0) {
            vm.createSelectFork(url);
        } else {
            vm.createSelectFork(url, blockNumber);
        }
        return true;
    }
}
