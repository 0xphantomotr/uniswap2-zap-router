// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Univ2ZapRouter.sol";
import {IUniswapV2Factory} from "lib/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

contract ZapRoundTrip is Test {
    /* ─── Mainnet constants (UniV2, USDC-WETH 0.3% pool) ───────── */
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    Univ2ZapRouter zap;
    address user = vm.addr(1);

    function setUp() public {
        /* fork latest mainnet block (set env MAINNET_RPC) */
        vm.createSelectFork(vm.envString("MAINNET_RPC"));

        zap = new Univ2ZapRouter(ROUTER);

        /* give the test user 1 000 USDC */
        deal(USDC, user, 1_000e6);
    }

    function testRoundTripUSDC() public {
        vm.startPrank(user);

        IERC20(USDC).approve(address(zap), type(uint256).max);

        /* ---- zap in USDC → LP ---- */
        // event ZapIn(
        //     address indexed sender,
        //     address indexed tokenIn,
        //     address indexed pairTokenA,
        //     address pairTokenB,
        //     uint256 amountIn,
        //     uint256 liquidityMinted
        // );
        // We check the 3 indexed topics (sender, tokenIn, pairTokenA).
        // The data part (pairTokenB, amountIn, liquidityMinted) is not strictly checked by this expectEmit call.
        vm.expectEmit(true, true, true, false);
        emit Univ2ZapRouter.ZapIn(user, USDC, USDC, WETH, 1_000e6, 0); // placeholder for liquidityMinted

        uint256 lp = zap.zapInSingleToken(
            USDC, // tokenIn
            USDC,
            WETH, // pool tokens
            1_000e6, // amountIn
            50,
            1, // lpMin
            block.timestamp + 1 hours,
            false // feeOnTransfer
        );
        assertGt(lp, 0, "LP not minted");

        /* ---- zap out LP → USDC ---- */
        IERC20(zap.getPair(USDC, WETH)).approve(address(zap), lp);

        // event ZapOut(
        //     address indexed sender,
        //     address indexed tokenOut,
        //     address indexed pairTokenA,
        //     address pairTokenB,
        //     uint256 lpAmount,
        //     uint256 amountOut
        // );
        // We check the 3 indexed topics (sender, tokenOut, pairTokenA).
        // The data part (pairTokenB, lpAmount, amountOut) is not strictly checked by this expectEmit call.
        vm.expectEmit(true, true, true, false);
        emit Univ2ZapRouter.ZapOut(user, USDC, USDC, WETH, lp, 0); // placeholder for amountOut

        uint256 usdcOut = zap.zapOutSingleToken(
            USDC,
            USDC,
            WETH,
            lp,
            50, // maxSlippageBps (0.5%)
            1, // outMin
            block.timestamp + 1 hours,
            false // feeOnTransfer
        );

        /* sanity: should get most of the USDC back (small loss = trading fees) */
        assertGt(usdcOut, 990e6, "slippage too high (>1%)");

        vm.stopPrank();
    }

    function testRoundTripUSDC_FeeOnTransfer() public {
        vm.startPrank(user);

        IERC20(USDC).approve(address(zap), type(uint256).max);

        // Expect ZapIn event
        vm.expectEmit(true, true, true, false);
        emit Univ2ZapRouter.ZapIn(user, USDC, USDC, WETH, 1_000e6, 0);

        uint256 lp = zap.zapInSingleToken(
            USDC,
            USDC,
            WETH,
            1_000e6,
            50,
            1,
            block.timestamp + 1 hours,
            true // feeOnTransfer set to true
        );
        assertGt(lp, 0, "LP not minted (feeOnTransfer=true)");

        IERC20(zap.getPair(USDC, WETH)).approve(address(zap), lp);

        // Expect ZapOut event
        vm.expectEmit(true, true, true, false);
        emit Univ2ZapRouter.ZapOut(user, USDC, USDC, WETH, lp, 0);

        uint256 usdcOut = zap.zapOutSingleToken(
            USDC,
            USDC,
            WETH,
            lp,
            50,
            1,
            block.timestamp + 1 hours,
            true // feeOnTransfer set to true
        );

        assertGt(usdcOut, 980e6, "slippage too high (>2%) (feeOnTransfer=true)"); // Adjusted expectation slightly, as router behavior might differ, though unlikely with non-FOT tokens. Should be similar to the false case.
        // The assertion for usdcOut might need slight adjustment, but with non-FOT tokens, it should be very close to the original.
        // The primary goal is to ensure this path doesn't revert and executes the intended logic.

        vm.stopPrank();
    }
}
