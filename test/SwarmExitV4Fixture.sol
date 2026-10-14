// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmExit} from "../src/SwarmExit.sol";
import {MockERC20, FeeOnTransferToken, HoneypotToken} from "./mocks/MockTokens.sol";
import {MockPools, MockV2Router, MockV3Router, MockV3Quoter, MockWETH, MockV4PoolManager} from "./mocks/MockVenues.sol";

/// @notice Shared deployment for the Uniswap v4 edge-case and invariant suites. WETH sits at its
/// mainnet address so V2 legs can bridge into the native-ETH v4 IMD route, as on chain.
///
/// Routes: V -> IMD (v4 direct), E -> ETH (v4, bridged), F -> IMD (v4 direct, 5% fee on transfer),
/// G -> ETH (v4, 5% fee on transfer, bridged), A -> WETH (V2, unwrapped into the v4 IMD route),
/// H -> IMD (v4, honeypot: transfers into the manager revert). IMD route: ETH -> IMD on v4.
abstract contract SwarmExitV4Fixture is Test {
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

    MockERC20 tokenV;
    MockERC20 tokenE;
    FeeOnTransferToken feeV; // F
    FeeOnTransferToken feeE; // G
    MockERC20 tokenA;
    HoneypotToken honey; // H
    MockERC20 tokenC; // V2 route C -> IMD directly: sells even when the v4 manager is broken

    address user = makeAddr("user");
    address lp = makeAddr("lp");

    function _deployV4Fixture() internal {
        vm.warp(1_760_000_000);
        imd = MockERC20(IMD_ADDR);
        vm.etch(IMD_ADDR, address(new MockERC20("IMD", "IMD")).code);
        weth = MockWETH(payable(WETH_ADDR));
        vm.etch(WETH_ADDR, address(new MockWETH()).code);
        vm.deal(WETH_ADDR, 1_000_000 ether);
        pools = new MockPools();
        v2 = new MockV2Router(pools);
        v3 = new MockV3Router(pools);
        quoter = new MockV3Quoter(pools, v3);
        pm = new MockV4PoolManager();
        exit = new SwarmExit(OWNER);

        tokenV = new MockERC20("V", "V");
        tokenE = new MockERC20("E", "E");
        feeV = new FeeOnTransferToken(500);
        feeE = new FeeOnTransferToken(500);
        tokenA = new MockERC20("A", "A");
        honey = new HoneypotToken();
        tokenC = new MockERC20("C", "C");

        _addLiquidity(address(tokenA), WETH_ADDR, 1_000_000e18, 1000e18);
        _addLiquidity(address(tokenC), IMD_ADDR, 50_000e18, 100_000e18);
        _addV4(NATIVE, IMD_ADDR, 100e18, 100_000e18);
        _addV4(address(tokenV), IMD_ADDR, 50_000e18, 100_000e18);
        _addV4(address(tokenE), NATIVE, 1_000_000e18, 1000e18);
        _addV4(address(feeV), IMD_ADDR, 50_000e18, 100_000e18);
        _addV4(address(feeE), NATIVE, 1_000_000e18, 1000e18);
        _addV4(address(honey), IMD_ADDR, 50_000e18, 100_000e18);
        honey.setBlocked(address(pm), true);

        vm.startPrank(OWNER);
        _register(address(tokenV), SwarmExit.Venue.UniswapV4, address(pm), _v4(address(tokenV), IMD_ADDR));
        _register(address(tokenE), SwarmExit.Venue.UniswapV4, address(pm), _v4(address(tokenE), NATIVE));
        _register(address(feeV), SwarmExit.Venue.UniswapV4, address(pm), _v4(address(feeV), IMD_ADDR));
        _register(address(feeE), SwarmExit.Venue.UniswapV4, address(pm), _v4(address(feeE), NATIVE));
        _register(address(tokenA), SwarmExit.Venue.UniswapV2, address(v2), _v2(address(tokenA), WETH_ADDR));
        _register(address(honey), SwarmExit.Venue.UniswapV4, address(pm), _v4(address(honey), IMD_ADDR));
        _register(address(tokenC), SwarmExit.Venue.UniswapV2, address(v2), _v2(address(tokenC), IMD_ADDR));
        exit.setImdRoute(SwarmExit.Venue.UniswapV4, address(pm), address(0), _v4(NATIVE, IMD_ADDR));
        vm.stopPrank();

        tokenV.mint(user, 1_000e18);
        tokenE.mint(user, 10_000e18);
        feeV.mint(user, 1_000e18);
        feeE.mint(user, 10_000e18);
        tokenA.mint(user, 10_000e18);
        honey.mint(user, 1_000e18);
        tokenC.mint(user, 1_000e18);
    }

    // ------------------------------------------------------------------ helpers

    function _register(address token, SwarmExit.Venue venue, address router, bytes memory data) internal {
        exit.setSwarmToken(token, true);
        exit.setTokenRoute(
            token, venue, router, venue == SwarmExit.Venue.UniswapV3 ? address(quoter) : address(0), data
        );
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

    /// @dev Adds `amtA` of `a` and `amtB` of `b` to the v4 pool from `lp` (minted, or dealt for ETH).
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

    /// @dev What the mock pool pays for `amountIn` of `a` into `b`, read without touching state.
    function _v4Out(address a, address b, uint256 amountIn) internal view returns (uint256) {
        return pm.getAmountOut(_key(a, b), a < b, amountIn);
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

    function _v4TwoHop(address a, address mid, address b) internal pure returns (bytes memory) {
        SwarmExit.V4Hop[] memory hops = new SwarmExit.V4Hop[](2);
        hops[0] = SwarmExit.V4Hop({currencyOut: mid, fee: FEE_1PCT, tickSpacing: 200, hooks: address(0)});
        hops[1] = SwarmExit.V4Hop({currencyOut: b, fee: FEE_1PCT, tickSpacing: 200, hooks: address(0)});
        return abi.encode(a, hops);
    }

    function _approveAll(address who, address[] memory tokens) internal {
        vm.startPrank(who);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20(tokens[i]).approve(address(exit), type(uint256).max);
        }
        vm.stopPrank();
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

    function _expectedImd(address who, address token) internal returns (uint256) {
        return exit.preview(who, _one(token))[0].expectedImd;
    }

    /// @dev The manager is idle and owes / is owed nothing in any currency this fixture uses.
    function _assertManagerSettled() internal view {
        assertEq(pm.locker(), address(0), "manager still locked");
        assertEq(pm.currencyDelta(NATIVE), 0, "native delta");
        assertEq(pm.currencyDelta(IMD_ADDR), 0, "IMD delta");
        assertEq(pm.currencyDelta(address(tokenV)), 0, "V delta");
        assertEq(pm.currencyDelta(address(tokenE)), 0, "E delta");
        assertEq(pm.currencyDelta(address(feeV)), 0, "F delta");
        assertEq(pm.currencyDelta(address(feeE)), 0, "G delta");
        assertEq(pm.currencyDelta(address(honey)), 0, "H delta");
    }

    /// @dev Nothing a sale moves ever rests in the exit between transactions.
    function _assertExitEmpty() internal view {
        assertEq(address(exit).balance, 0, "ETH rests in exit");
        assertEq(weth.balanceOf(address(exit)), 0, "WETH rests in exit");
        assertEq(imd.balanceOf(address(exit)), 0, "IMD rests in exit");
        assertEq(tokenV.balanceOf(address(exit)), 0, "V rests in exit");
        assertEq(tokenE.balanceOf(address(exit)), 0, "E rests in exit");
        assertEq(feeV.balanceOf(address(exit)), 0, "F rests in exit");
        assertEq(feeE.balanceOf(address(exit)), 0, "G rests in exit");
        assertEq(tokenA.balanceOf(address(exit)), 0, "A rests in exit");
        assertEq(honey.balanceOf(address(exit)), 0, "H rests in exit");
        assertEq(tokenC.balanceOf(address(exit)), 0, "C rests in exit");
    }
}
