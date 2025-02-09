// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import "forge-std/Test.sol";
import {Pool, TokenWeight, Side} from "src/pool/Pool.sol";
import {PoolAsset, PositionView, PoolLens} from "src/lens/PoolLens.sol";
import {MockOracle} from "test/mocks/MockOracle.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {ILPToken} from "src/interfaces/ILPToken.sol";
import {PoolErrors} from "src/pool/PoolErrors.sol";
import {LPToken} from "src/tokens/LPToken.sol";
import {PoolTestFixture} from "test/Fixture.sol";
import {PoolTokenInfo} from "src/pool/PoolStorage.sol";

/// @dev DAO take all fee. Test Position param only
contract PoolTest is PoolTestFixture {
    address tranche;
    address feeDistributor;

    mapping(address => PoolTokenInfo) public poolTokens;

    function setUp() external {
        build();
        vm.startPrank(owner);

        // Initialize tranche
        tranche = address(new LPToken("LLP", "LLP", address(pool)));
        pool.addTranche(tranche);

        // Initialize feeDistributor with a valid address
        feeDistributor = address(0x1234567890123456789012345678901234567890); // Mock address for testing

        // Set risk factors
        Pool.RiskConfig[] memory config = new Pool.RiskConfig[](1);
        config[0] = Pool.RiskConfig(tranche, 1000);
        pool.setRiskFactor(address(btc), config);
        // pool.setRiskFactor(address(usdc), config);
        pool.setRiskFactor(address(weth), config);

        vm.stopPrank();
    }

    function _beforeTestPosition() internal {
        vm.prank(owner);
        pool.setOrderManager(orderManager);
        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(btc), 20000e22);
        oracle.setPrice(address(weth), 1000e12);
        vm.startPrank(alice);
        btc.mint(10e8);
        usdc.mint(50000e6);
        vm.deal(alice, 100e18);
        vm.stopPrank();
    }

    // ========== ADMIN FUNCTIONS ==========
    function test_fail_set_oracle_from_unauthorized_should_revert() public {
        vm.prank(eve);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.setOracle(address(oracle));
    }

    function test_set_oracle() public {
        vm.prank(owner);
        pool.setOracle(address(oracle));
    }

    // ========== LIQUIDITY PROVIDER ==========

    function test_fail_to_add_liquidity_when_risk_factor_not_set() public {
        MockERC20 tokenA = new MockERC20("tokenA", "TA", 18);
        vm.prank(owner);
        pool.addToken(address(tokenA), false);
        vm.startPrank(alice, alice);
        tokenA.mint(1 ether);
        tokenA.approve(address(router), 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(PoolErrors.AddLiquidityNotAllowed.selector, address(tranche), address(tokenA))
        );
        router.addLiquidity(tranche, address(tokenA), 1 ether, 0, alice);
    }

    function test_add_liquidity_using_not_whitelisted_token() public {
        vm.startPrank(alice, alice);
        btc.approve(address(router), 1000e6);
        vm.expectRevert();
        router.addLiquidity(tranche, address(0), 100e6, 0, alice);
    }

    function test_add_and_remove_liquidity() external {
        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(btc), 20000e22);
        oracle.setPrice(address(weth), 1000e12);
        vm.startPrank(alice);
        vm.deal(alice, 100e18);
        btc.mint(1e8);
        usdc.mint(10000e6);
        btc.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        ILPToken lpToken = ILPToken(tranche);

        // // add more 10k $
        router.addLiquidity(tranche, address(usdc), 10_000e6, 0, address(alice));
        uint256 poolAmount1;
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            assertEq(asset.poolBalance, 10000e6);
            assertEq(asset.poolAmount, 10000e6);
            assertEq(lpToken.balanceOf(address(alice)), 10000e18);
            poolAmount1 = asset.poolAmount;
        }

        //add 1btc = 20k$, receive 20k LP
        router.addLiquidity(tranche, address(btc), 1e8, 0, address(alice));
        console.log("liquidity added 2");
        assertEq(lpToken.balanceOf(address(alice)), 30000e18);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            assertEq(asset.poolBalance, 1e8);
            assertEq(asset.poolAmount, 1e8);
            assertEq(asset.feeReserve, 0);
            assertEq(asset.reservedAmount, 0);
        }

        // eth
        router.addLiquidityETH{value: 10e18}(tranche, 0, address(alice));
        console.log("liquidity added 3");
        // assertEq(pool.getPoolValue(true), 40000e30);
        assertEq(lpToken.balanceOf(address(alice)), 40000e18);

        lpToken.approve(address(router), type(uint256).max);
        router.removeLiquidity(tranche, address(usdc), 1e18, 0, alice);

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log("after remove", asset.poolAmount);
            assertEq(asset.poolAmount, poolAmount1 - 1e6);
        }
        // console.log("check balance");
        // assertEq(usdc.balanceOf(alice), 1e6);
        vm.stopPrank();
    }

    // ============ POSITIONS ==============
    function test_only_order_manager_can_increase_decrease_position() external {
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.OrderManagerOnly.selector));
        pool.increasePosition(alice, address(btc), address(btc), 1e8, Side.LONG);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.OrderManagerOnly.selector));
        pool.decreasePosition(alice, address(btc), address(btc), 1e6, 1e8, Side.LONG, alice);
    }

    function test_set_order_manager() external {
        vm.expectRevert("Ownable: caller is not the owner");
        pool.setOrderManager(alice);
        vm.prank(owner);
        pool.setOrderManager(alice);
        assertEq(pool.orderManager(), alice);
    }

    function test_cannot_long_with_invalid_size() external {
        _beforeTestPosition();
        vm.startPrank(orderManager);
        btc.mint(1e8);
        // cannot open position with size larger than pool amount
        btc.transfer(address(pool), 1e7); // 0.1BTC = 2_000$
        // try to long 10x
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.InsufficientPoolAmount.selector, address(btc)));
        pool.increasePosition(alice, address(btc), address(btc), 20_000e30, Side.LONG);
        vm.stopPrank();
    }

    function test_long_position() external {
        _beforeTestPosition();
        // add liquidity
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 10e8, 0, alice);
        vm.stopPrank();

        vm.startPrank(orderManager);
        btc.mint(1e8);

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            console.log("cumulativeInterestRate", asset.borrowIndex, asset.lastAccrualTimestamp);
            // Check invariant: poolBalance equals poolAmount + feeReserve
            assertEq(asset.poolAmount + asset.feeReserve, asset.poolBalance, "addLiquidity: !invariant");
        }

        // try to open long position with 5x leverage
        vm.warp(1000);
        btc.transfer(address(pool), 1e7); // 0.1BTC = 2,000$

        // == OPEN POSITION ==
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.LONG);
        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.size, 10_000e30);
        assertEq(position.reserveAmount, 5e7);
        // fee = 10_000 * 0.1% = 10$
        // collateral value: ~2000 - fee => 1990 (scaled by 1e30)
        assertEq(position.collateralValue, 1990e30);

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            // At the moment of increase, interest is just initialized.
            assertEq(asset.lastAccrualTimestamp, 1000, "increase: interest not accrued");
            // Instead of expecting 0, the borrow index is set to a base value of 1e30.
            assertEq(asset.borrowIndex, 1e30, "increase: interest not accrued");
            assertEq(asset.poolBalance, btc.balanceOf(address(pool)), "pool balance not update"); // 1BTC deposit + 0.1BTC collateral
            assertEq(asset.feeReserve, 50000, "fee reserve not match");
            assertEq(asset.poolAmount, 1009950000, "pool amount not match");
            assertApproxEqAbs(asset.poolAmount + asset.feeReserve, asset.poolBalance, 1, "increase: !invariant");
            assertEq(asset.reservedAmount, 5e7, "reserved amount not match"); // 0.5BTC = position size
            assertEq(asset.guaranteedValue, 8_010e30, "increase: guaranteed value incorrect");
            assertEq(pool.getTrancheAsset(tranche, address(btc)).reservedAmount, 5e7, "tranche reserve not update");
        }

        // calculate pnl
        oracle.setPrice(address(btc), 20_500e22);
        position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.pnl, 250e30);

        vm.warp(1100);
        uint256 priorBalance = btc.balanceOf(alice);

        // ==== DECREASE PARTIAL ====
        // close 50%, fee = 5 (position) + 0.454566 (funding/interest)
        // profit = 125, transfer out 995$ + 119$ = 0.05434146BTC (values scaled appropriately)
        pool.decreasePosition(alice, address(btc), address(btc), 995e30, 5_000e30, Side.LONG, alice);

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            console.log(asset.poolAmount, asset.feeReserve, asset.poolBalance);
            assertEq(asset.lastAccrualTimestamp, 1100, "interest not accrued");
            // Calculate the raw interest accrued: subtract the base value (1e30)
            uint256 interestAccrued = asset.borrowIndex - 1e30;
            assertEq(interestAccrued, 49507, "interest not accrued"); // 1 interval interest increment
            assertEq(asset.reservedAmount, 25e6, "reserved amount after partial close");
            assertEq(asset.poolBalance, 1004561218, "pool balance not match");
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve, asset.poolBalance, 1, "pool balance and amount not match"
            );
        }

        position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.pnl, 125e30);
        assertEq(position.size, 5_000e30);
        assertEq(position.collateralValue, 995e30);
        {
            uint256 balance = btc.balanceOf(alice);
            uint256 transferOut = balance - priorBalance;
            assertEq(transferOut, 5438782, "partial close transfer amount mismatch");
            priorBalance = balance;
        }

        // == CLOSE ALL POSITION ==
        vm.warp(1200);
        position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        pool.decreasePosition(alice, address(btc), address(btc), 995e30, 5_000e30, Side.LONG, alice);

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            assertEq(asset.guaranteedValue, 0, "guaranteed value not zero after full close");
        }

        position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.size, 0, "position size not zero after full close");
        assertEq(position.collateralValue, 0, "collateral value not zero after full close");
        {
            uint256 balance = btc.balanceOf(alice);
            uint256 transferOut = balance - priorBalance;
            assertEq(transferOut, 5438963, "final close transfer amount mismatch");
            priorBalance = balance;
        }

        vm.stopPrank();
    }

    function test_short_position() external {
        vm.prank(owner);
        pool.setPositionFee(0, 0);
        vm.prank(owner);
        pool.setInterestRate(0, 1);
        _beforeTestPosition();
        // add liquidity
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(usdc), 10000e6, 0, alice);
        uint256 amountToRemove = LPToken(tranche).balanceOf(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 10e8, 0, alice);
        vm.stopPrank();

        vm.startPrank(orderManager);
        // OPEN SHORT position with 5x leverage
        usdc.mint(2000e6);
        usdc.transfer(address(pool), 2000e6); // 0.1BTC = 2_000$
        vm.warp(1000);
        pool.increasePosition(alice, address(btc), address(usdc), 10_000e30, Side.SHORT);

        {
            PositionView memory position =
                lens.getPosition(address(pool), alice, address(btc), address(usdc), Side.SHORT);
            assertEq(position.size, 10_000e30);
            assertEq(position.collateralValue, 2_000e30);
            assertEq(position.reserveAmount, 10_000e6);
        }

        uint256 poolAmountBefore;
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            assertEq(asset.totalShortSize, 10_000e30);
            assertEq(asset.averageShortPrice, 20_000e22);
            poolAmountBefore = asset.poolAmount;
            // test usdc balance
            assertEq(lens.poolAssets(address(pool), address(usdc)).poolBalance, 12000e6);
        }
        // console.log("pool value before", pool.getPoolValue(true));

        // CLOSE position in full
        oracle.setPrice(address(btc), 19500e22);
        uint256 close;
        {
            PositionView memory position =
                lens.getPosition(address(pool), alice, address(btc), address(usdc), Side.SHORT);
            console.log("Pnl", position.pnl);
            console.log("collateral value", position.collateralValue);
            close = position.collateralValue;
        }

        vm.warp(1100);
        uint256 priorBalance = usdc.balanceOf(alice);
        pool.decreasePosition(alice, address(btc), address(usdc), close, 10_000e30, Side.SHORT, alice);
        uint256 transferOut = usdc.balanceOf(alice) - priorBalance;
        console.log("transfer out", transferOut);
        // console.log("pool value after", pool.getPoolValue(true));

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            PositionView memory position =
                lens.getPosition(address(pool), alice, address(btc), address(usdc), Side.SHORT);
            assertEq(position.size, 0);
            assertEq(position.collateralValue, 0);
            assertEq(asset.poolAmount, poolAmountBefore);
        }
        vm.stopPrank();
        // REMOVE liquidity after add
        vm.startPrank(alice);

        uint256 aliceUsdc = usdc.balanceOf(alice);
        LPToken(tranche).approve(address(router), type(uint256).max);
        router.removeLiquidity(tranche, address(usdc), amountToRemove, 0, alice);
        console.log("USDC out", usdc.balanceOf(alice) - aliceUsdc);
        vm.stopPrank();
    }

    // liquidate when maintenance margin not sufficient
    function test_liquidate_position_with_low_maintenance_margin() external {
        _beforeTestPosition();
        // add liquidity
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        vm.stopPrank();

        vm.startPrank(orderManager);
        btc.mint(1e8);
        // try to open long position with 5x leverage
        vm.warp(1000);
        btc.transfer(address(pool), 1e7); // 0.1BTC = 2_000$
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.LONG);
        vm.stopPrank();

        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.size, 10_000e30);
        assertEq(position.reserveAmount, 5e7);
        assertEq(position.collateralValue, 1990e30); // 0.1% fee = 2000 - (20_000 * 0.1%) = 1990

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            assertEq(asset.poolBalance, 110000000, "pool balance not update"); // 1BTC deposit + 0.1BTC collateral
            assertEq(asset.reservedAmount, 5e7); // 0.5BTC = position size
            _checkInvariant(address(btc));
        }

        // calculate pnl
        oracle.setPrice(address(btc), 16190e22);
        position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.pnl, 1905e30);
        assertFalse(position.hasProfit);

        // liquidate position
        // profit = -1905, collateral value = 85, margin rate = 0.85% -> liquidated
        // take 10$ position fee, refund 70$ collateral, pay 5$ to liquidator
        // pool balance = 1.1 - 75/16190
        // vm.startPrank(bob);
        uint256 balance = btc.balanceOf(orderManager);
        vm.startPrank(orderManager);
        pool.liquidatePosition(alice, address(btc), address(btc), Side.LONG);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            assertEq(asset.reservedAmount, 0, "liquidate: reserved not reset");
            assertEq(asset.poolBalance, 109536752, "balance not update after liquidate");
            _checkInvariant(address(btc));
        }
        balance = btc.balanceOf(orderManager) - balance;
        assertEq(balance, 30883, "not transfer out liquidation fee"); // 5$ / 16190
        vm.stopPrank();
    }

    // liquidate too slow, net value far lower than liquidation fee
    // collect all collateral amount, liquidation fee take from pool amount
    function test_liquidate_when_net_value_lower_than_liquidate_fee() external {
        _beforeTestPosition();
        // add liquidity
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        vm.stopPrank();

        vm.startPrank(orderManager);
        btc.mint(1e8);

        // try to open long position with 5x leverage
        vm.warp(1000);
        btc.transfer(address(pool), 1e7); // 0.1BTC = 2_000$
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.LONG);
        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.size, 10_000e30);
        assertEq(position.reserveAmount, 5e7);
        assertEq(position.collateralValue, 1990e30); // 0.1% fee = 2000 - (20_000 * 0.1%) = 1990

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));
            assertEq(asset.poolBalance, 110000000, "pool balance not update"); // 1BTC deposit + 0.1BTC collateral
            assertEq(asset.reservedAmount, 5e7); // 0.5BTC = position size
            _checkInvariant(address(btc));
        }

        // calculate pnl
        oracle.setPrice(address(btc), 16000e22);
        position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.pnl, 2000e30);
        assertFalse(position.hasProfit);
        // collateral = (init + pnl) = 85$ < 0.01 * 10_000
        // charge liquidate fee = 5$, position fee = 10$ transfer remain 70$ to position owner
        // pool balance =
        vm.stopPrank();

        // liquidate position
        // profit = -2000, transfer out liquidation fee
        // pool balance -= 5$ (liquidation fee only)
        uint256 balance = btc.balanceOf(orderManager);
        vm.startPrank(orderManager);
        pool.liquidatePosition(alice, address(btc), address(btc), Side.LONG);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(btc));

            assertEq(asset.reservedAmount, 0, "liquidate: reserve amount reset");
            assertEq(asset.poolBalance, 109968750, "balance not update after liquidate");
            assertApproxEqAbs(
                asset.poolAmount + asset.feeReserve, asset.poolBalance, 1, "pool amount and pool balance miss matched"
            );
        }
        balance = btc.balanceOf(orderManager) - balance;
        assertEq(balance, 31250, "not transfer out liquidation fee"); // 5$ / 16k
        vm.stopPrank();
    }

    function test_liquidate_short_position() external {
        vm.prank(owner);
        pool.setPositionFee(1e7, 5e30);
        _beforeTestPosition();
        // add liquidity
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(usdc), 10000e6, 0, alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 10e8, 0, alice);
        vm.stopPrank();

        vm.startPrank(orderManager);
        usdc.mint(1000e6);

        // try to open long position with 5x leverage
        vm.warp(1000);
        usdc.transfer(address(pool), 1000e6); // 0.1BTC = 2_000$
        pool.increasePosition(alice, address(btc), address(usdc), 10_000e30, Side.SHORT);
        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(usdc), Side.SHORT);
        assertEq(position.size, 10_000e30);
        assertEq(position.reserveAmount, 10_000e6);
        assertEq(position.collateralValue, 990e30); // 0.1% fee = 1000 - (10_000 * 0.1%) = 1990

        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));
            assertEq(asset.reservedAmount, 10_000e6); //
        }

        // calculate pnl
        oracle.setPrice(address(btc), 22_000e22);
        position = lens.getPosition(address(pool), alice, address(btc), address(usdc), Side.SHORT);
        assertEq(position.pnl, 1000e30);
        assertFalse(position.hasProfit);

        vm.stopPrank();

        // liquidate position
        // profit = -1000, transfer out liquidation fee
        vm.startPrank(bob);
        pool.liquidatePosition(alice, address(btc), address(usdc), Side.SHORT);
        {
            PoolAsset memory asset = lens.poolAssets(address(pool), address(usdc));

            assertEq(asset.reservedAmount, 0);
            // balance take all 1000$ collateral, minus 5$ liq fee sent to liquidator
            assertEq(asset.poolBalance, 10995000000, "balance not update after liquidate");
            console.log("feeReserve", asset.feeReserve);
            console.log("poolAmount", asset.poolAmount);
            assertEq(
                asset.poolAmount + asset.feeReserve, asset.poolBalance, "pool amount and pool balance miss matched"
            );
        }
        uint256 balance = usdc.balanceOf(bob);
        assertEq(balance, 5e6, "not transfer out liquidation fee"); // 5$ / 6190
        vm.stopPrank();
    }

    function test_swap() external {
        _beforeTestPosition();

        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(btc), 20000e22);
        oracle.setPrice(address(weth), 1000e12);

        vm.prank(owner);
        pool.setSwapFee(1e7, 1e7, 1e7, 1e7);

        // target weight: 25 eth - 25 btc - 50 usdc
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        usdc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(usdc), 20000e6, 0, alice);
        // current weight: 0eth - 50btc - 50usdc

        {
            vm.expectRevert(abi.encodeWithSelector(PoolErrors.ZeroAmount.selector));
            pool.swap(address(usdc), address(btc), 0, alice, new bytes(0));
        }

        {
            vm.expectRevert(); // SameTokenSwap
            pool.swap(address(btc), address(btc), 0, alice, new bytes(0));
        }

        {
            uint256 output = btc.balanceOf(alice);
            usdc.transfer(address(pool), 1e6);
            (uint256 amountOut,) = pool.calcSwapOutput(address(usdc), address(btc), 1e6);
            pool.swap(address(usdc), address(btc), 0, alice, new bytes(0));
            output = btc.balanceOf(alice) - output;
            assertEq(output, 4995);
            assertEq(amountOut, 4995);
        }
        {
            uint256 output = usdc.balanceOf(alice);
            btc.transfer(address(pool), 5000);
            pool.swap(address(btc), address(usdc), 0, alice, new bytes(0));
            output = usdc.balanceOf(alice) - output;
            assertEq(output, 998000);
            console.log("price", output * 1e8 / 5000);
        }
        {
            /// swap a larger amount
            uint256 output = usdc.balanceOf(alice);
            btc.transfer(address(pool), 5e7);
            pool.swap(address(btc), address(usdc), 0, alice, new bytes(0));
            output = usdc.balanceOf(alice) - output;
            console.log("price", output * 1e8 / 5e7);
        }
        vm.stopPrank();
    }

    function test_set_max_global_short_size() public {
        _beforeTestPosition();

        vm.prank(eve);
        vm.expectRevert();
        pool.setMaxGlobalShortSize(address(btc), 1000e30);

        assertEq(pool.maxGlobalShortSizes(address(btc)), 0, "initial short size should be 0");
        vm.prank(owner);
        // vm.expectEmit(true, false, false, false);
        pool.setMaxGlobalShortSize(address(btc), 1000e30);
        assertEq(pool.maxGlobalShortSizes(address(btc)), 1000e30, "max short size not set properly");

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.NotApplicableForStableCoin.selector));
        pool.setMaxGlobalShortSize(address(usdc), 1000e30);
    }

    function test_max_global_short_size() external {
        vm.startPrank(owner);
        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(btc), 20000e22);
        oracle.setPrice(address(weth), 1000e12);
        vm.stopPrank();
        vm.startPrank(alice);
        usdc.mint(1000e6);
        usdc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(usdc), 1000e6, 0, alice);
        btc.mint(10e8);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 10e8, 0, alice);
        vm.stopPrank();

        test_set_max_global_short_size();
        vm.prank(alice);
        usdc.transfer(address(pool), 100e6); // 100$
        vm.prank(orderManager);
        pool.increasePosition(alice, address(btc), address(usdc), 1_000e30, Side.SHORT);
        vm.prank(alice);
        usdc.transfer(address(pool), 100e6); // 100$
        vm.prank(orderManager);
        vm.expectRevert();
        pool.increasePosition(alice, address(btc), address(usdc), 1_000e30, Side.SHORT);
    }

    function test_max_global_long_size() external {
        vm.startPrank(owner);
        oracle.setPrice(address(usdc), 1e24);
        oracle.setPrice(address(btc), 20000e22);
        oracle.setPrice(address(weth), 1000e12);
        vm.stopPrank();
        vm.startPrank(alice);
        usdc.mint(1000e6);
        btc.mint(2e8);
        usdc.approve(address(router), type(uint256).max);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(usdc), 1000e6, 0, alice);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        vm.stopPrank();

        vm.prank(owner);
        pool.setMaxGlobalLongSizeRatio(address(btc), 5e9); // 50%

        vm.prank(alice);
        btc.transfer(address(pool), 1e6); // 0.01BTC
        vm.prank(orderManager);
        pool.increasePosition(alice, address(btc), address(btc), 2_000e30, Side.LONG);
        vm.prank(alice);
        btc.transfer(address(pool), 1e7); // 100$
        vm.prank(orderManager);
        vm.expectRevert();
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.SHORT);
    }

    function test_create_and_execute_stop_loss_order() external {
        _beforeTestPosition();
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        vm.stopPrank();

        vm.startPrank(orderManager);
        btc.mint(1e8);
        btc.transfer(address(pool), 1e7); // 0.1BTC = 2_000$
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.LONG);

        // Create stop-loss order with alice as the owner
        vm.startPrank(alice); // Use alice's address for order creation
        pool.createStopLossOrder(address(btc), address(btc), 19_000e22, 10_000e30, Side.LONG);
        vm.stopPrank();

        // Trigger stop-loss order
        oracle.setPrice(address(btc), 18_000e22);
        bytes32 key = pool.getOrderKey(alice, address(btc), address(btc), Side.LONG);

        // Switch to OrderManager to execute the stop-loss order
        vm.startPrank(orderManager);
        pool.executeStopLossOrder(key);
        vm.stopPrank();

        // Verify position is closed
        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.size, 0);
    }

    function test_create_and_execute_take_profit_order() external {
        _beforeTestPosition();
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        vm.stopPrank();

        vm.startPrank(orderManager);
        btc.mint(1e8);
        btc.transfer(address(pool), 1e7); // 0.1BTC = 2_000$
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.LONG);
        vm.stopPrank();

        // Create take-profit order with alice as the owner
        vm.startPrank(alice); // Use alice's address for order creation
        pool.createTakeProfitOrder(address(btc), address(btc), 21_000e22, 10_000e30, Side.LONG);
        vm.stopPrank();

        // Trigger take-profit order
        oracle.setPrice(address(btc), 21_500e22); // Price exceeds trigger price
        bytes32 key = pool.getOrderKey(alice, address(btc), address(btc), Side.LONG);

        // Switch to OrderManager to execute the take-profit order
        vm.startPrank(orderManager);
        pool.executeTakeProfitOrder(key);
        vm.stopPrank();

        // Verify position is closed
        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.size, 0);
    }

    function test_create_and_execute_trailing_stop_order() external {
        _beforeTestPosition();

        // Alice adds liquidity
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        vm.stopPrank();

        // Order manager increases Alice's position
        vm.startPrank(orderManager);
        btc.mint(1e8);
        btc.transfer(address(pool), 1e7); // 0.1BTC = 2_000$
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.LONG);
        vm.stopPrank();

        // Alice creates a trailing stop order
        vm.startPrank(alice);
        pool.createTrailingStopOrder(address(btc), address(btc), 500e22, 10_000e30, Side.LONG);
        vm.stopPrank();

        // Update price to trigger trailing stop order
        oracle.setPrice(address(btc), 20_500e22); // Initial price

        // Get the order key (Alice is the owner)
        bytes32 key = pool.getOrderKey(alice, address(btc), address(btc), Side.LONG);
        console.log("Order Key:", uint256(key));

        // Price drops below the trigger price (20_000e22 - 500e22 = 19_500e22)
        oracle.setPrice(address(btc), 19_400e22); // Price drops by 1_100e22

        // Order manager executes the trailing stop order
        vm.startPrank(orderManager);
        pool.executeTrailingStopOrder(key);
        vm.stopPrank();

        // Verify position is closed
        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.size, 0);
    }

    function test_withdraw_fee() external {
        _beforeTestPosition();

        // Set fee distributor using the owner.
        // (Replace the following addresses with the appropriate ones for your test environment.)
        address owner = 0x2E20CFb2f7f98Eb5c9FD31Df41620872C0aef524;
        address feeDist = 0x1234567890123456789012345678901234567890;
        vm.startPrank(owner);
        pool.setFeeDistributor(feeDist);
        vm.stopPrank();

        // Alice adds liquidity.
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        vm.stopPrank();

        // Order manager increases position.
        vm.startPrank(orderManager);
        btc.mint(1e8);
        btc.transfer(address(pool), 1e7); // 0.1 BTC = 2,000$
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.LONG);

        // Accumulate fees.
        vm.warp(1000);
        pool.decreasePosition(alice, address(btc), address(btc), 1e7, 5_000e30, Side.LONG, alice);
        vm.stopPrank();

        // Unauthorized withdrawal should revert (Alice is not the feeDistributor).
        vm.startPrank(alice);
        vm.expectRevert(PoolErrors.FeeDistributorOnly.selector);
        pool.withdrawFee(address(btc), alice);
        vm.stopPrank();

        // Capture the fee reserve before withdrawal.
        PoolTokenInfo memory info = pool.getPoolTokenInfo(address(btc));
        uint256 feeReserve = info.feeReserve;

        // FeeDistributor withdraws fees.
        uint256 beforeBalance = btc.balanceOf(feeDist);
        vm.startPrank(feeDist);
        pool.withdrawFee(address(btc), feeDist);
        vm.stopPrank();
        uint256 afterBalance = btc.balanceOf(feeDist);

        // Assert that the fee distributor's balance increased exactly by the fee reserve.
        assertEq(afterBalance, beforeBalance + feeReserve);
    }

    function test_interest_accrual() external {
        _beforeTestPosition();

        // Set the time to a nonzero value so that the initial call initializes token info with a nonzero timestamp.
        vm.warp(100);

        // Add liquidity (performed by alice)
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        vm.stopPrank();

        // Open an initial position to initialize accruals (performed by orderManager)
        vm.startPrank(orderManager);
        btc.mint(1e8);
        btc.transfer(address(pool), 1e7);
        // This call will invoke _accrueInterest. With block.timestamp = 100,
        // it will set lastAccrualTimestamp = (100/100)*100 = 100 and borrowIndex = BASE (1e30).
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.LONG);

        // Log the initial state
        PoolTokenInfo memory tokenInfoBefore = pool.getPoolTokenInfo(address(btc));
        console.log("Borrow Index Before:", tokenInfoBefore.borrowIndex);
        console.log("Last Accrual Timestamp Before:", tokenInfoBefore.lastAccrualTimestamp);
        console.log("Pool Amount Before:", tokenInfoBefore.poolBalance);
        console.log("Reserved Amount Before:", tokenInfoBefore.feeReserve);

        // Check that the initial borrow index is the expected base value
        uint256 BASE_BORROW_INDEX = 1e30;
        assertEq(tokenInfoBefore.borrowIndex, BASE_BORROW_INDEX, "Initial borrow index should be the base value");
        // We now expect tokenInfoBefore.lastAccrualTimestamp to be 100 (or 0 if rounding gives 0, but here interval is 100)
        // so that later interest can accrue.

        // Advance time to trigger interest accrual.
        // (Now, the elapsed time will be 2000 - 100 = 1900 seconds.)
        vm.warp(2000);
        uint256 borrowIndexBeforeAccrual = pool.getPoolTokenInfo(address(btc)).borrowIndex;

        // Mint and deposit additional collateral so that _getAmountIn returns a nonzero amount.
        btc.mint(1e6);
        btc.transfer(address(pool), 1e6);

        // This second call to increasePosition will trigger _accrueInterest.
        // Now nInterval = (2000 - lastAccrualTimestamp) / accrualInterval = (2000 - 100)/100 = 19.
        pool.increasePosition(alice, address(btc), address(btc), 1e18, Side.LONG);

        uint256 borrowIndexAfter = pool.getPoolTokenInfo(address(btc)).borrowIndex;

        // Log final state for inspection
        PoolTokenInfo memory tokenInfoAfter = pool.getPoolTokenInfo(address(btc));
        console.log("Borrow Index After:", tokenInfoAfter.borrowIndex);
        console.log("Last Accrual Timestamp After:", tokenInfoAfter.lastAccrualTimestamp);
        console.log("Pool Amount After:", tokenInfoAfter.poolBalance);
        console.log("Reserved Amount After:", tokenInfoAfter.feeReserve);

        // Now, since interest should be accrued, we expect the borrow index to have increased.
        assertGt(borrowIndexAfter, borrowIndexBeforeAccrual, "Borrow index should increase after interest accrual");
        vm.stopPrank();
    }

    function test_take_profit_order_not_triggered() external {
        _beforeTestPosition();

        // Add liquidity (performed by alice)
        vm.startPrank(alice);
        btc.approve(address(router), type(uint256).max);
        router.addLiquidity(tranche, address(btc), 1e8, 0, alice);
        vm.stopPrank();

        // Open an initial position (performed by orderManager)
        vm.startPrank(orderManager);
        btc.mint(1e8);
        btc.transfer(address(pool), 1e7); // deposit collateral into pool
        pool.increasePosition(alice, address(btc), address(btc), 10_000e30, Side.LONG);
        vm.stopPrank();

        // Let alice create the take-profit order
        vm.startPrank(alice);
        pool.createTakeProfitOrder(address(btc), address(btc), 21_000e22, 10_000e30, Side.LONG);
        vm.stopPrank();

        // Set the price below the trigger price
        oracle.setPrice(address(btc), 20_500e22); // current price below trigger price

        // Retrieve the order key using alice's address (since she is the order owner)
        bytes32 key = pool.getOrderKey(alice, address(btc), address(btc), Side.LONG);

        // When attempting to execute the order, expect a revert with "Order not triggered"
        vm.startPrank(orderManager);
        vm.expectRevert("Order not triggered");
        pool.executeTakeProfitOrder(key);
        vm.stopPrank();

        // Verify that the position is still open
        PositionView memory position = lens.getPosition(address(pool), alice, address(btc), address(btc), Side.LONG);
        assertEq(position.size, 10_000e30);
    }
}
