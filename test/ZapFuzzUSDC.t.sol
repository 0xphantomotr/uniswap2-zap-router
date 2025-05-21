// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../src/Univ2ZapRouter.sol";

contract ZapFuzzUSDC is Test {
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    Univ2ZapRouter zap;
    address user = vm.addr(22);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC"));
        zap = new Univ2ZapRouter(ROUTER);
    }

    function test_fuzz_USDC(uint96 amt) public {
        amt = uint96(bound(amt, 100e6, 10_000e6));   // 100→10 000 USDC
        deal(USDC, user, amt);

        vm.startPrank(user);
        IERC20(USDC).approve(address(zap), type(uint).max);

        uint lp = zap.zapInSingleToken(USDC, USDC, WETH, amt, 50, 1, block.timestamp+1 hours, false);
        IERC20(zap.getPair(USDC, WETH)).approve(address(zap), lp);
        uint out = zap.zapOutSingleToken(
            USDC, USDC, WETH,
            lp,
            50, // maxSlippageBps (0.5%)
            1,  // outMin
            block.timestamp+1 hours,
            false // feeOnTransfer
        );
        vm.stopPrank();

        assertGe(out * 100, amt * 97, "loss >3%");
    }
}