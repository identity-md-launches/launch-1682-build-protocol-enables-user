// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmExit} from "../src/SwarmExit.sol";
import {SwarmExitFixture} from "./SwarmExitFixture.sol";
import {MockERC20} from "./mocks/MockTokens.sol";
import {MockPools} from "./mocks/MockVenues.sol";
import {FalseReturnToken} from "./mocks/EdgeMocks.sol";

/// @notice Drives SwarmExit with several actors, random token subsets, random minimums, broken
/// pools, pauses, route changes, stray deposits, refunds the token refuses to deliver and their
/// later claims. Every successful `sellAll` is checked for the per-call accounting; the ghost
/// totals feed the invariants below.
contract SwarmExitHandler is Test {
    address constant TREASURY = 0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB;
    uint256 immutable N;

    SwarmExit public exit;
    IERC20 public imd;
    IERC20 public weth;
    MockPools public pools;
    address public owner;
    address public v2;
    address public v3;

    address[] public actors;
    address[] public tokens; // A, B, C, honey, noLiq, feeTok, blk
    address public feeToken;
    address public honeyToken;
    FalseReturnToken public blkToken; // V2 route to IMD; its transfers can be made to return false
    address[] public routeOuts; // the bridge/IMD each token route ends in

    // ghosts
    uint256 public ghostGross;
    uint256 public ghostTax;
    uint256 public ghostNet;
    mapping(address => uint256) public ghostNetOf;
    mapping(address => uint256) public ghostStray; // sent straight to the exit by the handler
    mapping(address => uint256) public ghostHeldTotal; // per token, what the exit owes as refunds
    mapping(address => mapping(address => uint256)) public ghostHeldOf; // per actor and token
    uint256 public ghostSales;
    uint256 public ghostReverts;
    uint256 public ghostRefunds;
    uint256 public ghostHeldEvents;
    uint256 public ghostClaims;
    uint256 public ghostRegistered;

    constructor(
        SwarmExit exit_,
        IERC20 imd_,
        IERC20 weth_,
        MockPools pools_,
        address owner_,
        address v2_,
        address v3_,
        address[] memory tokens_,
        address feeToken_,
        address honeyToken_,
        FalseReturnToken blkToken_
    ) {
        exit = exit_;
        imd = imd_;
        weth = weth_;
        pools = pools_;
        owner = owner_;
        v2 = v2_;
        v3 = v3_;
        tokens = tokens_;
        N = tokens_.length;
        feeToken = feeToken_;
        honeyToken = honeyToken_;
        blkToken = blkToken_;
        ghostRegistered = tokens_.length;
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        for (uint256 a; a < actors.length; ++a) {
            vm.startPrank(actors[a]);
            for (uint256 i; i < tokens.length; ++i) {
                IERC20(tokens[i]).approve(address(exit), type(uint256).max);
            }
            vm.stopPrank();
        }
        for (uint256 i; i < tokens.length; ++i) {
            routeOuts.push(exit.tokenRoute(tokens[i]).tokenOut);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    // ------------------------------------------------------------------ actions

    function mint(uint8 actorSeed, uint8 tokenSeed, uint96 amount) external {
        address actor = actors[actorSeed % actors.length];
        address token = tokens[tokenSeed % N];
        amount = uint96(bound(amount, 1, 50_000e18));
        MockERC20(token).mint(actor, amount);
    }

    struct Snap {
        address actor;
        address[] list;
        uint256[] mins;
        uint256[] before;
        uint256[] heldBefore;
        uint256 imdBefore;
        uint256 treasuryBefore;
    }

    function sell(uint8 actorSeed, uint8 mask, uint8 rot, uint8 minMode, uint8 deadlineMode) external {
        Snap memory s = _prepare(actors[actorSeed % actors.length], mask, rot, minMode);
        uint256 deadline = deadlineMode % 7 == 0 ? block.timestamp - 1 : block.timestamp + 60;

        vm.prank(s.actor);
        (bool ok, bytes memory ret) = address(exit).call(abi.encodeCall(SwarmExit.sellAll, (s.list, s.mins, deadline)));

        if (!ok) {
            _checkRevert(s);
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
        s.heldBefore = new uint256[](count);
        uint256 k;
        for (uint256 j; j < N; ++j) {
            uint256 i = (j + rot) % N;
            if (mask & (1 << i) == 0) continue;
            s.list[k] = tokens[i];
            // minMode: 0 = zero, 1 = isolated quote (later tokens may be refunded), 2 = quote + 1 (refund)
            if (minMode % 3 != 0) {
                SwarmExit.Preview[] memory p = exit.preview(actor, _one(tokens[i]));
                s.mins[k] = minMode % 3 == 1 ? p[0].expectedImd : p[0].expectedImd + 1;
            }
            s.before[k] = IERC20(tokens[i]).balanceOf(actor);
            s.heldBefore[k] = exit.heldRefunds(actor, tokens[i]);
            ++k;
        }
        s.imdBefore = imd.balanceOf(actor);
        s.treasuryBefore = imd.balanceOf(TREASURY);
    }

    function _checkRevert(Snap memory s) internal {
        ++ghostReverts;
        for (uint256 i; i < s.list.length; ++i) {
            assertEq(IERC20(s.list[i]).balanceOf(s.actor), s.before[i], "revert must move nothing");
            assertEq(exit.heldRefunds(s.actor, s.list[i]), s.heldBefore[i], "revert must hold nothing");
        }
        assertEq(imd.balanceOf(s.actor), s.imdBefore, "revert must pay nothing");
        assertEq(imd.balanceOf(TREASURY), s.treasuryBefore, "revert must tax nothing");
    }

    function _checkSuccess(Snap memory s, bytes memory ret) internal {
        (SwarmExit.Outcome[] memory out, uint256 gross, uint256 tax, uint256 net) =
            abi.decode(ret, (SwarmExit.Outcome[], uint256, uint256, uint256));
        uint256 sum;
        for (uint256 i; i < s.list.length; ++i) {
            sum += out[i].imdOut;
            uint256 heldDelta = exit.heldRefunds(s.actor, s.list[i]) - s.heldBefore[i];
            if (out[i].status == SwarmExit.Status.Sold) {
                assertEq(IERC20(s.list[i]).balanceOf(s.actor), 0, "sold token fully taken");
                assertGe(out[i].imdOut, s.mins[i], "settled below the caller's minimum");
                assertEq(heldDelta, 0, "a sold token holds no refund");
            } else {
                ++ghostRefunds;
                assertEq(out[i].imdOut, 0, "unsold token yields nothing");
                if (out[i].status != SwarmExit.Status.SaleFailed) {
                    assertEq(out[i].amountIn, 0, "a skipped token is never pulled");
                    assertEq(IERC20(s.list[i]).balanceOf(s.actor), s.before[i], "a skipped token never moves");
                    assertEq(heldDelta, 0, "a skipped token holds no refund");
                } else if (s.list[i] != feeToken) {
                    // refunded in full: back in the wallet, or held for `claimRefund`, never both lost
                    assertEq(
                        IERC20(s.list[i]).balanceOf(s.actor) + heldDelta,
                        s.before[i],
                        "unsold token neither in the wallet nor held"
                    );
                    if (heldDelta > 0) {
                        ++ghostHeldEvents;
                        assertEq(heldDelta, out[i].amountIn, "held amount is exactly what was pulled");
                        ghostHeldTotal[s.list[i]] += heldDelta;
                        ghostHeldOf[s.actor][s.list[i]] += heldDelta;
                    }
                }
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

    function breakPool(uint8 tokenSeed, bool broken) external {
        uint256 i = tokenSeed % N;
        pools.setBroken(tokens[i], routeOuts[i], broken);
    }

    /// @dev The blocking token's swap fails at execution (transfer into the pool returns false)
    /// while its quote still succeeds, so the pull happens and the refund path runs.
    function blockVenue(bool blocked) external {
        blkToken.setBlocked(address(pools), blocked);
    }

    /// @dev The blocking token refuses the pull itself (transferFrom into the exit returns false).
    function blockPull(bool blocked) external {
        blkToken.setBlocked(address(exit), blocked);
    }

    /// @dev The blocking token refuses to deliver to an actor: a refund to them is held.
    function blockRefund(uint8 actorSeed, bool blocked) external {
        blkToken.setBlocked(actors[actorSeed % actors.length], blocked);
    }

    function claim(uint8 actorSeed, uint8 tokenSeed) external {
        address actor = actors[actorSeed % actors.length];
        address token = tokens[tokenSeed % N];
        uint256 held = exit.heldRefunds(actor, token);
        uint256 balBefore = IERC20(token).balanceOf(actor);
        uint256 exitBefore = IERC20(token).balanceOf(address(exit));
        uint256 totalBefore = exit.totalHeld(token);
        vm.prank(actor);
        (bool ok, bytes memory ret) = address(exit).call(abi.encodeCall(SwarmExit.claimRefund, (token)));
        if (held == 0) {
            assertFalse(ok, "nothing held must not be claimable");
            assertEq(bytes4(ret), SwarmExit.NothingToClaim.selector);
            return;
        }
        if (!ok) {
            // the token still refuses delivery: the entry must survive untouched
            assertTrue(token == address(blkToken) && blkToken.blockedRecipient(actor), "only a refusal may fail");
            assertEq(exit.heldRefunds(actor, token), held);
            assertEq(exit.totalHeld(token), totalBefore);
            assertEq(IERC20(token).balanceOf(address(exit)), exitBefore);
            return;
        }
        ++ghostClaims;
        assertEq(IERC20(token).balanceOf(actor), balBefore + held, "claim delivers exactly what was held");
        assertEq(IERC20(token).balanceOf(address(exit)), exitBefore - held);
        assertEq(exit.heldRefunds(actor, token), 0);
        assertEq(exit.totalHeld(token), totalBefore - held);
        ghostHeldTotal[token] -= held;
        ghostHeldOf[actor][token] -= held;
    }

    function breakBridge(bool broken) external {
        pools.setBroken(address(weth), address(imd), broken);
    }

    function togglePause(bool pause) external {
        vm.startPrank(owner);
        if (pause && !exit.paused()) exit.pause();
        if (!pause && exit.paused()) exit.unpause();
        vm.stopPrank();
    }

    function setMinImdOut(uint96 value) external {
        vm.prank(owner);
        exit.setMinImdOut(value);
    }

    function clearOrRestoreRoute(uint8 tokenSeed, bool clear) external {
        uint256 i = tokenSeed % N;
        vm.startPrank(owner);
        if (clear) {
            exit.setTokenRoute(tokens[i], SwarmExit.Venue.None, address(0), address(0), "");
        } else {
            address[] memory path = new address[](2);
            path[0] = tokens[i];
            path[1] = routeOuts[i];
            exit.setTokenRoute(tokens[i], SwarmExit.Venue.UniswapV2, v2, address(0), abi.encode(path));
        }
        vm.stopPrank();
    }

    function unregisterAndReregister(uint8 tokenSeed) external {
        uint256 i = tokenSeed % N;
        vm.startPrank(owner);
        exit.setSwarmToken(tokens[i], false);
        assertFalse(exit.isSwarmToken(tokens[i]));
        exit.setSwarmToken(tokens[i], true);
        vm.stopPrank();
    }

    function strayDeposit(uint8 tokenSeed, uint96 amount) external {
        amount = uint96(bound(amount, 1, 1_000e18));
        address token = tokenSeed % 8 == 6 ? address(weth) : tokenSeed % 8 == 7 ? address(imd) : tokens[tokenSeed % N];
        if (token == feeToken) return; // its transfer fee makes the stray amount unmeasurable here
        MockERC20(token).mint(address(this), amount);
        uint256 before = IERC20(token).balanceOf(address(exit));
        IERC20(token).transfer(address(exit), amount); // may return false for blkToken while blockPull is on
        ghostStray[token] += IERC20(token).balanceOf(address(exit)) - before;
    }

    function addLiquidity(uint8 tokenSeed, uint96 amountA, uint96 amountB) external {
        uint256 i = tokenSeed % N;
        if (tokens[i] == address(honeyToken)) return; // the honeypot refuses transfers into the pool
        if (tokens[i] == address(blkToken) && blkToken.blockedRecipient(address(pools))) return;
        amountA = uint96(bound(amountA, 1e18, 100_000e18));
        amountB = uint96(bound(amountB, 1e18, 1_000e18));
        address a = tokens[i];
        address b = routeOuts[i];
        MockERC20(a).mint(address(this), amountA);
        MockERC20(b).mint(address(this), amountB);
        IERC20(a).approve(address(pools), amountA);
        IERC20(b).approve(address(pools), amountB);
        pools.addLiquidity(a, b, amountA, amountB);
    }

    function warp(uint32 by) external {
        vm.warp(block.timestamp + bound(by, 1, 1 days));
    }

    function _one(address t) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = t;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = false
contract SwarmExitInvariantTest is SwarmExitFixture {
    SwarmExitHandler handler;
    address[] allTokens;
    FalseReturnToken blk;

    function setUp() public {
        _deployFixture();
        blk = new FalseReturnToken();
        _addLiquidity(address(blk), IMD_ADDR, 50_000e18, 100_000e18);
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(blk), true);
        exit.setTokenRoute(
            address(blk), SwarmExit.Venue.UniswapV2, address(v2), address(0), _v2(address(blk), IMD_ADDR)
        );
        vm.stopPrank();
        allTokens.push(address(tokenA));
        allTokens.push(address(tokenB));
        allTokens.push(address(tokenC));
        allTokens.push(address(honey));
        allTokens.push(address(noLiq));
        allTokens.push(address(feeTok));
        allTokens.push(address(blk));
        handler = new SwarmExitHandler(
            exit,
            IERC20(IMD_ADDR),
            IERC20(address(weth)),
            pools,
            OWNER,
            address(v2),
            address(v3),
            allTokens,
            address(feeTok),
            address(honey),
            blk
        );
        for (uint256 a; a < handler.actorCount(); ++a) {
            address actor = handler.actors(a);
            tokenA.mint(actor, 1_000e18);
            tokenB.mint(actor, 1_000e18);
            tokenC.mint(actor, 100e18);
            honey.mint(actor, 1_000e18);
            feeTok.mint(actor, 1_000e18);
            blk.mint(actor, 100e18);
        }
        targetContract(address(handler));
    }

    /// @notice The exit never keeps anything it did not receive as a stray deposit or hold as a
    /// refund the token refused to deliver: every sale either settles, refunds or holds inside the
    /// same transaction.
    function invariant_exitHoldsOnlyStrayBalancesAndHeldRefunds() public view {
        for (uint256 i; i < allTokens.length; ++i) {
            assertEq(
                IERC20(allTokens[i]).balanceOf(address(exit)),
                handler.ghostStray(allTokens[i]) + exit.totalHeld(allTokens[i]),
                "swarm token rests in exit"
            );
        }
        assertEq(weth.balanceOf(address(exit)), handler.ghostStray(address(weth)), "bridge token rests in exit");
        assertEq(imd.balanceOf(address(exit)), handler.ghostStray(IMD_ADDR), "IMD rests in exit");
    }

    /// @notice What the exit says it holds for everyone equals the sum of what it owes each user,
    /// equals what the handler saw being held and claimed, and only the blocking token is ever held.
    function invariant_heldRefundsAreBackedAndAccounted() public view {
        for (uint256 i; i < allTokens.length; ++i) {
            address token = allTokens[i];
            uint256 sum;
            for (uint256 a; a < handler.actorCount(); ++a) {
                address actor = handler.actors(a);
                assertEq(exit.heldRefunds(actor, token), handler.ghostHeldOf(actor, token), "per-user held");
                sum += exit.heldRefunds(actor, token);
            }
            assertEq(exit.totalHeld(token), sum, "totalHeld is the sum over users");
            assertEq(exit.totalHeld(token), handler.ghostHeldTotal(token), "totalHeld matches the ghost");
            assertLe(exit.totalHeld(token), IERC20(token).balanceOf(address(exit)), "held refunds are backed");
            if (token != address(blk)) assertEq(exit.totalHeld(token), 0, "only a refusing token is held");
        }
    }

    /// @notice The owner can never sweep a held refund, whatever the stray balance beside it.
    function invariant_ownerCannotRescueHeldRefunds() public {
        uint256 held = exit.totalHeld(address(blk));
        uint256 stray = handler.ghostStray(address(blk));
        vm.prank(OWNER);
        vm.expectRevert(SwarmExit.CannotRescueSwarmToken.selector);
        exit.rescue(address(blk), OWNER, 1);
        // even once unregistered, only the stray part is reachable
        uint256 snap = vm.snapshotState();
        vm.startPrank(OWNER);
        exit.setSwarmToken(address(blk), false);
        vm.expectRevert(SwarmExit.CannotRescueHeldRefunds.selector);
        exit.rescue(address(blk), OWNER, stray + 1);
        if (stray > 0) exit.rescue(address(blk), OWNER, stray);
        vm.stopPrank();
        assertEq(exit.totalHeld(address(blk)), held);
        assertGe(blk.balanceOf(address(exit)), held);
        vm.revertToState(snap);
    }

    /// @notice Treasury holds exactly the sum of every sale's 2% tax and nothing else.
    function invariant_treasuryEqualsTaxSum() public view {
        assertEq(imd.balanceOf(TREASURY), handler.ghostTax());
    }

    /// @notice Users hold exactly the sum of their net proceeds; gross is conserved into tax plus net.
    function invariant_usersHoldNetProceeds() public view {
        uint256 total;
        for (uint256 a; a < handler.actorCount(); ++a) {
            address actor = handler.actors(a);
            assertEq(imd.balanceOf(actor), handler.ghostNetOf(actor));
            total += imd.balanceOf(actor);
        }
        assertEq(total, handler.ghostNet());
        assertEq(handler.ghostNet() + handler.ghostTax(), handler.ghostGross());
        // sum of per-sale floors is within one wei per sale of 2% of the total
        assertLe(handler.ghostTax() * 10_000, handler.ghostGross() * 200);
        assertGe(handler.ghostTax() * 10_000 + handler.ghostSales() * 10_000, handler.ghostGross() * 200);
    }

    /// @notice No router allowance survives a call, so a later router exploit cannot pull from the exit.
    function invariant_noAllowanceLeftBehind() public view {
        for (uint256 i; i < allTokens.length; ++i) {
            assertEq(IERC20(allTokens[i]).allowance(address(exit), address(v2)), 0);
            assertEq(IERC20(allTokens[i]).allowance(address(exit), address(v3)), 0);
        }
        assertEq(weth.allowance(address(exit), address(v2)), 0);
        assertEq(weth.allowance(address(exit), address(v3)), 0);
    }

    /// @notice The registry list and the mapping agree, with no duplicates.
    function invariant_registryConsistent() public view {
        address[] memory list = exit.swarmTokens();
        assertEq(list.length, exit.swarmTokenCount());
        assertEq(list.length, handler.ghostRegistered());
        for (uint256 i; i < list.length; ++i) {
            assertTrue(exit.isSwarmToken(list[i]));
            for (uint256 j; j < i; ++j) {
                assertTrue(list[i] != list[j], "duplicate in registry");
            }
        }
        for (uint256 i; i < allTokens.length; ++i) {
            assertTrue(exit.isSwarmToken(allTokens[i]));
        }
    }

    /// @notice Fixed values from the brief never change.
    function invariant_constantsFixed() public view {
        assertEq(address(exit.IMD()), IMD_ADDR);
        assertEq(exit.TREASURY(), TREASURY);
        assertEq(exit.SELL_TAX_BPS(), 200);
        assertEq(exit.owner(), OWNER);
    }
}
