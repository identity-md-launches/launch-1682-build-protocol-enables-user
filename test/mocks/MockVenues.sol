// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3SwapRouter} from "../../src/interfaces/IDexVenues.sol";

/// @notice Constant-product pools keyed by token pair, shared by the V2 and V3 mocks.
/// Liquidity is held by the pool contract itself; swaps apply a 0.3% fee like Uniswap V2.
contract MockPools {
    using SafeERC20 for IERC20;

    mapping(bytes32 => uint256) public reserveA;
    mapping(bytes32 => uint256) public reserveB;
    mapping(bytes32 => bool) public broken;

    function key(address a, address b) public pure returns (bytes32, bool) {
        return a < b ? (keccak256(abi.encode(a, b)), false) : (keccak256(abi.encode(b, a)), true);
    }

    /// @dev Caller must have approved both tokens.
    function addLiquidity(address a, address b, uint256 amountA, uint256 amountB) external {
        IERC20(a).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(b).safeTransferFrom(msg.sender, address(this), amountB);
        (bytes32 k, bool flipped) = key(a, b);
        if (flipped) (amountA, amountB) = (amountB, amountA);
        reserveA[k] += amountA;
        reserveB[k] += amountB;
    }

    function setBroken(address a, address b, bool value) external {
        (bytes32 k,) = key(a, b);
        broken[k] = value;
    }

    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        (bytes32 k, bool flipped) = key(tokenIn, tokenOut);
        require(!broken[k], "pool broken");
        uint256 rIn = flipped ? reserveB[k] : reserveA[k];
        uint256 rOut = flipped ? reserveA[k] : reserveB[k];
        require(rIn > 0 && rOut > 0, "no liquidity");
        uint256 inWithFee = amountIn * 997;
        return (inWithFee * rOut) / (rIn * 1000 + inWithFee);
    }

    /// @dev Pulls tokenIn from msg.sender; the pool measures what it actually received.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address to) public returns (uint256 out) {
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - before;
        out = getAmountOut(tokenIn, tokenOut, received);
        (bytes32 k, bool flipped) = key(tokenIn, tokenOut);
        if (flipped) {
            reserveB[k] += received;
            reserveA[k] -= out;
        } else {
            reserveA[k] += received;
            reserveB[k] -= out;
        }
        IERC20(tokenOut).safeTransfer(to, out);
    }
}

/// @notice Uniswap V2 Router02 lookalike over MockPools.
contract MockV2Router {
    using SafeERC20 for IERC20;

    MockPools public immutable pools;

    constructor(MockPools p) {
        pools = p;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i + 1 < path.length; ++i) {
            amounts[i + 1] = pools.getAmountOut(path[i], path[i + 1], amounts[i]);
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, "EXPIRED");
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amount = IERC20(path[0]).balanceOf(address(this));
        for (uint256 i; i + 1 < path.length; ++i) {
            IERC20(path[i]).forceApprove(address(pools), amount);
            address recipient = i + 2 == path.length ? to : address(this);
            uint256 before = IERC20(path[i + 1]).balanceOf(recipient);
            pools.swap(path[i], path[i + 1], amount, recipient);
            amount = IERC20(path[i + 1]).balanceOf(recipient) - before;
        }
        require(amount >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
    }
}

/// @notice Uniswap V3 SwapRouter02 lookalike over MockPools (fees in the packed path are ignored).
contract MockV3Router {
    using SafeERC20 for IERC20;

    MockPools public immutable pools;

    constructor(MockPools p) {
        pools = p;
    }

    function exactInput(IUniswapV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256) {
        address[] memory path = decodePath(params.path);
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), params.amountIn);
        uint256 amount = params.amountIn;
        for (uint256 i; i + 1 < path.length; ++i) {
            IERC20(path[i]).forceApprove(address(pools), amount);
            address recipient = i + 2 == path.length ? params.recipient : address(this);
            amount = pools.swap(path[i], path[i + 1], amount, recipient);
        }
        require(amount >= params.amountOutMinimum, "Too little received");
        return amount;
    }

    function decodePath(bytes memory path) public pure returns (address[] memory tokens) {
        uint256 hops = (path.length - 20) / 23;
        tokens = new address[](hops + 1);
        for (uint256 k; k <= hops; ++k) {
            uint256 off = 23 * k;
            bytes20 t;
            assembly ("memory-safe") {
                t := mload(add(add(path, 32), off))
            }
            tokens[k] = address(t);
        }
    }
}

/// @notice Uniswap V3 QuoterV2 lookalike over MockPools.
contract MockV3Quoter {
    MockPools public immutable pools;
    MockV3Router public immutable router;

    constructor(MockPools p, MockV3Router r) {
        pools = p;
        router = r;
    }

    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint160[] memory a, uint32[] memory b, uint256 c)
    {
        address[] memory tokens = router.decodePath(path);
        amountOut = amountIn;
        for (uint256 i; i + 1 < tokens.length; ++i) {
            amountOut = pools.getAmountOut(tokens[i], tokens[i + 1], amountOut);
        }
        return (amountOut, a, b, c);
    }
}

/// @notice Chainlink aggregator stand-in.
contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public constant decimals = 8;

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
