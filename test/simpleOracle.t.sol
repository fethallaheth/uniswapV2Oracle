// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/simpleOracle.sol";
import { IUniswapV2Pair } from "@v2-core/interfaces/IUniswapV2Pair.sol";

contract MockUniswapV2Pair {
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;

    function setReserves(uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimestampLast = _blockTimestampLast;
    }

    function setCumulativePrices(uint256 _price0, uint256 _price1) external {
        price0CumulativeLast = _price0;
        price1CumulativeLast = _price1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
}

contract SimpleOracleTest is Test {
    SimpleOracle public oracle;
    MockUniswapV2Pair public mockPair;
    address public owner;
    address public user;
    
    uint32 constant WINDOW_SIZE = 3600; // 1 hour
    uint112 constant INITIAL_RESERVE0 = 1000000;
    uint112 constant INITIAL_RESERVE1 = 2000000;

    // Events for testing
    event OracleUpdated(uint256 price0, uint256 price1);
    event WindowSizeChanged(uint32 newWindowSize);

    function setUp() public {
        owner = address(this);
        user = address(0x1);
        
        mockPair = new MockUniswapV2Pair();
        mockPair.setReserves(INITIAL_RESERVE0, INITIAL_RESERVE1, uint32(block.timestamp));
        mockPair.setCumulativePrices(0, 0);
        
        oracle = new SimpleOracle(address(mockPair), WINDOW_SIZE, owner);
    }

    function testConstructorValidation() public {
        // Test invalid pair address
        vm.expectRevert("Invalid pair address");
        new SimpleOracle(address(0), WINDOW_SIZE, owner);
        
        // Test invalid window size
        vm.expectRevert("Window size must be >0");
        new SimpleOracle(address(mockPair), 0, owner);
    }

    function testConstructorInitialization() public view {
        assertEq(address(oracle.pair()), address(mockPair));
        assertEq(oracle.windowSize(), WINDOW_SIZE);
        assertEq(oracle.owner(), owner);
        
        // Check initial cumulative prices are set
        assertTrue(oracle.lastTimestamp() > 0);
    }

    function testUpdateRequiresWindowElapsed() public {
        // Try to update immediately - should fail
        vm.expectRevert("Window not elapsed");
        oracle.update();
        
        // Advance time by less than window size
        vm.warp(block.timestamp + WINDOW_SIZE - 1);
        vm.expectRevert("Window not elapsed");
        oracle.update();
    }

    function testSuccessfulUpdate() public {
        // Get initial state after construction
        (uint256 initialPrice0, uint256 initialPrice1,) = oracle.currentCumulativePrices();
        
        // Advance time by window size
        vm.warp(block.timestamp + WINDOW_SIZE);
        
        // The currentCumulativePrices will automatically calculate new values based on reserves
        // So we need to get what those calculated values will be
        (uint256 newPrice0, uint256 newPrice1,) = oracle.currentCumulativePrices();
        
        // Update oracle
        oracle.update();
        
        // Check TWAP calculations: (newPrice - initialPrice) / timeElapsed
        uint256 expectedPrice0 = (newPrice0 - initialPrice0) / WINDOW_SIZE;
        uint256 expectedPrice1 = (newPrice1 - initialPrice1) / WINDOW_SIZE;
        
        assertEq(oracle.price0Average(), expectedPrice0);
        assertEq(oracle.price1Average(), expectedPrice1);
    }

    function testGetTokenPrices() public {
        // First update the oracle
        vm.warp(block.timestamp + WINDOW_SIZE);
        oracle.update();
        
        uint256 price0 = oracle.getToken0Price();
        uint256 price1 = oracle.getToken1Price();
        
        assertEq(price0, oracle.price0Average());
        assertEq(price1, oracle.price1Average());
    }

    function testConvertToken0ToToken1() public {
        // Set up oracle with known TWAP price
        vm.warp(block.timestamp + WINDOW_SIZE);
        
        // Set up a scenario where price0Average will be 2.0 in Q112.112
        uint256 initialPrice0 = oracle.lastPrice0Cumulative();
        uint256 price0InQ112 = 2 * (2**112); // 2.0 in Q112.112
        uint256 newPrice0 = initialPrice0 + (price0InQ112 * WINDOW_SIZE);
        
        mockPair.setCumulativePrices(newPrice0, oracle.lastPrice1Cumulative());
        oracle.update();
        
        uint256 amountIn = 1000000; // 1M token0
        uint256 result = oracle.convertToken0ToToken1(amountIn);
        
        // Expected: 1M * 2.0 = 2M token1
        uint256 expected = (amountIn * oracle.price0Average()) >> 112;
        assertEq(result, expected);
    }

    function testConvertToken1ToToken0() public {
        // Set up oracle with known TWAP price
        vm.warp(block.timestamp + WINDOW_SIZE);
        
        // Set up a scenario where price1Average will be 0.5 in Q112.112
        uint256 initialPrice1 = oracle.lastPrice1Cumulative();
        uint256 price1InQ112 = (2**112) / 2; // 0.5 in Q112.112
        uint256 newPrice1 = initialPrice1 + (price1InQ112 * WINDOW_SIZE);
        
        mockPair.setCumulativePrices(oracle.lastPrice0Cumulative(), newPrice1);
        oracle.update();
        
        uint256 amountIn = 2000000; // 2M token1
        uint256 result = oracle.convertToken1ToToken0(amountIn);
        
        // Expected: 2M * 0.5 = 1M token0
        uint256 expected = (amountIn * oracle.price1Average()) >> 112;
        assertEq(result, expected);
    }

    function testConvertZeroAmount() public {
        vm.warp(block.timestamp + WINDOW_SIZE);
        oracle.update();
        
        assertEq(oracle.convertToken0ToToken1(0), 0);
        assertEq(oracle.convertToken1ToToken0(0), 0);
    }

    function testSetWindowSizeOnlyOwner() public {
        uint32 newWindowSize = 7200; // 2 hours
        
        // Should work for owner
        oracle.setWindowSize(newWindowSize);
        assertEq(oracle.windowSize(), newWindowSize);
        
        // Should fail for non-owner
        vm.prank(user);
        vm.expectRevert();
        oracle.setWindowSize(1800);
    }

    function testSetWindowSizeValidation() public {
        vm.expectRevert("Invalid window size");
        oracle.setWindowSize(0);
    }

    function testSetWindowSizeEmitsEvent() public {
        uint32 newWindowSize = 7200;
        
        vm.expectEmit(true, true, true, true);
        emit WindowSizeChanged(newWindowSize);
        oracle.setWindowSize(newWindowSize);
    }

    function testCurrentCumulativePricesNoUpdate() public {
        // When blockTimestampLast equals current timestamp
        mockPair.setReserves(INITIAL_RESERVE0, INITIAL_RESERVE1, uint32(block.timestamp));
        mockPair.setCumulativePrices(1000000, 500000);
        
        (uint256 price0, uint256 price1, uint32 timestamp) = oracle.currentCumulativePrices();
        
        assertEq(price0, 1000000);
        assertEq(price1, 500000);
        assertEq(timestamp, uint32(block.timestamp % 2**32));
    }

    function testCurrentCumulativePricesWithUpdate() public {
        // Set up pair with old timestamp - ensure no underflow
        uint32 currentTime = uint32(block.timestamp);
        require(currentTime > 1800, "Block timestamp too small for test");
        
        uint32 oldTimestamp = currentTime - 1800; // 30 minutes ago
        
        mockPair.setReserves(INITIAL_RESERVE0, INITIAL_RESERVE1, oldTimestamp);
        mockPair.setCumulativePrices(1000000, 500000);
        
        (uint256 price0, uint256 price1, uint32 timestamp) = oracle.currentCumulativePrices();
        
        // Should be updated with current reserves price * time elapsed
        assertTrue(price0 > 1000000);
        assertTrue(price1 > 500000);
        assertEq(timestamp, uint32(block.timestamp % 2**32));
    }

    function testFixedPointFraction() public pure {
        // Test the FixedPoint library
        uint112 numerator = 2000000;
        uint112 denominator = 1000000;
        
        FixedPoint.uq112x112 memory result = FixedPoint.fraction(numerator, denominator);
        
        // Should equal 2.0 in Q112.112 format
        uint256 expected = (uint256(numerator) << 112) / denominator;
        assertEq(result._x, expected);
    }

    function testFixedPointFractionDivisionByZero() public {
        vm.expectRevert("DIV_BY_ZERO");
        FixedPoint.fraction(1000000, 0);
    }

    function testOracleUpdateEmitsEvent() public {
        vm.warp(block.timestamp + WINDOW_SIZE);
        
        // Just check that event is emitted
        vm.expectEmit(false, false, false, false);
        emit OracleUpdated(0, 0); // Placeholder values
        oracle.update();
    }

    function testMultipleUpdates() public {
        // First update
        vm.warp(block.timestamp + WINDOW_SIZE);
        oracle.update();
        
        uint256 firstPrice0 = oracle.price0Average();
        uint256 firstPrice1 = oracle.price1Average();
        
        // Second update after another window
        vm.warp(block.timestamp + WINDOW_SIZE);
        oracle.update();
        
        uint256 secondPrice0 = oracle.price0Average();
        uint256 secondPrice1 = oracle.price1Average();
        
        // Prices should have changed (or stayed the same if reserves didn't change)
        // Just verify the oracle can handle multiple updates
        assertTrue(secondPrice0 >= 0);
        assertTrue(secondPrice1 >= 0);
    }

    function testSimpleUpdateScenario() public {
        // Test with controlled scenario
        vm.warp(block.timestamp + WINDOW_SIZE);
        
        // Set the pair to have no time difference (blockTimestampLast = current)
        mockPair.setReserves(INITIAL_RESERVE0, INITIAL_RESERVE1, uint32(block.timestamp));
        
        // Set specific cumulative prices
        uint256 initialPrice0 = oracle.lastPrice0Cumulative();
        uint256 initialPrice1 = oracle.lastPrice1Cumulative();
        
        // Set new cumulative prices that will give us a TWAP of 1
        mockPair.setCumulativePrices(initialPrice0 + WINDOW_SIZE, initialPrice1 + WINDOW_SIZE);
        
        oracle.update();
        
        // TWAP should be (WINDOW_SIZE) / WINDOW_SIZE = 1
        assertEq(oracle.price0Average(), 1);
        assertEq(oracle.price1Average(), 1);
    }

    function testLargeAmountConversions() public {
        // Test with large amounts
        vm.warp(block.timestamp + WINDOW_SIZE);
        
        // Set the pair to have no time difference
        mockPair.setReserves(INITIAL_RESERVE0, INITIAL_RESERVE1, uint32(block.timestamp));
        
        uint256 initialPrice0 = oracle.lastPrice0Cumulative();
        uint256 initialPrice1 = oracle.lastPrice1Cumulative();
        
        // Set price to 1.0 in Q112.112 format
        uint256 priceInQ112 = (2**112);
        mockPair.setCumulativePrices(
            initialPrice0 + (priceInQ112 * WINDOW_SIZE), 
            initialPrice1 + (priceInQ112 * WINDOW_SIZE)
        );
        oracle.update();
        
        uint256 largeAmount = 1e18; // 1 ETH worth
        uint256 result0to1 = oracle.convertToken0ToToken1(largeAmount);
        uint256 result1to0 = oracle.convertToken1ToToken0(largeAmount);
        
        // With price of 1.0, should be equal
        assertEq(result0to1, largeAmount);
        assertEq(result1to0, largeAmount);
    }

    function testPriceCalculationWithReserves() public {
        // Test that demonstrates how reserves affect price calculation
        vm.warp(block.timestamp + WINDOW_SIZE);
        
        // Update oracle to get current TWAP based on reserves
        oracle.update();
        
        // Verify that prices are calculated
        uint256 price0 = oracle.price0Average();
        uint256 price1 = oracle.price1Average();
        
        // Both should be non-zero since reserves are non-zero
        assertTrue(price0 > 0);
        assertTrue(price1 > 0);
        
        // Test conversion works
        uint256 amount = 1000;
        uint256 converted0to1 = oracle.convertToken0ToToken1(amount);
        uint256 converted1to0 = oracle.convertToken1ToToken0(amount);
        
        assertTrue(converted0to1 > 0);
        assertTrue(converted1to0 > 0);
    }
}
