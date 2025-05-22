// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";
import {IERC20}            from "v2-periphery/interfaces/IERC20.sol";
import {IUniswapV2Factory} from "lib/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "lib/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract Univ2ZapRouter is ReentrancyGuard {
    IUniswapV2Router02 public immutable router;
    address public immutable WETH;
    uint16 public constant BPS = 10_000;  // 100 %

    event ZapIn(
        address indexed sender,
        address indexed tokenIn,
        address indexed pairTokenA,
        address pairTokenB, // Not indexed as it's often paired with tokenIn or WETH
        uint256 amountIn,
        uint256 liquidityMinted
    );

    event ZapOut(
        address indexed sender,
        address indexed tokenOut,
        address indexed pairTokenA,
        address pairTokenB, // Not indexed for similar reasons
        uint256 lpAmount,
        uint256 amountOut
    );

    constructor(address _router) { router = IUniswapV2Router02(_router); WETH = router.WETH(); }

    /* ─────────────────────────── ZAP IN ─────────────────────────── */
    function zapInSingleToken(
        address tokenIn,
        address tokenA,
        address tokenB,
        uint256 amountIn,
        uint16  maxSlippageBps,
        uint lpMin,
        uint256 deadline,
        bool feeOnTransfer
    ) external nonReentrant returns (uint256 liquidity)
    {
        require(amountIn > 0, "zero");

        // ── Pull & approve ──────────────────────────────────────────────
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        _forceApprove(tokenIn, address(router), amountIn);

        // ── Optimal swap size ──────────────────────────────────────────
        address pair = IUniswapV2Factory(router.factory()).getPair(tokenA, tokenB);
        require(pair != address(0), "pair !exist");

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        uint256 reserveIn = (tokenIn == tokenA) ? r0 : r1;
        uint256 toSwap    = _optimalSwap(amountIn, reserveIn);
        require(toSwap > 0 && toSwap < amountIn, "swap bounds");

        // ── Swap & add liquidity (helpers keep stack shallow) ──────────
        (uint256 amtA, uint256 amtB) =
            _swapForPair(tokenIn, tokenA, tokenB, amountIn, toSwap, deadline, feeOnTransfer);

        liquidity = _addLiquidity(
            tokenA, tokenB, amtA, amtB, msg.sender, maxSlippageBps, deadline
        );
        require(liquidity >= lpMin, "lp<min");
        emit ZapIn(msg.sender, tokenIn, tokenA, tokenB, amountIn, liquidity);
    }


    /* ─────────────────────────── ZAP OUT ────────────────────────── */
    function zapOutSingleToken(
        address tokenOut,
        address tokenA,
        address tokenB,
        uint    lpIn,
        uint16  maxSlippageBps,
        uint    outMin,
        uint    deadline,
        bool feeOnTransfer
    ) external nonReentrant returns (uint amountOut) {
        require(lpIn > 0, "zero");

        address pair = IUniswapV2Factory(router.factory()).getPair(tokenA, tokenB);
        IERC20(pair).transferFrom(msg.sender, address(this), lpIn);
        _forceApprove(pair, address(router), lpIn);

        (uint amtA, uint amtB) = router.removeLiquidity(
            tokenA, tokenB, lpIn, 1, 1, address(this), deadline
        );

        if (tokenOut == tokenA) {
            if (amtB > 0) {
                _forceApprove(tokenB, address(router), amtB);
                address[] memory path = _buildPath(tokenB, tokenA);
                uint[] memory expectedAmountsFromSwap = router.getAmountsOut(amtB, path);
                uint minAmountFromSwap = _minOut(expectedAmountsFromSwap[1], maxSlippageBps);

                uint[] memory actualAmountsFromSwap = new uint[](2);
                if (feeOnTransfer) {
                    uint balBefore = IERC20(tokenA).balanceOf(address(this));
                    router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                        amtB,
                        minAmountFromSwap,
                        path,
                        address(this),
                        deadline
                    );
                    actualAmountsFromSwap[1] = IERC20(tokenA).balanceOf(address(this)) - balBefore;
                } else {
                    actualAmountsFromSwap = router.swapExactTokensForTokens(
                        amtB,
                        minAmountFromSwap,
                        path,
                        address(this),
                        deadline
                    );
                }
                amountOut = amtA + actualAmountsFromSwap[1];
            } else {
                amountOut = amtA;
            }
        } else if (tokenOut == tokenB) {
            if (amtA > 0) {
                _forceApprove(tokenA, address(router), amtA);
                address[] memory path = _buildPath(tokenA, tokenB);
                uint[] memory expectedAmountsFromSwap = router.getAmountsOut(amtA, path);
                uint minAmountFromSwap = _minOut(expectedAmountsFromSwap[1], maxSlippageBps);

                uint[] memory actualAmountsFromSwap = new uint[](2);
                if (feeOnTransfer) {
                    uint balBefore = IERC20(tokenB).balanceOf(address(this));
                    router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                        amtA,
                        minAmountFromSwap,
                        path,
                        address(this),
                        deadline
                    );
                    actualAmountsFromSwap[1] = IERC20(tokenB).balanceOf(address(this)) - balBefore;
                } else {
                    actualAmountsFromSwap = router.swapExactTokensForTokens(
                        amtA,
                        minAmountFromSwap,
                        path,
                        address(this),
                        deadline
                    );
                }
                amountOut = amtB + actualAmountsFromSwap[1];
            } else {
                amountOut = amtB;
            }
        } else {
            revert("tokenOut");
        }

        require(amountOut >= outMin, "out<min");
        IERC20(tokenOut).transfer(msg.sender, amountOut);
        emit ZapOut(msg.sender, tokenOut, tokenA, tokenB, lpIn, amountOut);
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

    function _sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) { z = x; x = (y / x + x) / 2;}
        } else if (y != 0) {
            z = 1;
        }
    }

    function _optimalSwap(uint amountIn, uint reserveIn) internal pure returns (uint) {
        // constants for 0.3 % fee
        uint num   = amountIn * 3988000 + reserveIn * 3988009;
        uint sqrt_ = _sqrt(reserveIn * num);
        return (sqrt_ - reserveIn * 1997) / 1994;        // returns x
    }

    /* ───── internal swap helper ─────
    * Returns (amountA, amountB) that will be fed to addLiquidity().
    */
    function _swapForPair(
        address tokenIn,
        address tokenA,
        address tokenB,
        uint256 amountIn,
        uint256 toSwap,
        uint256 deadline,
        bool feeOnTransfer
    ) internal returns (uint256 amtA, uint256 amtB)
    {
        address[] memory path = _buildPath(
            tokenIn == tokenA ? tokenA : tokenB,
            tokenIn == tokenA ? tokenB : tokenA
        );

        uint256[] memory outs = new uint256[](2);
        if (feeOnTransfer) {
            //uint balBefore = IERC20(path[1]).balanceOf(address(this));
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                toSwap, 0, path, address(this), deadline
            );
            outs[1] = IERC20(path[1]).balanceOf(address(this)); // Balance after swap is the amount received
        } else {
            outs = router.swapExactTokensForTokens(
                toSwap, 0, path, address(this), deadline
            );
        }

        amtA = (tokenIn == tokenA) ? amountIn - toSwap : outs[1];
        amtB = (tokenIn == tokenB) ? amountIn - toSwap : outs[1];
    }

    /* ───── internal add-liquidity helper ───── */
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amtA,
        uint256 amtB,
        address to,
        uint16  slipBps,
        uint256 deadline
    ) internal returns (uint256 liquidity)
    {
        _forceApprove(tokenA, address(router), amtA);
        _forceApprove(tokenB, address(router), amtB);

        (,, liquidity) = router.addLiquidity(
            tokenA, tokenB,
            amtA,        amtB,
            _minOut(amtA, slipBps),   // real slippage mins
            _minOut(amtB, slipBps),
            to,
            deadline
        );
    }


    function _minOut(uint256 amt, uint16 slipBps) internal pure returns (uint256) {
        require(slipBps <= BPS, "slippage>100%");
        unchecked { return amt * (BPS - slipBps) / BPS; }
    }

}