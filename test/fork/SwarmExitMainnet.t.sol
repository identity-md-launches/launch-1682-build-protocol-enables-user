// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwarmExit} from "../../src/SwarmExit.sol";

/// @notice End-to-end rehearsal against the live SwarmExit on an Ethereum mainnet fork: the owner
/// registers real swarm-launched tokens with their Uniswap v4 pools, the launch owner's wallet
/// (0x0acE…4782, which holds 44 swarm tokens) sells them, and the IMD split is asserted.
///
/// Skipped unless MAINNET_RPC_URL is set:
///   MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-contract SwarmExitMainnet -vv
///
/// Chain facts below come from .imd/reads/deployment.json, .imd/reads/network.json and reads of the
/// launch factory (positionOf) on 2026-10-15; see README "Swarm token discovery".
contract SwarmExitMainnetTest is Test {
    SwarmExit constant EXIT = SwarmExit(payable(0x5c3c2A6d7d340dB9F8b3e0CBBc8DBbb7Ec73bC61));
    address constant OWNER = 0x0acE1DBE8AAb293cd58D5e3Ea38814f0ccb74782;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant TREASURY = 0xFC3ad9C531e1736690b2d5f24FebD35ebf051cFB;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant SWARM_HOOK = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // Launch 1609 PLEA: the one held token whose pool holds IMD on 2026-10-15 (Uniswap v4 Quoter).
    address constant PLEA = 0xB3ca44F083d49f0864412141bF5382E4248795Bd;
    // Launch 1422 NECTAR and launch 1403 COMB: single-sided launch positions nobody has bought from,
    // so a sale finds no IMD (the v4 Quoter reverts NotEnoughLiquidity); expected unsellable.
    address constant NECTAR = 0x462bC29829dCe787E3C8b32f5C032a49234F0E2b;
    address constant COMB = 0x8A4D48595c25B69C98a143CA502BDB46f8edF2a7;

    bool forked;

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        forked = true;
    }

    function _hop(address out, uint24 fee, int24 spacing, address hooks) internal pure returns (SwarmExit.V4Hop[] memory h) {
        h = new SwarmExit.V4Hop[](1);
        h[0] = SwarmExit.V4Hop({currencyOut: out, fee: fee, tickSpacing: spacing, hooks: hooks});
    }

    function _register(address token) internal {
        vm.startPrank(OWNER);
        EXIT.setSwarmToken(token, true);
        EXIT.setTokenRoute(token, SwarmExit.Venue.UniswapV4, POOL_MANAGER, address(0), abi.encode(token, _hop(IMD, 12500, 60, SWARM_HOOK)));
        vm.stopPrank();
    }

    function _configure() internal {
        vm.startPrank(OWNER);
        // ETH/IMD 1% pool (fee 10000, spacing 200, no hook): the only ETH/IMD v4 pool with liquidity.
        EXIT.setImdRoute(SwarmExit.Venue.UniswapV4, POOL_MANAGER, address(0), abi.encode(address(0), _hop(IMD, 10000, 200, address(0))));
        EXIT.setEthUsdFeed(CHAINLINK_ETH_USD);
        vm.stopPrank();
    }

    function test_liveContractIsUnconfigured() public view {
        if (!forked) return;
        assertEq(EXIT.owner(), OWNER, "owner");
        assertEq(EXIT.swarmTokenCount(), 0, "no tokens registered on the live contract");
        assertEq(address(EXIT.ethUsdFeed()), address(0), "no feed");
        assertEq(uint8(EXIT.imdRoute().venue), uint8(SwarmExit.Venue.None), "no IMD route");
    }

    struct Snap {
        uint256 userImd;
        uint256 treasury;
        uint256 plea;
        uint256 nectar;
        uint256 comb;
    }

    function _snap() internal view returns (Snap memory s) {
        s.userImd = IERC20(IMD).balanceOf(OWNER);
        s.treasury = IERC20(IMD).balanceOf(TREASURY);
        s.plea = IERC20(PLEA).balanceOf(OWNER);
        s.nectar = IERC20(NECTAR).balanceOf(OWNER);
        s.comb = IERC20(COMB).balanceOf(OWNER);
    }

    function _tokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = PLEA;
        tokens[1] = NECTAR;
        tokens[2] = COMB;
    }

    function _checkPreviews(address[] memory tokens) internal returns (uint256 pleaQuote) {
        SwarmExit.Preview[] memory previews = EXIT.preview(OWNER, tokens);
        for (uint256 i; i < previews.length; ++i) {
            emit log_named_uint("status", uint256(previews[i].status));
            emit log_named_decimal_uint("expectedImd", previews[i].expectedImd, 18);
        }
        assertTrue(previews[0].sellable, "PLEA sellable");
        assertFalse(previews[1].sellable, "NECTAR not sellable: no IMD in its pool");
        assertFalse(previews[2].sellable, "COMB not sellable: no IMD in its pool");
        assertEq(uint8(previews[1].status), uint8(SwarmExit.Status.QuoteFailed), "NECTAR quote fails");
        assertEq(uint8(previews[2].status), uint8(SwarmExit.Status.QuoteFailed), "COMB quote fails");
        assertGt(previews[0].expectedImd, 0, "PLEA quote");
        pleaQuote = previews[0].expectedImd;
    }

    function _checkPricing() internal {
        (uint256 price, uint8 dec) = EXIT.ethUsdPrice();
        assertGt(price, 0, "chainlink price");
        assertEq(dec, 8, "chainlink decimals");
        uint256 ethPerImd = EXIT.quoteImdInBridge(1e18);
        assertGt(ethPerImd, 0, "IMD priced in ETH");
        emit log_named_decimal_uint("ETH per IMD", ethPerImd, 18);
    }

    function test_sellAllRealTokensSplitsImdTwoPercentToTreasury() public {
        if (!forked) return;
        _configure();
        _register(PLEA);
        _register(NECTAR);
        _register(COMB);
        address[] memory tokens = _tokens();
        uint256 pleaQuote = _checkPreviews(tokens);
        _checkPricing();
        Snap memory before = _snap();

        uint256[] memory mins = new uint256[](3);
        mins[0] = (pleaQuote * 97) / 100; // the site's 3% slippage
        vm.startPrank(OWNER);
        IERC20(PLEA).approve(address(EXIT), before.plea);
        IERC20(NECTAR).approve(address(EXIT), before.nectar);
        IERC20(COMB).approve(address(EXIT), before.comb);
        (SwarmExit.Outcome[] memory outcomes, uint256 gross, uint256 tax, uint256 net) =
            EXIT.sellAll(tokens, mins, block.timestamp + 600);
        vm.stopPrank();
        Snap memory after_ = _snap();

        assertEq(uint8(outcomes[0].status), uint8(SwarmExit.Status.Sold), "PLEA sold");
        assertEq(uint8(outcomes[1].status), uint8(SwarmExit.Status.QuoteFailed), "NECTAR skipped before the pull");
        assertEq(uint8(outcomes[2].status), uint8(SwarmExit.Status.QuoteFailed), "COMB skipped before the pull");
        assertEq(outcomes[1].amountIn, 0, "NECTAR never pulled");
        assertEq(after_.nectar, before.nectar, "NECTAR stays in the wallet");
        assertEq(after_.comb, before.comb, "COMB stays in the wallet");
        assertEq(after_.plea, 0, "PLEA fully sold");
        assertEq(outcomes[0].amountIn, before.plea, "whole PLEA balance sold");
        assertGe(outcomes[0].imdOut, mins[0], "PLEA proceeds respect the minimum");
        assertEq(gross, outcomes[0].imdOut, "one cumulative IMD amount");
        assertEq(tax, (gross * 200) / 10_000, "tax is 2% of gross");
        assertEq(net, gross - tax, "net is the rest");
        assertEq(after_.treasury - before.treasury, tax, "treasury received the fee");
        assertEq(after_.userImd - before.userImd, net, "user received the net IMD");
        assertEq(IERC20(IMD).balanceOf(address(EXIT)), 0, "no IMD rests in the contract");
        assertEq(IERC20(PLEA).balanceOf(address(EXIT)), 0, "no tokens rest in the contract");
        assertEq(address(EXIT).balance, 0, "no ETH rests in the contract");
        emit log_named_decimal_uint("gross IMD", gross, 18);
        emit log_named_decimal_uint("tax IMD", tax, 18);
        emit log_named_decimal_uint("net IMD", net, 18);
    }

    function test_saleBelowMinimumIsSkippedNotPulled() public {
        if (!forked) return;
        _configure();
        _register(PLEA);
        address[] memory tokens = new address[](1);
        tokens[0] = PLEA;
        uint256[] memory mins = new uint256[](1);
        mins[0] = type(uint256).max; // impossible floor: the quote is below it, so the token is skipped
        uint256 before = IERC20(PLEA).balanceOf(OWNER);
        vm.startPrank(OWNER);
        IERC20(PLEA).approve(address(EXIT), before);
        vm.expectRevert(SwarmExit.NothingSold.selector);
        EXIT.sellAll(tokens, mins, block.timestamp + 600);
        vm.stopPrank();
        assertEq(IERC20(PLEA).balanceOf(OWNER), before, "nothing moved");
    }
}
