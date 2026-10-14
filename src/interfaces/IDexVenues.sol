// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Uniswap V2 style router (Uniswap V2 Router02, SushiSwap and forks).
interface IUniswapV2Router {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @notice Uniswap V3 SwapRouter02 style router (no deadline inside the params struct).
interface IUniswapV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Uniswap V3 QuoterV2. Not a view: call it with eth_call.
interface IUniswapV3Quoter {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

/// @notice Uniswap v4 PoolManager (singleton). Currencies are addresses; address(0) is native ETH.
/// `BalanceDelta` is an int256 packing amount0 (upper 128 bits) and amount1 (lower 128 bits).
interface IUniswapV4PoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);

    function sync(address currency) external;

    function settle() external payable returns (uint256 paid);

    function take(address currency, address to, uint256 amount) external;
}

/// @notice Callback the PoolManager makes into the contract that called `unlock`.
interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice WETH9.
interface IWETH {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}

/// @notice Chainlink aggregator (ETH / USD).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
