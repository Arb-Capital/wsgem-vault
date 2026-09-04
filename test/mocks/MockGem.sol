// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

/// @notice Test stand-in for a gem (the underlying currency token, e.g. tGBP): a plain
/// ERC20 that also carries the `isBanned` deny-list surface MaseerGuardOZ reads for
/// compliance screening. Gem decimals live entirely inside the oracle price scaling;
/// the default harness uses 18 to keep numbers WAD, and the decimals suite passes
/// 2/6/8 to prove the SY's decimals-agnostic claim.
contract MockGem {
    string public constant name = "Mock Gem";
    string public constant symbol = "GEM";
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBanned;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
        emit Transfer(address(0), to, amt);
    }

    function ban(address usr) external {
        isBanned[usr] = true;
    }

    function unban(address usr) external {
        isBanned[usr] = false;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        return _move(msg.sender, to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amt;
        return _move(from, to, amt);
    }

    function _move(address from, address to, uint256 amt) internal returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
        return true;
    }
}
