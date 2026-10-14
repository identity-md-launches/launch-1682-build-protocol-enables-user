// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IUniswapV2Router,
    IUniswapV3SwapRouter,
    IUniswapV3Quoter,
    IUniswapV4PoolManager,
    IUnlockCallback,
    IWETH,
    IAggregatorV3
} from "./interfaces/IDexVenues.sol";

/// @title SwarmExit
/// @notice One-click exit from swarm-launched tokens into $IMD.
///
/// The owner registers every token the swarm launched together with the route that sells it
/// (a Uniswap V2 style path, a Uniswap V3 packed path or a Uniswap v4 hop list) into a bridge
/// currency (WETH or native ETH) or directly into IMD. A single global route turns the bridge
/// currency into IMD. A user calls `sellAll` with the tokens they hold: each token is pulled, sold
/// through its route, and the IMD proceeds are pooled. A 2% sell tax of the IMD proceeds goes to
/// the treasury and the rest to the user.
///
/// A token whose sale fails (no liquidity, honeypot, slippage, a transfer the token refuses) is
/// refunded to the user inside the same transaction and the remaining tokens are still sold. A
/// token that refuses even the refund transfer is held for the user, who claims it later with
/// `claimRefund`. Predictable failures (a quote that fails or is below the minimum) are skipped
/// before the token is pulled, so a fee-on-transfer token pays no fee for a sale that cannot work.
///
/// `preview` (call it with eth_call, it is not a view because quoting is not) tells the frontend
/// which tokens are sellable and how much IMD they would fetch.
contract SwarmExit is Ownable2Step, Pausable, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants fixed by the brief and the chain
    // ------------------------------------------------------------------

    /// @notice $IMD, the token every sale settles in (Ethereum mainnet).
    IERC20 public constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    /// @notice Treasury that receives the sell tax.
    address public constant TREASURY = 0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB;
    /// @notice WETH9 on Ethereum mainnet; wrapped and unwrapped when a V2/V3 leg meets a v4 ETH leg.
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @notice Native ETH as a Uniswap v4 currency.
    address public constant NATIVE = address(0);
    /// @notice Sell tax in basis points, taken from the IMD proceeds.
    uint256 public constant SELL_TAX_BPS = 200;
    uint256 public constant BPS = 10_000;
    /// @notice Oldest Chainlink answer `ethUsdPrice` accepts (the ETH/USD feed heartbeat is 1 hour).
    uint256 public constant MAX_PRICE_AGE = 3 hours;
    /// @notice Default dust threshold: a token whose quoted proceeds are below it is not sellable.
    uint256 public constant DEFAULT_MIN_IMD_OUT = 1e15;
    /// @notice Default price-impact bound for `preview` (30%): above it a holding is not sellable.
    uint256 public constant DEFAULT_MAX_IMPACT_BPS = 3000;
    /// @notice The impact probe quotes 1/IMPACT_PROBE_DIVISOR of the holding and scales it up.
    uint256 public constant IMPACT_PROBE_DIVISOR = 1000;
    /// @notice Upper bound on tokens per `sellAll` call so the loop stays inside the block gas limit.
    uint256 public constant MAX_TOKENS_PER_SALE = 50;
    /// @dev Uniswap v4 TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: swap to the pool's edge.
    uint160 private constant V4_MIN_PRICE_LIMIT = 4295128740;
    uint160 private constant V4_MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum Venue {
        None,
        UniswapV2,
        UniswapV3,
        UniswapV4
    }

    /// @param venue Which venue interface to use.
    /// @param router V2 Router02, V3 SwapRouter02 or the v4 PoolManager.
    /// @param quoter QuoterV2 for V3 routes; unused (zero) for V2 (quotes on the router) and v4 (self-quoted).
    /// @param tokenIn First currency of the path (address(0) is native ETH, v4 only).
    /// @param tokenOut Last currency of the path (address(0) is native ETH, v4 only).
    /// @param data abi.encode(address[] path) for V2, packed V3 path for V3,
    ///        abi.encode(address currencyIn, V4Hop[] hops) for v4.
    struct Route {
        Venue venue;
        address router;
        address quoter;
        address tokenIn;
        address tokenOut;
        bytes data;
    }

    /// @notice One Uniswap v4 pool hop: the pool key fields other than the input currency.
    struct V4Hop {
        address currencyOut;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    enum Status {
        Sold,
        NotRegistered,
        ZeroBalance,
        NoRoute,
        BridgeRouteMissing,
        QuoteFailed,
        BelowMinimum,
        SaleFailed,
        ExcessiveImpact,
        NoAllowance
    }

    struct Preview {
        address token;
        uint256 balance;
        uint256 expectedImd;
        bool sellable;
        Status status;
    }

    struct Outcome {
        address token;
        uint256 amountIn;
        uint256 imdOut;
        Status status;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    mapping(address => bool) public isSwarmToken;
    address[] private _swarmTokens;
    mapping(address => Route) private _tokenRoutes;
    /// @dev Route from the bridge currency (WETH or ETH) into IMD. Unset until the owner configures it.
    Route private _imdRoute;
    IAggregatorV3 public ethUsdFeed;
    uint256 public minImdOut = DEFAULT_MIN_IMD_OUT;
    uint256 public maxImpactBps = DEFAULT_MAX_IMPACT_BPS;
    /// @notice Refunds a token refused to deliver; the user claims them with `claimRefund`.
    mapping(address user => mapping(address token => uint256)) public heldRefunds;
    /// @notice Total held refunds per token; `rescue` can never touch them.
    mapping(address token => uint256) public totalHeld;
    /// @dev The v4 PoolManager this contract is inside an `unlock` of; zero otherwise.
    address private _v4Manager;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    event SwarmTokenSet(address indexed token, bool registered);
    event TokenRouteSet(address indexed token, Venue venue, address router, address quoter, address tokenOut);
    event ImdRouteSet(Venue venue, address router, address quoter, address tokenIn);
    event EthUsdFeedSet(address indexed feed);
    event MinImdOutSet(uint256 minImdOut);
    event MaxImpactBpsSet(uint256 maxImpactBps);
    event TokenSold(address indexed user, address indexed token, uint256 amountIn, uint256 imdOut);
    event TokenSkipped(address indexed user, address indexed token, Status status);
    event TokenRefunded(address indexed user, address indexed token, uint256 amount, bytes reason);
    event RefundHeld(address indexed user, address indexed token, uint256 amount);
    event RefundClaimed(address indexed user, address indexed token, uint256 amount);
    event SoldAll(address indexed user, uint256 grossImd, uint256 tax, uint256 netImd);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotAContract(address token);
    error NotSwarmToken(address token);
    error InvalidRoute();
    error NotConfigured(string what);
    error OnlySelf();
    error OnlyPoolManager();
    error TooManyTokens();
    error LengthMismatch();
    error DuplicateToken(address token);
    error Expired();
    error NothingSold();
    error NoProceeds();
    error SlippageExceeded(uint256 got, uint256 want);
    error InsufficientLiquidity();
    error StalePrice();
    error InvalidPrice();
    error InvalidBps();
    error CannotRescueSwarmToken();
    error CannotRescueHeldRefunds();
    error NothingToClaim();
    error EthTransferFailed();
    /// @dev Carries a v4 quote out of the reverted `unlock` used for quoting.
    error V4Quote(uint256 amountOut);

    // ------------------------------------------------------------------
    // Constructor: no external calls, no code requirements (runs on an empty chain).
    // ------------------------------------------------------------------

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Accepts ETH from WETH withdrawals and v4 takes during a sale.
    receive() external payable {}

    // ------------------------------------------------------------------
    // Owner configuration
    // ------------------------------------------------------------------

    /// @notice Register or unregister a token launched by the swarm. Unregistering clears its route.
    function setSwarmToken(address token, bool registered) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isSwarmToken[token] == registered) return;
        if (registered) {
            if (token.code.length == 0) revert NotAContract(token);
            isSwarmToken[token] = true;
            _swarmTokens.push(token);
        } else {
            isSwarmToken[token] = false;
            uint256 n = _swarmTokens.length;
            for (uint256 i; i < n; ++i) {
                if (_swarmTokens[i] == token) {
                    _swarmTokens[i] = _swarmTokens[n - 1];
                    _swarmTokens.pop();
                    break;
                }
            }
            if (_tokenRoutes[token].venue != Venue.None) {
                delete _tokenRoutes[token];
                emit TokenRouteSet(token, Venue.None, address(0), address(0), address(0));
            }
        }
        emit SwarmTokenSet(token, registered);
    }

    /// @notice Set the route that sells `token` into IMD or into the bridge currency of the IMD route.
    function setTokenRoute(address token, Venue venue, address router, address quoter, bytes calldata data)
        external
        onlyOwner
    {
        if (!isSwarmToken[token]) revert NotSwarmToken(token);
        if (venue == Venue.None) {
            delete _tokenRoutes[token];
            emit TokenRouteSet(token, Venue.None, address(0), address(0), address(0));
            return;
        }
        Route memory route = _buildRoute(venue, router, quoter, data);
        if (route.tokenIn != token) revert InvalidRoute();
        if (route.tokenOut == token) revert InvalidRoute();
        _tokenRoutes[token] = route;
        emit TokenRouteSet(token, venue, router, quoter, route.tokenOut);
    }

    /// @notice Set the route from the bridge currency (WETH, or native ETH on v4) into IMD.
    function setImdRoute(Venue venue, address router, address quoter, bytes calldata data) external onlyOwner {
        if (venue == Venue.None) revert InvalidRoute();
        Route memory route = _buildRoute(venue, router, quoter, data);
        if (route.tokenOut != address(IMD)) revert InvalidRoute();
        if (route.tokenIn == address(IMD)) revert InvalidRoute();
        _imdRoute = route;
        emit ImdRouteSet(venue, router, quoter, route.tokenIn);
    }

    /// @notice Set the Chainlink ETH/USD feed the frontend prices with.
    function setEthUsdFeed(address feed) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        ethUsdFeed = IAggregatorV3(feed);
        emit EthUsdFeedSet(feed);
    }

    /// @notice Set the dust threshold under which a sale is not made (enforced on chain).
    function setMinImdOut(uint256 value) external onlyOwner {
        minImdOut = value;
        emit MinImdOutSet(value);
    }

    /// @notice Set the price-impact bound `preview` applies (BPS disables it).
    function setMaxImpactBps(uint256 value) external onlyOwner {
        if (value > BPS) revert InvalidBps();
        maxImpactBps = value;
        emit MaxImpactBpsSet(value);
    }

    /// @notice Pause selling (configuration, previews and refund claims keep working).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Return tokens (or ETH, `token == address(0)`) sent here by mistake. Registered swarm
    /// tokens are refused, and so is any amount that belongs to held refunds. Swarm tokens, bridge
    /// currency and IMD never rest here in normal operation: every sale settles or refunds in the
    /// same transaction.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (isSwarmToken[token]) revert CannotRescueSwarmToken();
        if (_balance(token, address(this)) < amount + totalHeld[token]) revert CannotRescueHeldRefunds();
        _send(token, to, amount);
        emit Rescued(token, to, amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function swarmTokens() external view returns (address[] memory) {
        return _swarmTokens;
    }

    function swarmTokenCount() external view returns (uint256) {
        return _swarmTokens.length;
    }

    function tokenRoute(address token) external view returns (Route memory) {
        return _tokenRoutes[token];
    }

    function imdRoute() external view returns (Route memory) {
        return _imdRoute;
    }

    /// @notice ETH/USD from Chainlink with staleness and sanity checks. Reverts until the feed is set.
    function ethUsdPrice() external view returns (uint256 price, uint8 decimals) {
        if (address(ethUsdFeed) == address(0)) revert NotConfigured("ethUsdFeed");
        (, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePrice();
        return (uint256(answer), ethUsdFeed.decimals());
    }

    // ------------------------------------------------------------------
    // Quoting (eth_call)
    // ------------------------------------------------------------------

    /// @notice Per-token sellability and expected IMD for `user`. Call with eth_call.
    function preview(address user, address[] calldata tokens) external returns (Preview[] memory out) {
        out = new Preview[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            out[i] = _previewOne(user, tokens[i]);
        }
    }

    /// @notice Preview every registered token for `user`. Call with eth_call.
    function previewAll(address user) external returns (Preview[] memory out) {
        uint256 n = _swarmTokens.length;
        out = new Preview[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _previewOne(user, _swarmTokens[i]);
        }
    }

    /// @notice How much bridge currency (WETH or ETH, 1:1) `imdAmount` would fetch along the reversed
    /// IMD route. The frontend multiplies it by the ETH/USD price to show USD values. Call with eth_call.
    function quoteImdInBridge(uint256 imdAmount) external returns (uint256 bridgeAmount) {
        if (_imdRoute.venue == Venue.None) revert NotConfigured("imdRoute");
        (bool ok, uint256 amount) = _quote(_reverse(_imdRoute), imdAmount);
        if (!ok) revert NotConfigured("imdRoute quote");
        return amount;
    }

    // ------------------------------------------------------------------
    // Selling
    // ------------------------------------------------------------------

    /// @notice Sell the caller's balance of each token (capped by the allowance given to this
    /// contract) for IMD, net of the 2% treasury tax.
    /// @param tokens Registered swarm tokens to sell (no duplicates).
    /// @param minImdOuts Minimum IMD accepted for each token; a sale below it is refunded, not settled.
    ///        The contract's own floor `minImdOut` applies on top, and a sale yielding nothing never settles.
    /// @param deadline Unix time after which the whole call reverts.
    function sellAll(address[] calldata tokens, uint256[] calldata minImdOuts, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (Outcome[] memory outcomes, uint256 grossImd, uint256 tax, uint256 netImd)
    {
        if (block.timestamp > deadline) revert Expired();
        if (tokens.length == 0 || tokens.length > MAX_TOKENS_PER_SALE) revert TooManyTokens();
        if (tokens.length != minImdOuts.length) revert LengthMismatch();

        outcomes = new Outcome[](tokens.length);

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (!isSwarmToken[token]) revert NotSwarmToken(token);
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == token) revert DuplicateToken(token);
            }
            outcomes[i] = _sellOne(token, minImdOuts[i], deadline);
            grossImd += outcomes[i].imdOut;
        }

        if (grossImd == 0) revert NothingSold();
        tax = (grossImd * SELL_TAX_BPS) / BPS;
        netImd = grossImd - tax;
        IMD.safeTransfer(TREASURY, tax);
        IMD.safeTransfer(msg.sender, netImd);
        emit SoldAll(msg.sender, grossImd, tax, netImd);
    }

    /// @notice Claim a refund that the token refused to deliver during `sellAll`.
    function claimRefund(address token) external nonReentrant {
        uint256 amount = heldRefunds[msg.sender][token];
        if (amount == 0) revert NothingToClaim();
        heldRefunds[msg.sender][token] = 0;
        totalHeld[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit RefundClaimed(msg.sender, token, amount);
    }

    /// @notice Both swap legs of one token, atomic. Only callable by this contract.
    /// Reverts (so the caller refunds) when a leg yields nothing or the IMD is below the floor.
    function executeSale(address token, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        returns (uint256 imdOut)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        Route storage first = _tokenRoutes[token];
        uint256 imdBefore = IMD.balanceOf(address(this));
        if (first.tokenOut == address(IMD)) {
            _swap(first, amountIn, deadline);
        } else {
            Route storage second = _imdRoute;
            if (second.venue == Venue.None || !_bridgeable(first.tokenOut, second.tokenIn)) {
                revert NotConfigured("imdRoute");
            }
            uint256 bridgeOut = _swap(first, amountIn, deadline);
            if (bridgeOut < 1) revert NoProceeds();
            bridgeOut = _convertBridge(first.tokenOut, second.tokenIn, bridgeOut);
            _swap(second, bridgeOut, deadline);
        }
        imdOut = IMD.balanceOf(address(this)) - imdBefore;
        uint256 floor = minOut > minImdOut ? minOut : minImdOut;
        if (floor < 1) floor = 1;
        if (imdOut < floor) revert SlippageExceeded(imdOut, floor);
    }

    /// @notice Uniswap v4 callback: runs the hops of the route encoded in `data`. In quote mode it
    /// reverts with `V4Quote(amountOut)` so the manager's state rolls back; otherwise it settles the
    /// input and takes the output.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender == address(0) || msg.sender != _v4Manager) revert OnlyPoolManager();
        (bool quoteOnly, address currencyIn, V4Hop[] memory hops, uint256 amountIn) =
            abi.decode(data, (bool, address, V4Hop[], uint256));
        (address currencyOut, uint256 amountOut) = _swapV4Hops(msg.sender, currencyIn, hops, amountIn);
        if (quoteOnly) revert V4Quote(amountOut);
        IUniswapV4PoolManager pm = IUniswapV4PoolManager(msg.sender);
        if (currencyIn == NATIVE) {
            pm.settle{value: amountIn}();
        } else {
            pm.sync(currencyIn);
            IERC20(currencyIn).safeTransfer(msg.sender, amountIn);
            pm.settle();
        }
        if (amountOut > 0) pm.take(currencyOut, address(this), amountOut);
        return "";
    }

    // ------------------------------------------------------------------
    // Internals: selling
    // ------------------------------------------------------------------

    function _sellOne(address token, uint256 minOut, uint256 deadline) internal returns (Outcome memory outcome) {
        outcome.token = token;
        Route storage route = _tokenRoutes[token];
        if (route.venue == Venue.None) return _skip(outcome, Status.NoRoute);

        (bool ok, uint256 balance) = _staticUint(token, abi.encodeCall(IERC20.balanceOf, (msg.sender)));
        if (!ok || balance == 0) return _skip(outcome, Status.ZeroBalance);
        (ok, outcome.amountIn) = _staticUint(token, abi.encodeCall(IERC20.allowance, (msg.sender, address(this))));
        if (!ok || outcome.amountIn == 0) return _skip(outcome, Status.NoAllowance);
        if (outcome.amountIn > balance) outcome.amountIn = balance;

        // Predictable failures are skipped before anything is pulled.
        uint256 floor = minOut > minImdOut ? minOut : minImdOut;
        (Status quoted, uint256 expected) = _quoteToImd(route, outcome.amountIn);
        if (quoted != Status.Sold) return _skip(outcome, quoted);
        if (expected < floor || expected < 1) return _skip(outcome, Status.BelowMinimum);

        uint256 before = IERC20(token).balanceOf(address(this));
        bytes memory reason;
        (ok,, reason) =
            _callToken(token, abi.encodeCall(IERC20.transferFrom, (msg.sender, address(this), outcome.amountIn)));
        if (!ok) {
            outcome.amountIn = 0;
            outcome.status = Status.SaleFailed;
            emit TokenRefunded(msg.sender, token, 0, reason);
            return outcome;
        }
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        if (received < 1) return _skip(outcome, Status.ZeroBalance);
        outcome.amountIn = received;

        try this.executeSale(token, received, minOut, deadline) returns (uint256 imdOut) {
            outcome.imdOut = imdOut;
            outcome.status = Status.Sold;
            emit TokenSold(msg.sender, token, received, imdOut);
        } catch (bytes memory why) {
            // The self-call reverted, so every allowance it set is already gone. Refund what was pulled.
            uint256 leftover = IERC20(token).balanceOf(address(this)) - before;
            _refund(token, leftover);
            outcome.status = Status.SaleFailed;
            emit TokenRefunded(msg.sender, token, leftover, why);
        }
    }

    function _skip(Outcome memory outcome, Status status) internal returns (Outcome memory) {
        outcome.amountIn = 0;
        outcome.status = status;
        emit TokenSkipped(msg.sender, outcome.token, status);
        return outcome;
    }

    /// @dev Best-effort refund to the caller; what the token refuses to deliver is held for `claimRefund`.
    function _refund(address token, uint256 amount) internal {
        if (amount < 1) return;
        (bool ok,,) = _callToken(token, abi.encodeCall(IERC20.transfer, (msg.sender, amount)));
        if (ok) return;
        heldRefunds[msg.sender][token] += amount;
        totalHeld[token] += amount;
        emit RefundHeld(msg.sender, token, amount);
    }

    /// @dev Swap `amountIn` of route.tokenIn held by this contract; returns tokenOut received.
    function _swap(Route storage route, uint256 amountIn, uint256 deadline) internal returns (uint256 received) {
        uint256 before = _balance(route.tokenOut, address(this));
        if (route.venue == Venue.UniswapV4) {
            _swapV4(route, amountIn);
        } else {
            IERC20 tokenIn = IERC20(route.tokenIn);
            tokenIn.forceApprove(route.router, amountIn);
            if (route.venue == Venue.UniswapV2) {
                address[] memory path = abi.decode(route.data, (address[]));
                IUniswapV2Router(route.router)
                    .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, address(this), deadline);
            } else {
                IUniswapV3SwapRouter(route.router)
                    .exactInput(
                        IUniswapV3SwapRouter.ExactInputParams({
                            path: route.data, recipient: address(this), amountIn: amountIn, amountOutMinimum: 0
                        })
                    );
            }
            tokenIn.forceApprove(route.router, 0);
        }
        received = _balance(route.tokenOut, address(this)) - before;
    }

    function _swapV4(Route storage route, uint256 amountIn) internal {
        (address currencyIn, V4Hop[] memory hops) = abi.decode(route.data, (address, V4Hop[]));
        _v4Manager = route.router;
        IUniswapV4PoolManager(route.router).unlock(abi.encode(false, currencyIn, hops, amountIn));
        _v4Manager = address(0);
    }

    /// @dev Runs the hops inside an unlock. Every hop must consume its whole input (a pool without the
    /// liquidity to absorb it would leave an unsettled delta), else the sale fails.
    function _swapV4Hops(address manager, address currencyIn, V4Hop[] memory hops, uint256 amountIn)
        internal
        returns (address currency, uint256 amount)
    {
        currency = currencyIn;
        amount = amountIn;
        for (uint256 i; i < hops.length; ++i) {
            V4Hop memory hop = hops[i];
            if (amount > uint256(type(uint128).max)) revert InsufficientLiquidity();
            bool zeroForOne = currency < hop.currencyOut;
            IUniswapV4PoolManager.PoolKey memory key = IUniswapV4PoolManager.PoolKey({
                currency0: zeroForOne ? currency : hop.currencyOut,
                currency1: zeroForOne ? hop.currencyOut : currency,
                fee: hop.fee,
                tickSpacing: hop.tickSpacing,
                hooks: hop.hooks
            });
            int256 delta = IUniswapV4PoolManager(manager)
                .swap(
                    key,
                    IUniswapV4PoolManager.SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: -int256(amount),
                        sqrtPriceLimitX96: zeroForOne ? V4_MIN_PRICE_LIMIT : V4_MAX_PRICE_LIMIT
                    }),
                    ""
                );
            int128 amount0 = int128(delta >> 128);
            int128 amount1 = int128(delta);
            int128 consumed = zeroForOne ? amount0 : amount1;
            int128 got = zeroForOne ? amount1 : amount0;
            if (consumed > 0 || uint256(uint128(-consumed)) < amount) revert InsufficientLiquidity();
            amount = got > 0 ? uint256(uint128(got)) : 0;
            currency = hop.currencyOut;
        }
    }

    /// @dev WETH and native ETH bridge 1:1 between legs; anything else must match exactly.
    function _bridgeable(address from, address to) internal pure returns (bool) {
        if (from == to) return true;
        return (from == WETH && to == NATIVE) || (from == NATIVE && to == WETH);
    }

    function _convertBridge(address from, address to, uint256 amount) internal returns (uint256) {
        if (from == to) return amount;
        if (from == WETH) {
            IWETH(WETH).withdraw(amount);
        } else {
            IWETH(WETH).deposit{value: amount}();
        }
        return amount;
    }

    // ------------------------------------------------------------------
    // Internals: quoting
    // ------------------------------------------------------------------

    function _previewOne(address user, address token) internal returns (Preview memory p) {
        p.token = token;
        if (!isSwarmToken[token]) {
            p.status = Status.NotRegistered;
            return p;
        }
        Route memory first = _tokenRoutes[token];
        if (first.venue == Venue.None) {
            p.status = Status.NoRoute;
            return p;
        }
        bool ok;
        (ok, p.balance) = _staticUint(token, abi.encodeCall(IERC20.balanceOf, (user)));
        if (!ok) {
            p.status = Status.QuoteFailed;
            return p;
        }
        if (p.balance == 0) {
            p.status = Status.ZeroBalance;
            return p;
        }
        (p.status, p.expectedImd) = _quoteToImd(first, p.balance);
        if (p.status != Status.Sold) return p;
        if (p.expectedImd < minImdOut || p.expectedImd < 1) {
            p.status = Status.BelowMinimum;
            return p;
        }
        if (maxImpactBps < BPS && _impactTooHigh(first, p.balance, p.expectedImd)) {
            p.status = Status.ExcessiveImpact;
            return p;
        }
        p.sellable = true;
    }

    /// @dev Quote `amountIn` of a token route all the way to IMD (through the IMD route when needed).
    function _quoteToImd(Route memory first, uint256 amountIn) internal returns (Status status, uint256 out) {
        bool ok;
        (ok, out) = _quote(first, amountIn);
        if (!ok) return (Status.QuoteFailed, 0);
        if (first.tokenOut != address(IMD)) {
            Route memory second = _imdRoute;
            if (second.venue == Venue.None || !_bridgeable(first.tokenOut, second.tokenIn)) {
                return (Status.BridgeRouteMissing, 0);
            }
            (ok, out) = _quote(second, out);
            if (!ok) return (Status.QuoteFailed, 0);
        }
        return (Status.Sold, out);
    }

    /// @dev Compares the full quote with a small probe scaled up: the gap is the holding's price impact.
    function _impactTooHigh(Route memory first, uint256 amountIn, uint256 fullOut) internal returns (bool) {
        uint256 probeIn = amountIn / IMPACT_PROBE_DIVISOR;
        if (probeIn == 0) return false;
        (Status status, uint256 probeOut) = _quoteToImd(first, probeIn);
        if (status != Status.Sold) return false;
        uint256 scaled = probeOut * IMPACT_PROBE_DIVISOR;
        if (scaled <= fullOut) return false;
        return ((scaled - fullOut) * BPS) / scaled > maxImpactBps;
    }

    function _quote(Route memory route, uint256 amountIn) internal returns (bool ok, uint256 amountOut) {
        if (amountIn == 0) return (true, 0);
        if (route.venue == Venue.UniswapV2) {
            address[] memory path = abi.decode(route.data, (address[]));
            try IUniswapV2Router(route.router).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
                return (true, amounts[amounts.length - 1]);
            } catch {
                return (false, 0);
            }
        }
        if (route.venue == Venue.UniswapV4) {
            return _quoteV4(route.router, route.data, amountIn);
        }
        try IUniswapV3Quoter(route.quoter).quoteExactInput(route.data, amountIn) returns (
            uint256 out, uint160[] memory, uint32[] memory, uint256
        ) {
            return (true, out);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Quotes through the PoolManager the way Uniswap's own quoter does: run the swaps inside an
    /// unlock and revert with the result, so nothing is settled.
    function _quoteV4(address manager, bytes memory data, uint256 amountIn) internal returns (bool, uint256) {
        (address currencyIn, V4Hop[] memory hops) = abi.decode(data, (address, V4Hop[]));
        _v4Manager = manager;
        (bool success, bytes memory reason) =
            manager.call(abi.encodeCall(IUniswapV4PoolManager.unlock, (abi.encode(true, currencyIn, hops, amountIn))));
        _v4Manager = address(0);
        if (success || reason.length != 36 || bytes4(reason) != V4Quote.selector) return (false, 0);
        uint256 out;
        assembly ("memory-safe") {
            out := mload(add(reason, 36))
        }
        return (true, out);
    }

    // ------------------------------------------------------------------
    // Internals: routes
    // ------------------------------------------------------------------

    function _buildRoute(Venue venue, address router, address quoter, bytes calldata data)
        internal
        pure
        returns (Route memory route)
    {
        if (router == address(0)) revert ZeroAddress();
        route.venue = venue;
        route.router = router;
        route.data = data;
        if (venue == Venue.UniswapV2) {
            address[] memory path = abi.decode(data, (address[]));
            if (path.length < 2) revert InvalidRoute();
            for (uint256 i; i < path.length; ++i) {
                if (path[i] == address(0)) revert ZeroAddress();
            }
            route.tokenIn = path[0];
            route.tokenOut = path[path.length - 1];
        } else if (venue == Venue.UniswapV3) {
            if (quoter == address(0)) revert ZeroAddress();
            // 20-byte token, then (3-byte fee + 20-byte token) per hop.
            if (data.length < 43 || (data.length - 20) % 23 != 0) revert InvalidRoute();
            route.quoter = quoter;
            route.tokenIn = address(bytes20(data[0:20]));
            route.tokenOut = address(bytes20(data[data.length - 20:]));
            if (route.tokenIn == address(0) || route.tokenOut == address(0)) revert ZeroAddress();
        } else {
            (address currencyIn, V4Hop[] memory hops) = abi.decode(data, (address, V4Hop[]));
            if (hops.length == 0) revert InvalidRoute();
            address current = currencyIn;
            for (uint256 i; i < hops.length; ++i) {
                if (hops[i].currencyOut == current) revert InvalidRoute();
                current = hops[i].currencyOut;
            }
            route.tokenIn = currencyIn;
            route.tokenOut = current;
        }
    }

    /// @dev Reverse a route so it quotes tokenOut -> tokenIn.
    function _reverse(Route memory route) internal pure returns (Route memory r) {
        r.venue = route.venue;
        r.router = route.router;
        r.quoter = route.quoter;
        r.tokenIn = route.tokenOut;
        r.tokenOut = route.tokenIn;
        if (route.venue == Venue.UniswapV2) {
            address[] memory path = abi.decode(route.data, (address[]));
            uint256 n = path.length;
            address[] memory rev = new address[](n);
            for (uint256 i; i < n; ++i) {
                rev[i] = path[n - 1 - i];
            }
            r.data = abi.encode(rev);
        } else if (route.venue == Venue.UniswapV4) {
            (address currencyIn, V4Hop[] memory hops) = abi.decode(route.data, (address, V4Hop[]));
            uint256 n = hops.length;
            V4Hop[] memory rev = new V4Hop[](n);
            for (uint256 i; i < n; ++i) {
                V4Hop memory hop = hops[n - 1 - i];
                rev[i] = V4Hop({
                    currencyOut: n - 1 - i == 0 ? currencyIn : hops[n - 2 - i].currencyOut,
                    fee: hop.fee,
                    tickSpacing: hop.tickSpacing,
                    hooks: hop.hooks
                });
            }
            r.data = abi.encode(hops[n - 1].currencyOut, rev);
        } else {
            bytes memory d = route.data;
            uint256 hops = (d.length - 20) / 23;
            bytes memory rev = new bytes(d.length);
            // tokens at offsets 23*k, fees at 23*k + 20
            for (uint256 k; k <= hops; ++k) {
                uint256 src = 23 * (hops - k);
                uint256 dst = 23 * k;
                for (uint256 b; b < 20; ++b) {
                    rev[dst + b] = d[src + b];
                }
                if (k < hops) {
                    uint256 feeSrc = 23 * (hops - 1 - k) + 20;
                    for (uint256 b; b < 3; ++b) {
                        rev[dst + 20 + b] = d[feeSrc + b];
                    }
                }
            }
            r.data = rev;
        }
    }

    // ------------------------------------------------------------------
    // Internals: tokens and currencies
    // ------------------------------------------------------------------

    function _balance(address currency, address account) internal view returns (uint256) {
        return currency == NATIVE ? account.balance : IERC20(currency).balanceOf(account);
    }

    function _send(address currency, address to, uint256 amount) internal {
        if (currency == NATIVE) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(currency).safeTransfer(to, amount);
        }
    }

    /// @dev staticcall returning one uint256; (false, 0) on revert or malformed data.
    function _staticUint(address target, bytes memory data) internal view returns (bool ok, uint256 value) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev Non-reverting ERC20 call with SafeERC20's success rule (no data or a true boolean).
    function _callToken(address token, bytes memory data)
        internal
        returns (bool ok, bytes memory ret, bytes memory reason)
    {
        bool success;
        (success, ret) = token.call(data);
        if (!success) return (false, ret, ret);
        if (ret.length == 0) return (token.code.length > 0, ret, "");
        if (ret.length < 32) return (false, ret, ret);
        ok = abi.decode(ret, (bool));
        return (ok, ret, ok ? bytes("") : bytes("transfer returned false"));
    }
}
