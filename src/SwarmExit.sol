// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Router, IUniswapV3SwapRouter, IUniswapV3Quoter, IAggregatorV3} from "./interfaces/IDexVenues.sol";

/// @title SwarmExit
/// @notice One-click exit from swarm-launched tokens into $IMD.
///
/// The owner registers every token the swarm launched together with the route that sells it
/// (a Uniswap V2 style path or a Uniswap V3 packed path) into a bridge token (WETH) or directly
/// into IMD. A single global route turns the bridge token into IMD. A user calls `sellAll` with
/// the tokens they hold: each token is pulled, sold through its route, and the IMD proceeds are
/// pooled. A 2% sell tax of the IMD proceeds goes to the treasury and the rest to the user.
/// A token whose sale reverts (no liquidity, honeypot, slippage) is refunded to the user inside
/// the same transaction and the remaining tokens are still sold.
///
/// `preview` (call it with eth_call, it is not a view because Uniswap V3 quoting is not) tells
/// the frontend which tokens are sellable and how much IMD they would fetch.
contract SwarmExit is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants fixed by the brief
    // ------------------------------------------------------------------

    /// @notice $IMD, the token every sale settles in (Ethereum mainnet).
    IERC20 public constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    /// @notice Treasury that receives the sell tax.
    address public constant TREASURY = 0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB;
    /// @notice Sell tax in basis points, taken from the IMD proceeds.
    uint256 public constant SELL_TAX_BPS = 200;
    uint256 public constant BPS = 10_000;
    /// @notice Oldest Chainlink answer `ethUsdPrice` accepts (the ETH/USD feed heartbeat is 1 hour).
    uint256 public constant MAX_PRICE_AGE = 3 hours;
    /// @notice Default dust threshold: a token whose quoted proceeds are below it is not sellable.
    uint256 public constant DEFAULT_MIN_IMD_OUT = 1e15;
    /// @notice Upper bound on tokens per `sellAll` call so the loop stays inside the block gas limit.
    uint256 public constant MAX_TOKENS_PER_SALE = 50;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum Venue {
        None,
        UniswapV2,
        UniswapV3
    }

    /// @param venue Which router interface to use.
    /// @param router Router to swap through (V2 Router02 or V3 SwapRouter02).
    /// @param quoter QuoterV2 for V3 routes; unused (zero) for V2 routes, which quote on the router.
    /// @param tokenIn First token of the path.
    /// @param tokenOut Last token of the path.
    /// @param data abi.encode(address[] path) for V2, packed V3 path for V3.
    struct Route {
        Venue venue;
        address router;
        address quoter;
        address tokenIn;
        address tokenOut;
        bytes data;
    }

    enum Status {
        Sold,
        NotRegistered,
        ZeroBalance,
        NoRoute,
        BridgeRouteMissing,
        QuoteFailed,
        BelowMinimum,
        SaleFailed
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
    /// @dev Route from the bridge token (WETH) into IMD. Unset until the owner configures it.
    Route private _imdRoute;
    IAggregatorV3 public ethUsdFeed;
    uint256 public minImdOut = DEFAULT_MIN_IMD_OUT;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    event SwarmTokenSet(address indexed token, bool registered);
    event TokenRouteSet(address indexed token, Venue venue, address router, address quoter, address tokenOut);
    event ImdRouteSet(Venue venue, address router, address quoter, address tokenIn);
    event EthUsdFeedSet(address indexed feed);
    event MinImdOutSet(uint256 minImdOut);
    event TokenSold(address indexed user, address indexed token, uint256 amountIn, uint256 imdOut);
    event TokenRefunded(address indexed user, address indexed token, uint256 amount, bytes reason);
    event SoldAll(address indexed user, uint256 grossImd, uint256 tax, uint256 netImd);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotSwarmToken(address token);
    error InvalidRoute();
    error NotConfigured(string what);
    error OnlySelf();
    error TooManyTokens();
    error LengthMismatch();
    error DuplicateToken(address token);
    error Expired();
    error NothingSold();
    error SlippageExceeded(uint256 got, uint256 want);
    error StalePrice();
    error InvalidPrice();
    error CannotRescueSwarmToken();

    // ------------------------------------------------------------------
    // Constructor: no external calls, no code requirements (runs on an empty chain).
    // ------------------------------------------------------------------

    constructor(address owner_) Ownable(owner_) {}

    // ------------------------------------------------------------------
    // Owner configuration
    // ------------------------------------------------------------------

    /// @notice Register or unregister a token launched by the swarm.
    function setSwarmToken(address token, bool registered) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isSwarmToken[token] == registered) return;
        isSwarmToken[token] = registered;
        if (registered) {
            _swarmTokens.push(token);
        } else {
            uint256 n = _swarmTokens.length;
            for (uint256 i; i < n; ++i) {
                if (_swarmTokens[i] == token) {
                    _swarmTokens[i] = _swarmTokens[n - 1];
                    _swarmTokens.pop();
                    break;
                }
            }
        }
        emit SwarmTokenSet(token, registered);
    }

    /// @notice Set the route that sells `token` into IMD or into the bridge token of the IMD route.
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

    /// @notice Set the route from the bridge token (WETH) into IMD.
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

    /// @notice Set the dust threshold under which a token is reported as not sellable.
    function setMinImdOut(uint256 value) external onlyOwner {
        minImdOut = value;
        emit MinImdOutSet(value);
    }

    /// @notice Pause selling (configuration and previews keep working).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Return tokens sent here by mistake. Swarm tokens and IMD never rest here in normal
    /// operation (every sale either settles or refunds in the same transaction), and swarm tokens
    /// cannot be rescued at all so the owner can never claim a user's token mid-flight.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (isSwarmToken[token]) revert CannotRescueSwarmToken();
        IERC20(token).safeTransfer(to, amount);
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

    /// @notice How much bridge token (WETH) `imdAmount` would fetch along the reversed IMD route.
    /// The frontend multiplies it by the ETH/USD price to show USD values. Call with eth_call.
    function quoteImdInBridge(uint256 imdAmount) external returns (uint256 bridgeAmount) {
        if (_imdRoute.venue == Venue.None) revert NotConfigured("imdRoute");
        (bool ok, uint256 amount) = _quote(_reverse(_imdRoute), imdAmount);
        if (!ok) revert NotConfigured("imdRoute quote");
        return amount;
    }

    // ------------------------------------------------------------------
    // Selling
    // ------------------------------------------------------------------

    /// @notice Sell the caller's full balance of each token for IMD, net of the 2% treasury tax.
    /// @param tokens Registered swarm tokens to sell (no duplicates).
    /// @param minImdOuts Minimum IMD accepted for each token; a sale below it is refunded, not settled.
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

        address user = msg.sender;
        outcomes = new Outcome[](tokens.length);

        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            if (!isSwarmToken[token]) revert NotSwarmToken(token);
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == token) revert DuplicateToken(token);
            }
            outcomes[i] = _sellOne(user, token, minImdOuts[i], deadline);
            grossImd += outcomes[i].imdOut;
        }

        if (grossImd == 0) revert NothingSold();
        tax = (grossImd * SELL_TAX_BPS) / BPS;
        netImd = grossImd - tax;
        IMD.safeTransfer(TREASURY, tax);
        IMD.safeTransfer(user, netImd);
        emit SoldAll(user, grossImd, tax, netImd);
    }

    /// @notice Both swap legs of one token, atomic. Only callable by this contract.
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
            if (second.venue == Venue.None || second.tokenIn != first.tokenOut) {
                revert NotConfigured("imdRoute");
            }
            uint256 bridgeOut = _swap(first, amountIn, deadline);
            _swap(second, bridgeOut, deadline);
        }
        imdOut = IMD.balanceOf(address(this)) - imdBefore;
        if (imdOut < minOut) revert SlippageExceeded(imdOut, minOut);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _sellOne(address user, address token, uint256 minOut, uint256 deadline)
        internal
        returns (Outcome memory outcome)
    {
        outcome.token = token;
        Route storage route = _tokenRoutes[token];
        if (route.venue == Venue.None) {
            outcome.status = Status.NoRoute;
            return outcome;
        }
        IERC20 erc = IERC20(token);
        uint256 balance = erc.balanceOf(user);
        if (balance == 0) {
            outcome.status = Status.ZeroBalance;
            return outcome;
        }
        uint256 before = erc.balanceOf(address(this));
        erc.safeTransferFrom(user, address(this), balance);
        uint256 received = erc.balanceOf(address(this)) - before;
        if (received == 0) {
            outcome.status = Status.ZeroBalance;
            return outcome;
        }
        outcome.amountIn = received;

        try this.executeSale(token, received, minOut, deadline) returns (uint256 imdOut) {
            outcome.imdOut = imdOut;
            outcome.status = Status.Sold;
            emit TokenSold(user, token, received, imdOut);
        } catch (bytes memory reason) {
            // Refund whatever was pulled, and leave no allowance behind.
            erc.forceApprove(route.router, 0);
            if (route.tokenOut != address(IMD) && _imdRoute.venue != Venue.None) {
                IERC20(route.tokenOut).forceApprove(_imdRoute.router, 0);
            }
            uint256 leftover = erc.balanceOf(address(this)) - before;
            if (leftover > 0) erc.safeTransfer(user, leftover);
            outcome.status = Status.SaleFailed;
            emit TokenRefunded(user, token, leftover, reason);
        }
    }

    /// @dev Swap `amountIn` of route.tokenIn held by this contract; returns tokenOut received.
    function _swap(Route storage route, uint256 amountIn, uint256 deadline) internal returns (uint256 received) {
        IERC20 tokenIn = IERC20(route.tokenIn);
        IERC20 tokenOut = IERC20(route.tokenOut);
        uint256 before = tokenOut.balanceOf(address(this));
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
        received = tokenOut.balanceOf(address(this)) - before;
    }

    function _previewOne(address user, address token) internal returns (Preview memory p) {
        p.token = token;
        if (!isSwarmToken[token]) {
            p.status = Status.NotRegistered;
            return p;
        }
        p.balance = IERC20(token).balanceOf(user);
        Route memory first = _tokenRoutes[token];
        if (first.venue == Venue.None) {
            p.status = Status.NoRoute;
            return p;
        }
        if (p.balance == 0) {
            p.status = Status.ZeroBalance;
            return p;
        }
        (bool ok, uint256 out) = _quote(first, p.balance);
        if (!ok) {
            p.status = Status.QuoteFailed;
            return p;
        }
        if (first.tokenOut != address(IMD)) {
            Route memory second = _imdRoute;
            if (second.venue == Venue.None || second.tokenIn != first.tokenOut) {
                p.status = Status.BridgeRouteMissing;
                return p;
            }
            (ok, out) = _quote(second, out);
            if (!ok) {
                p.status = Status.QuoteFailed;
                return p;
            }
        }
        p.expectedImd = out;
        if (out < minImdOut) {
            p.status = Status.BelowMinimum;
            return p;
        }
        p.sellable = true;
        p.status = Status.Sold;
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
        try IUniswapV3Quoter(route.quoter).quoteExactInput(route.data, amountIn) returns (
            uint256 out, uint160[] memory, uint32[] memory, uint256
        ) {
            return (true, out);
        } catch {
            return (false, 0);
        }
    }

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
        } else {
            if (quoter == address(0)) revert ZeroAddress();
            // 20-byte token, then (3-byte fee + 20-byte token) per hop.
            if (data.length < 43 || (data.length - 20) % 23 != 0) revert InvalidRoute();
            route.quoter = quoter;
            route.tokenIn = address(bytes20(data[0:20]));
            route.tokenOut = address(bytes20(data[data.length - 20:]));
            if (route.tokenIn == address(0) || route.tokenOut == address(0)) revert ZeroAddress();
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
}
