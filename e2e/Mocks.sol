// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// Stand-in for Robinhood's ArbSys precompile on a local devnet.
contract LiveArbSys {
    function arbBlockNumber() external view returns (uint256) { return block.number; }
    function arbBlockHash(uint256 n) external view returns (bytes32) {
        require(n < block.number && n + 256 >= block.number, "range");
        return blockhash(n);
    }
}

contract MockIMD {
    string public name = "Identity.md";
    string public symbol = "IMD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function mint(address to, uint256 a) external { balanceOf[to] += a; emit Transfer(address(0), to, a); }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; emit Transfer(msg.sender, to, a); return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; emit Transfer(f, to, a); return true;
    }
}
