// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SwarmExit} from "../src/SwarmExit.sol";
import {DeployScript} from "../script/Deploy.s.sol";
import {MockERC20, FeeOnTransferToken, HoneypotToken, ReentrantToken} from "./mocks/MockTokens.sol";
import {MockPools, MockV2Router, MockV3Router, MockV3Quoter, MockFeed} from "./mocks/MockVenues.sol";

contract SwarmExitTest is Test {
    address constant OWNER = 0x0acE1DBE8AAb293cd58D5e3Ea38814f0ccb74782;
    address constant IMD_ADDR = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant TREASURY = 0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB;
    uint24 constant FEE_1PCT = 10_000;

    SwarmExit exit;
    MockERC20 imd;
    MockERC20 weth;
    MockPools pools;
    MockV2Router v2;
    MockV3Router v3;
    MockV3Quoter quoter;
    MockFeed feed;

    MockERC20 tokenA; // V2 route A -> WETH
    MockERC20 tokenB; // V3 route B -> WETH
    MockERC20 tokenC; // V2 route C -> IMD directly
    HoneypotToken honey; // V2 route, transfers into the pool revert
    MockERC20 noLiq; // V2 route, pool empty
    FeeOnTransferToken feeTok; // V2 route with transfer fee
    MockERC20 stray; // never registered

    address user = makeAddr("user");
    address lp = makeAddr("lp");

    function setUp() public {
        vm.warp(1_760_000_000);
        imd = MockERC20(IMD_ADDR);
        vm.etch(IMD_ADDR, address(new MockERC20("IMD", "IMD")).code);
        weth = new MockERC20("WETH", "WETH");
        pools = new MockPools();
        v2 = new MockV2Router(pools);
        v3 = new MockV3Router(pools);
        quoter = new MockV3Quoter(pools, v3);
        feed = new MockFeed();

        exit = new SwarmExit(OWNER);

        tokenA = new MockERC20("A", "A");
        tokenB = new MockERC20("B", "B");
        tokenC = new MockERC20("C", "C");
        honey = new HoneypotToken();
        noLiq = new MockERC20("N", "N");
        feeTok = new FeeOnTransferToken(500);
        stray = new MockERC20("X", "X");

        // Liquidity: 1 WETH = 1000 IMD; 1 A = 0.001 WETH; 1 B = 0.002 WETH; 1 C = 2 IMD; honey like A.
        _addLiquidity(address(weth), IMD_ADDR, 100e18, 100_000e18);
        _addLiquidity(address(tokenA), address(weth), 1_000_000e18, 1000e18);
        _addLiquidity(address(tokenB), address(weth), 500_000e18, 1000e18);
        _addLiquidity(address(tokenC), IMD_ADDR, 50_000e18, 100_000e18);
        _addLiquidity(address(honey), address(weth), 1_000_000e18, 1000e18);
        _addLiquidity(address(feeTok), address(weth), 1_000_000e18, 1000e18);
        honey.setBlocked(address(pools), true);

        vm.startPrank(OWNER);
        exit.setSwarmToken(address(tokenA), true);
        exit.setSwarmToken(address(tokenB), true);
        exit.setSwarmToken(address(tokenC), true);
        exit.setSwarmToken(address(honey), true);
        exit.setSwarmToken(address(noLiq), true);
        exit.setSwarmToken(address(feeTok), true);
        exit.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenA), address(weth))
        );
        exit.setTokenRoute(
            address(tokenB),
            SwarmExit.Venue.UniswapV3,
            address(v3),
            address(quoter),
            _v3(address(tokenB), address(weth))
        );
        exit.setTokenRoute(
            address(tokenC), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenC), IMD_ADDR)
        );
        exit.setTokenRoute(
            address(honey), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(honey), address(weth))
        );
        exit.setTokenRoute(
            address(noLiq), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(noLiq), address(weth))
        );
        exit.setTokenRoute(
            address(feeTok), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(feeTok), address(weth))
        );
        exit.setImdRoute(SwarmExit.Venue.UniswapV3, address(v3), address(quoter), _v3(address(weth), IMD_ADDR));
        exit.setEthUsdFeed(address(feed));
        vm.stopPrank();
        feed.set(3000e8, block.timestamp);

        tokenA.mint(user, 10_000e18);
        tokenB.mint(user, 5_000e18);
        tokenC.mint(user, 1_000e18);
        honey.mint(user, 10_000e18);
        noLiq.mint(user, 10_000e18);
        feeTok.mint(user, 10_000e18);
    }

    // ------------------------------------------------------------------ helpers

    function _addLiquidity(address a, address b, uint256 amtA, uint256 amtB) internal {
        MockERC20(a).mint(lp, amtA);
        MockERC20(b).mint(lp, amtB);
        vm.startPrank(lp);
        IERC20(a).approve(address(pools), amtA);
        IERC20(b).approve(address(pools), amtB);
        pools.addLiquidity(a, b, amtA, amtB);
        vm.stopPrank();
    }

    function _v2(address a, address b) internal pure returns (bytes memory) {
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        return abi.encode(path);
    }

    function _v3(address a, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, FEE_1PCT, b);
    }

    function _approveAll(address[] memory tokens) internal {
        vm.startPrank(user);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20(tokens[i]).approve(address(exit), IERC20(tokens[i]).balanceOf(user));
        }
        vm.stopPrank();
    }

    function _one(address t) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = t;
    }

    function _zeros(uint256 n) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](n);
    }

    function _expectedImd(address token) internal returns (uint256) {
        SwarmExit.Preview[] memory p = exit.preview(user, _one(token));
        return p[0].expectedImd;
    }

    // ------------------------------------------------------------------ deployment and ownership

    function test_constructorSetsOwnerNotDeployer() public {
        SwarmExit fresh = new SwarmExit(OWNER);
        assertEq(fresh.owner(), OWNER);
        assertTrue(fresh.owner() != address(this));
        assertEq(address(fresh.IMD()), IMD_ADDR);
        assertEq(fresh.TREASURY(), TREASURY);
        assertEq(fresh.SELL_TAX_BPS(), 200);
        assertEq(fresh.minImdOut(), fresh.DEFAULT_MIN_IMD_OUT());
    }

    function test_deployScriptFunctionUsesGivenOwner() public {
        DeployScript script = new DeployScript();
        SwarmExit deployed = script.deploy(OWNER);
        assertEq(deployed.owner(), OWNER);
        assertEq(script.OWNER(), OWNER);
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

    function test_twoStepOwnership() public {
        address next = makeAddr("next");
        vm.prank(OWNER);
        exit.transferOwnership(next);
        assertEq(exit.owner(), OWNER);
        vm.prank(next);
        exit.acceptOwnership();
        assertEq(exit.owner(), next);
    }

    function test_ownerOnlyFunctionsRejectOthers() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        exit.setSwarmToken(address(stray), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        exit.setTokenRoute(address(tokenA), SwarmExit.Venue.None, address(0), address(0), "");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        exit.setImdRoute(SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(weth), IMD_ADDR));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        exit.setEthUsdFeed(address(feed));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        exit.setMinImdOut(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        exit.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        exit.rescue(address(stray), user, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ registry and routes

    function test_registryAddRemove() public {
        assertEq(exit.swarmTokenCount(), 6);
        vm.startPrank(OWNER);
        vm.expectEmit(true, false, false, true);
        emit SwarmExit.SwarmTokenSet(address(stray), true);
        exit.setSwarmToken(address(stray), true);
        assertEq(exit.swarmTokenCount(), 7);
        exit.setSwarmToken(address(stray), true); // idempotent
        assertEq(exit.swarmTokenCount(), 7);
        exit.setSwarmToken(address(tokenA), false);
        assertEq(exit.swarmTokenCount(), 6);
        assertFalse(exit.isSwarmToken(address(tokenA)));
        address[] memory list = exit.swarmTokens();
        for (uint256 i; i < list.length; ++i) {
            assertTrue(list[i] != address(tokenA));
        }
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.setSwarmToken(address(0), true);
        vm.stopPrank();
    }

    function test_setTokenRouteValidation() public {
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(SwarmExit.NotSwarmToken.selector, address(stray)));
        exit.setTokenRoute(
            address(stray), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(stray), address(weth))
        );
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenB), address(weth))
        );
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenA), address(tokenA))
        );
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV2, address(0), address(0), _v2(address(tokenA), address(weth))
        );
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV3, address(v3), address(0), _v3(address(tokenA), address(weth))
        );
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(address(tokenA), SwarmExit.Venue.UniswapV3, address(v3), address(quoter), hex"0011");
        address[] memory short = new address[](1);
        short[0] = address(tokenA);
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), abi.encode(short));
        // clearing a route
        exit.setTokenRoute(address(tokenA), SwarmExit.Venue.None, address(0), address(0), "");
        assertTrue(exit.tokenRoute(address(tokenA)).venue == SwarmExit.Venue.None);
        vm.stopPrank();
    }

    function test_setImdRouteValidation() public {
        vm.startPrank(OWNER);
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setImdRoute(SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(weth), address(tokenA)));
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setImdRoute(SwarmExit.Venue.None, address(v2), address(0), "");
        exit.setImdRoute(SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(weth), IMD_ADDR));
        SwarmExit.Route memory r = exit.imdRoute();
        assertEq(r.tokenIn, address(weth));
        assertEq(r.tokenOut, IMD_ADDR);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ preview

    function test_previewStatuses() public {
        address[] memory tokens = new address[](7);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(tokenC);
        tokens[3] = address(honey);
        tokens[4] = address(noLiq);
        tokens[5] = address(stray);
        tokens[6] = address(feeTok);
        SwarmExit.Preview[] memory p = exit.preview(user, tokens);
        assertTrue(p[0].sellable && p[0].status == SwarmExit.Status.Sold);
        assertTrue(p[1].sellable);
        assertTrue(p[2].sellable);
        assertTrue(p[3].sellable, "honeypot looks sellable from quotes alone");
        assertFalse(p[4].sellable);
        assertTrue(p[4].status == SwarmExit.Status.QuoteFailed);
        assertFalse(p[5].sellable);
        assertTrue(p[5].status == SwarmExit.Status.NotRegistered);
        assertTrue(p[6].sellable);
        assertEq(p[0].balance, 10_000e18);
        // A: 10_000 A -> ~9.9 WETH -> ~8_960 IMD after price impact on both legs
        assertGt(p[0].expectedImd, 8_000e18);
        assertLt(p[0].expectedImd, 10_000e18);
        // C: 1_000 C -> ~1_950 IMD direct
        assertGt(p[2].expectedImd, 1_900e18);

        // zero balance
        SwarmExit.Preview[] memory q = exit.preview(makeAddr("nobody"), _one(address(tokenA)));
        assertTrue(q[0].status == SwarmExit.Status.ZeroBalance);

        // no route
        vm.prank(OWNER);
        exit.setSwarmToken(address(stray), true);
        q = exit.preview(user, _one(address(stray)));
        assertTrue(q[0].status == SwarmExit.Status.NoRoute);

        // below minimum
        vm.prank(OWNER);
        exit.setMinImdOut(type(uint256).max);
        q = exit.preview(user, _one(address(tokenA)));
        assertTrue(q[0].status == SwarmExit.Status.BelowMinimum && !q[0].sellable);
        assertGt(q[0].expectedImd, 0);
    }

    function test_previewAllCoversRegistry() public {
        SwarmExit.Preview[] memory p = exit.previewAll(user);
        assertEq(p.length, 6);
        assertEq(p[0].token, address(tokenA));
    }

    function test_previewBridgeRouteMissing() public {
        SwarmExit fresh = new SwarmExit(OWNER);
        vm.startPrank(OWNER);
        fresh.setSwarmToken(address(tokenA), true);
        fresh.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenA), address(weth))
        );
        vm.stopPrank();
        SwarmExit.Preview[] memory p = fresh.preview(user, _one(address(tokenA)));
        assertTrue(p[0].status == SwarmExit.Status.BridgeRouteMissing);
        assertFalse(p[0].sellable);
    }

    // ------------------------------------------------------------------ selling: success

    function test_sellAllHappyPathSplitsTax() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        tokens[2] = address(tokenC);
        uint256 expA = _expectedImd(address(tokenA));
        _approveAll(tokens);
        uint256[] memory mins = new uint256[](3);
        mins[0] = (expA * 99) / 100;

        vm.prank(user);
        (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
            exit.sellAll(tokens, mins, block.timestamp + 60);

        assertEq(out.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertTrue(out[i].status == SwarmExit.Status.Sold);
            assertGt(out[i].imdOut, 0);
        }
        assertEq(out[0].imdOut, expA, "quote matches execution for the first sale");
        assertEq(gross, out[0].imdOut + out[1].imdOut + out[2].imdOut);
        assertEq(tax, gross * 200 / 10_000);
        assertEq(net, gross - tax);
        assertEq(imd.balanceOf(user), net);
        assertEq(imd.balanceOf(TREASURY), tax);
        assertEq(imd.balanceOf(address(exit)), 0);
        assertEq(tokenA.balanceOf(user), 0);
        assertEq(tokenB.balanceOf(user), 0);
        assertEq(tokenC.balanceOf(user), 0);
        assertEq(tokenA.balanceOf(address(exit)), 0);
        assertEq(weth.balanceOf(address(exit)), 0);
        assertEq(tokenA.allowance(address(exit), address(v2)), 0);
        assertEq(weth.allowance(address(exit), address(v3)), 0);
    }

    function test_sellAllEmitsEvents() public {
        address[] memory tokens = _one(address(tokenC));
        uint256 exp = _expectedImd(address(tokenC));
        _approveAll(tokens);
        vm.expectEmit(true, true, false, true);
        emit SwarmExit.TokenSold(user, address(tokenC), 1_000e18, exp);
        vm.expectEmit(true, false, false, true);
        emit SwarmExit.SoldAll(user, exp, exp * 200 / 10_000, exp - exp * 200 / 10_000);
        vm.prank(user);
        exit.sellAll(tokens, _zeros(1), block.timestamp);
    }

    function test_feeOnTransferTokenSellsMeasuredAmount() public {
        address[] memory tokens = _one(address(feeTok));
        _approveAll(tokens);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(tokens, _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].amountIn, 9_500e18, "5% burned on the way in");
        assertEq(feeTok.balanceOf(address(exit)), 0);
        assertGt(imd.balanceOf(user), 0);
    }

    function test_zeroBalanceTokenIsSkippedNotPulled() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenC);
        _approveAll(tokens);
        uint256 cBalance = tokenC.balanceOf(user);
        vm.prank(user);
        tokenC.transfer(lp, cBalance);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(tokens, _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertTrue(out[1].status == SwarmExit.Status.ZeroBalance);
        assertEq(out[1].amountIn, 0);
    }

    // ------------------------------------------------------------------ selling: failure and refunds

    function test_honeypotIsRefundedOthersSell() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA);
        tokens[1] = address(honey);
        tokens[2] = address(tokenB);
        _approveAll(tokens);
        uint256 honeyBefore = honey.balanceOf(user);

        vm.expectEmit(true, true, false, false);
        emit SwarmExit.TokenRefunded(user, address(honey), honeyBefore, "");
        vm.prank(user);
        (SwarmExit.Outcome[] memory out, uint256 gross,,) = exit.sellAll(tokens, _zeros(3), block.timestamp);

        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertTrue(out[1].status == SwarmExit.Status.SaleFailed);
        assertEq(out[1].amountIn, honeyBefore);
        assertEq(out[1].imdOut, 0);
        assertTrue(out[2].status == SwarmExit.Status.Sold);
        assertEq(honey.balanceOf(user), honeyBefore, "honeypot refunded in full");
        assertEq(honey.balanceOf(address(exit)), 0);
        assertEq(honey.allowance(address(exit), address(v2)), 0);
        assertEq(gross, out[0].imdOut + out[2].imdOut);
        assertEq(imd.balanceOf(user) + imd.balanceOf(TREASURY), gross);
    }

    function test_noLiquidityTokenIsRefunded() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(noLiq);
        tokens[1] = address(tokenC);
        _approveAll(tokens);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(tokens, _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(noLiq.balanceOf(user), 10_000e18);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_slippageBreachRefundsThatTokenOnly() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenC);
        _approveAll(tokens);
        uint256[] memory mins = new uint256[](2);
        mins[0] = _expectedImd(address(tokenA)) + 1;
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(tokens, mins, block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(tokenA.balanceOf(user), 10_000e18);
        assertEq(weth.balanceOf(address(exit)), 0, "first leg was rolled back with the second");
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_bridgeRouteMissingRefunds() public {
        SwarmExit fresh = new SwarmExit(OWNER);
        vm.startPrank(OWNER);
        fresh.setSwarmToken(address(tokenA), true);
        fresh.setSwarmToken(address(tokenC), true);
        fresh.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenA), address(weth))
        );
        fresh.setTokenRoute(
            address(tokenC), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenC), IMD_ADDR)
        );
        vm.stopPrank();
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenC);
        vm.startPrank(user);
        tokenA.approve(address(fresh), type(uint256).max);
        tokenC.approve(address(fresh), type(uint256).max);
        (SwarmExit.Outcome[] memory out,,,) = fresh.sellAll(tokens, _zeros(2), block.timestamp);
        vm.stopPrank();
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(tokenA.balanceOf(user), 10_000e18);
        assertTrue(out[1].status == SwarmExit.Status.Sold, "direct-to-IMD route needs no bridge");
    }

    function test_nothingSoldReverts() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(honey);
        tokens[1] = address(noLiq);
        _approveAll(tokens);
        vm.prank(user);
        vm.expectRevert(SwarmExit.NothingSold.selector);
        exit.sellAll(tokens, _zeros(2), block.timestamp);
        assertEq(honey.balanceOf(user), 10_000e18);
        assertEq(noLiq.balanceOf(user), 10_000e18);
    }

    function test_noRouteTokenIsSkippedWithoutPull() public {
        vm.prank(OWNER);
        exit.setTokenRoute(address(tokenA), SwarmExit.Venue.None, address(0), address(0), "");
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenC);
        _approveAll(tokens);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(tokens, _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.NoRoute);
        assertEq(tokenA.balanceOf(user), 10_000e18);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_inputValidation() public {
        address[] memory tokens = _one(address(tokenA));
        _approveAll(tokens);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(SwarmExit.NotSwarmToken.selector, address(stray)));
        exit.sellAll(_one(address(stray)), _zeros(1), block.timestamp);
        vm.expectRevert(SwarmExit.Expired.selector);
        exit.sellAll(tokens, _zeros(1), block.timestamp - 1);
        vm.expectRevert(SwarmExit.LengthMismatch.selector);
        exit.sellAll(tokens, _zeros(2), block.timestamp);
        vm.expectRevert(SwarmExit.TooManyTokens.selector);
        exit.sellAll(new address[](0), _zeros(0), block.timestamp);
        vm.expectRevert(SwarmExit.TooManyTokens.selector);
        exit.sellAll(new address[](51), _zeros(51), block.timestamp);
        address[] memory dup = new address[](2);
        dup[0] = address(tokenA);
        dup[1] = address(tokenA);
        vm.expectRevert(abi.encodeWithSelector(SwarmExit.DuplicateToken.selector, address(tokenA)));
        exit.sellAll(dup, _zeros(2), block.timestamp);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(user), 10_000e18);
    }

    function test_missingApprovalRevertsWholeCall() public {
        vm.prank(user);
        vm.expectRevert();
        exit.sellAll(_one(address(tokenA)), _zeros(1), block.timestamp);
    }

    function test_pauseBlocksSelling() public {
        address[] memory tokens = _one(address(tokenA));
        _approveAll(tokens);
        vm.prank(OWNER);
        exit.pause();
        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        exit.sellAll(tokens, _zeros(1), block.timestamp);
        // previews still work while paused
        assertTrue(exit.preview(user, tokens)[0].sellable);
        vm.prank(OWNER);
        exit.unpause();
        vm.prank(user);
        exit.sellAll(tokens, _zeros(1), block.timestamp);
        assertEq(tokenA.balanceOf(user), 0);
    }

    function test_executeSaleOnlySelf() public {
        vm.expectRevert(SwarmExit.OnlySelf.selector);
        exit.executeSale(address(tokenA), 1, 0, block.timestamp);
    }

    function test_reentrancyFromTokenIsBlocked() public {
        ReentrantToken re = new ReentrantToken();
        re.setTarget(address(exit));
        _addLiquidity(address(re), address(weth), 1_000_000e18, 1000e18);
        re.mint(user, 1_000e18);
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(re), true);
        exit.setTokenRoute(
            address(re), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(re), address(weth))
        );
        vm.stopPrank();
        address[] memory tokens = _one(address(re));
        _approveAll(tokens);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(tokens, _zeros(1), block.timestamp);
        assertTrue(re.attempted());
        assertFalse(re.reentered(), "nested sellAll must fail");
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(re.balanceOf(address(exit)), 0);
    }

    // ------------------------------------------------------------------ pricing

    function test_ethUsdPriceChecks() public {
        (uint256 price, uint8 dec) = exit.ethUsdPrice();
        assertEq(price, 3000e8);
        assertEq(dec, 8);
        feed.set(3000e8, block.timestamp - 3 hours - 1);
        vm.expectRevert(SwarmExit.StalePrice.selector);
        exit.ethUsdPrice();
        feed.set(0, block.timestamp);
        vm.expectRevert(SwarmExit.InvalidPrice.selector);
        exit.ethUsdPrice();
        SwarmExit fresh = new SwarmExit(OWNER);
        vm.expectRevert(abi.encodeWithSelector(SwarmExit.NotConfigured.selector, "ethUsdFeed"));
        fresh.ethUsdPrice();
    }

    function test_quoteImdInBridgeReversesV3Route() public {
        uint256 got = exit.quoteImdInBridge(1_000e18);
        assertEq(got, pools.getAmountOut(IMD_ADDR, address(weth), 1_000e18));
        assertGt(got, 0.98e18);
    }

    function test_quoteImdInBridgeReversesV2Route() public {
        vm.prank(OWNER);
        exit.setImdRoute(SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(weth), IMD_ADDR));
        uint256 got = exit.quoteImdInBridge(1_000e18);
        assertEq(got, pools.getAmountOut(IMD_ADDR, address(weth), 1_000e18));
    }

    function test_quoteImdInBridgeReversesMultiHopV3Route() public {
        // WETH -> C -> IMD, reversed must be IMD -> C -> WETH
        _addLiquidity(address(weth), address(tokenC), 10e18, 1000e18);
        bytes memory path = abi.encodePacked(address(weth), FEE_1PCT, address(tokenC), uint24(3000), IMD_ADDR);
        vm.prank(OWNER);
        exit.setImdRoute(SwarmExit.Venue.UniswapV3, address(v3), address(quoter), path);
        uint256 got = exit.quoteImdInBridge(100e18);
        uint256 mid = pools.getAmountOut(IMD_ADDR, address(tokenC), 100e18);
        assertEq(got, pools.getAmountOut(address(tokenC), address(weth), mid));
    }

    function test_quoteImdInBridgeNotConfigured() public {
        SwarmExit fresh = new SwarmExit(OWNER);
        vm.expectRevert(abi.encodeWithSelector(SwarmExit.NotConfigured.selector, "imdRoute"));
        fresh.quoteImdInBridge(1e18);
    }

    // ------------------------------------------------------------------ rescue

    function test_rescueOnlyNonSwarmTokens() public {
        stray.mint(address(exit), 5e18);
        vm.startPrank(OWNER);
        vm.expectRevert(SwarmExit.CannotRescueSwarmToken.selector);
        exit.rescue(address(tokenA), OWNER, 1);
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.rescue(address(stray), address(0), 1);
        exit.rescue(address(stray), OWNER, 5e18);
        vm.stopPrank();
        assertEq(stray.balanceOf(OWNER), 5e18);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_taxSplitConservesImd(uint96 amountA, uint96 amountC) public {
        amountA = uint96(bound(amountA, 1e18, 100_000e18));
        amountC = uint96(bound(amountC, 1e18, 10_000e18));
        address fuzzUser = makeAddr("fuzz");
        tokenA.mint(fuzzUser, amountA);
        tokenC.mint(fuzzUser, amountC);
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenC);
        vm.startPrank(fuzzUser);
        tokenA.approve(address(exit), amountA);
        tokenC.approve(address(exit), amountC);
        (, uint256 gross, uint256 tax, uint256 net) = exit.sellAll(tokens, _zeros(2), block.timestamp);
        vm.stopPrank();
        assertEq(tax, gross * 200 / 10_000);
        assertEq(net + tax, gross);
        assertEq(imd.balanceOf(fuzzUser), net);
        assertEq(imd.balanceOf(TREASURY), tax);
        assertEq(imd.balanceOf(address(exit)), 0);
        assertEq(tokenA.balanceOf(address(exit)), 0);
        assertEq(weth.balanceOf(address(exit)), 0);
    }

    function testFuzz_slippageGuardNeverSettlesBelowMin(uint96 amount, uint256 minOut) public {
        amount = uint96(bound(amount, 1e18, 100_000e18));
        address fuzzUser = makeAddr("fuzz2");
        tokenC.mint(fuzzUser, amount);
        uint256 expected = exit.preview(fuzzUser, _one(address(tokenC)))[0].expectedImd;
        minOut = bound(minOut, 0, expected * 2);
        vm.startPrank(fuzzUser);
        tokenC.approve(address(exit), amount);
        uint256[] memory mins = new uint256[](1);
        mins[0] = minOut;
        if (minOut > expected) {
            vm.expectRevert(SwarmExit.NothingSold.selector);
            exit.sellAll(_one(address(tokenC)), mins, block.timestamp);
            assertEq(tokenC.balanceOf(fuzzUser), amount);
        } else {
            (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(_one(address(tokenC)), mins, block.timestamp);
            assertEq(out[0].imdOut, expected);
            assertGe(out[0].imdOut, minOut);
        }
        vm.stopPrank();
    }
}
