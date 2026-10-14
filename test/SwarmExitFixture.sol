// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmExit} from "../src/SwarmExit.sol";
import {MockERC20, FeeOnTransferToken, HoneypotToken} from "./mocks/MockTokens.sol";
import {MockPools, MockV2Router, MockV3Router, MockV3Quoter, MockFeed} from "./mocks/MockVenues.sol";

/// @notice Shared deployment used by the edge-case and invariant suites. Mirrors the fixture of
/// `SwarmExit.t.sol` (same tokens, routes and liquidity) so numbers are comparable across suites.
abstract contract SwarmExitFixture is Test {
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

    function _deployFixture() internal {
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
        SwarmExit.Preview[] memory p = exit.preview(who, _one(token));
        return p[0].expectedImd;
    }
}
