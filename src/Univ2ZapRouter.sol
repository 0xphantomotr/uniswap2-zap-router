// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";
import {IERC20}            from "v2-periphery/interfaces/IERC20.sol";
import {IUniswapV2Factory} from "lib/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

contract Univ2ZapRouter {
    IUniswapV2Router02 public immutable router;
    address public immutable WETH;

    constructor(address _router) { router = IUniswapV2Router02(_router); WETH = router.WETH(); }

    /* ─────────────────────────── ZAP IN ─────────────────────────── */
    function zapInSingleToken(
        address tokenIn,
        address tokenA,
        address tokenB,
        uint    amountIn,
        uint    lpMin,
        uint    deadline
    ) external returns (uint liquidity) {
        require(amountIn > 0, "zero");

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        _forceApprove(tokenIn, address(router), amountIn);

        uint toSwap = amountIn / 2;
        address[] memory path = _buildPath(
            tokenIn == tokenA ? tokenA : tokenB,
            tokenIn == tokenA ? tokenB : tokenA
        );

        uint[] memory outs = router.swapExactTokensForTokens(
            toSwap, 0, path, address(this), deadline
        );

        uint amtA = tokenIn == tokenA ? amountIn - toSwap : outs[1];
        uint amtB = tokenIn == tokenB ? amountIn - toSwap : outs[1];

        _forceApprove(tokenA, address(router), amtA);
        _forceApprove(tokenB, address(router), amtB);

        (,,liquidity) = router.addLiquidity(
            tokenA, tokenB, amtA, amtB,
            1, 1, msg.sender, deadline
        );
        require(liquidity >= lpMin, "lp<min");
    }

    /* ─────────────────────────── ZAP OUT ────────────────────────── */
    function zapOutSingleToken(
        address tokenOut,
        address tokenA,
        address tokenB,
        uint    lpIn,
        uint    outMin,
        uint    deadline
    ) external returns (uint amountOut) {
        require(lpIn > 0, "zero");

        address pair = IUniswapV2Factory(router.factory()).getPair(tokenA, tokenB);
        IERC20(pair).transferFrom(msg.sender, address(this), lpIn);
        _forceApprove(pair, address(router), lpIn);

        (uint amtA, uint amtB) = router.removeLiquidity(
            tokenA, tokenB, lpIn, 1, 1, address(this), deadline
        );

        if (tokenOut == tokenA) {
            _forceApprove(tokenB, address(router), amtB);
            uint[] memory outs = router.swapExactTokensForTokens(
                amtB, 0, _buildPath(tokenB, tokenA), address(this), deadline
            );
            amountOut = amtA + outs[1];
        } else if (tokenOut == tokenB) {
            _forceApprove(tokenA, address(router), amtA);
            uint[] memory outs = router.swapExactTokensForTokens(
                amtA, 0, _buildPath(tokenA, tokenB), address(this), deadline
            );
            amountOut = amtB + outs[1];
        } else revert("tokenOut");

        require(amountOut >= outMin, "out<min");
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }

    // HELPERS
    function _buildPath(address a, address b)
        internal
        pure
        returns (address[] memory p)
    {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _forceApprove(address token, address spender, uint amount) internal {
        if (IERC20(token).allowance(address(this), spender) < amount)
            IERC20(token).approve(spender, type(uint).max);
    }

    function pairFor(address a, address b) internal view returns (address) {
        address factory = router.factory();
        (address token0, address token1) = a < b ? (a, b) : (b, a);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 data = keccak256(
            abi.encodePacked(
                hex"ff", factory, salt,
                hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd3b3ec7b92f4f07e4fd8b27"
            )
        );
        return address(uint160(uint(data)));
    }

    function getPair(address a, address b) external view returns (address) {
        return IUniswapV2Factory(router.factory()).getPair(a, b);
    }
}