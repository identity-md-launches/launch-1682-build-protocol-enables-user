// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SwarmExit} from "../src/SwarmExit.sol";
import {IUniswapV2Router} from "../src/interfaces/IDexVenues.sol";
import {MockERC20, FeeOnTransferToken, HoneypotToken} from "./mocks/MockTokens.sol";
import {MockPools, MockV2Router, MockV3Router, MockV3Quoter, MockWETH, MockV4PoolManager} from "./mocks/MockVenues.sol";

/// @dev Transfers to blocked recipients revert; used to make a refund fail after the pull succeeded.
contract RefundBlockingToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Blocker", "BLK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool v) external {
        blocked[who] = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "BLK: recipient blocked");
        super._update(from, to, value);
    }
}

/// @dev `balanceOf` reverts for everyone: a registry entry that must not brick `previewAll`.
contract RevertingBalanceToken {
    function balanceOf(address) external pure returns (uint256) {
        revert("paused");
    }
}

/// @dev Quotes generously, pulls the tokens, pays nothing.
contract ThiefRouter is IUniswapV2Router {
    using SafeERC20 for IERC20;

    function getAmountsOut(uint256 amountIn, address[] calldata path) external pure returns (uint256[] memory a) {
        a = new uint256[](path.length);
        a[0] = amountIn;
        a[path.length - 1] = amountIn * 10;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address,
        uint256
    ) external {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
    }
}

