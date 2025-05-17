// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Univ2ZapRouter.sol";

contract ZapETH is Test {
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    Univ2ZapRouter zap;
    address user = vm.addr(11);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC"));
        zap = new Univ2ZapRouter(ROUTER);

        // give the user 1 WETH
        deal(WETH, user, 1 ether);
    }

    function test_WETH_ZapInAndOut() public {
        vm.startPrank(user);
        IERC20(WETH).approve(address(zap), type(uint).max);

        uint lp = zap.zapInSingleToken(
            WETH,
            USDC, WETH,
            1 ether, 1, block.timestamp + 1 hours
        );
        assertGt(lp, 0);

        IERC20(zap.getPair(USDC, WETH)).approve(address(zap), lp);
        uint wethOut = zap.zapOutSingleToken(
            WETH, USDC, WETH,
            lp, 1, block.timestamp + 1 hours
        );

        // should return ≥ 0.97 ETH after fees
        assertGe(wethOut * 100, 97 ether);
        vm.stopPrank();
    }
}
