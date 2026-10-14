// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmExit} from "../src/SwarmExit.sol";
import {SwarmExitV4Fixture} from "./SwarmExitV4Fixture.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {MockV4PoolManager} from "./mocks/MockVenues.sol";

/// @notice Drives SwarmExit through its Uniswap v4 venue with several actors: direct and bridged
/// v4 routes, native ETH legs, fee-on-transfer tokens settled before the swap, a honeypot that
/// reverts inside the manager, a V2 leg unwrapped into the native v4 IMD route, thin pools that
/// fill partially, liquidity changes, floor changes, stray ETH and expired deadlines.
contract SwarmExitV4Handler is Test {
    address constant TREASURY = 0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB;
    address constant NATIVE = address(0);
    uint256 immutable N;

    SwarmExit public exit;
    IERC20 public imd;
    MockV4PoolManager public pm;
    address public owner;
    address[] public actors;
    address[] public tokens; // V, E, feeV, feeE, A, honey, C
    mapping(address => bool) public isFeeToken;
    mapping(address => bool) public isV4Token;

    uint256 public ghostGross;
    uint256 public ghostTax;
    uint256 public ghostNet;
    mapping(address => uint256) public ghostNetOf;
    uint256 public ghostStrayEth;
    uint256 public ghostSales;
    uint256 public ghostReverts;
    uint256 public ghostFailures;
    uint256 public ghostFeeSales;

    constructor(
        SwarmExit exit_,
        IERC20 imd_,
        MockV4PoolManager pm_,
        address owner_,
        address[] memory tokens_,
        address[] memory feeTokens_,
        address[] memory v4Tokens_
    ) {
        exit = exit_;
        imd = imd_;
        pm = pm_;
        owner = owner_;
        tokens = tokens_;
        N = tokens_.length;
        for (uint256 i; i < feeTokens_.length; ++i) {
            isFeeToken[feeTokens_[i]] = true;
        }
        for (uint256 i; i < v4Tokens_.length; ++i) {
            isV4Token[v4Tokens_[i]] = true;
        }
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        for (uint256 a; a < actors.length; ++a) {
            vm.startPrank(actors[a]);
            for (uint256 i; i < N; ++i) {
                IERC20(tokens[i]).approve(address(exit), type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------------ actions

    function mint(uint8 actorSeed, uint8 tokenSeed, uint96 amount) external {
        amount = uint96(bound(amount, 1, 20_000e18));
        MockERC20(tokens[tokenSeed % N]).mint(actors[actorSeed % actors.length], amount);
    }

    struct Snap {
        address actor;
        address[] list;
        uint256[] mins;
        uint256[] before;
        uint256 imdBefore;
        uint256 treasuryBefore;
    }

    function sell(uint8 actorSeed, uint8 mask, uint8 rot, uint8 minMode, uint8 deadlineMode) external {
        Snap memory s = _prepare(actors[actorSeed % actors.length], mask, rot, minMode);
        uint256 deadline = deadlineMode % 7 == 0 ? block.timestamp - 1 : block.timestamp + 60;
        vm.prank(s.actor);
        (bool ok, bytes memory ret) = address(exit).call(abi.encodeCall(SwarmExit.sellAll, (s.list, s.mins, deadline)));
        if (!ok) {
            ++ghostReverts;
            for (uint256 i; i < s.list.length; ++i) {
                assertEq(IERC20(s.list[i]).balanceOf(s.actor), s.before[i], "revert must move nothing");
            }
            assertEq(imd.balanceOf(s.actor), s.imdBefore, "revert must pay nothing");
            assertEq(imd.balanceOf(TREASURY), s.treasuryBefore, "revert must tax nothing");
            return;
        }
        _checkSuccess(s, ret);
    }

    function _prepare(address actor, uint8 mask, uint8 rot, uint8 minMode) internal returns (Snap memory s) {
        s.actor = actor;
        mask = uint8(bound(mask, 1, (1 << N) - 1));
        uint256 count;
        for (uint256 i; i < N; ++i) {
            if (mask & (1 << i) != 0) ++count;
        }
        s.list = new address[](count);
        s.mins = new uint256[](count);
        s.before = new uint256[](count);
        uint256 k;
        for (uint256 j; j < N; ++j) {
            uint256 i = (j + rot) % N;
            if (mask & (1 << i) == 0) continue;
            s.list[k] = tokens[i];
            // minMode: 0 = zero, 1 = isolated quote (fee tokens and shared pools refund), 2 = quote + 1
            if (minMode % 3 != 0) {
                SwarmExit.Preview[] memory p = exit.preview(actor, _one(tokens[i]));
                s.mins[k] = minMode % 3 == 1 ? p[0].expectedImd : p[0].expectedImd + 1;
            }
            s.before[k] = IERC20(tokens[i]).balanceOf(actor);
            ++k;
        }
        s.imdBefore = imd.balanceOf(actor);
        s.treasuryBefore = imd.balanceOf(TREASURY);
    }

    function _checkSuccess(Snap memory s, bytes memory ret) internal {
        (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
            abi.decode(ret, (SwarmExit.Outcome[], uint256, uint256, uint256));
        uint256 sum;
        for (uint256 i; i < s.list.length; ++i) {
            address token = s.list[i];
            sum += out[i].imdOut;
            if (out[i].status == SwarmExit.Status.Sold) {
                assertEq(IERC20(token).balanceOf(s.actor), 0, "sold token fully taken");
                assertGe(out[i].imdOut, s.mins[i], "settled below the caller's minimum");
                assertGe(out[i].imdOut, 1, "sold for nothing");
                if (isFeeToken[token]) {
                    ++ghostFeeSales;
                    assertEq(out[i].amountIn, s.before[i] - s.before[i] * 500 / 10_000, "amountIn is what arrived");
                } else {
                    assertEq(out[i].amountIn, s.before[i], "amountIn is the whole balance");
                }
                continue;
            }
            assertEq(out[i].imdOut, 0, "unsold token yields nothing");
            if (out[i].status != SwarmExit.Status.SaleFailed) {
                assertEq(out[i].amountIn, 0, "a skipped token is never pulled");
                assertEq(IERC20(token).balanceOf(s.actor), s.before[i], "a skipped token never moves");
                continue;
            }
            ++ghostFailures;
            if (out[i].amountIn == 0) {
                assertEq(IERC20(token).balanceOf(s.actor), s.before[i], "a refused pull moves nothing");
            } else if (isFeeToken[token]) {
                uint256 pulled = s.before[i] - s.before[i] * 500 / 10_000;
                assertEq(out[i].amountIn, pulled, "refund is every wei the exit received");
                assertEq(
                    IERC20(token).balanceOf(s.actor), pulled - pulled * 500 / 10_000, "refund minus the token's fee"
                );
            } else {
                assertEq(out[i].amountIn, s.before[i]);
                assertEq(IERC20(token).balanceOf(s.actor), s.before[i], "refunded in full");
            }
        }
        assertEq(gross, sum, "gross is the sum of outcomes");
        assertGt(gross, 0, "a success always sold something");
        assertEq(tax, gross * 200 / 10_000, "tax is exactly 2% rounded down");
        assertEq(net + tax, gross, "nothing lost between gross and net");
        assertEq(imd.balanceOf(s.actor), s.imdBefore + net, "user paid net");
        assertEq(imd.balanceOf(TREASURY), s.treasuryBefore + tax, "treasury paid tax");
        ++ghostSales;
        ghostGross += gross;
        ghostTax += tax;
        ghostNet += net;
        ghostNetOf[s.actor] += net;
    }

    /// @dev Thin pools: every real v4 swap consumes only half its input, so every v4 leg fails.
    function togglePartialFill(bool on) external {
        pm.setPartialFillRealSwaps(on);
    }

    function addV4Liquidity(uint8 tokenSeed, uint96 amountA, uint96 amountB) external {
        address token = tokens[tokenSeed % N];
        if (!isV4Token[token]) return;
        amountA = uint96(bound(amountA, 1e18, 100_000e18));
        amountB = uint96(bound(amountB, 1e18, 1_000e18));
        address out = exit.tokenRoute(token).tokenOut;
        (address c0, address c1) = token < out ? (token, out) : (out, token);
        (uint256 amt0, uint256 amt1) = token < out ? (amountA, amountB) : (amountB, amountA);
        MockV4PoolManager.PoolKey memory key =
            MockV4PoolManager.PoolKey({currency0: c0, currency1: c1, fee: 10_000, tickSpacing: 200, hooks: address(0)});
        uint256 value;
        if (c0 == NATIVE) {
            vm.deal(address(this), amt0);
            value = amt0;
        } else {
            MockERC20(c0).mint(address(this), amt0);
            IERC20(c0).approve(address(pm), amt0);
        }
        if (c1 == NATIVE) {
            vm.deal(address(this), amt1);
            value = amt1;
        } else {
            MockERC20(c1).mint(address(this), amt1);
            IERC20(c1).approve(address(pm), amt1);
        }
        pm.addLiquidity{value: value}(key, amt0, amt1);
    }

    function setMinImdOut(uint96 value) external {
        vm.prank(owner);
        exit.setMinImdOut(value);
    }

    function strayEth(uint96 amount) external {
        amount = uint96(bound(amount, 1, 10 ether));
        vm.deal(address(this), amount);
        (bool ok,) = address(exit).call{value: amount}("");
        assertTrue(ok, "the exit accepts ETH");
        ghostStrayEth += amount;
    }

    function warp(uint32 by) external {
        vm.warp(block.timestamp + bound(by, 1, 1 days));
    }

    function _one(address t) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = t;
    }
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 32
/// forge-config: default.invariant.fail-on-revert = false
contract SwarmExitV4InvariantTest is SwarmExitV4Fixture {
    SwarmExitV4Handler handler;
    address[] allTokens;

    function setUp() public {
        _deployV4Fixture();
        allTokens.push(address(tokenV));
        allTokens.push(address(tokenE));
        allTokens.push(address(feeV));
        allTokens.push(address(feeE));
        allTokens.push(address(tokenA));
        allTokens.push(address(honey));
        allTokens.push(address(tokenC));
        address[] memory feeTokens = _two(address(feeV), address(feeE));
        address[] memory v4Tokens = new address[](4);
        v4Tokens[0] = address(tokenV);
        v4Tokens[1] = address(tokenE);
        v4Tokens[2] = address(feeV);
        v4Tokens[3] = address(feeE);
        handler = new SwarmExitV4Handler(exit, IERC20(IMD_ADDR), pm, OWNER, allTokens, feeTokens, v4Tokens);
        for (uint256 a; a < handler.actorCount(); ++a) {
            address actor = handler.actors(a);
            tokenV.mint(actor, 100e18);
            tokenE.mint(actor, 1_000e18);
            feeV.mint(actor, 100e18);
            feeE.mint(actor, 1_000e18);
            tokenA.mint(actor, 1_000e18);
            honey.mint(actor, 100e18);
            tokenC.mint(actor, 100e18);
        }
        targetContract(address(handler));
    }

    /// @notice Every sale settles or refunds inside its transaction: the exit keeps no token, no
    /// WETH, no IMD and no ETH beyond what was sent to it directly.
    function invariant_exitHoldsNothingButStrayEth() public view {
        for (uint256 i; i < allTokens.length; ++i) {
            assertEq(IERC20(allTokens[i]).balanceOf(address(exit)), 0, "swarm token rests in exit");
        }
        assertEq(weth.balanceOf(address(exit)), 0, "WETH rests in exit");
        assertEq(imd.balanceOf(address(exit)), 0, "IMD rests in exit");
        assertEq(address(exit).balance, handler.ghostStrayEth(), "ETH rests in exit");
    }

    /// @notice The manager is never left locked or with an unsettled delta in any currency, whether
    /// the input was paid first and the swap then failed, or the token credited less than was sent.
    function invariant_managerSettledAndIdle() public view {
        _assertManagerSettled();
        assertEq(pm.currencyDelta(address(tokenC)), 0);
    }

    /// @notice Outside a sale nobody, not even the manager, can drive the callback.
    function invariant_callbackClosedBetweenTransactions() public {
        vm.prank(address(pm));
        vm.expectRevert(SwarmExit.OnlyPoolManager.selector);
        exit.unlockCallback(abi.encode(false, address(tokenV), new SwarmExit.V4Hop[](0), uint256(1)));
    }

    /// @notice Treasury holds exactly the sum of every sale's 2% tax.
    function invariant_treasuryEqualsTaxSum() public view {
        assertEq(imd.balanceOf(TREASURY), handler.ghostTax());
    }

    /// @notice Users hold exactly their net proceeds; gross is conserved into tax plus net.
    function invariant_usersHoldNetProceeds() public view {
        uint256 total;
        for (uint256 a; a < handler.actorCount(); ++a) {
            address actor = handler.actors(a);
            assertEq(imd.balanceOf(actor), handler.ghostNetOf(actor));
            total += imd.balanceOf(actor);
        }
        assertEq(total, handler.ghostNet());
        assertEq(handler.ghostNet() + handler.ghostTax(), handler.ghostGross());
        assertLe(handler.ghostTax() * 10_000, handler.ghostGross() * 200);
        assertGe(handler.ghostTax() * 10_000 + handler.ghostSales() * 10_000, handler.ghostGross() * 200);
    }

    /// @notice The registry and the brief's constants never change under the handler.
    function invariant_configurationFixed() public view {
        assertEq(exit.swarmTokenCount(), allTokens.length);
        assertEq(address(exit.IMD()), IMD_ADDR);
        assertEq(exit.TREASURY(), TREASURY);
        assertEq(exit.owner(), OWNER);
        assertTrue(exit.imdRoute().venue == SwarmExit.Venue.UniswapV4);
    }
}
