// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SwarmExit} from "../src/SwarmExit.sol";
import {SwarmExitFixture} from "./SwarmExitFixture.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {
    ApproveBlockingToken,
    RefundBlockingToken,
    OverReportingToken,
    AllBurnToken,
    GasBurnToken,
    RevertingFeed
} from "./mocks/EdgeMocks.sol";

/// @notice Adversarial edge cases for SwarmExit: inputs the happy-path suite did not consider.
/// Where a token misbehaves in a way the contract cannot recover from, the property asserted is
/// the one that must hold either way: the user never loses tokens to the exit contract.
/// forge-config: default.fuzz.runs = 512
contract SwarmExitEdgesTest is SwarmExitFixture {
    function setUp() public {
        _deployFixture();
    }

    // ------------------------------------------------------------------ ownership edges

    function test_acceptOwnershipByStrangerReverts() public {
        address next = makeAddr("next");
        vm.prank(OWNER);
        exit.transferOwnership(next);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        exit.acceptOwnership();
        assertEq(exit.owner(), OWNER);
        assertEq(exit.pendingOwner(), next);
    }

    function test_transferOwnershipToZeroOnlyCancelsPending() public {
        address next = makeAddr("next");
        vm.startPrank(OWNER);
        exit.transferOwnership(next);
        exit.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(exit.pendingOwner(), address(0));
        assertEq(exit.owner(), OWNER, "owner is never zeroed by the two-step handover");
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        exit.acceptOwnership();
    }

    function test_pendingOwnerCannotConfigureBeforeAccepting() public {
        address next = makeAddr("next");
        vm.prank(OWNER);
        exit.transferOwnership(next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        exit.pause();
    }

    function test_unpauseAndRescueAndAcceptAreOwnerGated() public {
        vm.prank(OWNER);
        exit.pause();
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        exit.unpause();
        vm.prank(OWNER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        exit.pause();
        vm.prank(OWNER);
        exit.unpause();
        vm.prank(OWNER);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        exit.unpause();
    }

    // ------------------------------------------------------------------ registry edges

    function test_unregisteredTokenCannotBeSoldEvenWithRouteLeft() public {
        vm.prank(OWNER);
        exit.setSwarmToken(address(tokenA), false);
        _approveAll(user, _one(address(tokenA)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(SwarmExit.NotSwarmToken.selector, address(tokenA)));
        exit.sellAll(_one(address(tokenA)), _zeros(1), block.timestamp);
        SwarmExit.Preview[] memory p = exit.preview(user, _one(address(tokenA)));
        assertTrue(p[0].status == SwarmExit.Status.NotRegistered);
        assertFalse(p[0].sellable);
        assertEq(tokenA.balanceOf(user), 10_000e18);
    }

    function test_registryRemoveFirstMiddleLastAndMissing() public {
        address[] memory before = exit.swarmTokens();
        assertEq(before.length, 6);
        vm.startPrank(OWNER);
        exit.setSwarmToken(before[0], false);
        exit.setSwarmToken(before[3], false);
        exit.setSwarmToken(before[5], false);
        exit.setSwarmToken(address(stray), false); // never registered: no-op
        vm.stopPrank();
        address[] memory after_ = exit.swarmTokens();
        assertEq(after_.length, 3);
        for (uint256 i; i < after_.length; ++i) {
            assertTrue(exit.isSwarmToken(after_[i]));
            assertTrue(after_[i] != before[0] && after_[i] != before[3] && after_[i] != before[5]);
            for (uint256 j; j < i; ++j) {
                assertTrue(after_[i] != after_[j], "no duplicates after swap-remove");
            }
        }
        // previewAll follows the registry
        assertEq(exit.previewAll(user).length, 3);
    }

    function test_setTokenRouteOnUnregisteredAfterRemovalReverts() public {
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(tokenA), false);
        vm.expectRevert(abi.encodeWithSelector(SwarmExit.NotSwarmToken.selector, address(tokenA)));
        exit.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(tokenA), address(weth))
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ route validation edges

    function test_v3PathLengthBoundaries() public {
        vm.startPrank(OWNER);
        // 43 bytes: exactly one hop, valid
        exit.setTokenRoute(
            address(tokenA),
            SwarmExit.Venue.UniswapV3,
            address(v3),
            address(quoter),
            _v3(address(tokenA), address(weth))
        );
        assertEq(exit.tokenRoute(address(tokenA)).tokenOut, address(weth));
        // 66 bytes: two hops, valid
        bytes memory two = abi.encodePacked(address(tokenA), FEE_1PCT, address(tokenB), FEE_1PCT, address(weth));
        exit.setTokenRoute(address(tokenA), SwarmExit.Venue.UniswapV3, address(v3), address(quoter), two);
        assertEq(exit.tokenRoute(address(tokenA)).tokenOut, address(weth));
        // 42 and 44 bytes: invalid
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV3, address(v3), address(quoter), abi.encodePacked(two, hex"00")
        );
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(address(tokenA), SwarmExit.Venue.UniswapV3, address(v3), address(quoter), new bytes(42));
        // 20 bytes only (no hop)
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV3, address(v3), address(quoter), abi.encodePacked(address(tokenA))
        );
        // zero tokenOut in a V3 path
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.setTokenRoute(
            address(tokenA), SwarmExit.Venue.UniswapV3, address(v3), address(quoter), _v3(address(tokenA), address(0))
        );
        // zero element inside a V2 path
        address[] memory p = new address[](3);
        p[0] = address(tokenA);
        p[1] = address(0);
        p[2] = address(weth);
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.setTokenRoute(address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), abi.encode(p));
        // V2 route with garbage data: abi.decode reverts
        vm.expectRevert();
        exit.setTokenRoute(address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), hex"deadbeef");
        vm.stopPrank();
    }

    function testFuzz_v3PathLengthRule(uint16 len) public {
        len = uint16(bound(len, 0, 300));
        bytes memory data = new bytes(len);
        // non-zero first and last 20 bytes so only the length rule can reject
        for (uint256 i; i < len; ++i) {
            data[i] = 0x11;
        }
        bool valid = len >= 43 && (len - 20) % 23 == 0;
        vm.prank(OWNER);
        if (!valid) {
            vm.expectRevert(SwarmExit.InvalidRoute.selector);
            exit.setImdRoute(SwarmExit.Venue.UniswapV3, address(v3), address(quoter), data);
        } else {
            // tokenOut must be IMD for the IMD route, so overwrite the tail
            bytes memory tail = abi.encodePacked(IMD_ADDR);
            for (uint256 i; i < 20; ++i) {
                data[len - 20 + i] = tail[i];
            }
            exit.setImdRoute(SwarmExit.Venue.UniswapV3, address(v3), address(quoter), data);
            assertEq(exit.imdRoute().tokenOut, IMD_ADDR);
        }
    }

    function test_setImdRouteZeroRouterOrQuoterReverts() public {
        vm.startPrank(OWNER);
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.setImdRoute(SwarmExit.Venue.UniswapV2, address(0), address(0), _v2(address(weth), IMD_ADDR));
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.setImdRoute(SwarmExit.Venue.UniswapV3, address(v3), address(0), _v3(address(weth), IMD_ADDR));
        // IMD -> IMD is rejected
        vm.expectRevert(SwarmExit.InvalidRoute.selector);
        exit.setImdRoute(SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(IMD_ADDR, IMD_ADDR));
        vm.stopPrank();
    }

    function test_setTokenRouteV3QuoterIsStored() public {
        vm.prank(OWNER);
        exit.setTokenRoute(
            address(tokenA),
            SwarmExit.Venue.UniswapV3,
            address(v3),
            address(quoter),
            _v3(address(tokenA), address(weth))
        );
        SwarmExit.Route memory r = exit.tokenRoute(address(tokenA));
        assertEq(r.quoter, address(quoter));
        assertEq(r.router, address(v3));
        assertTrue(r.venue == SwarmExit.Venue.UniswapV3);
    }

    // ------------------------------------------------------------------ multi-hop routes

    function test_multiHopV2RouteDirectToImdNeedsNoBridgeRoute() public {
        SwarmExit fresh = new SwarmExit(OWNER);
        address[] memory path = new address[](3);
        path[0] = address(tokenA);
        path[1] = address(weth);
        path[2] = IMD_ADDR;
        vm.startPrank(OWNER);
        fresh.setSwarmToken(address(tokenA), true);
        fresh.setTokenRoute(address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), address(0), abi.encode(path));
        vm.stopPrank();
        SwarmExit.Preview[] memory p = fresh.preview(user, _one(address(tokenA)));
        assertTrue(p[0].sellable, "a route ending in IMD needs no bridge route");
        vm.startPrank(user);
        tokenA.approve(address(fresh), type(uint256).max);
        (SwarmExit.Outcome[] memory out, uint256 gross,,) =
            fresh.sellAll(_one(address(tokenA)), _zeros(1), block.timestamp);
        vm.stopPrank();
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].imdOut, p[0].expectedImd);
        assertEq(gross, out[0].imdOut);
        assertEq(weth.balanceOf(address(fresh)), 0);
        assertEq(imd.balanceOf(address(fresh)), 0);
        assertEq(tokenA.balanceOf(address(fresh)), 0);
    }

    function test_multiHopV3RouteToImdSells() public {
        bytes memory path = abi.encodePacked(address(tokenB), FEE_1PCT, address(weth), FEE_1PCT, IMD_ADDR);
        vm.prank(OWNER);
        exit.setTokenRoute(address(tokenB), SwarmExit.Venue.UniswapV3, address(v3), address(quoter), path);
        uint256 expected = _expectedImd(user, address(tokenB));
        _approveAll(user, _one(address(tokenB)));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(_one(address(tokenB)), _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].imdOut, expected);
        assertEq(weth.balanceOf(address(exit)), 0);
    }

    function test_routeEndingInAnotherSwarmTokenIsRefunded() public {
        // D -> A; A is a swarm token but not the bridge token, so the second leg cannot run.
        MockERC20 d = new MockERC20("D", "D");
        _addLiquidity(address(d), address(tokenA), 1_000e18, 1_000e18);
        d.mint(user, 100e18);
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(d), true);
        exit.setTokenRoute(
            address(d), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(d), address(tokenA))
        );
        vm.stopPrank();
        SwarmExit.Preview[] memory p = exit.preview(user, _one(address(d)));
        assertTrue(p[0].status == SwarmExit.Status.BridgeRouteMissing);
        _approveAll(user, _two(address(d), address(tokenC)));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(d), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(d.balanceOf(user), 100e18, "refunded in full");
        assertEq(tokenA.balanceOf(address(exit)), 0, "first leg rolled back");
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_imdRegisteredAsSwarmTokenIsRefundedNotLost() public {
        // Owner misconfiguration: IMD itself registered with a route IMD -> WETH.
        imd.mint(user, 1_000e18);
        vm.startPrank(OWNER);
        exit.setSwarmToken(IMD_ADDR, true);
        exit.setTokenRoute(IMD_ADDR, SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(IMD_ADDR, address(weth)));
        vm.stopPrank();
        _approveAll(user, _two(IMD_ADDR, address(tokenC)));
        uint256 imdBefore = imd.balanceOf(user);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,, uint256 tax, uint256 net) =
            exit.sellAll(_two(IMD_ADDR, address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed, "IMD round trip cannot be settled");
        assertTrue(out[1].status == SwarmExit.Status.Sold);
        assertEq(imd.balanceOf(user), imdBefore + net, "IMD refunded plus proceeds of C");
        assertEq(imd.balanceOf(TREASURY), tax);
        assertEq(imd.balanceOf(address(exit)), 0);
    }

    function test_bridgeTokenRegisteredAsSwarmTokenSellsDirectly() public {
        weth.mint(user, 2e18);
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(weth), true);
        exit.setTokenRoute(
            address(weth), SwarmExit.Venue.UniswapV3, address(v3), address(quoter), _v3(address(weth), IMD_ADDR)
        );
        vm.stopPrank();
        uint256 expected = _expectedImd(user, address(weth));
        _approveAll(user, _one(address(weth)));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(_one(address(weth)), _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].imdOut, expected);
        assertEq(weth.balanceOf(address(exit)), 0);
    }

    // ------------------------------------------------------------------ amounts at the edges

    function test_oneWeiBalanceSellsWithZeroTax() public {
        address tiny = makeAddr("tiny");
        tokenC.mint(tiny, 1);
        _approveAll(tiny, _one(address(tokenC)));
        vm.prank(tiny);
        (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
            exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].amountIn, 1);
        assertEq(gross, 1, "1 wei of C fetches 1 wei of IMD at this price");
        assertEq(tax, 0, "2% of 1 wei rounds down to nothing");
        assertEq(net, 1);
        assertEq(imd.balanceOf(tiny), 1);
        assertEq(imd.balanceOf(TREASURY), 0);
        assertEq(tokenC.balanceOf(tiny), 0);
    }

    function testFuzz_taxRoundsDownAndNeverExceedsTwoPercent(uint96 amount) public {
        amount = uint96(bound(amount, 1, 10_000e18));
        address who = makeAddr("fuzzTax");
        tokenC.mint(who, amount);
        _approveAll(who, _one(address(tokenC)));
        uint256 expected = _expectedImd(who, address(tokenC));
        vm.prank(who);
        (, uint256 gross, uint256 tax, uint256 net) = exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        assertEq(gross, expected);
        assertEq(tax, gross * 200 / 10_000);
        assertLe(tax * 10_000, gross * 200, "tax never exceeds 2% of gross");
        assertGt((tax + 1) * 10_000, gross * 200, "tax is the floor, not less");
        assertEq(tax + net, gross);
        assertEq(imd.balanceOf(who), net);
        assertEq(imd.balanceOf(TREASURY), tax);
        assertEq(imd.balanceOf(address(exit)), 0);
    }

    function test_maximumTokensPerSaleAllSell() public {
        uint256 n = exit.MAX_TOKENS_PER_SALE();
        address[] memory tokens = new address[](n);
        vm.startPrank(OWNER);
        for (uint256 i; i < n; ++i) {
            MockERC20 t = new MockERC20("M", "M");
            tokens[i] = address(t);
            exit.setSwarmToken(address(t), true);
            exit.setTokenRoute(
                address(t), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(t), IMD_ADDR)
            );
        }
        vm.stopPrank();
        for (uint256 i; i < n; ++i) {
            _addLiquidity(tokens[i], IMD_ADDR, 1_000e18, 1_000e18);
            MockERC20(tokens[i]).mint(user, 10e18);
        }
        _approveAll(user, tokens);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
            exit.sellAll(tokens, _zeros(n), block.timestamp);
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            assertTrue(out[i].status == SwarmExit.Status.Sold);
            sum += out[i].imdOut;
            assertEq(MockERC20(tokens[i]).balanceOf(user), 0);
        }
        assertEq(gross, sum);
        assertEq(net + tax, gross);
        assertEq(imd.balanceOf(user), net);
    }

    function test_minImdOutExactlyEqualToOutputSettles() public {
        uint256 expected = _expectedImd(user, address(tokenC));
        _approveAll(user, _one(address(tokenC)));
        uint256[] memory mins = new uint256[](1);
        mins[0] = expected;
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(_one(address(tokenC)), mins, block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].imdOut, expected);
    }

    function test_deadlineExactlyNowIsAccepted() public {
        _approveAll(user, _one(address(tokenC)));
        vm.prank(user);
        exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        assertEq(tokenC.balanceOf(user), 0);
    }

    function test_sellTwiceSecondCallHasNothingToSell() public {
        _approveAll(user, _one(address(tokenC)));
        vm.startPrank(user);
        exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        vm.expectRevert(SwarmExit.NothingSold.selector);
        exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        vm.stopPrank();
    }

    function test_repeatedSalesAccumulateTreasuryExactly() public {
        _approveAll(user, _one(address(tokenC)));
        vm.prank(user);
        (,, uint256 tax1,) = exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        tokenC.mint(user, 500e18);
        vm.prank(user);
        (,, uint256 tax2,) = exit.sellAll(_one(address(tokenC)), _zeros(1), block.timestamp);
        assertEq(imd.balanceOf(TREASURY), tax1 + tax2);
        assertGt(tax2, 0);
    }

    function test_laterTokenInBatchGetsLessThanIsolatedQuote() public {
        // A and B both bridge through the same WETH/IMD pool: B's isolated quote overstates the batch.
        uint256 isolatedB = _expectedImd(user, address(tokenB));
        _approveAll(user, _two(address(tokenA), address(tokenB)));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(tokenA), address(tokenB)), _zeros(2), block.timestamp);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
        assertLt(out[1].imdOut, isolatedB, "sequential sales share liquidity");
        // and a user who passed the isolated quote as the minimum is refunded, not short-changed
        tokenA.mint(user, 10_000e18);
        tokenB.mint(user, 5_000e18);
        uint256[] memory mins = new uint256[](2);
        mins[1] = _expectedImd(user, address(tokenB));
        vm.prank(user);
        (out,,,) = exit.sellAll(_two(address(tokenA), address(tokenB)), mins, block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertTrue(out[1].status == SwarmExit.Status.SaleFailed);
        assertEq(tokenB.balanceOf(user), 5_000e18);
    }

    // ------------------------------------------------------------------ misbehaving tokens

    function test_partialApprovalRevertsWholeCallNothingMoves() public {
        vm.startPrank(user);
        tokenA.approve(address(exit), 10_000e18 - 1);
        tokenC.approve(address(exit), type(uint256).max);
        vm.expectRevert();
        exit.sellAll(_two(address(tokenC), address(tokenA)), _zeros(2), block.timestamp);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(user), 10_000e18);
        assertEq(tokenC.balanceOf(user), 1_000e18);
        assertEq(imd.balanceOf(user), 0);
        assertEq(imd.balanceOf(TREASURY), 0);
    }

    function test_overReportingBalanceRevertsWholeCallNothingMoves() public {
        OverReportingToken liar = new OverReportingToken();
        liar.mint(user, 100e18);
        liar.setExtra(1);
        _addLiquidity(address(liar), IMD_ADDR, 1_000e18, 1_000e18);
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(liar), true);
        exit.setTokenRoute(
            address(liar), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(liar), IMD_ADDR)
        );
        vm.stopPrank();
        _approveAll(user, _two(address(liar), address(tokenC)));
        vm.prank(user);
        vm.expectRevert();
        exit.sellAll(_two(address(tokenC), address(liar)), _zeros(2), block.timestamp);
        assertEq(tokenC.balanceOf(user), 1_000e18);
        assertEq(imd.balanceOf(user), 0);
    }

    function test_tokenBurningEverythingOnTransferIsReportedZeroBalance() public {
        AllBurnToken burn = new AllBurnToken();
        burn.mint(user, 100e18);
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(burn), true);
        exit.setTokenRoute(
            address(burn), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(burn), IMD_ADDR)
        );
        vm.stopPrank();
        _approveAll(user, _two(address(burn), address(tokenC)));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(burn), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.ZeroBalance, "nothing arrived, nothing to sell");
        assertEq(out[0].amountIn, 0);
        assertEq(burn.balanceOf(address(exit)), 0);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    /// @dev A token that refuses `approve` for the router makes both the sale and the refund path
    /// revert (the catch block calls `forceApprove(router, 0)`). Whatever the outcome, the user must
    /// not be short a single token and the exit must hold nothing.
    function test_approveBlockingTokenNeverCostsTheUser() public {
        ApproveBlockingToken abl = new ApproveBlockingToken();
        abl.mint(user, 100e18);
        _addLiquidity(address(abl), IMD_ADDR, 1_000e18, 1_000e18);
        abl.setBlockedSpender(address(v2), true);
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(abl), true);
        exit.setTokenRoute(
            address(abl), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(abl), IMD_ADDR)
        );
        vm.stopPrank();
        assertTrue(exit.preview(user, _one(address(abl)))[0].sellable, "quotes alone cannot see the approve block");
        _approveAll(user, _two(address(abl), address(tokenC)));
        vm.prank(user);
        (bool ok,) = address(exit)
            .call(abi.encodeCall(SwarmExit.sellAll, (_two(address(abl), address(tokenC)), _zeros(2), block.timestamp)));
        assertEq(abl.balanceOf(user), 100e18, "user keeps the blocking token either way");
        assertEq(abl.balanceOf(address(exit)), 0);
        if (ok) {
            assertEq(tokenC.balanceOf(user), 0);
        } else {
            assertEq(tokenC.balanceOf(user), 1_000e18, "a revert moves nothing");
            assertEq(imd.balanceOf(TREASURY), 0);
        }
    }

    /// @dev A token that blacklists the user after the pull: the refund transfer reverts.
    function test_refundBlockedTokenNeverCostsTheUser() public {
        RefundBlockingToken rbl = new RefundBlockingToken();
        rbl.mint(user, 100e18);
        _addLiquidity(address(rbl), IMD_ADDR, 1_000e18, 1_000e18);
        pools.setBroken(address(rbl), IMD_ADDR, true); // sale reverts, so the refund path runs
        rbl.setBlocked(user, true); // and the refund itself reverts
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(rbl), true);
        exit.setTokenRoute(
            address(rbl), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(rbl), IMD_ADDR)
        );
        vm.stopPrank();
        _approveAll(user, _two(address(rbl), address(tokenC)));
        vm.prank(user);
        (bool ok,) = address(exit)
            .call(abi.encodeCall(SwarmExit.sellAll, (_two(address(tokenC), address(rbl)), _zeros(2), block.timestamp)));
        assertEq(rbl.balanceOf(user), 100e18);
        assertEq(rbl.balanceOf(address(exit)), 0);
        if (!ok) {
            assertEq(tokenC.balanceOf(user), 1_000e18, "a revert moves nothing");
            assertEq(imd.balanceOf(user), 0);
        }
    }

    /// @dev A token that burns all gas inside the venue: the inner self-call runs out of gas and the
    /// catch block runs on the 1/64 that was held back. Nothing may be lost either way.
    function test_gasBurningTokenNeverCostsTheUser() public {
        GasBurnToken gas = new GasBurnToken();
        gas.mint(user, 100e18);
        _addLiquidity(address(gas), IMD_ADDR, 1_000e18, 1_000e18);
        gas.setSink(address(pools));
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(gas), true);
        exit.setTokenRoute(
            address(gas), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(gas), IMD_ADDR)
        );
        vm.stopPrank();
        _approveAll(user, _two(address(gas), address(tokenC)));
        vm.prank(user);
        (bool ok, bytes memory ret) = address(exit).call{gas: 3_000_000}(
            abi.encodeCall(SwarmExit.sellAll, (_two(address(tokenC), address(gas)), _zeros(2), block.timestamp))
        );
        assertEq(gas.balanceOf(user), 100e18, "user keeps the gas-burning token either way");
        assertEq(gas.balanceOf(address(exit)), 0);
        if (ok) {
            (SwarmExit.Outcome[] memory out,,,) = abi.decode(ret, (SwarmExit.Outcome[], uint256, uint256, uint256));
            assertTrue(out[1].status == SwarmExit.Status.SaleFailed);
            assertTrue(out[0].status == SwarmExit.Status.Sold);
        } else {
            assertEq(tokenC.balanceOf(user), 1_000e18);
        }
    }

    function testFuzz_honeypotRefundIsExactForAnyAmount(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));
        address who = makeAddr("honeyHolder");
        honey.mint(who, amount);
        tokenC.mint(who, 1e18);
        _approveAll(who, _two(address(honey), address(tokenC)));
        vm.prank(who);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(honey), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(out[0].amountIn, amount);
        assertEq(honey.balanceOf(who), amount);
        assertEq(honey.balanceOf(address(exit)), 0);
        assertTrue(out[1].status == SwarmExit.Status.Sold);
    }

    function test_feeOnTransferRefundReturnsEverythingTheExitHolds() public {
        pools.setBroken(address(feeTok), address(weth), true);
        _approveAll(user, _two(address(feeTok), address(tokenC)));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(feeTok), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(out[0].amountIn, 9_500e18);
        assertEq(feeTok.balanceOf(address(exit)), 0, "exit keeps nothing");
        // the token itself burned 5% on each leg; the exit returned all 9_500 it held
        assertEq(feeTok.balanceOf(user), 9_025e18);
    }

    // ------------------------------------------------------------------ stray balances in the exit

    function test_strayBalancesAreNeitherSoldNorCountedAsProceeds() public {
        // Someone sent A, WETH and IMD straight to the contract.
        tokenA.mint(address(exit), 777e18);
        weth.mint(address(exit), 3e18);
        imd.mint(address(exit), 1_234e18);
        uint256 expected = _expectedImd(user, address(tokenA));
        _approveAll(user, _one(address(tokenA)));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
            exit.sellAll(_one(address(tokenA)), _zeros(1), block.timestamp);
        assertEq(out[0].amountIn, 10_000e18, "only the user's balance is sold");
        assertEq(out[0].imdOut, expected, "stray WETH and IMD do not inflate the proceeds");
        assertEq(gross, expected);
        assertEq(imd.balanceOf(user), net);
        assertEq(imd.balanceOf(TREASURY), tax);
        assertEq(tokenA.balanceOf(address(exit)), 777e18);
        assertEq(weth.balanceOf(address(exit)), 3e18);
        assertEq(imd.balanceOf(address(exit)), 1_234e18);
    }

    function test_strayBalanceRefundIsExactWhenSaleFails() public {
        honey.mint(address(exit), 50e18);
        _approveAll(user, _two(address(honey), address(tokenC)));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(honey), address(tokenC)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(honey.balanceOf(user), 10_000e18, "refund is the pulled amount, not the whole balance");
        assertEq(honey.balanceOf(address(exit)), 50e18);
    }

    function test_rescueSwarmTokenOnlyAfterUnregistering() public {
        tokenA.mint(address(exit), 5e18);
        vm.startPrank(OWNER);
        vm.expectRevert(SwarmExit.CannotRescueSwarmToken.selector);
        exit.rescue(address(tokenA), OWNER, 5e18);
        exit.setSwarmToken(address(tokenA), false);
        exit.rescue(address(tokenA), OWNER, 5e18);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(OWNER), 5e18);
    }

    function test_rescueBridgeAndImdAllowedAndBounded() public {
        weth.mint(address(exit), 1e18);
        imd.mint(address(exit), 1e18);
        vm.startPrank(OWNER);
        exit.rescue(address(weth), OWNER, 1e18);
        exit.rescue(IMD_ADDR, OWNER, 1e18);
        vm.expectRevert();
        exit.rescue(IMD_ADDR, OWNER, 1); // nothing left
        vm.stopPrank();
        assertEq(weth.balanceOf(OWNER), 1e18);
        assertEq(imd.balanceOf(OWNER), 1e18);
    }

    // ------------------------------------------------------------------ preview and pricing edges

    function test_previewEmptyListAndEmptyRegistry() public {
        address[] memory none = new address[](0);
        assertEq(exit.preview(user, none).length, 0);
        SwarmExit fresh = new SwarmExit(OWNER);
        assertEq(fresh.previewAll(user).length, 0);
    }

    function test_previewReportsBelowMinimumAtExactThreshold() public {
        uint256 expected = _expectedImd(user, address(tokenC));
        vm.prank(OWNER);
        exit.setMinImdOut(expected);
        assertTrue(exit.preview(user, _one(address(tokenC)))[0].sellable, "equal to the threshold is sellable");
        vm.prank(OWNER);
        exit.setMinImdOut(expected + 1);
        SwarmExit.Preview[] memory p = exit.preview(user, _one(address(tokenC)));
        assertFalse(p[0].sellable);
        assertTrue(p[0].status == SwarmExit.Status.BelowMinimum);
    }

    function test_previewQuoteFailedWhenBridgePoolIsBroken() public {
        pools.setBroken(address(weth), IMD_ADDR, true);
        SwarmExit.Preview[] memory p = exit.preview(user, _two(address(tokenA), address(tokenC)));
        assertTrue(p[0].status == SwarmExit.Status.QuoteFailed, "second leg quote fails");
        assertFalse(p[0].sellable);
        assertTrue(p[1].sellable, "direct route unaffected");
        vm.expectRevert(abi.encodeWithSelector(SwarmExit.NotConfigured.selector, "imdRoute quote"));
        exit.quoteImdInBridge(1e18);
    }

    function test_previewDoesNotMoveFunds() public {
        exit.previewAll(user);
        exit.preview(user, _one(address(tokenA)));
        assertEq(tokenA.balanceOf(user), 10_000e18);
        assertEq(imd.balanceOf(user), 0);
        assertEq(tokenA.balanceOf(address(exit)), 0);
    }

    function test_quoteImdInBridgeZeroAmount() public {
        assertEq(exit.quoteImdInBridge(0), 0);
    }

    function test_ethUsdPriceBoundaryAndBadFeeds() public {
        feed.set(3000e8, block.timestamp - 3 hours);
        (uint256 price,) = exit.ethUsdPrice();
        assertEq(price, 3000e8, "exactly MAX_PRICE_AGE old is still accepted");
        feed.set(-1, block.timestamp);
        vm.expectRevert(SwarmExit.InvalidPrice.selector);
        exit.ethUsdPrice();
        feed.set(3000e8, block.timestamp + 1);
        vm.expectRevert();
        exit.ethUsdPrice(); // updatedAt in the future underflows: still a revert, never a price
        RevertingFeed down = new RevertingFeed();
        vm.prank(OWNER);
        exit.setEthUsdFeed(address(down));
        vm.expectRevert(bytes("feed down"));
        exit.ethUsdPrice();
        vm.prank(OWNER);
        vm.expectRevert(SwarmExit.ZeroAddress.selector);
        exit.setEthUsdFeed(address(0));
    }

    function test_pauseDoesNotBlockConfigurationOrPreview() public {
        vm.startPrank(OWNER);
        exit.pause();
        exit.setMinImdOut(1);
        exit.setSwarmToken(address(stray), true);
        vm.stopPrank();
        assertTrue(exit.paused());
        assertEq(exit.previewAll(user).length, 7);
    }

    // ------------------------------------------------------------------ reversed-route oracle

    /// @dev `quoteImdInBridge` must equal quoting the hand-reversed packed path on the quoter.
    function testFuzz_v3ReverseMatchesHandReversedPath(uint8 hopsSeed, uint96 amount, uint24 f1, uint24 f2, uint24 f3)
        public
    {
        uint256 hops = bound(hopsSeed, 1, 4);
        amount = uint96(bound(amount, 1, 10_000e18));
        address[] memory chain = new address[](hops + 1);
        chain[0] = address(weth);
        chain[hops] = IMD_ADDR;
        for (uint256 i = 1; i < hops; ++i) {
            chain[i] = address(new MockERC20("X", "X"));
        }
        for (uint256 i; i < hops; ++i) {
            if (chain[i] == address(weth) && chain[i + 1] == IMD_ADDR) continue; // already seeded
            _addLiquidity(chain[i], chain[i + 1], 1_000e18 * (i + 1), 2_000e18);
        }
        uint24[] memory fees = new uint24[](4);
        fees[0] = f1;
        fees[1] = f2;
        fees[2] = f3;
        fees[3] = FEE_1PCT;
        bytes memory fwd = abi.encodePacked(chain[0]);
        bytes memory rev = abi.encodePacked(chain[hops]);
        for (uint256 i; i < hops; ++i) {
            fwd = abi.encodePacked(fwd, fees[i], chain[i + 1]);
            rev = abi.encodePacked(rev, fees[hops - 1 - i], chain[hops - 1 - i]);
        }
        vm.prank(OWNER);
        exit.setImdRoute(SwarmExit.Venue.UniswapV3, address(v3), address(quoter), fwd);
        (uint256 oracle,,,) = quoter.quoteExactInput(rev, amount);
        assertEq(exit.quoteImdInBridge(amount), oracle);
    }

    function testFuzz_v2ReverseMatchesHandReversedPath(uint8 hopsSeed, uint96 amount) public {
        uint256 hops = bound(hopsSeed, 1, 4);
        amount = uint96(bound(amount, 1, 10_000e18));
        address[] memory chain = new address[](hops + 1);
        chain[0] = address(weth);
        chain[hops] = IMD_ADDR;
        for (uint256 i = 1; i < hops; ++i) {
            chain[i] = address(new MockERC20("Y", "Y"));
        }
        for (uint256 i; i < hops; ++i) {
            if (chain[i] == address(weth) && chain[i + 1] == IMD_ADDR) continue;
            _addLiquidity(chain[i], chain[i + 1], 3_000e18, 1_000e18 * (i + 1));
        }
        address[] memory rev = new address[](hops + 1);
        for (uint256 i; i <= hops; ++i) {
            rev[i] = chain[hops - i];
        }
        vm.prank(OWNER);
        exit.setImdRoute(SwarmExit.Venue.UniswapV2, address(v2), address(0), abi.encode(chain));
        uint256[] memory amounts = v2.getAmountsOut(amount, rev);
        assertEq(exit.quoteImdInBridge(amount), amounts[hops]);
    }

    // ------------------------------------------------------------------ order independence

    function testFuzz_anyOrderAndSubsetConservesImd(uint8 mask, uint8 rot) public {
        address[6] memory all =
            [address(tokenA), address(tokenB), address(tokenC), address(honey), address(noLiq), address(feeTok)];
        mask = uint8(bound(mask, 1, 63));
        uint256 count;
        for (uint256 i; i < 6; ++i) {
            if (mask & (1 << i) != 0) ++count;
        }
        address[] memory tokens = new address[](count);
        uint256 k;
        for (uint256 j; j < 6; ++j) {
            uint256 i = (j + rot) % 6;
            if (mask & (1 << i) != 0) tokens[k++] = all[i];
        }
        _approveAll(user, tokens);
        uint256[6] memory before;
        for (uint256 i; i < 6; ++i) {
            before[i] = IERC20(all[i]).balanceOf(user);
        }
        vm.prank(user);
        (bool ok, bytes memory ret) =
            address(exit).call(abi.encodeCall(SwarmExit.sellAll, (tokens, _zeros(count), block.timestamp)));
        if (ok) {
            (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
                abi.decode(ret, (SwarmExit.Outcome[], uint256, uint256, uint256));
            uint256 sum;
            for (uint256 i; i < out.length; ++i) {
                sum += out[i].imdOut;
                if (out[i].status == SwarmExit.Status.Sold) {
                    assertEq(IERC20(out[i].token).balanceOf(user), 0);
                } else if (out[i].token != address(feeTok)) {
                    assertEq(IERC20(out[i].token).balanceOf(user), _before(all, before, out[i].token));
                }
            }
            assertEq(gross, sum);
            assertEq(tax, gross * 200 / 10_000);
            assertEq(net + tax, gross);
            assertEq(imd.balanceOf(user), net);
            assertEq(imd.balanceOf(TREASURY), tax);
        } else {
            assertEq(bytes4(ret), SwarmExit.NothingSold.selector, "only NothingSold may revert here");
            for (uint256 i; i < 6; ++i) {
                assertEq(IERC20(all[i]).balanceOf(user), before[i]);
            }
        }
        assertEq(imd.balanceOf(address(exit)), 0);
        assertEq(weth.balanceOf(address(exit)), 0);
        for (uint256 i; i < 6; ++i) {
            assertEq(IERC20(all[i]).balanceOf(address(exit)), 0);
            assertEq(IERC20(all[i]).allowance(address(exit), address(v2)), 0);
            assertEq(IERC20(all[i]).allowance(address(exit), address(v3)), 0);
        }
    }

    function _before(address[6] memory all, uint256[6] memory before, address t) internal pure returns (uint256) {
        for (uint256 i; i < 6; ++i) {
            if (all[i] == t) return before[i];
        }
        return 0;
    }
}
