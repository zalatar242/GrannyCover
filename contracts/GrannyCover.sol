// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./Tranche.sol";
import "./ITranche.sol";
import "./MockToken.sol";
import "./MockProtocol.sol";

contract GrannyCover {
    // Tranche token contracts
    address public A;  // Tranche A token contract
    address public B;  // Tranche B token contract

    // Mock protocols and tokens
    MockToken public baseToken;      // Base token (like DAI)
    MockProtocol public protocolX;   // First yield protocol
    MockProtocol public protocolY;   // Second yield protocol

    // Math constant for decimal precision
    uint256 constant RAY = 1e27;

    // Time periods
    uint256 public immutable S;  // End of deposit period
    uint256 public immutable T1; // End of investment period
    uint256 public immutable T2; // End of Tranche A claim period
    uint256 public immutable T3; // End of Tranche B claim period

    // State tracking
    uint256 public totalTranches;  // Total supply of both tranches
    bool public isInvested;       // True if funds are invested
    bool public inLiquidMode;     // True if in direct token distribution mode

    // Payout ratios (scaled by RAY)
    uint256 public basePayoutA;   // Tranche A base token payout ratio
    uint256 public basePayoutB;   // Tranche B base token payout ratio
    uint256 public xPayoutRatio;  // Protocol X yield token payout ratio
    uint256 public yPayoutRatio;  // Protocol Y yield token payout ratio

    // Events
    event RiskSplit(address indexed splitter, uint256 amount);
    event Invest(uint256 amount, uint256 amountX, uint256 amountY);
    event Divest(uint256 baseAmount, uint256 xAmount, uint256 yAmount);
    event Claim(
        address indexed claimant,
        uint256 amountA,
        uint256 amountB,
        uint256 baseAmount,
        uint256 xAmount,
        uint256 yAmount
    );

    constructor() {
        A = address(new Tranche("Tranche A", "TRNA"));
        B = address(new Tranche("Tranche B", "TRNB"));

        // Create mock tokens and protocols
        baseToken = new MockToken("Base Token", "BASE");
        protocolX = new MockProtocol("BASE", "yX");
        protocolY = new MockProtocol("BASE", "yY");

        // Initialize time periods
        S = block.timestamp + 3600 * 24 * 7;   // 7 days deposit period
        T1 = S + 3600 * 24 * 28;              // 28 days investment period
        T2 = T1 + 3600 * 24 * 1;              // 1 day Tranche A claim window
        T3 = T2 + 3600 * 24 * 3;              // 3 days Tranche B claim window

        // Mint initial tokens for testing
        baseToken.mint(msg.sender, 1000000 * 10**18);
    }

    function splitRisk(uint256 amount) public {
        require(block.timestamp < S, "deposit period ended");
        require(amount > 1, "amount too low");

        if (amount % 2 != 0) {
            amount -= 1; // Ensure even amount for equal split
        }

        require(
            baseToken.transferFrom(msg.sender, address(this), amount),
            "token transfer failed"
        );

        ITranche(A).mint(msg.sender, amount / 2);
        ITranche(B).mint(msg.sender, amount / 2);

        emit RiskSplit(msg.sender, amount);
    }

    function invest() public {
        require(!isInvested, "already invested");
        require(block.timestamp >= S, "deposit period active");
        require(block.timestamp < T1, "investment period ended");

        uint256 balance = baseToken.balanceOf(address(this));
        require(balance > 0, "no tokens available");
        totalTranches = ITranche(A).totalSupply() * 2;

        // Approve and deposit into both protocols
        uint256 halfAmount = balance / 2;
        baseToken.approve(address(protocolX), halfAmount);
        baseToken.approve(address(protocolY), halfAmount);

        protocolX.deposit(halfAmount);
        protocolY.deposit(halfAmount);

        isInvested = true;
        emit Invest(
            balance,
            protocolX.yieldToken().balanceOf(address(this)),
            protocolY.yieldToken().balanceOf(address(this))
        );
    }

    function divest() public {
        require(block.timestamp >= T1, "investment period active");
        require(block.timestamp < T2, "claim period started");

        uint256 halfOfTranches = totalTranches / 2;
        uint256 xBalance = protocolX.yieldToken().balanceOf(address(this));
        uint256 yBalance = protocolY.yieldToken().balanceOf(address(this));

        require(xBalance > 0 && yBalance > 0, "no tokens to withdraw");

        // Withdraw from both protocols
        uint256 baseBalance = baseToken.balanceOf(address(this));
        uint256 xWithdrawn = protocolX.withdraw(xBalance);
        uint256 yWithdrawn = protocolY.withdraw(yBalance);
        uint256 totalWithdrawn = xWithdrawn + yWithdrawn;

        // Calculate interest earned
        uint256 interest = 0;
        if (totalWithdrawn > totalTranches) {
            interest = totalWithdrawn - totalTranches;
        }

        // Set payout ratios
        inLiquidMode = true;
        if (totalWithdrawn >= totalTranches) {
            basePayoutA = (RAY * totalWithdrawn) / totalTranches;
            basePayoutB = basePayoutA;
        } else if (totalWithdrawn > halfOfTranches) {
            // Tranche A gets their investment back plus all interest
            basePayoutA = (RAY * interest) / halfOfTranches + RAY;
            basePayoutB = (RAY * (totalWithdrawn - halfOfTranches - interest)) / halfOfTranches;
        } else {
            // Not enough to fully cover Tranche A
            basePayoutA = (RAY * totalWithdrawn) / halfOfTranches;
            basePayoutB = 0;
        }

        emit Divest(totalWithdrawn, xWithdrawn, yWithdrawn);
    }

    function claimA(uint256 amount) public {
        if (!isInvested && !inLiquidMode && block.timestamp >= T1) {
            inLiquidMode = true;
        }
        if (inLiquidMode) {
            claim(amount, 0);
            return;
        }
        require(block.timestamp >= T2, "Tranche A claim period not started");
        _claimFromProtocols(amount, true);
    }

    function claimB(uint256 amount) public {
        if (!isInvested && !inLiquidMode && block.timestamp >= T1) {
            inLiquidMode = true;
        }
        if (inLiquidMode) {
            claim(0, amount);
            return;
        }
        require(block.timestamp >= T3, "Tranche B claim period not started");
        _claimFromProtocols(amount, false);
    }

    function _claimFromProtocols(uint256 amount, bool isTrancheA) internal {
        require(amount > 0, "no amount specified");

        address tranche = isTrancheA ? A : B;
        ITranche trancheToken = ITranche(tranche);
        require(
            trancheToken.balanceOf(msg.sender) >= amount,
            "insufficient tranche balance"
        );

        if (xPayoutRatio == 0) {
            xPayoutRatio = (RAY * protocolX.yieldToken().balanceOf(address(this))) / totalTranches / 2;
        }
        if (yPayoutRatio == 0) {
            yPayoutRatio = (RAY * protocolY.yieldToken().balanceOf(address(this))) / totalTranches / 2;
        }

        trancheToken.burn(msg.sender, amount);

        uint256 xPayout = (amount * xPayoutRatio) / RAY;
        uint256 yPayout = (amount * yPayoutRatio) / RAY;

        if (xPayout > 0) protocolX.yieldToken().transfer(msg.sender, xPayout);
        if (yPayout > 0) protocolY.yieldToken().transfer(msg.sender, yPayout);

        emit Claim(
            msg.sender,
            isTrancheA ? amount : 0,
            isTrancheA ? 0 : amount,
            0,
            xPayout,
            yPayout
        );
    }

    function claimAll() public {
        uint256 balanceA = ITranche(A).balanceOf(msg.sender);
        uint256 balanceB = ITranche(B).balanceOf(msg.sender);
        require(balanceA > 0 || balanceB > 0, "no tranche tokens owned");
        claim(balanceA, balanceB);
    }

    function claim(uint256 amountA, uint256 amountB) public {
        if (!inLiquidMode) {
            if (!isInvested && block.timestamp >= T1) {
                inLiquidMode = true;
            } else {
                if (block.timestamp < T1) {
                    revert("cannot claim during investment period");
                } else if (block.timestamp < T2) {
                    revert("divestment required first");
                } else {
                    revert("use claimA() or claimB()");
                }
            }
        }

        require(amountA > 0 || amountB > 0, "no tokens to claim");
        uint256 payout = 0;

        if (amountA > 0) {
            ITranche trancheA = ITranche(A);
            require(
                trancheA.balanceOf(msg.sender) >= amountA,
                "insufficient Tranche A balance"
            );
            trancheA.burn(msg.sender, amountA);
            payout += (basePayoutA * amountA) / RAY;
        }

        if (amountB > 0) {
            ITranche trancheB = ITranche(B);
            require(
                trancheB.balanceOf(msg.sender) >= amountB,
                "insufficient Tranche B balance"
            );
            trancheB.burn(msg.sender, amountB);
            payout += (basePayoutB * amountB) / RAY;
        }

        if (payout > 0) {
            baseToken.transfer(msg.sender, payout);
        }

        emit Claim(msg.sender, amountA, amountB, payout, 0, 0);
    }
}
