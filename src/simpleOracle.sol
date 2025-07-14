// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { IUniswapV2Pair} from "@v2-core/interfaces/IUniswapV2Pair.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


contract SimpleOracle is Ownable {
    IUniswapV2Pair public immutable pair;
    uint32 public windowSize;  // TWAP window in seconds (e.g., 3600 = 1 hour)

    // Last recorded cumulative prices
    uint256 public lastPrice0Cumulative;
    uint256 public lastPrice1Cumulative;
    uint32 public lastTimestamp;
    
    // TWAP results
    uint256 public price0Average;
    uint256 public price1Average;
    event OracleUpdated(uint256 price0, uint256 price1);
    event WindowSizeChanged(uint32 newWindowSize);

    constructor(address _pair, uint32 _windowSize, address _Owner) Ownable(_Owner) {
        require(_pair != address(0), "Invalid pair address");
        require(_windowSize > 0, "Window size must be >0");
        
        pair = IUniswapV2Pair(_pair);
        windowSize = _windowSize;
        
        // Initialize with current prices
        (lastPrice0Cumulative, lastPrice1Cumulative, lastTimestamp) = 
            currentCumulativePrices();
    }

      /// @notice Update the TWAP - must be called at least once per window
    function update() external {
        (uint256 currentPrice0Cumulative, 
         uint256 currentPrice1Cumulative, 
         uint32 currentTimestamp) = currentCumulativePrices();
         
        uint32 timeElapsed = currentTimestamp - lastTimestamp;
        require(timeElapsed >= windowSize, "Window not elapsed");

        // Calculate TWAPs
        price0Average = (currentPrice0Cumulative - lastPrice0Cumulative) / timeElapsed;
        price1Average = (currentPrice1Cumulative - lastPrice1Cumulative) / timeElapsed;

        // Update state
        lastPrice0Cumulative = currentPrice0Cumulative;
        lastPrice1Cumulative = currentPrice1Cumulative;
        lastTimestamp = currentTimestamp;
        
        emit OracleUpdated(price0Average, price1Average);
    }
      /// @notice Get price for token0 in terms of token1
    function getToken0Price() external view returns (uint256) {
        return price0Average;
    }
    
    /// @notice Get price for token1 in terms of token0
    function getToken1Price() external view returns (uint256) {
        return price1Average;
    }
    
    /// @notice Convert token0 amount to token1 using TWAP
    function convertToken0ToToken1(uint256 amountIn) external view returns (uint256) {
        return (amountIn * price0Average) >> 112; // Divide by 2^112 (Q112.112 format)
    }
    
    /// @notice Convert token1 amount to token0 using TWAP
    function convertToken1ToToken0(uint256 amountIn) external view returns (uint256) {
        return (amountIn * price1Average) >> 112; // Divide by 2^112 (Q112.112 format)
    }
    
    /// @notice Change the TWAP window size (owner only)
    function setWindowSize(uint32 newWindowSize) external onlyOwner {
        require(newWindowSize > 0, "Invalid window size");
        windowSize = newWindowSize;
        emit WindowSizeChanged(newWindowSize);
    }

    /// @notice Get current cumulative prices with up-to-date calculation
    function currentCumulativePrices()
        public
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 timestamp
        )
    {
        timestamp = currentBlockTimestamp();
        price0Cumulative = pair.price0CumulativeLast();
        price1Cumulative = pair.price1CumulativeLast();
        
        // Get current reserves
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = pair.getReserves();
        
        // Update cumulative prices if needed
        if (blockTimestampLast != timestamp) {
            uint32 timeElapsed = timestamp - blockTimestampLast;
            price0Cumulative += uint256(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            price1Cumulative += uint256(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }
    
    /// @notice Get current block  safe to prevent overflow in % 2**32 2106 
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2**32);
    }

}


// Minimal fixed-point library for Uniswap calculations
library FixedPoint {
    struct uq112x112 {
        uint224 _x;
    }
    
    function fraction(uint112 numerator, uint112 denominator) internal pure returns (uq112x112 memory) {
        require(denominator > 0, "DIV_BY_ZERO");
        return uq112x112((uint224(numerator) << 112) / denominator);
    }
}
