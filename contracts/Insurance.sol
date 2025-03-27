// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./Tranche.sol";
import "./ITranche.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAaveLendingPool {
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

interface IcDAI is IERC20 {
    function mint(uint256 mintAmount) external returns (uint256);

    function redeem(uint256 redeemTokens) external returns (uint256);
}

/// @title Multi-Protocol DeFi Insurance
/// @notice A DeFi insurance system that splits risk between two tranches and invests in multiple protocols
contract MultiProtocolInsurance {
    // Contract addresses for protocols and tokens
    address public A; // Senior tranche token contract
    address public B; // Junior tranche token contract
    address public c = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // DAI token
    address public x = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9; // Aave v2 lending pool
    address public cx = 0x028171bCA77440897B824Ca71D1c56caC55b68A3; // aDAI token
    address public cy = 0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643; // cDAI token

    // Constant for decimal math operations (1e27)
    uint256 constant RAY = 1e27;

    // Timestamp constants for different periods
    uint256 public immutable S; // End of deposit period
    uint256 public immutable T1; // End of investment period
    uint256 public immutable T2; // End of senior tranche claim period
    uint256 public immutable T3; // End of junior tranche claim period

    // State variables
    uint256 public totalTranches; // Total supply of both tranches
    bool public isInvested; // Tracks if funds are invested
    bool public inLiquidMode; // True if in DAI distribution mode

    // Payout calculations
    uint256 public cPayoutA; // Senior tranche DAI payout ratio
    uint256 public cPayoutB; // Junior tranche DAI payout ratio
    uint256 public cxPayout; // aDAI payout ratio per tranche
    uint256 public cyPayout; // cDAI payout ratio per tranche

    // Events
    event RiskSplit(address indexed splitter, uint256 amount_c);
    event Invest(
        uint256 amount_c,
        uint256 amount_cx,
        uint256 amount_cy,
        uint256 amount_c_incentive
    );
    event Divest(
        uint256 amount_c,
        uint256 amount_cx,
        uint256 amount_cy,
        uint256 amount_c_incentive
    );
    event Claim(
        address indexed claimant,
        uint256 amount_A,
        uint256 amount_B,
        uint256 amount_c,
        uint256 amount_cx,
        uint256 amount_cy
    );

    constructor() {
        A = address(new Tranche("Senior Tranche", "SNR"));
        B = address(new Tranche("Junior Tranche", "JNR"));
        S = block.timestamp + 3600 * 24 * 7; // 7 days deposit period
        T1 = S + 3600 * 24 * 28; // 28 days investment period
        T2 = T1 + 3600 * 24 * 1; // 1 day senior claim window
        T3 = T2 + 3600 * 24 * 3; // 3 days junior claim window
    }

    function splitRisk(uint256 amount_c) public {
        require(block.timestamp < S, "deposit period ended");
        require(amount_c > 1, "amount too low");

        if (amount_c % 2 != 0) {
            amount_c -= 1; // Ensure even amount for equal split
        }

        require(
            IERC20(c).transferFrom(msg.sender, address(this), amount_c),
            "DAI transfer failed"
        );

        ITranche(A).mint(msg.sender, amount_c / 2);
        ITranche(B).mint(msg.sender, amount_c / 2);

        emit RiskSplit(msg.sender, amount_c);
    }

    function invest() public {
        require(!isInvested, "already invested");
        require(block.timestamp >= S, "deposit period active");
        require(block.timestamp < T1, "investment period ended");

        address me = address(this);
        IERC20 cToken = IERC20(c);
        uint256 balance_c = cToken.balanceOf(me);
        require(balance_c > 0, "no DAI available");
        totalTranches = ITranche(A).totalSupply() * 2;

        // Split investment between Aave and Compound
        cToken.approve(x, balance_c / 2);
        IAaveLendingPool(x).deposit(c, balance_c / 2, me, 0);

        require(IcDAI(cy).mint(balance_c / 2) == 0, "cDAI minting failed");

        isInvested = true;
        emit Invest(
            balance_c,
            IERC20(cx).balanceOf(me),
            IERC20(cy).balanceOf(me),
            0
        );
    }

    function divest() public {
        require(block.timestamp >= T1, "investment period active");
        require(block.timestamp < T2, "claim period started");

        IERC20 cToken = IERC20(c);
        IERC20 cxToken = IERC20(cx);
        IcDAI cyToken = IcDAI(cy);
        address me = address(this);

        uint256 halfOfTranches = totalTranches / 2;
        uint256 balance_cx = cxToken.balanceOf(me);
        uint256 balance_cy = cyToken.balanceOf(me);
        require(balance_cx > 0 && balance_cy > 0, "no tokens to redeem");
        uint256 interest;

        // Withdraw from Aave
        uint256 balance_c = cToken.balanceOf(me);
        IAaveLendingPool(x).withdraw(c, balance_cx, me);
        uint256 withdrawn_x = cToken.balanceOf(me) - balance_c;
        if (withdrawn_x > halfOfTranches) {
            interest += withdrawn_x - halfOfTranches;
        }

        // Withdraw from Compound
        require(cyToken.redeem(balance_cy) == 0, "cDAI redemption failed");
        uint256 withdrawn_y = cToken.balanceOf(me) - balance_c - withdrawn_x;
        if (withdrawn_y > halfOfTranches) {
            interest += withdrawn_y - halfOfTranches;
        }

        require(
            cxToken.balanceOf(me) == 0 && cyToken.balanceOf(me) == 0,
            "token redemption incomplete"
        );

        // Calculate payouts
        inLiquidMode = true;
        balance_c = cToken.balanceOf(me);
        if (balance_c >= totalTranches) {
            // No losses - equal split
            cPayoutA = (RAY * balance_c) / totalTranches;
            cPayoutB = cPayoutA;
        } else if (balance_c > halfOfTranches) {
            // Senior tranche fully covered
            cPayoutA = (RAY * interest) / halfOfTranches + RAY;
            cPayoutB =
                (RAY * (balance_c - halfOfTranches - interest)) /
                halfOfTranches;
        } else {
            // Losses affect both tranches
            cPayoutA = (RAY * balance_c) / halfOfTranches;
            cPayoutB = 0;
        }

        emit Divest(balance_c, balance_cx, balance_cy, 0);
    }

    function claimA(uint256 tranches_to_cx, uint256 tranches_to_cy) public {
        if (!isInvested && !inLiquidMode && block.timestamp >= T1) {
            inLiquidMode = true;
        }
        if (inLiquidMode) {
            claim(tranches_to_cx + tranches_to_cy, 0);
            return;
        }
        require(block.timestamp >= T2, "senior claim period not started");
        _claimFallback(tranches_to_cx, tranches_to_cy, A);
    }

    function claimB(uint256 tranches_to_cx, uint256 tranches_to_cy) public {
        if (!isInvested && !inLiquidMode && block.timestamp >= T1) {
            inLiquidMode = true;
        }
        if (inLiquidMode) {
            claim(0, tranches_to_cx + tranches_to_cy);
            return;
        }
        require(block.timestamp >= T3, "junior claim period not started");
        _claimFallback(tranches_to_cx, tranches_to_cy, B);
    }

    function _claimFallback(
        uint256 tranches_to_cx,
        uint256 tranches_to_cy,
        address trancheAddress
    ) internal {
        require(tranches_to_cx > 0 || tranches_to_cy > 0, "no tokens to claim");

        ITranche tranche = ITranche(trancheAddress);
        require(
            tranche.balanceOf(msg.sender) >= tranches_to_cx + tranches_to_cy,
            "insufficient tranche balance"
        );

        uint256 amount_A;
        uint256 amount_B;
        if (trancheAddress == A) {
            amount_A = tranches_to_cx + tranches_to_cy;
        } else if (trancheAddress == B) {
            amount_B = tranches_to_cx + tranches_to_cy;
        }

        uint256 payout_cx;
        uint256 payout_cy;

        if (tranches_to_cx > 0) {
            IERC20 cxToken = IERC20(cx);
            if (cxPayout == 0) {
                cxPayout =
                    (RAY * cxToken.balanceOf(address(this))) /
                    totalTranches /
                    2;
            }
            tranche.burn(msg.sender, tranches_to_cx);
            payout_cx = (tranches_to_cx * cxPayout) / RAY;
            cxToken.transfer(msg.sender, payout_cx);
        }

        if (tranches_to_cy > 0) {
            IERC20 cyToken = IERC20(cy);
            if (cyPayout == 0) {
                cyPayout =
                    (RAY * cyToken.balanceOf(address(this))) /
                    totalTranches /
                    2;
            }
            tranche.burn(msg.sender, tranches_to_cy);
            payout_cy = (tranches_to_cy * cyPayout) / RAY;
            cyToken.transfer(msg.sender, payout_cy);
        }

        emit Claim(msg.sender, amount_A, amount_B, 0, payout_cx, payout_cy);
    }

    function claimAll() public {
        uint256 balance_A = ITranche(A).balanceOf(msg.sender);
        uint256 balance_B = ITranche(B).balanceOf(msg.sender);
        require(balance_A > 0 || balance_B > 0, "no tranche tokens owned");
        claim(balance_A, balance_B);
    }

    function claim(uint256 amount_A, uint256 amount_B) public {
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

        require(amount_A > 0 || amount_B > 0, "no tokens to claim");

        uint256 payout_c;

        if (amount_A > 0) {
            ITranche tranche_A = ITranche(A);
            require(
                tranche_A.balanceOf(msg.sender) >= amount_A,
                "insufficient senior tokens"
            );
            tranche_A.burn(msg.sender, amount_A);
            payout_c += (cPayoutA * amount_A) / RAY;
        }

        if (amount_B > 0) {
            ITranche tranche_B = ITranche(B);
            require(
                tranche_B.balanceOf(msg.sender) >= amount_B,
                "insufficient junior tokens"
            );
            tranche_B.burn(msg.sender, amount_B);
            payout_c += (cPayoutB * amount_B) / RAY;
        }

        if (payout_c > 0) {
            IERC20(c).transfer(msg.sender, payout_c);
        }

        emit Claim(msg.sender, amount_A, amount_B, payout_c, 0, 0);
    }
}
