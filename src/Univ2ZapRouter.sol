// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV2Router02} from "v2-periphery/interfaces/IUniswapV2Router02.sol";
import {IERC20} from "v2-periphery/interfaces/IERC20.sol";
import {IUniswapV2Factory} from "lib/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "lib/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Univ2ZapRouter
 * @author [Genci Mehmeti/0xphantomOtr]
 * @notice This contract provides "zap" functionality for Uniswap V2, allowing users to
 * add or remove liquidity using a single input token. It aims to optimize the swap amount
 * when zapping in to maximize LP tokens received.
 * It handles both ETH (via WETH) and ERC20 tokens.
 * This contract is subject to typical DeFi risks, including smart contract vulnerabilities
 * and impermanent loss.
 */
contract Univ2ZapRouter is ReentrancyGuard {
    /// @notice The Uniswap V2 Router02 interface.
    IUniswapV2Router02 public immutable router;
    /// @notice The address of Wrapped Ether (WETH) used by the Uniswap V2 Router.
    address public immutable WETH;
    /// @notice Basis points constant, representing 100% (10,000 BPS).
    uint16 public constant BPS = 10_000;

    /// @notice Emitted when a user zaps in with a single token to add liquidity.
    event ZapIn(
        address indexed sender,
        address indexed tokenIn,
        address indexed pairTokenA,
        address pairTokenB,
        uint256 amountIn,
        uint256 liquidityMinted
    );

    /// @notice Emitted when a user zaps out LP tokens to receive a single token.
    event ZapOut(
        address indexed sender,
        address indexed tokenOut,
        address indexed pairTokenA,
        address pairTokenB,
        uint256 lpAmount,
        uint256 amountOut
    );

    /**
     * @notice Constructor to initialize the Zap Router.
     * @param _router The address of the Uniswap V2 Router02 contract.
     */
    constructor(address _router) {
        router = IUniswapV2Router02(_router);
        WETH = router.WETH();
    }

    /* ─────────────────────────── ZAP IN ─────────────────────────── */
    function zapInSingleToken(
        address tokenIn,
        address tokenA,
        address tokenB,
        uint256 amountIn,
        uint16 maxSlippageBps,
        uint256 lpMin,
        uint256 deadline,
        bool feeOnTransfer
    ) external nonReentrant returns (uint256 liquidity) {
        require(amountIn > 0, "zero");
        address thisAddress = address(this);
        address routerAddress = address(router);

        // ── Pull & approve ──────────────────────────────────────────────
        IERC20(tokenIn).transferFrom(msg.sender, thisAddress, amountIn);
        _forceApprove(tokenIn, routerAddress, amountIn);

        // ── Optimal swap size ──────────────────────────────────────────
        address pair = IUniswapV2Factory(router.factory()).getPair(tokenA, tokenB);
        require(pair != address(0), "pair !exist");

        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        uint256 reserveIn = (tokenIn == tokenA) ? r0 : r1;
        uint256 toSwap = _optimalSwap(amountIn, reserveIn);
        require(toSwap > 0 && toSwap < amountIn, "swap bounds");

        // ── Swap & add liquidity (helpers keep stack shallow) ──────────
        (uint256 amtA, uint256 amtB) =
            _swapForPair(tokenIn, tokenA, tokenB, amountIn, toSwap, deadline, feeOnTransfer, thisAddress, routerAddress);

        liquidity = _addLiquidity(tokenA, tokenB, amtA, amtB, msg.sender, maxSlippageBps, deadline, routerAddress);
        require(liquidity >= lpMin, "lp<min");
        emit ZapIn(msg.sender, tokenIn, tokenA, tokenB, amountIn, liquidity);
    }

    /* ─────────────────────────── ZAP OUT ────────────────────────── */
    function zapOutSingleToken(
        address tokenOut,
        address tokenA,
        address tokenB,
        uint256 lpIn,
        uint16 maxSlippageBps,
        uint256 outMin,
        uint256 deadline,
        bool feeOnTransfer
    ) external nonReentrant returns (uint256 amountOut) {
        require(lpIn > 0, "zero");
        address thisAddress = address(this);
        address routerAddress = address(router);

        address pair = IUniswapV2Factory(router.factory()).getPair(tokenA, tokenB);
        IERC20(pair).transferFrom(msg.sender, thisAddress, lpIn);
        _forceApprove(pair, routerAddress, lpIn);

        (uint256 amtA, uint256 amtB) = router.removeLiquidity(tokenA, tokenB, lpIn, 1, 1, thisAddress, deadline);

        if (tokenOut == tokenA) {
            if (amtB > 0) {
                _forceApprove(tokenB, routerAddress, amtB);
                address[] memory path = _buildPath(tokenB, tokenA);
                uint256[] memory expectedAmountsFromSwap = router.getAmountsOut(amtB, path);
                uint256 minAmountFromSwap = _minOut(expectedAmountsFromSwap[1], maxSlippageBps);

                uint256 receivedTokenAFromSwap;
                if (feeOnTransfer) {
                    uint256 balBefore = IERC20(tokenA).balanceOf(thisAddress);
                    IUniswapV2Router02(routerAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                        amtB, minAmountFromSwap, path, thisAddress, deadline
                    );
                    receivedTokenAFromSwap = IERC20(tokenA).balanceOf(thisAddress) - balBefore;
                } else {
                    uint256[] memory actualAmountsFromSwap = IUniswapV2Router02(routerAddress).swapExactTokensForTokens(
                        amtB, minAmountFromSwap, path, thisAddress, deadline
                    );
                    receivedTokenAFromSwap = actualAmountsFromSwap[1];
                }
                amountOut = amtA + receivedTokenAFromSwap;
            } else {
                amountOut = amtA;
            }
        } else if (tokenOut == tokenB) {
            if (amtA > 0) {
                _forceApprove(tokenA, routerAddress, amtA);
                address[] memory path = _buildPath(tokenA, tokenB);
                uint256[] memory expectedAmountsFromSwap = router.getAmountsOut(amtA, path);
                uint256 minAmountFromSwap = _minOut(expectedAmountsFromSwap[1], maxSlippageBps);

                uint256 receivedTokenBFromSwap;
                if (feeOnTransfer) {
                    uint256 balBefore = IERC20(tokenB).balanceOf(thisAddress);
                    IUniswapV2Router02(routerAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                        amtA, minAmountFromSwap, path, thisAddress, deadline
                    );
                    receivedTokenBFromSwap = IERC20(tokenB).balanceOf(thisAddress) - balBefore;
                } else {
                    uint256[] memory actualAmountsFromSwap = IUniswapV2Router02(routerAddress).swapExactTokensForTokens(
                        amtA, minAmountFromSwap, path, thisAddress, deadline
                    );
                    receivedTokenBFromSwap = actualAmountsFromSwap[1];
                }
                amountOut = amtB + receivedTokenBFromSwap;
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
    function _buildPath(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _forceApprove(address token, address spender, uint256 amount) internal {
        if (IERC20(token).allowance(address(this), spender) < amount) {
            IERC20(token).approve(spender, type(uint256).max);
        }
    }

    function pairFor(address a, address b) internal view returns (address) {
        address factory = router.factory();
        (address token0, address token1) = a < b ? (a, b) : (b, a);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 data = keccak256(
            abi.encodePacked(
                hex"ff", factory, salt, hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd3b3ec7b92f4f07e4fd8b27"
            )
        );
        return address(uint160(uint256(data)));
    }

    function getPair(address a, address b) external view returns (address) {
        return IUniswapV2Factory(router.factory()).getPair(a, b);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _optimalSwap(uint256 amountIn, uint256 reserveIn) internal pure returns (uint256) {
        // constants for 0.3 % fee
        uint256 num = amountIn * 3988000 + reserveIn * 3988009;
        uint256 sqrt_ = _sqrt(reserveIn * num);
        return (sqrt_ - reserveIn * 1997) / 1994; // returns x
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
        bool feeOnTransfer,
        address thisAddress,
        address routerAddress
    ) internal returns (uint256 amtA, uint256 amtB) {
        address[] memory path = _buildPath(tokenIn == tokenA ? tokenA : tokenB, tokenIn == tokenA ? tokenB : tokenA);

        uint256[] memory outs;
        uint256 receivedFromSwap;

        if (feeOnTransfer) {
            uint256 balBefore = IERC20(path[1]).balanceOf(thisAddress);
            IUniswapV2Router02(routerAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                toSwap, 0, path, thisAddress, deadline
            );
            receivedFromSwap = IERC20(path[1]).balanceOf(thisAddress) - balBefore;
        } else {
            outs = IUniswapV2Router02(routerAddress).swapExactTokensForTokens(toSwap, 0, path, thisAddress, deadline);
            receivedFromSwap = outs[1];
        }

        unchecked {
            amtA = (tokenIn == tokenA) ? amountIn - toSwap : receivedFromSwap;
            amtB = (tokenIn == tokenB) ? amountIn - toSwap : receivedFromSwap;
        }
    }

    /* ───── internal add-liquidity helper ───── */
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amtA,
        uint256 amtB,
        address to,
        uint16 slipBps,
        uint256 deadline,
        address routerAddress
    ) internal returns (uint256 liquidity) {
        _forceApprove(tokenA, routerAddress, amtA);
        _forceApprove(tokenB, routerAddress, amtB);

        (,, liquidity) = IUniswapV2Router02(routerAddress).addLiquidity(
            tokenA,
            tokenB,
            amtA,
            amtB,
            _minOut(amtA, slipBps), // real slippage mins
            _minOut(amtB, slipBps),
            to,
            deadline
        );
    }

    function _minOut(uint256 amt, uint16 slipBps) internal pure returns (uint256) {
        require(slipBps <= BPS, "slippage>100%");
        unchecked {
            return amt * (BPS - slipBps) / BPS;
        }
    }
}
