// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Univ2ZapRouter.sol";
import {IUniswapV2Factory} from "lib/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

contract ZapRoundTrip is Test {
    /* ─── Mainnet constants (UniV2, USDC-WETH 0.3% pool) ───────── */
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

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

        IERC20(USDC).approve(address(zap), type(uint).max);

        /* ---- zap in USDC → LP ---- */
        uint lp = zap.zapInSingleToken(
            USDC,              // tokenIn
            USDC, WETH,        // pool tokens
            1_000e6,           // amountIn
            1,                 // lpMin
            block.timestamp + 1 hours
        );
        assertGt(lp, 0, "LP not minted");

        /* ---- zap out LP → USDC ---- */
        IERC20(zap.getPair(USDC, WETH)).approve(address(zap), lp);

        uint usdcOut = zap.zapOutSingleToken(
            USDC, USDC, WETH,
            lp,
            1,                 // outMin
            block.timestamp + 1 hours
        );

        /* sanity: should get most of the USDC back (small loss = trading fees) */
        assertGt(usdcOut, 990e6, "slippage too high (>1%)");

        vm.stopPrank();
    }
}