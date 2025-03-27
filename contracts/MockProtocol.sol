// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./MockToken.sol";

contract MockProtocol {
    MockToken public immutable baseToken;    // Like DAI
    MockToken public immutable yieldToken;   // Like aDAI or cDAI

    constructor(string memory baseSymbol, string memory yieldSymbol) {
        baseToken = new MockToken("Mock Base Token", baseSymbol);
        yieldToken = new MockToken("Mock Yield Token", yieldSymbol);
    }

    function deposit(uint256 amount) external {
        require(baseToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        yieldToken.mint(msg.sender, amount);
    }

    function withdraw(uint256 amount) external returns (uint256) {
        yieldToken.burn(msg.sender, amount);

        // Simulate yield by returning slightly more tokens
        uint256 yieldAmount = amount + (amount * 5 / 100); // 5% yield
        baseToken.mint(msg.sender, yieldAmount);

        return yieldAmount;
    }
}
