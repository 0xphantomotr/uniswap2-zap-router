# Uniswap V2 Zap Router (`Univ2ZapRouter.sol`)

## Overview

`Univ2ZapRouter` is a smart contract designed to simplify liquidity provision and removal on Uniswap V2. It enables users to "zap" into or out of a liquidity pool using a single input token (either ETH or an ERC20 token). The contract automatically handles the necessary swaps and liquidity operations, and for "zap-ins," it aims to calculate an optimal swap amount to maximize the LP tokens received by the user, considering Uniswap's 0.3% trading fee.

This project is built using [Foundry](https://book.getfoundry.sh/).

## Key Features

*   **Single Token Zap-In:** Add liquidity to a Uniswap V2 pair using a single input token (ETH or ERC20).
    *   Calculates an optimal amount of the input token to swap for the other token in the pair to maximize LP tokens minted.
*   **Single Token Zap-Out:** Remove liquidity and receive a single output token (ETH or ERC20).
    *   Withdraws both tokens from the pair and swaps one into the desired output token.
*   **Handles ETH and ERC20 tokens:** Automatically wraps/unwraps ETH to WETH where necessary.
*   **Fee-on-Transfer Token Support:** Includes logic paths for interacting with tokens that may have fees on transfer.
*   **Gas Optimized:** Implemented with various gas-saving techniques (see Gas Optimizations section).
*   **Reentrancy Protected:** Uses OpenZeppelin's `ReentrancyGuard` for enhanced security.
*   **Event Emissions:** Emits `ZapIn` and `ZapOut` events for off-chain tracking.

## How It Works

### Zap-In (`zapInSingleToken`)

1.  The user provides a single input token (`tokenIn`) and specifies the pair (`tokenA`, `tokenB`) they want to add liquidity to.
2.  The contract calculates an optimal amount (`toSwap`) of `tokenIn` to swap for the other token in the pair. This calculation aims to provide liquidity in the new optimal ratio post-swap, maximizing LP tokens received.
3.  If `tokenIn` is not one of the pair tokens, this scenario is not directly supported by `zapInSingleToken` (it assumes `tokenIn` is either `tokenA` or `tokenB`).
4.  The `toSwap` amount of `tokenIn` is swapped for the other pair token.
5.  The remaining `amountIn - toSwap` of `tokenIn` and the received amount of the other token are then added as liquidity to the Uniswap V2 pair.
6.  LP tokens are sent to the user.

### Zap-Out (`zapOutSingleToken`)

1.  The user provides LP tokens for a specific pair (`tokenA`, `tokenB`) and specifies the single output token (`tokenOut`) they wish to receive.
2.  The contract removes liquidity, receiving `tokenA` and `tokenB` from the pair.
3.  If `tokenOut` is `tokenA`, the received `tokenB` is swapped for `tokenA`. The total `tokenA` (initial + swapped) is sent to the user.
4.  If `tokenOut` is `tokenB`, the received `tokenA` is swapped for `tokenB`. The total `tokenB` (initial + swapped) is sent to the user.

## Development Setup

### Prerequisites

*   [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

Compile the smart contracts:
```shell
forge build
```

### Test

Run the test suite:
```shell
forge test
```

To see gas reports:
```shell
forge test --gas-report
```

Or, for more detailed verbosity on tests:
```shell
forge test -vvv
```

### Format

Ensure code is formatted correctly:
```shell
forge fmt
```

## Gas Optimizations Report

**Objective:** To reduce the gas consumption of key functions in `Univ2ZapRouter.sol` and its deployment cost.

**Optimizations Applied:**
1.  **Address Caching:** Cached `address(this)` and `address(router)` in local stack variables within `zapInSingleToken` and `zapOutSingleToken` to reduce repeated lookups.
2.  **Efficient Address Passing:** Passed cached addresses as arguments to internal helper functions (`_swapForPair`, `_addLiquidity`) to avoid redundant lookups within them.
3.  **Targeted `unchecked` Math:** Applied `unchecked` to the arithmetic `amountIn - toSwap` in `_swapForPair`, as its safety is guaranteed by prior `require` statements.
4.  **Optimized Fee-on-Transfer Swap Logic:** Refined `_swapForPair` to calculate the received amount for fee-on-transfer tokens by taking a balance snapshot before and after the swap, ensuring accurate accounting.

**Gas Consumption Comparison:**

| Metric                | Original State | Optimized State | Savings         | % Savings (Approx) |
| :-------------------- | :------------- | :-------------- | :-------------- | :----------------- |
| Deployment Cost (gas) | 2,572,729      | 2,489,135       | **83,594 gas**  | 3.25%              |
| Deployment Size (bytes)| 12,415         | 11,939          | **476 bytes**   | 3.83%              |
|                       |                |                 |                 |                    |
| **`zapInSingleToken`**|                |                 |                 |                    |
| Avg Gas per Call      | 318,653        | 317,954         | **699 gas**     | 0.22%              |
|                       |                |                 |                 |                    |
| **`zapOutSingleToken`**|               |                 |                 |                    |
| Avg Gas per Call      | 256,524        | 255,749         | **775 gas**     | 0.30%              |

**Summary:**
The applied optimizations resulted in notable improvements:
*   A significant reduction in **deployment cost by 83,594 gas** and **contract size by 476 bytes**.
*   Modest but consistent gas savings for runtime function calls:
    *   `zapInSingleToken` is now cheaper by approximately **699 gas** on average per call.
    *   `zapOutSingleToken` is now cheaper by approximately **775 gas** on average per call.

These changes enhance the efficiency of the `Univ2ZapRouter` contract.

## Mathematical Derivations

### Optimal Swap Amount for Zap-In (`_optimalSwap`)

The `_optimalSwap(amountIn, reserveIn)` function calculates the portion of `amountIn` that should be swapped to the other token in the pair to maximize LP tokens received, assuming a 0.3% trading fee (where `tokenIn` is one of the assets in the pair, and `reserveIn` is its corresponding reserve in the pool).

The formula implemented is:
`toSwap = (sqrt(reserveIn * (amountIn * 3988000 + reserveIn * 3988009)) - reserveIn * 1997) / 1994`

The constants (3988000, 3988009, 1997, 1994) are derived from algebraic manipulation of the Uniswap V2 constant product formula, accounting for the 0.3% swap fee, to find the value of `toSwap` (`x` in many derivations) that maximizes the liquidity provided.

*(A more detailed step-by-step derivation can be added here if desired. This often involves:
1. Defining reserves before swap (`R_in`, `R_out`).
2. Defining amounts after swap (`R_in - toSwap + amountSwappedIn`, `R_out - amountReceivedFromSwap`).
3. Accounting for Uniswap fee: `amountReceivedFromSwap = (toSwap * 0.997 * R_out) / (R_in + toSwap * 0.997)`.
4. Maximizing the product of the new reserves (or a function proportional to LP tokens, like `sqrt((R_in - toSwap) * R_out_effective)` if `tokenIn` is `tokenA`, where `R_out_effective` is the amount of `tokenB` after adding `amountReceivedFromSwap` to it).
This optimization problem is typically solved using calculus (taking the derivative with respect to `toSwap` and setting to zero) or algebraic methods to find the optimal `toSwap` value.)*

## Disclaimer

This is experimental software and is provided on an "as is" and "as available" basis. Interacting with DeFi protocols carries inherent risks. Always do your own research and exercise caution. The author is not responsible for any losses incurred.