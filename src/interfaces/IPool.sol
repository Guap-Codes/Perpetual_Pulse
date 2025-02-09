// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {SignedInt} from "../lib/SignedInt.sol";

/**
 * @title Side
 * @dev Enum representing the position side (LONG or SHORT).
 */
enum Side {
    LONG,
    SHORT
}

/**
 * @title TokenWeight
 * @dev Represents the weight of a token in a pool.
 * @param token The address of the token.
 * @param weight The weight of the token.
 */
struct TokenWeight {
    address token;
    uint256 weight;
}

/**
 * @title IPool
 * @dev Interface for a pool contract that manages positions, liquidity, and orders.
 */
interface IPool {
    /**
     * @dev Increases a position for a given account.
     * @param _account The address of the account.
     * @param _indexToken The index token for the position.
     * @param _collateralToken The collateral token for the position.
     * @param _sizeChanged The change in size of the position.
     * @param _side The side of the position (LONG or SHORT).
     */
    function increasePosition(
        address _account,
        address _indexToken,
        address _collateralToken,
        uint256 _sizeChanged,
        Side _side
    ) external;

    /**
     * @dev Decreases a position for a given account.
     * @param _account The address of the account.
     * @param _indexToken The index token for the position.
     * @param _collateralToken The collateral token for the position.
     * @param _desiredCollateralReduce The desired amount of collateral to reduce.
     * @param _sizeChanged The change in size of the position.
     * @param _side The side of the position (LONG or SHORT).
     * @param _receiver The address to receive the collateral.
     */
    function decreasePosition(
        address _account,
        address _indexToken,
        address _collateralToken,
        uint256 _desiredCollateralReduce,
        uint256 _sizeChanged,
        Side _side,
        address _receiver
    ) external;

    /**
     * @dev Liquidates a position for a given account.
     * @param _account The address of the account.
     * @param _indexToken The index token for the position.
     * @param _collateralToken The collateral token for the position.
     * @param _side The side of the position (LONG or SHORT).
     */
    function liquidatePosition(address _account, address _indexToken, address _collateralToken, Side _side) external;

    /**
     * @dev Validates a token pair for a position.
     * @param indexToken The index token.
     * @param collateralToken The collateral token.
     * @param side The side of the position (LONG or SHORT).
     * @param isIncrease Whether the position is being increased.
     * @return bool Whether the token pair is valid.
     */
    function validateToken(address indexToken, address collateralToken, Side side, bool isIncrease)
        external
        view
        returns (bool);

    /**
     * @dev Swaps tokens in the pool.
     * @param _tokenIn The token to swap from.
     * @param _tokenOut The token to swap to.
     * @param _minOut The minimum amount of `_tokenOut` to receive.
     * @param _to The address to receive the swapped tokens.
     * @param extradata Additional data for the swap.
     */
    function swap(address _tokenIn, address _tokenOut, uint256 _minOut, address _to, bytes calldata extradata)
        external;

    /**
     * @dev Adds liquidity to the pool.
     * @param _tranche The tranche to add liquidity to.
     * @param _token The token to add as liquidity.
     * @param _amountIn The amount of tokens to add.
     * @param _minLpAmount The minimum amount of LP tokens to receive.
     * @param _to The address to receive the LP tokens.
     */
    function addLiquidity(address _tranche, address _token, uint256 _amountIn, uint256 _minLpAmount, address _to)
        external;

