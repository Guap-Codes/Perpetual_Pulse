// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {Pool} from "src/pool/Pool.sol";
import {IPool, Side} from "src/interfaces/IPool.sol"; // Import Side from IPool
import {ILPToken} from "src/interfaces/ILPToken.sol";
import {LPToken} from "src/tokens/LPToken.sol";
import {ETHUnwrapper} from "src/orders/ETHUnwrapper.sol";
import {PoolTestFixture} from "../Fixture.sol";

contract LiquidityRouterTest is PoolTestFixture {
    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address tranche;

    function setUp() external {
        build();
        vm.startPrank(owner);
        tranche = address(new LPToken("LLP", "LLP", address(pool)));
        pool.addTranche(tranche);
        Pool.RiskConfig[] memory config = new Pool.RiskConfig[](1);
        config[0] = Pool.RiskConfig(tranche, 1000);
        pool.setRiskFactor(address(btc), config);
        pool.setRiskFactor(address(weth), config);
        ETHUnwrapper unwrapper = new ETHUnwrapper(address(weth));
        oracle.setPrice(address(btc), 20_000e22);
        oracle.setPrice(address(weth), 1000e12);
        vm.stopPrank();
    }

    function test_add_liquidity() external {
        vm.startPrank(alice);
        btc.mint(10e8);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tranche), address(btc), 1e8, 0, alice);
        assertEq(btc.balanceOf(address(alice)), 9e8);
    }

    function test_add_liquidity_eth() external {
        vm.startPrank(alice);
        vm.deal(alice, 100e18);
        router.addLiquidityETH{value: 20e18}(address(tranche), 0, alice);
        assertEq(alice.balance, 80e18);
    }

    function test_remove_liquidity() external {
        vm.startPrank(alice);
        btc.mint(10e8);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(address(tranche), address(btc), 1e8, 0, alice);
        assertEq(btc.balanceOf(address(alice)), 9e8);

        ILPToken(tranche).approve(address(router), type(uint256).max);
        router.removeLiquidity(tranche, address(btc), ILPToken(tranche).balanceOf(alice), 0, alice);
        assertEq(btc.balanceOf(address(alice)), 10e8);
    }

    function test_remove_liquidity_eth() external {
        vm.startPrank(alice);
        vm.deal(alice, 100e18);
        router.addLiquidityETH{value: 20e18}(address(tranche), 0, alice);
        assertEq(alice.balance, 80e18);

        ILPToken(tranche).approve(address(router), type(uint256).max);
        router.removeLiquidityETH(tranche, ILPToken(tranche).balanceOf(alice), 0, payable(alice));
        assertEq(alice.balance, 100e18);
    }

    function test_add_liquidity_with_stop_loss() external {
        // Start as Alice.
        vm.startPrank(alice);

        // Mint tokens for Alice and record her initial balance.
        btc.mint(10e8);
        uint256 aliceInitialBalance = btc.balanceOf(alice);
        console.log("Alice initial balance:", aliceInitialBalance);

        // Approve the router to spend Alice's tokens.
        btc.approve(address(router), type(uint256).max);

        // Optionally, if the router’s stop‑loss order creation logic requires the router to hold tokens,
        // pre-fund the router with the _amountIn_ (here, 1e8 tokens):
        btc.transfer(address(router), 1e8);

        // Call addLiquidityWithStopLoss.
        router.addLiquidityWithStopLoss(
            address(tranche),
            address(btc),
            1e8, // _amountIn_
            0, // _minLpAmount_
            alice, // _to
            19_000e22, // trigger price
            Side.LONG // side
        );

        // Check that Alice's balance has been reduced by 1e8.
        uint256 aliceFinalBalance = btc.balanceOf(alice);
        console.log("Alice final balance:", aliceFinalBalance);
        assertEq(
            aliceFinalBalance, aliceInitialBalance - 1e8, "Alice's balance should be reduced by the liquidity input"
        );

        vm.stopPrank();
    }

    function test_add_liquidity_with_take_profit() external {
        vm.startPrank(alice);
        btc.mint(10e8);
        btc.approve(address(router), type(uint256).max);
        // Pre-fund the router with the amount that will be used in the order creation.
        // This prevents the ERC20 transfer failure.
        btc.transfer(address(router), 1e8);

        router.addLiquidityWithTakeProfit(
            address(tranche),
            address(btc),
            1e8, // _amountIn
            0, // _minLpAmount
            alice, // recipient of LP tokens
            21_000e22, // take-profit trigger price
            Side.LONG // position side
        );
        // After spending 1e8 tokens, Alice's balance should have decreased by that amount.
        assertEq(btc.balanceOf(address(alice)), 9e8);
        vm.stopPrank();
    }
}
