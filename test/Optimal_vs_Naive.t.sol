// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Univ2ZapRouter.sol";

import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";
import {IERC20}            from "v2-periphery/interfaces/IERC20.sol";

contract OptimalVsNaive is Test {
    /* ─── Main-net constants ─────────────────────────── */
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    Univ2ZapRouter      zapOpt;
    IUniswapV2Router02  uni = IUniswapV2Router02(ROUTER);

    address userOpt  = vm.addr(1);   // will run the optimized zap
    address userNaive = vm.addr(2);  // will run the manual 50/50

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC"));

        zapOpt = new Univ2ZapRouter(ROUTER);

        // Seed each user with 10 000 USDC
        deal(USDC, userOpt,   10_000e6);
        deal(USDC, userNaive, 10_000e6);
    }

    function test_OptimalMintsMoreLP() public {
        /* ─── 1️⃣  OPTIMAL ZAP (userOpt) ─────────────────────────── */
        vm.startPrank(userOpt);

        IERC20(USDC).approve(address(zapOpt), type(uint256).max);

        uint256 lpOpt = zapOpt.zapInSingleToken(
            USDC,               // tokenIn
            USDC, WETH,         // pair tokens
            10_000e6,           // amountIn
            50,
            1,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        /* ─── 2️⃣  MANUAL 50/50 ZAP (userNaive) ──────────────────── */
        vm.startPrank(userNaive);

        IERC20(USDC).approve(ROUTER, type(uint256).max);

        uint256 halfUSDC = 10_000e6 / 2;

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;

        // swap half USDC → WETH
        uni.swapExactTokensForTokens(
            halfUSDC,
            0,
            path,
            userNaive,
            block.timestamp + 1 hours
        );

        // add liquidity with remaining USDC + received WETH
        uint256 balUSDC = IERC20(USDC).balanceOf(userNaive);
        uint256 balWETH = IERC20(WETH).balanceOf(userNaive);

        IERC20(USDC).approve(ROUTER, balUSDC);
        IERC20(WETH).approve(ROUTER, balWETH);

        ( , , uint256 lpNaive) = uni.addLiquidity(
            USDC, WETH,
            balUSDC, balWETH,
            1, 1,
            userNaive,
            block.timestamp + 1 hours
        );

        vm.stopPrank();

        /* ─── 3️⃣  ASSERT optimal ≥ naïve ───────────────────────── */
        assertGt(lpOpt, lpNaive, "optimized zap should mint more LP than manual 50/50");
    }
}
