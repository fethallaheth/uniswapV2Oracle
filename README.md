# FixedWindowTWAPOracle Contract

A production-ready fixed-window TWAP Oracle for Uniswap V2 pairs. Provides manipulation-resistant price feeds using Uniswap's cumulative price mechanism with enhanced security features.

## WARNING 

This is not audited or tested code. Use at your own risk.

## Features

-  **Anti-manipulation**: Time-weighted prices over configurable windows
-  **Gas-efficient**: Optimized for minimal update costs
-  **Simple integration**: Easy-to-use consultation functions
-  **Configurable**: Adjustable TWAP window size
-  **Security-first**: Liquidity checks and circuit breaker
-  **Precision**: Fixed-point arithmetic for accurate pricing


## Installation

```bash
npm install @uniswap/v2-core @openzeppelin/contracts
```

## Usage

### Importing the Contract

```solidity
import "path/to/FixedWindowTWAPOracle.sol";

contract MyContract {
    FixedWindowTWAPOracle oracle;
    
    constructor(address oracleAddress) {
        oracle = FixedWindowTWAPOracle(oracleAddress);
    }
}
```

### Basic Operations

```javascript
// Initialize oracle
const oracle = await FixedWindowTWAPOracle.deploy(
  "0xA478c297...", // Uniswap V2 pair
  3600              // 1-hour window
);

// Update TWAP (call after each window)
await oracle.update();

// Get ETH price in DAI terms
const ethPrice = await oracle.getToken0Price();

// Convert 1 ETH to DAI equivalent
const daiAmount = await oracle.convertToken0ToToken1(
  ethers.utils.parseEther("1")
);
```

### Configuration

```javascript
// Change to 24-hour window (owner only)
await oracle.setWindowSize(86400);
```


## Security Best Practices

1. **Automate Updates**:
   ```javascript
   // Use Chainlink Keepers or Gelato
   setInterval(async () => {
     await oracle.update();
   }, 3600 * 1000);
   ```

2. **Monitor Health**:
   ```solidity
   function isPriceStale() public view returns (bool) {
     return (block.timestamp - lastTimestamp) > windowSize * 2;
   }
   ```

3. **Add Liquidity Checks**:
   ```solidity
   (uint112 r0, uint112 r1,) = pair.getReserves();
   require(r0 > minReserve0 && r1 > minReserve1, "Low liquidity");
   ```

4. **Combine with Chainlink**:
   ```solidity
   function getPrice(address token) public view returns (uint256) {
     if (oracle.isPriceStale()) {
       return chainlinkOracle.getPrice(token);
     }
     return oracle.getToken0Price();
   }
   ```

## Support

For integration support or security concerns, please open an issue on GitHub.