    /**
     * @dev Removes liquidity from the pool.
     * @param _tranche The tranche to remove liquidity from.
     * @param _tokenOut The token to receive after removing liquidity.
     * @param _lpAmount The amount of LP tokens to remove.
     * @param _minOut The minimum amount of `_tokenOut` to receive.
     * @param _to The address to receive the tokens.
     */
    function removeLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to)
        external;

    /**
     * @dev Creates a stop-loss order.
     * @param _indexToken The index token for the order.
     * @param _collateralToken The collateral token for the order.
     * @param _triggerPrice The trigger price for the order.
     * @param _size The size of the order.
     * @param _side The side of the order (LONG or SHORT).
     */
    function createStopLossOrder(
        address _indexToken,
        address _collateralToken,
        uint256 _triggerPrice,
        uint256 _size,
        Side _side
    ) external;

    /**
     * @dev Creates a take-profit order.
     * @param _indexToken The index token for the order.
     * @param _collateralToken The collateral token for the order.
     * @param _triggerPrice The trigger price for the order.
     * @param _size The size of the order.
     * @param _side The side of the order (LONG or SHORT).
     */
    function createTakeProfitOrder(
        address _indexToken,
        address _collateralToken,
        uint256 _triggerPrice,
        uint256 _size,
        Side _side
    ) external;

    /**
     * @dev Creates a trailing-stop order.
     * @param _indexToken The index token for the order.
     * @param _collateralToken The collateral token for the order.
     * @param _trailingDelta The trailing delta for the order.
     * @param _size The size of the order.
     * @param _side The side of the order (LONG or SHORT).
     */
    function createTrailingStopOrder(
        address _indexToken,
        address _collateralToken,
        uint256 _trailingDelta,
        uint256 _size,
        Side _side
    ) external;

    /**
     * @dev Executes a stop-loss order.
     * @param _key The key (ID) of the stop-loss order.
     */
    function executeStopLossOrder(bytes32 _key) external;

    /**
     * @dev Executes a take-profit order.
     * @param _key The key (ID) of the take-profit order.
     */
    function executeTakeProfitOrder(bytes32 _key) external;

    /**
     * @dev Executes a trailing-stop order.
     * @param _key The key (ID) of the trailing-stop order.
     */
    function executeTrailingStopOrder(bytes32 _key) external;

    // =========== EVENTS ===========

    /**
     * @dev Emitted when the order manager is set.
     */
    event SetOrderManager(address indexed orderManager);

    /**
     * @dev Emitted when a position is increased.
     */
    event IncreasePosition(
        bytes32 indexed key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralValue,
        uint256 sizeChanged,
        Side side,
        uint256 indexPrice,
        uint256 feeValue
    );

    /**
     * @dev Emitted when a position is updated.
     */
    event UpdatePosition(
        bytes32 indexed key,
        uint256 size,
        uint256 collateralValue,
        uint256 entryPrice,
        uint256 entryInterestRate,
        uint256 reserveAmount,
        uint256 indexPrice
    );

    /**
     * @dev Emitted when a position is decreased.
     */
    event DecreasePosition(
        bytes32 indexed key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralChanged,
        uint256 sizeChanged,
        Side side,
        uint256 indexPrice,
        SignedInt pnl,
        uint256 feeValue
    );

    /**
     * @dev Emitted when a position is closed.
     */
    event ClosePosition(
        bytes32 indexed key,
        uint256 size,
        uint256 collateralValue,
        uint256 entryPrice,
        uint256 entryInterestRate,
        uint256 reserveAmount
    );

    /**
     * @dev Emitted when a position is liquidated.
     */
    event LiquidatePosition(
        bytes32 indexed key,
        address account,
        address collateralToken,
        address indexToken,
        Side side,
        uint256 size,
        uint256 collateralValue,
        uint256 reserveAmount,
        uint256 indexPrice,
        SignedInt pnl,
        uint256 feeValue
    );

    /**
     * @dev Emitted when DAO fees are withdrawn.
     */
    event DaoFeeWithdrawn(address indexed token, address recipient, uint256 amount);

    /**
     * @dev Emitted when DAO fees are reduced.
     */
    event DaoFeeReduced(address indexed token, uint256 amount);

    /**
     * @dev Emitted when the fee distributor is set.
     */
    event FeeDistributorSet(address indexed feeDistributor);

    /**
     * @dev Emitted when liquidity is added to the pool.
     */
    event LiquidityAdded(
        address indexed tranche, address indexed sender, address token, uint256 amount, uint256 lpAmount, uint256 fee
    );

    /**
     * @dev Emitted when liquidity is removed from the pool.
     */
    event LiquidityRemoved(
        address indexed tranche, address indexed sender, address token, uint256 lpAmount, uint256 amountOut, uint256 fee
    );

    /**
     * @dev Emitted when token weights are set.
     */
    event TokenWeightSet(TokenWeight[]);

    /**
     * @dev Emitted when a swap occurs.
     */
    event Swap(
        address indexed sender, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 fee
    );

    /**
     * @dev Emitted when position fees are set.
     */
    event PositionFeeSet(uint256 positionFee, uint256 liquidationFee);

    /**
     * @dev Emitted when DAO fees are set.
     */
    event DaoFeeSet(uint256 value);

    /**
     * @dev Emitted when swap fees are set.
     */
    event SwapFeeSet(
        uint256 baseSwapFee, uint256 taxBasisPoint, uint256 stableCoinBaseSwapFee, uint256 stableCoinTaxBasisPoint
    );

    /**
     * @dev Emitted when interest is accrued.
     */
    event InterestAccrued(address indexed token, uint256 borrowIndex);

    /**
     * @dev Emitted when the maximum leverage is changed.
     */
    event MaxLeverageChanged(uint256 maxLeverage);

    /**
     * @dev Emitted when a token is whitelisted.
     */
    event TokenWhitelisted(address indexed token);

    /**
     * @dev Emitted when a token is delisted.
     */
    event TokenDelisted(address indexed token);

    /**
     * @dev Emitted when the oracle is changed.
     */
    event OracleChanged(address indexed oldOracle, address indexed newOracle);

    /**
     * @dev Emitted when the interest rate is set.
     */
    event InterestRateSet(uint256 interestRate, uint256 interval);

    /**
     * @dev Emitted when the maximum position size is set.
     */
    event MaxPositionSizeSet(uint256 maxPositionSize);

    /**
     * @dev Emitted when the pool hook is changed.
     */
    event PoolHookChanged(address indexed hook);

    /**
     * @dev Emitted when a tranche is added.
     */
    event TrancheAdded(address indexed lpToken);

    /**
     * @dev Emitted when a token's risk factor is updated.
     */
    event TokenRiskFactorUpdated(address indexed token);

    /**
     * @dev Emitted when profit or loss is distributed.
     */
    event PnLDistributed(address indexed asset, address indexed tranche, uint256 amount, bool hasProfit);

    /**
     * @dev Emitted when the maintenance margin is changed.
     */
    event MaintenanceMarginChanged(uint256 ratio);

    /**
     * @dev Emitted when the add/remove liquidity fee is set.
     */
    event AddRemoveLiquidityFeeSet(uint256 value);

    /**
     * @dev Emitted when the maximum global short size is set.
     */
    event MaxGlobalShortSizeSet(address indexed token, uint256 max);

    /**
     * @dev Emitted when the maximum global long size ratio is set.
     */
    event MaxGlobalLongSizeRatioSet(address indexed token, uint256 max);

    /**
     * @dev Emitted when a stop-loss order is created.
     */
    event StopLossOrderCreated(
        bytes32 indexed key,
        address indexed owner,
        address indexToken,
        address collateralToken,
        uint256 triggerPrice,
        uint256 size,
        Side side
    );

    /**
     * @dev Emitted when a take-profit order is created.
     */
    event TakeProfitOrderCreated(
        bytes32 indexed key,
        address indexed owner,
        address indexToken,
        address collateralToken,
        uint256 triggerPrice,
        uint256 size,
        Side side
    );

    /**
     * @dev Emitted when a trailing-stop order is created.
     */
    event TrailingStopOrderCreated(
        bytes32 indexed key,
        address indexed owner,
        address indexToken,
        address collateralToken,
        uint256 trailingDelta,
        uint256 size,
        Side side
    );

    /**
     * @dev Emitted when a stop-loss order is executed.
     */
    event StopLossOrderExecuted(
        bytes32 indexed key,
        address indexed owner,
        address indexToken,
        address collateralToken,
        uint256 triggerPrice,
        uint256 size,
        Side side
    );

    /**
     * @dev Emitted when a take-profit order is executed.
     */
    event TakeProfitOrderExecuted(
        bytes32 indexed key,
        address indexed owner,
        address indexToken,
        address collateralToken,
        uint256 triggerPrice,
        uint256 size,
        Side side
    );

    /**
     * @dev Emitted when a trailing-stop order is executed.
     */
    event TrailingStopOrderExecuted(
        bytes32 indexed key,
        address indexed owner,
        address indexToken,
        address collateralToken,
        uint256 trailingDelta,
        uint256 size,
        Side side
    );
}