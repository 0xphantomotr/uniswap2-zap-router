// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../src/Univ2ZapRouter.sol";

contract ZapDAI is Test {
    address constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DAI   = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    Univ2ZapRouter zap; address user = vm.addr(33);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC"));
        zap = new Univ2ZapRouter(ROUTER);
        deal(DAI, user, 5_000e18);
    }

    function test_ZapIn_DAI() public {
        vm.startPrank(user);
        IERC20(DAI).approve(address(zap), type(uint).max);
        uint lp = zap.zapInSingleToken(DAI, DAI, WETH, 5_000e18, 50, 1, block.timestamp+1 hours, false);
        assertGt(lp, 0);
        vm.stopPrank();
    }
}