contract SwarmExitRevisionTest is Test {
    address constant OWNER = 0x0acE1DBE8AAb293cd58D5e3Ea38814f0ccb74782;
    address constant IMD_ADDR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant TREASURY = 0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB;
    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant NATIVE = address(0);
    uint24 constant FEE_1PCT = 10_000;

    SwarmExit exit;
    MockERC20 imd;
    MockWETH weth;
    MockPools pools;
    MockV2Router v2;
    MockV3Router v3;
    MockV3Quoter quoter;
    MockV4PoolManager pm;

    MockERC20 tokenA; // V2 route A -> WETH
    MockERC20 tokenC; // V2 route C -> IMD directly
    MockERC20 tokenV; // v4 route V -> IMD directly
    MockERC20 tokenE; // v4 route E -> native ETH
    FeeOnTransferToken feeTok; // V2 route with transfer fee
    RefundBlockingToken blk; // V2 route to IMD, refund can be blocked
    HoneypotToken honey; // V2 route, transfers into the pool revert

    address user = makeAddr("user");
    address lp = makeAddr("lp");

    function setUp() public {
        vm.warp(1_760_000_000);
        imd = MockERC20(IMD_ADDR);
        vm.etch(IMD_ADDR, address(new MockERC20("IMD", "IMD")).code);
        weth = MockWETH(payable(WETH_ADDR));
        vm.etch(WETH_ADDR, address(new MockWETH()).code);
        vm.deal(WETH_ADDR, 1_000_000 ether); // backing for the WETH minted into the mock pools
        pools = new MockPools();
        v2 = new MockV2Router(pools);
        v3 = new MockV3Router(pools);
        quoter = new MockV3Quoter(pools, v3);
        pm = new MockV4PoolManager();
        exit = new SwarmExit(OWNER);

        tokenA = new MockERC20("A", "A");
        tokenC = new MockERC20("C", "C");
        tokenV = new MockERC20("V", "V");
        tokenE = new MockERC20("E", "E");
        feeTok = new FeeOnTransferToken(500);
        blk = new RefundBlockingToken();
        honey = new HoneypotToken();

        // V2/V3 liquidity: 1 WETH = 1000 IMD; 1 A = 0.001 WETH; 1 C = 2 IMD.
        _addLiquidity(WETH_ADDR, IMD_ADDR, 100e18, 100_000e18);
        _addLiquidity(address(tokenA), WETH_ADDR, 1_000_000e18, 1000e18);
        _addLiquidity(address(tokenC), IMD_ADDR, 50_000e18, 100_000e18);
        _addLiquidity(address(feeTok), WETH_ADDR, 1_000_000e18, 1000e18);
        _addLiquidity(address(blk), IMD_ADDR, 50_000e18, 100_000e18);
        _addLiquidity(address(honey), WETH_ADDR, 1_000_000e18, 1000e18);
        honey.setBlocked(address(pools), true);
        // v4 liquidity: ETH/IMD 100 ETH = 100_000 IMD; V/IMD 1 V = 2 IMD; E/ETH 1 E = 0.001 ETH.
        _addV4(NATIVE, IMD_ADDR, 100e18, 100_000e18);
        _addV4(address(tokenV), IMD_ADDR, 50_000e18, 100_000e18);
        _addV4(address(tokenE), NATIVE, 1_000_000e18, 1000e18);

        vm.startPrank(OWNER);
        _register(address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenA), WETH_ADDR));
        _register(address(tokenC), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenC), IMD_ADDR));
        _register(address(tokenV), SwarmExit.Venue.UniswapV4, address(pm), address(0), _v4(address(tokenV), IMD_ADDR));
        _register(address(tokenE), SwarmExit.Venue.UniswapV4, address(pm), address(0), _v4(address(tokenE), NATIVE));
        _register(address(feeTok), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(feeTok), WETH_ADDR));
        _register(address(blk), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(blk), IMD_ADDR));
        _register(address(honey), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(honey), WETH_ADDR));
        // IMD route on v4: native ETH -> IMD.
        exit.setImdRoute(SwarmExit.Venue.UniswapV4, address(pm), address(0), _v4(NATIVE, IMD_ADDR));
        vm.stopPrank();

        tokenA.mint(user, 10_000e18);
        tokenC.mint(user, 1_000e18);
        tokenV.mint(user, 1_000e18);
        tokenE.mint(user, 10_000e18);
        feeTok.mint(user, 10_000e18);
        blk.mint(user, 1_000e18);
        honey.mint(user, 10_000e18);
        vm.startPrank(user);
        tokenA.approve(address(exit), type(uint256).max);
        tokenC.approve(address(exit), type(uint256).max);
        tokenV.approve(address(exit), type(uint256).max);
        tokenE.approve(address(exit), type(uint256).max);
        feeTok.approve(address(exit), type(uint256).max);
        blk.approve(address(exit), type(uint256).max);
        honey.approve(address(exit), type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _register(address token, SwarmExit.Venue venue, address router, address q, bytes memory data) internal {
        exit.setSwarmToken(token, true);
        exit.setTokenRoute(token, venue, router, q, data);
    }

    function _addLiquidity(address a, address b, uint256 amtA, uint256 amtB) internal {
        MockERC20(a).mint(lp, amtA);
        MockERC20(b).mint(lp, amtB);
        vm.startPrank(lp);
        IERC20(a).approve(address(pools), amtA);
        IERC20(b).approve(address(pools), amtB);
        pools.addLiquidity(a, b, amtA, amtB);
        vm.stopPrank();
    }

    function _key(address a, address b) internal pure returns (MockV4PoolManager.PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return
            MockV4PoolManager.PoolKey({
                currency0: c0, currency1: c1, fee: FEE_1PCT, tickSpacing: 200, hooks: address(0)
            });
    }

    function _addV4(address a, address b, uint256 amtA, uint256 amtB) internal {
        MockV4PoolManager.PoolKey memory key = _key(a, b);
        (uint256 amt0, uint256 amt1) = a < b ? (amtA, amtB) : (amtB, amtA);
        uint256 value;
        vm.startPrank(lp);
        if (key.currency0 == NATIVE) {
            vm.deal(lp, lp.balance + amt0);
            value = amt0;
        } else {
            MockERC20(key.currency0).mint(lp, amt0);
            IERC20(key.currency0).approve(address(pm), amt0);
        }
        if (key.currency1 == NATIVE) {
            vm.deal(lp, lp.balance + amt1);
            value = amt1;
        } else {
            MockERC20(key.currency1).mint(lp, amt1);
            IERC20(key.currency1).approve(address(pm), amt1);
        }
        pm.addLiquidity{value: value}(key, amt0, amt1);
        vm.stopPrank();
    }

    function _v2(address a, address b) internal pure returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        return abi.encode(path);
    }

    function _v4(address a, address b) internal pure returns (bytes memory) {
        SwarmExit.V4Hop[] memory hops = new SwarmExit.V4Hop[](1);
        hops[0] = SwarmExit.V4Hop({currencyOut: b, fee: FEE_1PCT, tickSpacing: 200, hooks: address(0)});
        return abi.encode(a, hops);
    }

    function _one(address t) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = t;
    }

    function _two(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _zeros(uint256 n) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](n);
    }

    function _expectedImd(address token) internal returns (uint256) {
        return exit.preview(user, _one(token))[0].expectedImd;
    }

    // ------------------------------------------------------------------ Uniswap v4 venue

    function test_v4RouteValidation() public {
        vm.startPrank(OWNER);
        SwarmExit.V4Hop[] memory none = new SwarmExit.V4Hop[](0);
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(
            address(tokenV), SwarmExit.Venue.UniswapV4, address(pm), address(0), abi.encode(tokenV, none)
        );
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(
            address(tokenV), SwarmExit.Venue.UniswapV4, address(pm), address(0), _v4(address(tokenV), address(tokenV))
        );
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(
            address(tokenV), SwarmExit.Venue.UniswapV4, address(pm), address(0), _v4(address(tokenC), IMD_ADDR)
        );
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.setTokenRoute(
            address(tokenV), SwarmExit.Venue.UniswapV4, address(0), address(0), _v4(address(tokenV), IMD_ADDR)
        );
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setImdRoute(SwarmExit.Venue.UniswapV4, address(pm), address(0), _v4(IMD_ADDR, NATIVE));
        vm.stopPrank();
        SwarmExit.Route memory r = exit.imdRoute();
        assertTrue(r.venue == SwarmExit.Venue.UniswapV4);
        assertEq(r.tokenIn, NATIVE);
        assertEq(r.tokenOut, IMD_ADDR);
    }

    function test_v4DirectRouteQuoteMatchesExecution() public {
        uint256 expected = _expectedImd(address(tokenV));
        assertEq(expected, pm.getAmountOut(_key(address(tokenV), IMD_ADDR), address(tokenV) < IMD_ADDR, 1_000e18));
        assertGt(expected, 1_900e18);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
            exit.sellAll(_one(address(tokenV)), _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].imdOut, expected);
        assertEq(gross, expected);
        assertEq(tax, expected * 200 / 10_000);
        assertEq(imd.balanceOf(user), net);
        assertEq(imd.balanceOf(TREASURY), tax);
        assertEq(tokenV.balanceOf(user), 0);
        assertEq(tokenV.balanceOf(address(exit)), 0);
        assertEq(imd.balanceOf(address(exit)), 0);
        assertEq(pm.locker(), address(0));
    }

    function test_v2ToWethThenV4NativeImdRoute() public {
        // A -> WETH (V2), unwrap to ETH, ETH -> IMD (v4). Nothing rests in the contract afterwards.
        uint256 expected = _expectedImd(address(tokenA));
        uint256 wethOut = pools.getAmountOut(address(tokenA), WETH_ADDR, 10_000e18);
        assertEq(expected, pm.getAmountOut(_key(NATIVE, IMD_ADDR), true, wethOut));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,, uint256 net) =
            exit.sellAll(_one(address(tokenA)), _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].imdOut, expected);
        assertEq(imd.balanceOf(user), net);
        assertEq(address(exit).balance, 0);
        assertEq(weth.balanceOf(address(exit)), 0);
        assertEq(tokenA.balanceOf(address(exit)), 0);
    }

    function test_v4ToNativeThenWrapIntoV3ImdRoute() public {
        // E -> ETH (v4), wrap to WETH, WETH -> IMD (V3).
        vm.prank(OWNER);
        exit.setImdRoute(
            SwarmExit.Venue.UniswapV3, address(v3), address(quoter), abi.encodePacked(WETH_ADDR, FEE_1PCT, IMD_ADDR)
        );
        uint256 expected = _expectedImd(address(tokenE));
        uint256 ethOut = pm.getAmountOut(_key(address(tokenE), NATIVE), address(tokenE) < NATIVE, 10_000e18);
        assertEq(expected, pools.getAmountOut(WETH_ADDR, IMD_ADDR, ethOut));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,, uint256 net) =
            exit.sellAll(_one(address(tokenE)), _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].imdOut, expected);
        assertEq(imd.balanceOf(user), net);
        assertEq(address(exit).balance, 0);
        assertEq(weth.balanceOf(address(exit)), 0);
    }

    function test_v4ToNativeThenV4NativeImdRoute() public {
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(tokenE), address(tokenV)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold && out[1].status == SwarmExit.Status.Sold);
        assertEq(address(exit).balance, 0);
    }

    function test_bridgeMismatchIsNotSellable() public {
        // The token route ends in a currency the IMD route does not take (and WETH/ETH cannot bridge it).
        _addLiquidity(address(tokenC), address(tokenA), 1_000e18, 1_000e18);
        vm.prank(OWNER);
        exit.setTokenRoute(
            address(tokenC), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenC), address(tokenA))
        );
        assertTrue(exit.preview(user, _one(address(tokenC)))[0].status == SwarmExit.Status.BridgeRouteMissing);
    }

    function test_quoteImdInBridgeReversesV4Route() public {
        uint256 got = exit.quoteImdInBridge(1_000e18);
        assertEq(got, pm.getAmountOut(_key(NATIVE, IMD_ADDR), false, 1_000e18));
        assertGt(got, 0.98e18);
    }

    function test_quoteImdInBridgeReversesMultiHopV4Route() public {
        // ETH -> V -> IMD, reversed must be IMD -> V -> ETH.
        _addV4(NATIVE, address(tokenV), 10e18, 1_000e18);
        SwarmExit.V4Hop[] memory hops = new SwarmExit.V4Hop[](2);
        hops[0] = SwarmExit.V4Hop({currencyOut: address(tokenV), fee: FEE_1PCT, tickSpacing: 200, hooks: address(0)});
        hops[1] = SwarmExit.V4Hop({currencyOut: IMD_ADDR, fee: FEE_1PCT, tickSpacing: 200, hooks: address(0)});
        vm.prank(OWNER);
        exit.setImdRoute(SwarmExit.Venue.UniswapV4, address(pm), address(0), abi.encode(NATIVE, hops));
        uint256 got = exit.quoteImdInBridge(100e18);
        uint256 mid = pm.getAmountOut(_key(IMD_ADDR, address(tokenV)), IMD_ADDR < address(tokenV), 100e18);
        assertEq(got, pm.getAmountOut(_key(address(tokenV), NATIVE), address(tokenV) < NATIVE, mid));
        assertGt(got, 0);
        // and the forward multi-hop sale settles through both pools
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(_one(address(tokenA)), _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(address(exit).balance, 0);
    }

    function test_v4QuoteFailsOnMissingPool() public {
        vm.prank(OWNER);
        exit.setTokenRoute(
            address(tokenV), SwarmExit.Venue.UniswapV4, address(pm), address(0), _v4(address(tokenV), address(tokenC))
        );
        assertTrue(exit.preview(user, _one(address(tokenV)))[0].status == SwarmExit.Status.QuoteFailed);
    }

    function test_v4PartialFillFailsTheSaleAndRefunds() public {
        pm.setPartialFillRealSwaps(true); // the pre-check quote fills, the real swap only half: an unsettled delta
        uint256 before = tokenV.balanceOf(user);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(tokenV), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(tokenV.balanceOf(user), before);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
        assertEq(pm.locker(), address(0));
    }

    function test_unlockCallbackOnlyFromTheManagerInFlight() public {
        vm.expectRevert(SwarmExit.OnlyPoolManager.selector);
        exit.unlockCallback("");
        vm.prank(address(pm));
        vm.expectRevert(SwarmExit.OnlyPoolManager.selector);
        exit.unlockCallback("");
    }

    // ------------------------------------------------------------------ refunds and the on-chain floor

    function test_refundRefusedByTokenIsHeldAndClaimable() public {
        blk.setBlocked(address(pools), true); // the quote works, the swap reverts
        blk.setBlocked(user, true); // and the refund transfer reverts too
        uint256 before = blk.balanceOf(user);
        vm.expectEmit(true, true, false, true);
        emit SwarmExit.RefundHeld(user, address(blk), before);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(blk), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
        assertEq(exit.heldRefunds(user, address(blk)), before);
        assertEq(exit.totalHeld(address(blk)), before);
        assertEq(blk.balanceOf(address(exit)), before);

        vm.prank(user);
        vm.expectRevert("BLK: recipient blocked");
        exit.claimRefund(address(blk));

        // the owner cannot take held refunds, even after unregistering the token
        vm.startPrank(OWNER);
        vm.expectRevert(SwarmExit.CannotRescueSwarmToken.selector);
        exit.rescue(address(blk), OWNER, 1);
        exit.setSwarmToken(address(blk), false);
        vm.expectRevert(SwarmExit.CannotRescueHeldRefunds.selector);
        exit.rescue(address(blk), OWNER, 1);
        vm.stopPrank();

        blk.setBlocked(user, false);
        vm.expectEmit(true, true, false, true);
        emit SwarmExit.RefundClaimed(user, address(blk), before);
        vm.prank(user);
        exit.claimRefund(address(blk));
        assertEq(blk.balanceOf(user), before);
        assertEq(exit.heldRefunds(user, address(blk)), 0);
        assertEq(exit.totalHeld(address(blk)), 0);
        vm.prank(user);
        vm.expectRevert(SwarmExit.NothingToClaim.selector);
        exit.claimRefund(address(blk));
    }

    function test_pullThatRevertsIsASaleFailureNotABatchRevert() public {
        blk.setBlocked(address(exit), true); // transferFrom into SwarmExit reverts
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(blk), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(out[0].amountIn, 0);
        assertEq(blk.balanceOf(user), 1_000e18);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_routeThatPaysNothingIsRefundedNotSettled() public {
        ThiefRouter thief = new ThiefRouter();
        vm.prank(OWNER);
        exit.setTokenRoute(
            address(tokenC), SwarmExit.Venue.UniswapV2, address(thief), address(0), _v2(address(tokenC), IMD_ADDR)
        );
        assertTrue(exit.preview(user, _one(address(tokenC)))[0].sellable, "the quote alone looks fine");
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(tokenC), address(tokenV)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed, "zero proceeds never settle as Sold");
        assertEq(tokenC.balanceOf(user), 1_000e18);
        assertEq(tokenC.balanceOf(address(thief)), 0);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_contractFloorIsEnforcedOnChain() public {
        uint256 expected = _expectedImd(address(tokenC));
        vm.prank(OWNER);
        exit.setMinImdOut(expected + 1);
        vm.prank(user);
        vm.expectRevert(SwarmExit.NothingSold.selector);
        exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        assertEq(tokenC.balanceOf(user), 1_000e18);
        vm.prank(OWNER);
        exit.setMinImdOut(expected);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
    }

    function test_feeOnTransferTokenPaysNoFeeForAPredictableFailure() public {
        pools.setBroken(address(feeTok), WETH_ADDR, true);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(feeTok), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.QuoteFailed);
        assertEq(feeTok.balanceOf(user), 10_000e18, "nothing pulled, nothing burned");
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_honeypotIsStillRefundedOnChain() public {
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(honey), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(honey.balanceOf(user), 10_000e18);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_oneWeiBalanceSellsNothingBelowTheFloor() public {
        address tiny = makeAddr("tiny");
        tokenC.mint(tiny, 1);
        vm.startPrank(tiny);
        tokenC.approve(address(exit), 1);
        vm.expectRevert(SwarmExit.NothingSold.selector);
        exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        vm.stopPrank();
        assertEq(tokenC.balanceOf(tiny), 1);
    }

    // ------------------------------------------------------------------ registry and preview robustness

    function test_registryRefusesAddressesWithoutCode() public {
        address eoa = address(0x1234);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(SwarmExit.NotAContract.selector, eoa));
        exit.setSwarmToken(eoa, true);
    }

    function test_revertingBalanceDoesNotBrickPreviewAll() public {
        RevertingBalanceToken bad = new RevertingBalanceToken();
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(bad), true);
        exit.setTokenRoute(
            address(bad), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(bad), IMD_ADDR)
        );
        vm.stopPrank();
        SwarmExit.Preview[] memory p = exit.previewAll(user);
        assertEq(p.length, 8);
        assertTrue(p[7].status == SwarmExit.Status.QuoteFailed && !p[7].sellable);
        assertTrue(p[1].sellable, "the other entries are still quoted");
        // and sellAll skips it instead of reverting
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(bad), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.ZeroBalance);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_unregisterClearsTheRoute() public {
        vm.startPrank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit SwarmExit.TokenRouteSet(address(tokenA), SwarmExit.Venue.None, address(0), address(0), address(0));
        exit.setSwarmToken(address(tokenA), false);
        assertTrue(exit.tokenRoute(address(tokenA)).venue == SwarmExit.Venue.None);
        exit.setSwarmToken(address(tokenA), true);
        vm.stopPrank();
        assertTrue(exit.preview(user, _one(address(tokenA)))[0].status == SwarmExit.Status.NoRoute);
    }

    function test_priceImpactBoundInPreview() public {
        // thin pool: 1e24 THIN against 0.001 WETH, the user holds the whole supply side.
        MockERC20 thin = new MockERC20("THIN", "THIN");
        _addLiquidity(address(thin), WETH_ADDR, 1e24, 1e15);
        thin.mint(user, 1e24);
        vm.startPrank(OWNER);
        _register(address(thin), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(thin), WETH_ADDR));
        vm.stopPrank();
        SwarmExit.Preview[] memory p = exit.preview(user, _one(address(thin)));
        assertTrue(p[0].status == SwarmExit.Status.ExcessiveImpact && !p[0].sellable);
        assertGt(p[0].expectedImd, 0);
        assertTrue(exit.preview(user, _one(address(tokenC)))[0].sellable, "a healthy pool is unaffected");
        vm.startPrank(OWNER);
        vm.expectRevert(SwarmExit.InvalidBps.selector);
        exit.setMaxImpactBps(10_001);
        exit.setMaxImpactBps(10_000); // disabled
        vm.stopPrank();
        assertTrue(exit.preview(user, _one(address(thin)))[0].sellable);
    }

    function test_rescueEthAndStrayTokens() public {
        vm.deal(address(exit), 1 ether);
        MockERC20 stray = new MockERC20("X", "X");
        stray.mint(address(exit), 5e18);
        vm.startPrank(OWNER);
        exit.rescue(address(0), OWNER, 1 ether);
        exit.rescue(address(stray), OWNER, 5e18);
        vm.expectRevert(SwarmExit.CannotRescueHeldRefunds.selector);
        exit.rescue(address(stray), OWNER, 1);
        vm.stopPrank();
        assertEq(OWNER.balance, 1 ether);
        assertEq(stray.balanceOf(OWNER), 5e18);
    }

    function test_runtimeSizeAndNoForbiddenOpcodes() public view {
        bytes memory code = address(exit).code;
        assertLe(code.length, 24_576);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_v4SaleConservesImdAndLeavesNothingBehind(uint96 amountV, uint96 amountE) public {
        amountV = uint96(bound(amountV, 1e18, 10_000e18));
        amountE = uint96(bound(amountE, 1e18, 100_000e18));
        address fuzzUser = makeAddr("fuzz");
        tokenV.mint(fuzzUser, amountV);
        tokenE.mint(fuzzUser, amountE);
        vm.startPrank(fuzzUser);
        tokenV.approve(address(exit), amountV);
        tokenE.approve(address(exit), amountE);
        (, uint256 gross, uint256 tax, uint256 net) =
            exit.sellAll(_two(address(tokenV), address(tokenE)), _zeros(2), block.timestamp);
        vm.stopPrank();
        assertEq(tax, gross * 200 / 10_000);
        assertEq(net + tax, gross);
        assertEq(imd.balanceOf(fuzzUser), net);
        assertEq(imd.balanceOf(TREASURY), tax);
        assertEq(imd.balanceOf(address(exit)), 0);
        assertEq(address(exit).balance, 0);
        assertEq(tokenV.balanceOf(address(exit)), 0);
        assertEq(tokenE.balanceOf(address(exit)), 0);
    }
}
