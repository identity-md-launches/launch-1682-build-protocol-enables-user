// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmExit} from "../src/SwarmExit.sol";
import {SwarmExitV4Fixture} from "./SwarmExitV4Fixture.sol";
import {FeeOnTransferToken} from "./mocks/MockTokens.sol";
import {SinkDropToken} from "./mocks/EdgeMocks.sol";

/// @notice Adversarial cases for the revised Uniswap v4 callback, which now pays the input into the
/// PoolManager first and swaps only what the manager credited. The inputs it did not consider: a
/// token that credits nothing, a token that reverts inside the manager, a fee charged twice on a
/// two-leg route, a fee of any size, a minimum taken from the pre-fee preview, and a swap that
/// fails after the input was already settled.
/// forge-config: default.fuzz.runs = 512
contract SwarmExitV4EdgesTest is SwarmExitV4Fixture {
    function setUp() public {
        _deployV4Fixture();
        _approveAll(
            user, _six(address(tokenV), address(tokenE), address(feeV), address(feeE), address(tokenA), address(honey))
        );
        _approveAll(user, _one(address(tokenC)));
    }

    // ------------------------------------------------------------------ the manager credits nothing

    /// @dev The transfer into the manager "succeeds" but nothing arrives: `settle` credits zero. The
    /// callback must not swap zero (which would leave the manager owed nothing and the exit holding
    /// the user's tokens as if sold) but revert so the whole sale is refunded.
    function test_v4TokenCreditingNothingIsRefundedNotSoldForZero() public {
        SinkDropToken drop = new SinkDropToken();
        _addV4(address(drop), IMD_ADDR, 50_000e18, 100_000e18);
        drop.setSink(address(pm)); // after the liquidity went in
        drop.mint(user, 100e18);
        vm.startPrank(OWNER);
        _register(address(drop), SwarmExit.Venue.UniswapV4, address(pm), _v4(address(drop), IMD_ADDR));
        vm.stopPrank();
        _approveAll(user, _one(address(drop)));
        assertTrue(exit.preview(user, _one(address(drop)))[0].sellable, "the quote cannot see the drop");

        vm.expectEmit(true, true, false, true);
        emit SwarmExit.TokenRefunded(user, address(drop), 100e18, abi.encodeWithSelector(SwarmExit.NoProceeds.selector));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out, uint256 gross,,) =
            exit.sellAll(_two(address(drop), address(tokenV)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(out[0].amountIn, 100e18);
        assertEq(out[0].imdOut, 0);
        assertEq(drop.balanceOf(user), 100e18, "the burn inside the reverted unlock is rolled back");
        assertEq(drop.balanceOf(address(exit)), 0);
        assertEq(drop.balanceOf(address(pm)), 50_000e18, "the pool is untouched");
        assertTrue(out[1].status == SwarmExit.Status.Sold);
        assertEq(gross, out[1].imdOut);
        assertEq(pm.currencyDelta(address(drop)), 0);
        _assertManagerSettled();
        _assertExitEmpty();
    }

    // ------------------------------------------------------------------ revert inside the manager

    function test_v4HoneypotRefundedAndCallbackGuardRestored() public {
        assertTrue(exit.preview(user, _one(address(honey)))[0].sellable, "quote mode never transfers");
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) =
            exit.sellAll(_two(address(honey), address(tokenV)), _zeros(2), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(out[0].amountIn, 1_000e18);
        assertEq(honey.balanceOf(user), 1_000e18, "refunded in full");
        assertTrue(out[1].status == SwarmExit.Status.Sold);
        _assertManagerSettled();
        _assertExitEmpty();
        // The in-flight manager marker was rolled back with the failed self-call: the manager
        // itself cannot drive the callback outside a sale.
        vm.prank(address(pm));
        vm.expectRevert(SwarmExit.OnlyPoolManager.selector);
        exit.unlockCallback(abi.encode(false, address(tokenV), new SwarmExit.V4Hop[](0), uint256(1)));
    }

    function test_callbackGuardHoldsAfterASuccessfulV4Sale() public {
        vm.prank(user);
        exit.sellAll(_one(address(tokenV)), _zeros(1), block.timestamp);
        vm.prank(address(pm));
        vm.expectRevert(SwarmExit.OnlyPoolManager.selector);
        exit.unlockCallback(abi.encode(false, address(tokenV), new SwarmExit.V4Hop[](0), uint256(1)));
        vm.prank(user);
        vm.expectRevert(SwarmExit.OnlyPoolManager.selector);
        exit.unlockCallback("");
    }

    // ------------------------------------------------------------------ fee on transfer, two legs

    /// @dev G -> ETH (v4) then ETH -> IMD (v4). The first leg sells what the manager credited
    /// (balance minus two fees); the native second leg sells exactly what the first leg took.
    function test_v4FeeOnTransferBridgedThroughNativeSellsMeasuredAmounts() public {
        uint256 received = 10_000e18 - 10_000e18 * 500 / 10_000; // pulled into the exit
        uint256 settled = received - received * 500 / 10_000; // credited by the manager
        uint256 ethOut = _v4Out(address(feeE), NATIVE, settled);
        uint256 expected = _v4Out(NATIVE, IMD_ADDR, ethOut);
        uint256 previewed = _expectedImd(user, address(feeE));
        assertGt(previewed, expected, "preview quotes the pre-fee wallet balance");

        vm.prank(user);
        (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
            exit.sellAll(_one(address(feeE)), _zeros(1), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.Sold);
        assertEq(out[0].amountIn, received);
        assertEq(out[0].imdOut, expected, "both legs ran on measured amounts");
        assertEq(gross, expected);
        assertEq(tax, gross * 200 / 10_000);
        assertEq(net, gross - tax);
        assertEq(imd.balanceOf(user), net);
        assertEq(imd.balanceOf(TREASURY), tax);
        assertEq(feeE.balanceOf(user), 0);
        _assertManagerSettled();
        _assertExitEmpty();
    }

    /// @dev A minimum copied from the pre-fee preview cannot be met once the manager credits the
    /// post-fee amount: the sale must fail and refund every wei the exit received, never settle short.
    function test_v4FeeOnTransferWithPreviewMinimumIsRefundedNotSettledShort() public {
        uint256[] memory mins = new uint256[](2);
        mins[0] = _expectedImd(user, address(feeV));
        uint256 received = 1_000e18 - 1_000e18 * 500 / 10_000;
        uint256 poolBefore = feeV.balanceOf(address(pm));
        vm.expectEmit(true, true, false, false);
        emit SwarmExit.TokenRefunded(user, address(feeV), received, "");
        vm.prank(user);
        (SwarmExit.Outcome[] memory out,,,) = exit.sellAll(_two(address(feeV), address(tokenV)), mins, block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(out[0].amountIn, received);
        assertEq(out[0].imdOut, 0);
        assertEq(
            feeV.balanceOf(user), received - received * 500 / 10_000, "refund of all 950, minus the token's own fee"
        );
        assertEq(feeV.balanceOf(address(pm)), poolBefore, "the settled input was rolled back with the unlock");
        assertTrue(out[1].status == SwarmExit.Status.Sold);
        _assertManagerSettled();
        _assertExitEmpty();
    }

    /// @dev The input is settled before the hop runs. When the hop then fails (thin pool: partial
    /// fill), the credit must be rolled back with the unlock and the pulled tokens refunded.
    function test_v4SwapFailingAfterSettleRefundsThePulledFeeToken() public {
        pm.setPartialFillRealSwaps(true);
        uint256 received = 1_000e18 - 1_000e18 * 500 / 10_000;
        uint256 poolBefore = feeV.balanceOf(address(pm));
        address[] memory list = new address[](3);
        list[0] = address(feeV);
        list[1] = address(tokenA);
        list[2] = address(tokenC);
        vm.prank(user);
        (SwarmExit.Outcome[] memory out, uint256 gross,,) = exit.sellAll(list, _zeros(3), block.timestamp);
        assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
        assertEq(out[0].amountIn, received);
        assertEq(feeV.balanceOf(user), received - received * 500 / 10_000);
        assertEq(feeV.balanceOf(address(pm)), poolBefore, "nothing stays credited");
        // A's V2 leg succeeded but its native v4 leg failed: the whole self-call rolled back
        assertTrue(out[1].status == SwarmExit.Status.SaleFailed, "the bridged v4 leg fails too");
        assertEq(tokenA.balanceOf(user), 10_000e18, "A refunded in full");
        assertTrue(out[2].status == SwarmExit.Status.Sold, "the V2-only token still sells");
        assertEq(gross, out[2].imdOut);
        _assertManagerSettled();
        _assertExitEmpty();
    }

    /// @dev For any transfer fee and any amount the outcome is one of exactly three: skipped on the
    /// pre-fee quote (nothing moves), sold for precisely the measured-amount quote, or refunded in
    /// full because the measured proceeds are below the floor. Never a settlement for a different
    /// amount, never an unsettled manager, never a balance left in the exit.
    function testFuzz_v4FeeOnTransferAnyFeeSellsMeasuredOrRefundsExactly(uint16 feeBps, uint96 amount) public {
        feeBps = uint16(bound(feeBps, 0, 9_999));
        amount = uint96(bound(amount, 1, 50_000e18));
        FeeOnTransferToken tok = new FeeOnTransferToken(feeBps);
        _addV4(address(tok), IMD_ADDR, 50_000e18, 100_000e18);
        vm.startPrank(OWNER);
        _register(address(tok), SwarmExit.Venue.UniswapV4, address(pm), _v4(address(tok), IMD_ADDR));
        vm.stopPrank();
        address who = makeAddr("feeHolder");
        tok.mint(who, amount);
        _approveAll(who, _one(address(tok)));

        uint256 previewed = _v4Out(address(tok), IMD_ADDR, amount);
        uint256 received = amount - amount * feeBps / 10_000;
        uint256 settled = received - received * feeBps / 10_000;
        uint256 measured = _v4Out(address(tok), IMD_ADDR, settled);
        uint256 floor = exit.minImdOut();
        uint256 poolBefore = tok.balanceOf(address(pm));
        assertEq(_expectedImd(who, address(tok)), previewed, "preview quotes the pre-fee balance");

        vm.prank(who);
        (bool ok, bytes memory ret) =
            address(exit).call(abi.encodeCall(SwarmExit.sellAll, (_one(address(tok)), _zeros(1), block.timestamp)));
        if (previewed < floor) {
            assertFalse(ok, "skipped before the pull, nothing sold");
            assertEq(bytes4(ret), SwarmExit.NothingSold.selector);
            assertEq(tok.balanceOf(who), amount, "nothing moved");
        } else if (measured >= floor) {
            assertTrue(ok);
            (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
                abi.decode(ret, (SwarmExit.Outcome[], uint256, uint256, uint256));
            assertTrue(out[0].status == SwarmExit.Status.Sold);
            assertEq(out[0].amountIn, received);
            assertEq(out[0].imdOut, measured, "sold for the measured-amount quote");
            assertEq(gross, measured);
            assertEq(net + tax, gross);
            assertEq(imd.balanceOf(who), net);
            assertEq(imd.balanceOf(TREASURY), tax);
            assertEq(tok.balanceOf(who), 0);
            assertEq(tok.balanceOf(address(pm)), poolBefore + settled, "the pool got exactly what was credited");
        } else {
            assertFalse(ok, "the only token failed, so nothing was sold");
            assertEq(bytes4(ret), SwarmExit.NothingSold.selector);
            assertEq(tok.balanceOf(who), amount, "a revert moves nothing");
            // and beside a token that sells, the failure is a refund of every wei the exit received
            tokenV.mint(who, 1e18);
            _approveAll(who, _one(address(tokenV)));
            vm.prank(who);
            (SwarmExit.Outcome[] memory out,,,) =
                exit.sellAll(_two(address(tok), address(tokenV)), _zeros(2), block.timestamp);
            assertTrue(out[0].status == SwarmExit.Status.SaleFailed);
            assertEq(out[0].amountIn, received);
            assertEq(tok.balanceOf(who), received - received * feeBps / 10_000, "refund of all that was pulled");
            assertEq(tok.balanceOf(address(pm)), poolBefore, "the credit was rolled back");
            assertTrue(out[1].status == SwarmExit.Status.Sold);
        }
        assertEq(tok.balanceOf(address(exit)), 0);
        assertEq(pm.currencyDelta(address(tok)), 0);
        _assertManagerSettled();
        _assertExitEmpty();
    }

    // ------------------------------------------------------------------ quote mode

    function test_v4QuoteModeMovesNothingForAnyToken() public {
        uint256 feePool = feeV.balanceOf(address(pm));
        uint256 honeyPool = honey.balanceOf(address(pm));
        uint256 ethPool = address(pm).balance;
        exit.previewAll(user);
        assertEq(feeV.balanceOf(user), 1_000e18);
        assertEq(honey.balanceOf(user), 1_000e18);
        assertEq(feeE.balanceOf(user), 10_000e18);
        assertEq(feeV.balanceOf(address(pm)), feePool);
        assertEq(honey.balanceOf(address(pm)), honeyPool);
        assertEq(address(pm).balance, ethPool);
        _assertManagerSettled();
        _assertExitEmpty();
    }

    /// @dev `quoteImdInBridge` reverses the native v4 IMD route: IMD -> ETH must match the pool.
    function test_quoteImdInBridgeReversesNativeV4Route() public {
        uint256 oracle = _v4Out(IMD_ADDR, NATIVE, 1_000e18);
        assertEq(exit.quoteImdInBridge(1_000e18), oracle);
        assertGt(oracle, 0);
        _assertManagerSettled();
    }

    // ------------------------------------------------------------------ mixed batch

    function test_v4MixedBatchSettlesEveryCurrencyAndConservesImd() public {
        pm.setPartialFillRealSwaps(false);
        address[] memory list =
            _six(address(feeV), address(honey), address(tokenV), address(feeE), address(tokenA), address(tokenE));
        vm.prank(user);
        (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
            exit.sellAll(list, _zeros(6), block.timestamp);
        uint256 sum;
        for (uint256 i; i < out.length; ++i) {
            sum += out[i].imdOut;
            if (out[i].status == SwarmExit.Status.Sold) {
                assertEq(IERC20(out[i].token).balanceOf(user), 0, "sold token fully taken");
            }
        }
        assertTrue(out[0].status == SwarmExit.Status.Sold, "fee token on v4 sells");
        assertTrue(out[1].status == SwarmExit.Status.SaleFailed, "honeypot refunded");
        assertEq(honey.balanceOf(user), 1_000e18);
        assertTrue(out[2].status == SwarmExit.Status.Sold);
        assertTrue(out[3].status == SwarmExit.Status.Sold, "fee token bridged through native sells");
        assertTrue(out[4].status == SwarmExit.Status.Sold, "V2 leg unwrapped into the native v4 leg");
        assertTrue(out[5].status == SwarmExit.Status.Sold);
        assertEq(gross, sum);
        assertEq(tax, gross * 200 / 10_000);
        assertEq(net + tax, gross);
        assertEq(imd.balanceOf(user), net);
        assertEq(imd.balanceOf(TREASURY), tax);
        _assertManagerSettled();
        _assertExitEmpty();
    }

    function _six(address a, address b, address c, address d, address e, address f)
        internal
        pure
        returns (address[] memory arr)
    {
        arr = new address[](6);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        arr[3] = d;
        arr[4] = e;
        arr[5] = f;
    }
}
