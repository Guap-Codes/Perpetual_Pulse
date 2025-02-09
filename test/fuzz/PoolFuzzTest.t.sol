// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {Pool, TokenWeight, Side} from "src/pool/Pool.sol";
import {PoolAsset, PositionView, PoolLens} from "src/lens/PoolLens.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {ILPToken} from "src/interfaces/ILPToken.sol";
import {PoolErrors} from "src/pool/PoolErrors.sol";
import {LPToken} from "src/tokens/LPToken.sol";
import {PoolTestFixture} from "test/Fixture.sol";
import {LiquidityRouter} from "src/pool/LiquidityRouter.sol";

contract PoolFuzzTest is PoolTestFixture {
    address tranche;

    function setUp() external {
        build();
        vm.startPrank(owner);
        tranche = address(new LPToken("LLP", "LLP", address(pool)));
        pool.addTranche(tranche);
        Pool.RiskConfig[] memory config = new Pool.RiskConfig[](1);
        config[0] = Pool.RiskConfig(tranche, 1000);
        pool.setRiskFactor(address(btc), config);
        // pool.setRiskFactor(address(usdc), config);
        pool.setRiskFactor(address(weth), config);
        vm.stopPrank();
        vm.startPrank(owner);
        pool.setPositionFee(1e7, 0);
        pool.setInterestRate(1e5, 1);
        pool.setSwapFee(5e7, 3e7, 1e7, 1e7);
        pool.setAddRemoveLiquidityFee(3e7);
        pool.setDaoFee(2e9);
        vm.stopPrank();
    }

    function _beforeTestPosition() internal {
        vm.prank(owner);
        pool.setOrderManager(orderManager);
        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(btc), 20000e22);
        oracle.setPrice(address(weth), 1000e12);
        vm.startPrank(alice);
        btc.mint(100e8);
        usdc.mint(1_000_000e6);
        vm.deal(alice, 100e18);
        weth.deposit{value: 100e18}();
        usdc.approve(address(router), type(uint256).max);
        btc.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(usdc), 1_000_000e6, 0, alice);
        router.addLiquidity(tranche, address(btc), 100e8, 0, alice);
        router.addLiquidity(tranche, address(weth), 100e18, 0, alice);
        vm.stopPrank();
    }

    function test_fuzz_long_fee(uint256 collateralAmount, int256 priceChange) external {
        uint256 leverage = 10;
        vm.assume(collateralAmount > 0 && priceChange != 0 && collateralAmount < 1e8);
        vm.assume(priceChange < 5 && priceChange > -5);

        _beforeTestPosition();
        uint256 entryPrice = 20_000e22;
        oracle.setPrice(address(btc), entryPrice);

        uint256 size = collateralAmount * entryPrice * leverage;

        // increase position
        vm.startPrank(orderManager);
        btc.mint(collateralAmount);
        btc.transfer(address(pool), collateralAmount); // 0.01BTC
        pool.increasePosition(alice, address(btc), address(btc), size, Side.LONG);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "open: pool_amount + fee_reserve = pool_balance"
            );
        }

        uint256 markPrice = priceChange > 0
            ? entryPrice * (100 + uint256(priceChange)) / 100
            : entryPrice * (100 - uint256(-priceChange)) / 100;

        oracle.setPrice(address(btc), markPrice);
        // close full
        pool.decreasePosition(alice, address(btc), address(btc), type(uint256).max, type(uint256).max, Side.LONG, alice);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "close: pool_amount + fee_reserve = pool_balance"
            );
        }
    }

    function test_fuzz_short_fee(uint256 collateralAmount, int256 priceChange) external {
        // Exclude the minimum int256 value to prevent overflow
        vm.assume(priceChange != type(int256).min);

        uint256 leverage = 10;
        // Constrain collateralAmount to be between (1e6 + 1) and 1e7
        collateralAmount = bound(collateralAmount, 1e6 + 1, 1e7);

        // Constrain priceChange to be between -4 and 4, and force nonzero.
        if (priceChange == 0) {
            priceChange = 1;
        } else {
            // First, bound the absolute value.
            uint256 absPriceChange = uint256(priceChange < 0 ? -priceChange : priceChange);
            absPriceChange = bound(absPriceChange, 1, 4);
            // Restore the sign.
            priceChange = priceChange < 0 ? -int256(absPriceChange) : int256(absPriceChange);
        }

        _beforeTestPosition();
        uint256 entryPrice = 20_000e22;
        oracle.setPrice(address(btc), entryPrice);

        // Compute the position size.
        uint256 size = collateralAmount * 1e24 * leverage;

        // --- Increase Position (SHORT) ---
        vm.startPrank(orderManager);
        usdc.mint(collateralAmount);
        usdc.transfer(address(pool), collateralAmount);

        uint256 initPoolAmount;
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            initPoolAmount = asset.poolAmount;
        }
        pool.increasePosition(alice, address(btc), address(usdc), size, Side.SHORT);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            uint256 expectedFee = size * 1e7 * (1e10 - 2e9) / 1e10 / 1e24 / 1e10;
            assertApproxEqAbs(asset.poolAmount, initPoolAmount + expectedFee, 5, "open: pool_amount += fee");
        }

        // --- Update Price ---
        uint256 markPrice = priceChange > 0
            ? entryPrice * (100 + uint256(priceChange)) / 100
            : entryPrice * (100 - uint256(-priceChange)) / 100;
        oracle.setPrice(address(btc), markPrice);

        // --- Close the Position Fully ---
        pool.decreasePosition(
            alice, address(btc), address(usdc), type(uint256).max, type(uint256).max, Side.SHORT, alice
        );
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log("After close:", asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                5,
                "close: pool_amount + fee_reserve = pool_balance"
            );
        }
        vm.stopPrank();
    }

    function test_fuzz_liquidate_long(uint256 collateralAmount, uint8 priceChange) public {
        uint256 leverage = 10;
        vm.assume(collateralAmount > 0 && priceChange != 0 && collateralAmount < 1e8);
        vm.assume(priceChange >= 9 && priceChange < 100);

        _beforeTestPosition();
        uint256 entryPrice = 20_000e22;
        oracle.setPrice(address(btc), entryPrice);

        uint256 size = collateralAmount * entryPrice * leverage;

        // increase position
        vm.startPrank(orderManager);
        btc.mint(collateralAmount);
        btc.transfer(address(pool), collateralAmount); // 0.01BTC
        pool.increasePosition(alice, address(btc), address(btc), size, Side.LONG);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "open: pool_amount + fee_reserve = pool_balance"
            );
        }

        uint256 markPrice = entryPrice * (100 - uint256(priceChange)) / 100;

        oracle.setPrice(address(btc), markPrice);
        // close full
        pool.liquidatePosition(alice, address(btc), address(btc), Side.LONG);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "close: pool_amount + fee_reserve = pool_balance"
            );
        }
    }

    function test_fuzz_liquidate_short(uint256 collateralAmount, uint8 priceChange) public {
        uint256 leverage = 10;
        // Ensure collateral is in a realistic range and force an adverse move.
        vm.assume(collateralAmount > 1e6 && collateralAmount < 100_000e6 && priceChange != 0);
        // Require at least a 100% adverse move (i.e. markPrice = 2 * entryPrice)
        vm.assume(priceChange >= 100);

        _beforeTestPosition();

        // Set the entry price for the underlying asset (BTC) with proper scaling.
        uint256 entryPrice = 20_000e22; // e.g., 20,000 scaled appropriately
        oracle.setPrice(address(btc), entryPrice);

        // Calculate the notional position size.
        uint256 size = collateralAmount * 1e24 * leverage;

        vm.startPrank(orderManager);

        // The protocol reserves funds equal to: reserve = size / collateralPrice = collateralAmount * leverage.
        // Because adding liquidity via the LiquidityRouter deducts a fee,
        // we add a little extra (here ~0.06%) so that the pool's internal balance (poolAmount)
        // is at least collateralAmount * leverage.
        uint256 baseLiquidity = collateralAmount * leverage;
        uint256 extra = (baseLiquidity * 6) / 10000; // ~0.06% extra
        uint256 requiredLiquidity = baseLiquidity + extra;

        // Deposit the required liquidity into the pool.
        usdc.mint(requiredLiquidity);
        usdc.transfer(address(pool), requiredLiquidity);

        // Record the initial pool asset amount for USDC.
        uint256 initPoolAmount;
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            initPoolAmount = asset.poolAmount;
        }

        // Open the short position.
        pool.increasePosition(alice, address(btc), address(usdc), size, Side.SHORT);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log("pool asset", asset.poolAmount);
            // Verify that poolAmount has increased by the fee amount (as computed in your fee logic).
            assertApproxEqAbs(
                asset.poolAmount,
                initPoolAmount + size * 1e7 * (1e10 - 2e9) / 1e10 / 1e24 / 1e10,
                5,
                "open: pool_amount += fee"
            );
        }

        // Compute an adverse mark price using the fuzzed priceChange.
        // With priceChange >= 100, the markPrice will be at least 2 * entryPrice.
        uint256 markPrice = entryPrice * (100 + uint256(priceChange)) / 100;
        console.log("markPrice", markPrice);
        oracle.setPrice(address(btc), markPrice);

        // Liquidate the position. With a >=100% adverse move, the position should be eligible for liquidation.
        pool.liquidatePosition(alice, address(btc), address(usdc), Side.SHORT);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                5,
                "close: pool_amount + fee_reserve = pool_balance"
            );
        }
        vm.stopPrank();
    }

    function test_fuzz_add_remove_liquidity(uint256 add, uint256 remove) external {
        // Constrain the inputs using bound:
        // For `add`, require it to be at least 10e6 and less than 100_000_000_000e6.
        // For remove, since the original assume was 1 < remove <= 100, we set the lower bound to 2.
        add = bound(add, 10e6, 100_000_000_000e6 - 1);
        remove = bound(remove, 2, 100);

        _beforeTestPosition();
        vm.startPrank(alice);
        IERC20(tranche).approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        usdc.mint(add);
        uint256 before = IERC20(tranche).balanceOf(alice);
        pool.addLiquidity(tranche, address(usdc), add, 0, alice);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log("add liquidity:", asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "add: pool_amount + fee_reserve = pool_balance"
            );
        }
        uint256 lp = IERC20(tranche).balanceOf(alice) - before;
        console.log("LP amount", lp);
        uint256 lpRemove = lp * remove / 100;
        pool.removeLiquidity(tranche, address(usdc), lpRemove, 0, alice);

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log("remove liquidity:", asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "remove: pool_amount + fee_reserve = pool_balance"
            );
        }
        vm.stopPrank();
    }

    function test_fuzz_swap(uint256 amountIn) external {
        vm.assume(10e6 <= amountIn && amountIn < 200_000e6);
        _beforeTestPosition();
        vm.startPrank(alice);
        IERC20(tranche).approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        usdc.mint(amountIn);
        usdc.transfer(address(pool), amountIn);
        uint256 before = btc.balanceOf(alice);
        pool.swap(address(usdc), address(btc), 0, alice, new bytes(0));
        uint256 amountOut = btc.balanceOf(alice) - before;

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "swap: pool_amount + fee_reserve = pool_balance"
            );
        }
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "swap: pool_amount + fee_reserve = pool_balance"
            );
        }

        btc.transfer(address(pool), amountOut);
        pool.swap(address(btc), address(usdc), 0, alice, new bytes(0));

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "swap: pool_amount + fee_reserve = pool_balance"
            );
        }
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            console.log(asset.poolAmount + asset.feeReserve, asset.poolBalance);
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve,
                asset.poolBalance,
                1,
                "swap: pool_amount + fee_reserve = pool_balance"
            );
        }
    }
}
