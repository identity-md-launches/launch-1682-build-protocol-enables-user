// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapV3SwapRouter, IUnlockCallback} from "../../src/interfaces/IDexVenues.sol";

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

/// @notice WETH9 stand-in, etched at the mainnet WETH address in tests.
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "WETH: send failed");
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Uniswap v4 PoolManager stand-in: unlock/callback, flash accounting per currency, constant
/// product pools keyed by the full PoolKey, native ETH as address(0), fee in hundredths of a bip.
contract MockV4PoolManager {
    using SafeERC20 for IERC20;

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

    mapping(bytes32 => uint256) public reserve0;
    mapping(bytes32 => uint256) public reserve1;
    mapping(address => int256) public currencyDelta;
    address[] private _touched;
    address public locker;
    address private _synced;
    uint256 private _syncedBalance;
    bool public partialFillRealSwaps; // real (non-quote) swaps consume only half the input: thin pool behaviour
    bool private _quoting;

    function poolId(PoolKey memory key) public pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function setPartialFillRealSwaps(bool v) external {
        partialFillRealSwaps = v;
    }

    /// @dev Caller must have approved ERC20 currencies; native ETH comes with msg.value.
    function addLiquidity(PoolKey memory key, uint256 amount0, uint256 amount1) external payable {
        require(key.currency0 < key.currency1, "unsorted");
        _pull(key.currency0, amount0);
        _pull(key.currency1, amount1);
        bytes32 id = poolId(key);
        reserve0[id] += amount0;
        reserve1[id] += amount1;
    }

    function getAmountOut(PoolKey memory key, bool zeroForOne, uint256 amountIn) public view returns (uint256) {
        bytes32 id = poolId(key);
        uint256 rIn = zeroForOne ? reserve0[id] : reserve1[id];
        uint256 rOut = zeroForOne ? reserve1[id] : reserve0[id];
        require(rIn > 0 && rOut > 0, "PoolNotInitialized");
        uint256 inWithFee = amountIn * (1_000_000 - key.fee);
        return (inWithFee * rOut) / (rIn * 1_000_000 + inWithFee);
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(locker == address(0), "AlreadyUnlocked");
        locker = msg.sender;
        _quoting = abi.decode(data[:32], (bool)); // SwarmExit's first callback word is its quote flag
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        for (uint256 i; i < _touched.length; ++i) {
            require(currencyDelta[_touched[i]] == 0, "CurrencyNotSettled");
        }
        delete _touched;
        locker = address(0);
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata) external returns (int256 delta) {
        require(msg.sender == locker, "ManagerLocked");
        require(params.amountSpecified < 0, "exact input only in this mock");
        uint256 amountIn = uint256(-params.amountSpecified);
        if (partialFillRealSwaps && !_quoting) amountIn /= 2;
        uint256 out = getAmountOut(key, params.zeroForOne, amountIn);
        bytes32 id = poolId(key);
        (address cIn, address cOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        if (params.zeroForOne) {
            reserve0[id] += amountIn;
            reserve1[id] -= out;
        } else {
            reserve1[id] += amountIn;
            reserve0[id] -= out;
        }
        _account(cIn, -int256(amountIn));
        _account(cOut, int256(out));
        int256 amount0 = params.zeroForOne ? -int256(amountIn) : int256(out);
        int256 amount1 = params.zeroForOne ? int256(out) : -int256(amountIn);
        assembly ("memory-safe") {
            delta := or(shl(128, amount0), and(sub(shl(128, 1), 1), amount1))
        }
    }

    function sync(address currency) external {
        _synced = currency;
        _syncedBalance = currency == address(0) ? 0 : IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        require(msg.sender == locker, "ManagerLocked");
        if (_synced == address(0)) {
            paid = msg.value;
            _account(address(0), int256(paid));
        } else {
            require(msg.value == 0, "NonzeroNativeValue");
            paid = IERC20(_synced).balanceOf(address(this)) - _syncedBalance;
            _account(_synced, int256(paid));
            _synced = address(0);
        }
    }

    function take(address currency, address to, uint256 amount) external {
        require(msg.sender == locker, "ManagerLocked");
        _account(currency, -int256(amount));
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native send failed");
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }

    function _account(address currency, int256 change) internal {
        if (currencyDelta[currency] == 0) _touched.push(currency);
        currencyDelta[currency] += change;
    }

    function _pull(address currency, uint256 amount) internal {
        if (currency == address(0)) {
            require(msg.value == amount, "wrong msg.value");
        } else {
            IERC20(currency).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    receive() external payable {}
}
