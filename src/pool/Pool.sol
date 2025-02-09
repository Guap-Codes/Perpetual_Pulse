// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {OwnableUpgradeable} from "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "openzeppelin/interfaces/IERC20Metadata.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {Initializable} from "openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {SignedIntOps} from "../lib/SignedInt.sol";
import {MathUtils} from "../lib/MathUtils.sol";
import {PositionUtils} from "../lib/PositionUtils.sol";
import {IPulseOracle} from "../interfaces/IPulseOracle.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {IPool, Side, TokenWeight} from "../interfaces/IPool.sol";
import {
    PoolStorage,
    Position,
    PoolTokenInfo,
    Fee,
    AssetInfo,
    PRECISION,
    LP_INITIAL_PRICE,
    MAX_BASE_SWAP_FEE,
    MAX_TAX_BASIS_POINT,
    MAX_POSITION_FEE,
    MAX_LIQUIDATION_FEE,
    MAX_INTEREST_RATE,
    MAX_ASSETS,
    MAX_MAINTENANCE_MARGIN
} from "./PoolStorage.sol";
import {PoolErrors} from "./PoolErrors.sol";
import {IPoolHook} from "../interfaces/IPoolHook.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import "forge-std/console.sol";

uint256 constant USD_VALUE_DECIMAL = 30;

/// @dev Struct to hold variables related to increasing a position in the liquidity pool.
/// This struct is used during the process of increasing a user's position, capturing all necessary
/// information to compute fees, collateral adjustments, and other relevant metrics.
struct IncreasePositionVars {
    uint256 reserveAdded;
    /// @notice Amount of reserve added to the position.
    uint256 collateralAmount;
    /// @notice Total amount of collateral involved in the position.
    uint256 collateralValueAdded;
    /// @notice Value of the collateral added to the position.
    uint256 feeValue;
    /// @notice Total fee value incurred during the position increase.
    uint256 daoFee;
    /// @notice Fee allocated to the DAO for managing the pool.
    uint256 indexPrice;
    /// @notice Price of the index token at the time of the position increase.
    uint256 sizeChanged;
    /// @notice Change in size of the position after the increase.
    uint256 feeAmount;
    /// @notice Amount of fees to be paid for the transaction.
    uint256 totalLpFee;
}
/// @notice Total liquidity provider fee associated with the position increase.

/// @notice common variable used accross decrease process
struct DecreasePositionVars {
    /// @notice santinized input: collateral value able to be withdraw
    uint256 collateralReduced;
    /// @notice santinized input: position size to decrease, capped to position's size
    uint256 sizeChanged;
    /// @notice current price of index
    uint256 indexPrice;
    /// @notice current price of collateral
    uint256 collateralPrice;
    /// @notice postion's remaining collateral value in USD after decrease position
    uint256 remainingCollateral;
    /// @notice reserve reduced due to reducion process
    uint256 reserveReduced;
    /// @notice total value of fee to be collect (include dao fee and LP fee)
    uint256 feeValue;
    /// @notice amount of collateral taken as fee
    uint256 daoFee;
    /// @notice real transfer out amount to user
    uint256 payout;
    /// @notice 'net' PnL (fee not counted)
    int256 pnl;
    int256 poolAmountReduced;
    uint256 totalLpFee;
}

/// @dev Struct to represent a stop-loss order in the liquidity pool.
/// A stop-loss order is a conditional order that triggers when the price of the index token reaches a specified trigger price.
/// This struct holds all necessary information to manage and execute stop-loss orders for users.
struct StopLossOrder {
    address owner;
    /// @notice The address of the user who owns the stop-loss order.
    address indexToken;
    /// @notice The address of the index token associated with the stop-loss order.
    address collateralToken;
    /// @notice The address of the collateral token used for the order.
    uint256 triggerPrice;
    /// @notice The price at which the stop-loss order will be triggered.
    uint256 size;
    /// @notice The size of the position to be liquidated when the trigger price is reached.
    Side side;
    /// @notice The side of the order (buy/sell) represented by the `Side` enum.
    bool isExecuted;
}
/// @notice A flag indicating whether the stop-loss order has been executed.

/// @dev Struct to represent a take-profit order in the liquidity pool.
/// A take-profit order is a conditional order that triggers when the price of the index token reaches a specified trigger price.
/// This struct holds all necessary information to manage and execute take-profit orders for users.
struct TakeProfitOrder {
    address owner;
    /// @notice The address of the user who owns the take-profit order.
    address indexToken;
    /// @notice The address of the index token associated with the take-profit order.
    address collateralToken;
    /// @notice The address of the collateral token used for the order.
    uint256 triggerPrice;
    /// @notice The price at which the take-profit order will be triggered.
    uint256 size;
    /// @notice The size of the position to be liquidated when the trigger price is reached.
    Side side;
    /// @notice The side of the order (buy/sell) represented by the `Side` enum.
    bool isExecuted;
}
/// @notice A flag indicating whether the take-profit order has been executed.

/// @dev Struct to represent a trailing stop order in the liquidity pool.
/// A trailing stop order is a conditional order that triggers when the price of the index token reaches a specified trailing delta.
/// This struct holds all necessary information to manage and execute trailing stop orders for users.
struct TrailingStopOrder {
    address owner;
    /// @notice The address of the user who owns the trailing stop order.
    address indexToken;
    /// @notice The address of the index token associated with the trailing stop order.
    address collateralToken;
    /// @notice The address of the collateral token used for the order.
    uint256 trailingDelta;
    /// @notice The trailing delta value for the trailing stop order.
    uint256 size;
    /// @notice The size of the position to be liquidated when the trailing delta is reached.
    Side side;
    /// @notice The side of the order (buy/sell) represented by the `Side` enum.
    uint256 lastPrice;
    /// @notice The last price at which the trailing stop order was triggered.
    bool isExecuted;
}
/// @notice A flag indicating whether the trailing stop order has been executed.

/// @title Pool Contract
/// @notice This contract manages a liquidity pool for decentralized finance (DeFi) applications.
/// It allows users to deposit, withdraw, and manage their positions in various tokens while accruing interest.
/// The contract also implements risk management features and handles order execution for users.
contract Pool is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PoolStorage, IPool {
    using SignedIntOps for int256;
    /// @notice This library provides signed integer operations for both positive and negative numbers.
    using SafeERC20 for IERC20;
    /// @notice This library provides a safe ERC-20 token standard.
    using SafeCast for uint256;
    /// @notice This library provides a safe casting operation for unsigned integers.
    using SafeCast for int256;
    /// @notice This library provides a safe casting operation for signed integers.

    // advanced feature mappings
    /// @dev Mapping to store stop-loss orders by a unique key.
    /// The key is typically derived from the user's address and the token involved.
    /// Each entry in this mapping corresponds to a specific stop-loss order, allowing for efficient retrieval and management.
    mapping(bytes32 => StopLossOrder) public stopLossOrders;

    /// @dev Mapping to store take-profit orders by a unique key.
    /// Similar to stop-loss orders, the key is derived from the user's address and the token involved.
    /// Each entry in this mapping corresponds to a specific take-profit order, facilitating easy access and execution.
    mapping(bytes32 => TakeProfitOrder) public takeProfitOrders;

    /// @dev Mapping to store trailing stop orders by a unique key.
    /// This mapping allows for the management of trailing stop orders, which adjust dynamically based on market conditions.
    /// Each entry corresponds to a specific trailing stop order, enabling efficient tracking and execution.
    mapping(bytes32 => TrailingStopOrder) public trailingStopOrders;

    /* =========== MODIFIERS ========== */
    /// @dev Modifier that restricts function access to only the order manager.
    /// This ensures that only authorized entities can manage orders within the liquidity pool.
    modifier onlyOrderManager() {
        _requireOrderManager();
        _;
    }

    /// @dev Modifier that restricts function access to only the asset token.
    /// This ensures that only authorized entities can manage orders within the liquidity pool.
    modifier onlyAsset(address _token) {
        _validateAsset(_token);
        _;
    }

    /// @dev Modifier that restricts function access to only the listed token.
    /// This ensures that only authorized entities can manage orders within the liquidity pool.
    modifier onlyListedToken(address _token) {
        _requireListedToken(_token);
        _;
    }

    /// @dev Constructor that disables the initializers.
    /// This is important for upgradeable contracts to ensure that the contract's state is only set once at deployment.
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the contract with the specified parameters.
    /// This function sets the initial values for maximum leverage, position fees,
    /// liquidation fees, interest rates, accrual intervals, and maintenance margins.
    /// It also initializes the ownership and reentrancy guard mechanisms.
    /// @param _maxLeverage The maximum leverage allowed for positions.
    /// @param _positionFee The fee charged for opening a position.
    /// @param _liquidationFee The fee incurred during liquidation of a position.
    /// @param _interestRate The interest rate applied to borrowed funds.
    /// @param _accrualInterval The interval at which interest is accrued.
    /// @param _maintainanceMargin The maintenance margin required to keep positions open.
    function initialize(
        uint256 _maxLeverage,
        uint256 _positionFee,
        uint256 _liquidationFee,
        uint256 _interestRate,
        uint256 _accrualInterval,
        uint256 _maintainanceMargin
    ) external virtual initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        _setMaxLeverage(_maxLeverage);
        _setPositionFee(_positionFee, _liquidationFee);
        _setInterestRate(_interestRate, _accrualInterval);
        _setMaintenanceMargin(_maintainanceMargin);
        fee.daoFee = PRECISION;
    }

    // ========= View functions =========

    /// @dev Validates a token pair and side for a position.
    /// @param _indexToken The token used as the index for the position.
    /// @param _collateralToken The token used as the collateral for the position.
    /// @param _side The side of the position, either long or short.
    /// @param _isIncrease A boolean indicating whether the position is an increase or decrease.
    /// @return True if the token pair and side are valid, false otherwise.
    function validateToken(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        external
        view
        returns (bool)
    {
        return _validateToken(_indexToken, _collateralToken, _side, _isIncrease);
    }

    /// @dev Returns the asset information for a given token.
    /// @param _token The token address.
    /// @return The asset information for the token.
    function getPoolAsset(address _token) external view returns (AssetInfo memory) {
        return _getPoolAsset(_token);
    }

    /// @dev Function to get PoolTokenInfo for a specific token.
    /// @param _token The token address.
    /// @return The PoolTokenInfo for the token.
    function getPoolTokenInfo(address _token) external view virtual returns (PoolTokenInfo memory) {
        return poolTokens[_token]; // Return the PoolTokenInfo associated with the token
    }

    /// @dev Returns the total number of tranches in the pool.
    /// This function provides the count of all tranches, which represent different liquidity segments within the pool.
    /// @return The total number of tranches.
    function getAllTranchesLength() external view returns (uint256) {
        return allTranches.length;
    }

    /// @dev Returns the total value of the pool.
    /// This function calculates the total value of the pool based on the specified parameter.
    /// @param _max A boolean indicating whether to return the maximum value or not.
    /// @return The total value of the pool.
    function getPoolValue(bool _max) external view returns (uint256) {
        return _getPoolValue(_max);
    }

    /// @dev Returns the value of a specific tranche.
    /// This function retrieves the value of a specified tranche, validating it before fetching the value.
    /// @param _tranche The address of the tranche to validate and get the value for.
    /// @param _max A boolean indicating whether to return the maximum value of the tranche.
    /// @return sum The value of the specified tranche.
    function getTrancheValue(address _tranche, bool _max) external view returns (uint256 sum) {
        _validateTranche(_tranche);
        return _getTrancheValue(_tranche, _max);
    }

    /// @dev Calculates the output amount for a token swap.
    /// This function estimates the amount of output tokens received from a swap given an input amount.
    /// @param _tokenIn The address of the token being swapped in.
    /// @param _tokenOut The address of the token being swapped out.
    /// @param _amountIn The amount of input tokens for the swap.
    /// @return amountOut The estimated amount of output tokens received.
    /// @return feeAmount The fee incurred for the swap.
    function calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        return _calcSwapOutput(_tokenIn, _tokenOut, _amountIn);
    }

    /// @dev Calculates the output amounts for removing liquidity from a specific tranche.
    /// This function estimates the amount of tokens received upon removing liquidity, including fees.
    /// @param _tranche The address of the tranche from which liquidity is being removed.
    /// @param _tokenOut The address of the token that will be received upon removal.
    /// @param _lpAmount The amount of liquidity provider tokens to be redeemed.
    /// @return outAmount The estimated amount of output tokens received before fees.
    /// @return outAmountAfterFee The estimated amount of output tokens received after deducting fees.
    /// @return feeAmount The fee incurred for the liquidity removal.
    function calcRemoveLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount)
        external
        view
        returns (uint256 outAmount, uint256 outAmountAfterFee, uint256 feeAmount)
    {
        (outAmount, outAmountAfterFee, feeAmount,) = _calcRemoveLiquidity(_tranche, _tokenOut, _lpAmount);
    }

    // ============= Mutative functions =============

    /// @dev Adds liquidity to a specific tranche in the pool.
    /// This function allows users to deposit tokens into a tranche, minting liquidity provider tokens in return.
    /// It validates the tranche, accrues interest, and ensures that the minimum liquidity provider tokens are met.
    /// @param _tranche The address of the tranche to which liquidity is being added.
    /// @param _token The address of the token being deposited.
    /// @param _amountIn The amount of tokens being deposited.
    /// @param _minLpAmount The minimum amount of liquidity provider tokens that must be received.
    /// @param _to The address that will receive the liquidity provider tokens.
    function addLiquidity(address _tranche, address _token, uint256 _amountIn, uint256 _minLpAmount, address _to)
        external
        nonReentrant
        onlyListedToken(_token)
    {
        _validateTranche(_tranche);
        _accrueInterest(_token);
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amountIn);
        _amountIn = _requireAmount(_getAmountIn(_token));

        (uint256 amountInAfterDaoFee, uint256 daoFee, uint256 lpAmount) = _calcAddLiquidity(_tranche, _token, _amountIn);
        if (lpAmount < _minLpAmount) {
            revert PoolErrors.SlippageExceeded();
        }

        poolTokens[_token].feeReserve += daoFee;
        trancheAssets[_tranche][_token].poolAmount += amountInAfterDaoFee;
        refreshVirtualPoolValue();

        ILPToken(_tranche).mint(_to, lpAmount);
        emit LiquidityAdded(_tranche, msg.sender, _token, _amountIn, lpAmount, daoFee);
    }

    /// @dev Removes liquidity from a specific tranche in the pool.
    /// This function allows users to withdraw tokens from a tranche by redeeming liquidity provider tokens.
    /// It validates the tranche, accrues interest, and ensures that the minimum output amount is met.
    /// @param _tranche The address of the tranche from which liquidity is being removed.
    /// @param _tokenOut The address of the token that will be received upon removal.
    /// @param _lpAmount The amount of liquidity provider tokens to be redeemed.
    /// @param _minOut The minimum amount of tokens that must be received.
    /// @param _to The address that will receive the output tokens.
    function removeLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to)
        external
        nonReentrant
        onlyAsset(_tokenOut)
    {
        _validateTranche(_tranche);
        _accrueInterest(_tokenOut);
        _requireAmount(_lpAmount);
        ILPToken lpToken = ILPToken(_tranche);

        (, uint256 outAmountAfterFee, uint256 daoFee, uint256 tokenOutPrice) =
            _calcRemoveLiquidity(_tranche, _tokenOut, _lpAmount);
        if (outAmountAfterFee < _minOut) {
            revert PoolErrors.SlippageExceeded();
        }

        poolTokens[_tokenOut].feeReserve += daoFee;
        _decreaseTranchePoolAmount(_tranche, _tokenOut, outAmountAfterFee + daoFee, tokenOutPrice);
        refreshVirtualPoolValue();

        lpToken.burnFrom(msg.sender, _lpAmount);
        _doTransferOut(_tokenOut, _to, outAmountAfterFee);

        emit LiquidityRemoved(_tranche, msg.sender, _tokenOut, _lpAmount, outAmountAfterFee, daoFee);
    }

    /// @dev Swaps one token for another within the pool.
    /// This function allows users to exchange one token for another, accruing interest and validating the tokens involved.
    /// It ensures that the minimum output amount is met and handles the transfer of tokens.
    /// @param _tokenIn The address of the token being swapped in.
    /// @param _tokenOut The address of the token being swapped out.
    /// @param _minOut The minimum amount of output tokens that must be received.
    /// @param _to The address that will receive the output tokens.
    /// @param extradata Additional data to be passed to the pool hook, if applicable.
    function swap(address _tokenIn, address _tokenOut, uint256 _minOut, address _to, bytes calldata extradata)
        external
        nonReentrant
        onlyListedToken(_tokenIn)
        onlyAsset(_tokenOut)
    {
        if (_tokenIn == _tokenOut) {
            revert PoolErrors.SameTokenSwap(_tokenIn);
        }
        _accrueInterest(_tokenIn);
        _accrueInterest(_tokenOut);
        uint256 amountIn = _requireAmount(_getAmountIn(_tokenIn));
        (uint256 amountOutAfterFee, uint256 swapFee) = _calcSwapOutput(_tokenIn, _tokenOut, amountIn);
        if (amountOutAfterFee < _minOut) {
            revert PoolErrors.SlippageExceeded();
        }
        (uint256 daoFee,) = _calcDaoFee(swapFee);
        poolTokens[_tokenIn].feeReserve += daoFee;
        _rebalanceTranches(_tokenIn, amountIn - daoFee, _tokenOut, amountOutAfterFee);
        _doTransferOut(_tokenOut, _to, amountOutAfterFee);
        emit Swap(msg.sender, _tokenIn, _tokenOut, amountIn, amountOutAfterFee, swapFee);
        if (address(poolHook) != address(0)) {
            poolHook.postSwap(_to, _tokenIn, _tokenOut, abi.encode(amountIn, amountOutAfterFee, swapFee, extradata));
        }
    }

    /// @dev Increases the user's position in the pool.
    /// This function allows users to add collateral and increase their position size for a specific index token.
    /// It validates the token pair, accrues interest, and updates the position accordingly.
    /// @param _owner The address of the user whose position is being increased.
    /// @param _indexToken The token being indexed for the position.
    /// @param _collateralToken The collateral token used for the position.
    /// @param _sizeChanged The amount by which the position size is being increased.
    /// @param _side The side of the position (LONG or SHORT).
    function increasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _sizeChanged,
        Side _side
    ) external onlyOrderManager {
        _requireValidTokenPair(_indexToken, _collateralToken, _side, true);
        IncreasePositionVars memory vars;
        vars.collateralAmount = _requireAmount(_getAmountIn(_collateralToken));
        uint256 collateralPrice = _getCollateralPrice(_collateralToken, true);
        vars.collateralValueAdded = collateralPrice * vars.collateralAmount;
        uint256 borrowIndex = _accrueInterest(_collateralToken);
        bytes32 key = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        vars.indexPrice = _getIndexPrice(_indexToken, _side, true);
        vars.sizeChanged = _sizeChanged;

        // update position
        vars.feeValue = _calcPositionFee(position, vars.sizeChanged, borrowIndex);
        vars.feeAmount = vars.feeValue / collateralPrice;
        (vars.daoFee, vars.totalLpFee) = _calcDaoFee(vars.feeAmount);
        vars.reserveAdded = vars.sizeChanged / collateralPrice;

        position.entryPrice = PositionUtils.calcAveragePrice(
            _side, position.size, position.size + vars.sizeChanged, position.entryPrice, vars.indexPrice, 0
        );
        position.collateralValue =
            MathUtils.zeroCapSub(position.collateralValue + vars.collateralValueAdded, vars.feeValue);
        position.size = position.size + vars.sizeChanged;
        position.borrowIndex = borrowIndex;
        position.reserveAmount += vars.reserveAdded;

        _validatePosition(position, _collateralToken, _side, true, vars.indexPrice);

        // update pool assets
        _reservePoolAsset(key, vars, _indexToken, _collateralToken, _side);
        positions[key] = position;

        emit IncreasePosition(
            key,
            _owner,
            _collateralToken,
            _indexToken,
            vars.collateralAmount,
            vars.sizeChanged,
            _side,
            vars.indexPrice,
            vars.feeValue
        );

        emit UpdatePosition(
            key,
            position.size,
            position.collateralValue,
            position.entryPrice,
            position.borrowIndex,
            position.reserveAmount,
            vars.indexPrice
        );

        if (address(poolHook) != address(0)) {
            poolHook.postIncreasePosition(
                _owner,
                _indexToken,
                _collateralToken,
                _side,
                abi.encode(_sizeChanged, vars.collateralValueAdded, vars.feeValue)
            );
        }
    }

    /// @dev Decreases the user's position in the pool.
    /// This function allows users to withdraw collateral and decrease their position size for a specific index token.
    /// It validates the token pair, accrues interest, and updates the position accordingly.
    /// @param _owner The address of the user whose position is being decreased.
    /// @param _indexToken The token being indexed for the position.
    /// @param _collateralToken The collateral token used for the position.
    /// @param _collateralChanged The amount of collateral being changed.
    /// @param _sizeChanged The amount by which the position size is being decreased.
    /// @param _side The side of the position (LONG or SHORT).
    /// @param _receiver The address that will receive the collateral payout.
    function decreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _collateralChanged,
        uint256 _sizeChanged,
        Side _side,
        address _receiver
    ) external onlyOrderManager {
        _requireValidTokenPair(_indexToken, _collateralToken, _side, false);
        uint256 borrowIndex = _accrueInterest(_collateralToken);
        bytes32 key = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];

        if (position.size == 0) {
            revert PoolErrors.PositionNotExists(_owner, _indexToken, _collateralToken, _side);
        }

        DecreasePositionVars memory vars =
            _calcDecreasePayout(position, _indexToken, _collateralToken, _side, _sizeChanged, _collateralChanged, false);

        // reset to actual reduced value instead of user input
        vars.collateralReduced = position.collateralValue - vars.remainingCollateral;
        _releasePoolAsset(key, vars, _indexToken, _collateralToken, _side);
        position.size = position.size - vars.sizeChanged;
        position.borrowIndex = borrowIndex;
        position.reserveAmount = position.reserveAmount - vars.reserveReduced;
        position.collateralValue = vars.remainingCollateral;

        _validatePosition(position, _collateralToken, _side, false, vars.indexPrice);

        emit DecreasePosition(
            key,
            _owner,
            _collateralToken,
            _indexToken,
            vars.collateralReduced,
            vars.sizeChanged,
            _side,
            vars.indexPrice,
            vars.pnl.asTuple(),
            vars.feeValue
        );
        if (position.size == 0) {
            emit ClosePosition(
                key,
                position.size,
                position.collateralValue,
                position.entryPrice,
                position.borrowIndex,
                position.reserveAmount
            );
            // delete position when closed
            delete positions[key];
        } else {
            emit UpdatePosition(
                key,
                position.size,
                position.collateralValue,
                position.entryPrice,
                position.borrowIndex,
                position.reserveAmount,
                vars.indexPrice
            );
            positions[key] = position;
        }
        _doTransferOut(_collateralToken, _receiver, vars.payout);

        if (address(poolHook) != address(0)) {
            poolHook.postDecreasePosition(
                _owner,
                _indexToken,
                _collateralToken,
                _side,
                abi.encode(vars.sizeChanged, vars.collateralReduced, vars.feeValue)
            );
        }
    }

    /// @dev Liquidates a user's position in the pool.
    /// This function allows the liquidation of a position if certain conditions are met.
    /// It validates the token pair, accrues interest, and updates the position accordingly.
    /// @param _account The address of the user whose position is being liquidated.
    /// @param _indexToken The token being indexed for the position.
    /// @param _collateralToken The collateral token used for the position.
    /// @param _side The side of the position (LONG or SHORT).
    function liquidatePosition(address _account, address _indexToken, address _collateralToken, Side _side) external {
        _requireValidTokenPair(_indexToken, _collateralToken, _side, false);
        uint256 borrowIndex = _accrueInterest(_collateralToken);

        bytes32 key = _getPositionKey(_account, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        uint256 markPrice = _getIndexPrice(_indexToken, _side, false);
        if (!_liquidatePositionAllowed(position, _side, markPrice, borrowIndex)) {
            revert PoolErrors.PositionNotLiquidated(key);
        }

        DecreasePositionVars memory vars = _calcDecreasePayout(
            position, _indexToken, _collateralToken, _side, position.size, position.collateralValue, true
        );

        _releasePoolAsset(key, vars, _indexToken, _collateralToken, _side);

        emit LiquidatePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            _side,
            position.size,
            position.collateralValue - vars.remainingCollateral,
            position.reserveAmount,
            vars.indexPrice,
            vars.pnl.asTuple(),
            vars.feeValue
        );

        delete positions[key];
        _doTransferOut(_collateralToken, _account, vars.payout);
        _doTransferOut(_collateralToken, msg.sender, fee.liquidationFee / vars.collateralPrice);

        if (address(poolHook) != address(0)) {
            poolHook.postLiquidatePosition(
                _account, _indexToken, _collateralToken, _side, abi.encode(position.size, position.collateralValue)
            );
        }
    }

    /// @dev Refreshes the virtual value of the pool.
    /// This function calculates the average of the pool's total value based on the current state.
    /// It updates the `virtualPoolValue` variable to reflect the current pool value.
    function refreshVirtualPoolValue() public {
        virtualPoolValue = (_getPoolValue(true) + _getPoolValue(false)) / 2;
    }

    // ========= ADMIN FUNCTIONS ========
    /// @dev remove this unused function to reduce contract size
    // function addTranche(address _tranche) external virtual {}

    /// @notice Configuration for risk factors associated with a tranche.
    /// @param tranche The address of the tranche.
    /// @param riskFactor The risk factor associated with the tranche.
    struct RiskConfig {
        address tranche;
        uint256 riskFactor;
    }

    /// @notice Sets the risk factor for a given token and its associated tranches.
    /// @param _token The address of the token for which to set risk factors.
    /// @param _config An array of RiskConfig containing tranche addresses and their respective risk factors.
    /// @dev Reverts if the token is a stable coin or if any tranche is invalid.
    function setRiskFactor(address _token, RiskConfig[] memory _config) external onlyOwner onlyAsset(_token) {
        if (isStableCoin[_token]) {
            revert PoolErrors.NotApplicableForStableCoin();
        }
        uint256 total = totalRiskFactor[_token];
        for (uint256 i = 0; i < _config.length; ++i) {
            (address tranche, uint256 factor) = (_config[i].tranche, _config[i].riskFactor);
            if (!isTranche[tranche]) {
                revert PoolErrors.InvalidTranche(tranche);
            }
            total = total + factor - riskFactor[_token][tranche];
            riskFactor[_token][tranche] = factor;
        }
        totalRiskFactor[_token] = total;
        emit TokenRiskFactorUpdated(_token);
    }

    /// @notice Adds a new token to the pool.
    /// @param _token The address of the token to be added.
    /// @param _isStableCoin A boolean indicating if the token is a stable coin.
    /// @dev Reverts if the token is already listed or if the maximum asset limit is exceeded.
    function addToken(address _token, bool _isStableCoin) external onlyOwner {
        if (!isAsset[_token]) {
            isAsset[_token] = true;
            isListed[_token] = true;
            allAssets.push(_token);
            isStableCoin[_token] = _isStableCoin;
            if (allAssets.length > MAX_ASSETS) {
                revert PoolErrors.TooManyTokenAdded(allAssets.length, MAX_ASSETS);
            }
            emit TokenWhitelisted(_token);
            return;
        }

        if (isListed[_token]) {
            revert PoolErrors.DuplicateToken(_token);
        }

        // token is added but not listed
        isListed[_token] = true;
        emit TokenWhitelisted(_token);
    }

    /// @notice Delists a token from the pool.
    /// @param _token The address of the token to be delisted.
    /// @dev Reverts if the token is not currently listed.
    function delistToken(address _token) external onlyOwner {
        if (!isListed[_token]) {
            revert PoolErrors.AssetNotListed(_token);
        }
        isListed[_token] = false;
        uint256 weight = targetWeights[_token];
        totalWeight -= weight;
        targetWeights[_token] = 0;
        emit TokenDelisted(_token);
    }

    /// @notice Sets the maximum leverage for the pool.
    /// @param _maxLeverage The maximum leverage value to be set.
    function setMaxLeverage(uint256 _maxLeverage) external onlyOwner {
        _setMaxLeverage(_maxLeverage);
    }

    /// @notice Sets the maintenance margin for the pool.
    /// @param _margin The maintenance margin value to be set.
    function setMaintenanceMargin(uint256 _margin) external onlyOwner {
        _setMaintenanceMargin(_margin);
    }

    /// @notice Sets the oracle address for the pool.
    /// @param _oracle The address of the new oracle.
    /// @dev Validates the oracle address before setting it.
    function setOracle(address _oracle) external onlyOwner {
        _requireAddress(_oracle);
        address oldOracle = address(oracle);
        oracle = IPulseOracle(_oracle);
        emit OracleChanged(oldOracle, _oracle);
    }

    /// @notice Sets the swap fee parameters for the pool.
    /// @param _baseSwapFee The base swap fee to be set.
    /// @param _taxBasisPoint The tax basis point to be set.
    /// @param _stableCoinBaseSwapFee The base swap fee for stable coins.
    /// @param _stableCoinTaxBasisPoint The tax basis point for stable coins.
    /// @dev Validates the maximum values for all fee parameters before setting them.
    function setSwapFee(
        uint256 _baseSwapFee,
        uint256 _taxBasisPoint,
        uint256 _stableCoinBaseSwapFee,
        uint256 _stableCoinTaxBasisPoint
    ) external onlyOwner {
        _validateMaxValue(_baseSwapFee, MAX_BASE_SWAP_FEE);
        _validateMaxValue(_stableCoinBaseSwapFee, MAX_BASE_SWAP_FEE);
        _validateMaxValue(_taxBasisPoint, MAX_TAX_BASIS_POINT);
        _validateMaxValue(_stableCoinTaxBasisPoint, MAX_TAX_BASIS_POINT);
        fee.baseSwapFee = _baseSwapFee;
        fee.taxBasisPoint = _taxBasisPoint;
        fee.stableCoinBaseSwapFee = _stableCoinBaseSwapFee;
        fee.stableCoinTaxBasisPoint = _stableCoinTaxBasisPoint;
        emit SwapFeeSet(_baseSwapFee, _taxBasisPoint, _stableCoinBaseSwapFee, _stableCoinTaxBasisPoint);
    }

    /// @notice Sets the fee for adding or removing liquidity.
    /// @param _value The fee value to be set.
    /// @dev Validates the maximum value before setting it.
    function setAddRemoveLiquidityFee(uint256 _value) external onlyOwner {
        _validateMaxValue(_value, MAX_BASE_SWAP_FEE);
        addRemoveLiquidityFee = _value;
        emit AddRemoveLiquidityFeeSet(_value);
    }

    /// @notice Sets the position and liquidation fees.
    /// @param _positionFee The position fee to be set.
    /// @param _liquidationFee The liquidation fee to be set.
    function setPositionFee(uint256 _positionFee, uint256 _liquidationFee) external onlyOwner {
        _setPositionFee(_positionFee, _liquidationFee);
    }

    /// @notice Sets the DAO fee for the pool.
    /// @param _daoFee The DAO fee to be set.
    /// @dev Validates the maximum value before setting it.
    function setDaoFee(uint256 _daoFee) external onlyOwner {
        _validateMaxValue(_daoFee, PRECISION);
        fee.daoFee = _daoFee;
        emit DaoFeeSet(_daoFee);
    }

    /// @notice Sets the interest rate and accrual interval for the pool.
    /// @param _interestRate The interest rate to be set.
    /// @param _accrualInterval The interval for interest accrual.
    /// @dev Reverts if the accrual interval is less than 1.
    function setInterestRate(uint256 _interestRate, uint256 _accrualInterval) external onlyOwner {
        _setInterestRate(_interestRate, _accrualInterval);
    }

    /// @notice Sets the address of the order manager.
    /// @param _orderManager The address of the new order manager.
    /// @dev Validates the address before setting it.
    function setOrderManager(address _orderManager) external onlyOwner {
        _requireAddress(_orderManager);
        orderManager = _orderManager;
        emit SetOrderManager(_orderManager);
    }

    /// @notice Withdraws fees from the pool.
    /// @param _token The address of the token to withdraw.
    /// @param _recipient The address to send the withdrawn fees to.
    /// @dev Reverts if the caller is not the fee distributor.
    function withdrawFee(address _token, address _recipient) external onlyAsset(_token) {
        if (msg.sender != feeDistributor) {
            revert PoolErrors.FeeDistributorOnly();
        }
        uint256 amount = poolTokens[_token].feeReserve;
        poolTokens[_token].feeReserve = 0;
        _doTransferOut(_token, _recipient, amount);
        emit DaoFeeWithdrawn(_token, _recipient, amount);
    }

    /// @notice Generates a unique key for an order.
    /// @param _owner The address of the order owner.
    /// @param _indexToken The index token associated with the order.
    /// @param _collateralToken The collateral token associated with the order.
    /// @param _side The side of the order (LONG or SHORT).
    /// @return The unique order key as a bytes32 value.
    function getOrderKey(address _owner, address _indexToken, address _collateralToken, Side _side)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

    /// @notice Sets the address of the fee distributor.
    /// @param _feeDistributor The address of the new fee distributor.
    /// @dev Validates the address before setting it.
    function setFeeDistributor(address _feeDistributor) external onlyOwner {
        _requireAddress(_feeDistributor);
        feeDistributor = _feeDistributor;
        emit FeeDistributorSet(feeDistributor);
    }

    /// @notice Sets the target weight for tokens in the pool.
    /// @param tokens An array of TokenWeight structs representing the target weights.
    /// @dev Reverts if the number of tokens does not match the total assets.
    function setTargetWeight(TokenWeight[] memory tokens) external onlyOwner {
        uint256 nTokens = tokens.length;
        if (nTokens != allAssets.length) {
            revert PoolErrors.RequireAllTokens();
        }
        uint256 total;
        for (uint256 i = 0; i < nTokens; ++i) {
            TokenWeight memory item = tokens[i];
            assert(isAsset[item.token]);
            // unlisted token always has zero weight
            uint256 weight = isListed[item.token] ? item.weight : 0;
            targetWeights[item.token] = weight;
            total += weight;
        }
        totalWeight = total;
        emit TokenWeightSet(tokens);
    }

    /// @notice Sets the pool hook address.
    /// @param _hook The address of the new pool hook.
    function setPoolHook(address _hook) external onlyOwner {
        poolHook = IPoolHook(_hook);
        emit PoolHookChanged(_hook);
    }

    /// @notice Sets the maximum global short size for a token.
    /// @param _token The address of the token.
    /// @param _value The maximum global short size to be set.
    /// @dev Reverts if the token is a stable coin.
    function setMaxGlobalShortSize(address _token, uint256 _value) external onlyOwner onlyAsset(_token) {
        if (isStableCoin[_token]) {
            revert PoolErrors.NotApplicableForStableCoin();
        }
        maxGlobalShortSizes[_token] = _value;
        emit MaxGlobalShortSizeSet(_token, _value);
    }

    /// @notice Sets the maximum global long size ratio for a token.
    /// @param _token The address of the token.
    /// @param _ratio The maximum global long size ratio to be set.
    /// @dev Reverts if the token is a stable coin or if the ratio exceeds the maximum value.
    function setMaxGlobalLongSizeRatio(address _token, uint256 _ratio) external onlyOwner onlyAsset(_token) {
        if (isStableCoin[_token]) {
            revert PoolErrors.NotApplicableForStableCoin();
        }
        _validateMaxValue(_ratio, PRECISION);
        maxGlobalLongSizeRatios[_token] = _ratio;
        emit MaxGlobalLongSizeRatioSet(_token, _ratio);
    }

    // ======== internal functions =========
    /// @notice Sets the maximum leverage for the pool.
    /// @param _maxLeverage The maximum leverage value to be set.
    /// @dev Reverts if the maximum leverage is zero.
    function _setMaxLeverage(uint256 _maxLeverage) internal {
        if (_maxLeverage == 0) {
            revert PoolErrors.InvalidMaxLeverage();
        }
        maxLeverage = _maxLeverage;
        emit MaxLeverageChanged(_maxLeverage);
    }

    /// @notice Sets the maintenance margin for the pool.
    /// @param _ratio The maintenance margin ratio to be set.
    /// @dev Validates the maximum value before setting it.
    function _setMaintenanceMargin(uint256 _ratio) internal {
        _validateMaxValue(_ratio, MAX_MAINTENANCE_MARGIN);
        maintenanceMargin = _ratio;
        emit MaintenanceMarginChanged(_ratio);
    }

    /// @notice Sets the interest rate and accrual interval for the pool.
    /// @param _interestRate The interest rate to be set.
    /// @param _accrualInterval The interval for interest accrual.
    /// @dev Reverts if the accrual interval is less than 1 or if the interest rate exceeds the maximum value.
    function _setInterestRate(uint256 _interestRate, uint256 _accrualInterval) internal {
        if (_accrualInterval < 1) {
            revert PoolErrors.InvalidInterval();
        }
        _validateMaxValue(_interestRate, MAX_INTEREST_RATE);
        interestRate = _interestRate;
        accrualInterval = _accrualInterval;
        emit InterestRateSet(_interestRate, _accrualInterval);
    }

    /// @notice Sets the position and liquidation fees for the pool.
    /// @param _positionFee The position fee to be set.
    /// @param _liquidationFee The liquidation fee to be set.
    /// @dev Validates the maximum values before setting them.
    function _setPositionFee(uint256 _positionFee, uint256 _liquidationFee) internal {
        _validateMaxValue(_positionFee, MAX_POSITION_FEE);
        _validateMaxValue(_liquidationFee, MAX_LIQUIDATION_FEE);
        fee.positionFee = _positionFee;
        fee.liquidationFee = _liquidationFee;
        emit PositionFeeSet(_positionFee, _liquidationFee);
    }

    /// @notice Validates the tokens involved in a position.
    /// @param _indexToken The index token.
    /// @param _collateralToken The collateral token.
    /// @param _side The side of the position (LONG or SHORT).
    /// @param _isIncrease Whether the position is being increased.
    /// @return True if the tokens are valid, false otherwise.
    function _validateToken(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        internal
        view
        returns (bool)
    {
        if (!isAsset[_indexToken] || !isAsset[_collateralToken]) {
            return false;
        }

        if (_isIncrease && (!isListed[_indexToken] || !isListed[_collateralToken])) {
            return false;
        }

        return _side == Side.LONG ? _indexToken == _collateralToken : isStableCoin[_collateralToken];
    }

    /**
     * @dev Calculates the amount of liquidity to add after fees, the DAO fee, and the LP token amount to mint.
     *
     * @param _tranche The address of the tranche to which liquidity is being added.
     * @param _token The address of the token being added as liquidity.
     * @param _amountIn The amount of the token being added as liquidity.
     *
     * @return amountInAfterFee The amount of tokens added after deducting the DAO fee.
     * @return daoFee The fee amount taken by the DAO.
     * @return lpAmount The amount of LP tokens to mint for the liquidity provider.
     *
     * @notice Reverts if the token is not a stablecoin and has a risk factor of 0 for the tranche.
     */
    function _calcAddLiquidity(address _tranche, address _token, uint256 _amountIn)
        internal
        view
        returns (uint256 amountInAfterFee, uint256 daoFee, uint256 lpAmount)
    {
        // Check if the token is allowed for adding liquidity
        if (!isStableCoin[_token] && riskFactor[_token][_tranche] == 0) {
            revert PoolErrors.AddLiquidityNotAllowed(_tranche, _token);
        }
        // Get the price of the token
        uint256 tokenPrice = _getPrice(_token, false);
        // Calculate the value change based on the input amount and token price
        uint256 valueChange = _amountIn * tokenPrice;

        // Calculate the fee rate for adding liquidity
        uint256 _fee = _calcFeeRate(_token, tokenPrice, valueChange, addRemoveLiquidityFee, fee.taxBasisPoint, true);
        // Calculate the user's amount after deducting the fee
        uint256 userAmount = MathUtils.frac(_amountIn, PRECISION - _fee, PRECISION);
        // Calculate the DAO fee
        (daoFee,) = _calcDaoFee(_amountIn - userAmount);
        // Calculate the amount after deducting the DAO fee
        amountInAfterFee = _amountIn - daoFee;

        // Get the tranche's total value and LP token supply
        uint256 trancheValue = _getTrancheValue(_tranche, true);
        uint256 lpSupply = ILPToken(_tranche).totalSupply();
        // Calculate the LP token amount to mint
        if (lpSupply == 0 || trancheValue == 0) {
            lpAmount = MathUtils.frac(userAmount, tokenPrice, LP_INITIAL_PRICE);
        } else {
            lpAmount = (userAmount * tokenPrice * lpSupply) / trancheValue;
        }
    }

    /**
     * @dev Calculates the amount of tokens to withdraw after fees, the DAO fee, and the token price.
     *
     * @param _tranche The address of the tranche from which liquidity is being removed.
     * @param _tokenOut The address of the token being withdrawn.
     * @param _lpAmount The amount of LP tokens being burned to withdraw liquidity.
     *
     * @return outAmount The amount of tokens to withdraw before fees.
     * @return outAmountAfterFee The amount of tokens to withdraw after deducting fees.
     * @return daoFee The fee amount taken by the DAO.
     * @return tokenPrice The price of the token being withdrawn.
     */
    function _calcRemoveLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount)
        internal
        view
        returns (uint256 outAmount, uint256 outAmountAfterFee, uint256 daoFee, uint256 tokenPrice)
    {
        // Get the price of the token being withdrawn
        tokenPrice = _getPrice(_tokenOut, true);
        // Get the tranche's total value and LP token supply
        uint256 poolValue = _getTrancheValue(_tranche, false);
        uint256 totalSupply = ILPToken(_tranche).totalSupply();
        // Calculate the value change based on the LP amount being burned
        uint256 valueChange = (_lpAmount * poolValue) / totalSupply;
        // Calculate the fee rate for removing liquidity
        uint256 _fee = _calcFeeRate(_tokenOut, tokenPrice, valueChange, addRemoveLiquidityFee, fee.taxBasisPoint, false);
        // Calculate the amount of tokens to withdraw before fees
        outAmount = (_lpAmount * poolValue) / totalSupply / tokenPrice;
        // Calculate the amount of tokens to withdraw after deducting fees
        outAmountAfterFee = MathUtils.frac(outAmount, PRECISION - _fee, PRECISION);
        // Calculate the DAO fee
        (daoFee,) = _calcDaoFee(outAmount - outAmountAfterFee);
    }

    /**
     * @dev Calculates the output amount of a swap after fees and the fee amount.
     *
     * @param _tokenIn The address of the input token.
     * @param _tokenOut The address of the output token.
     * @param _amountIn The amount of the input token being swapped.
     *
     * @return amountOutAfterFee The amount of output tokens after deducting fees.
     * @return feeAmount The total fee amount deducted.
     */
    function _calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn)
        internal
        view
        returns (uint256 amountOutAfterFee, uint256 feeAmount)
    {
        // Get the prices of the input and output tokens
        uint256 priceIn = _getPrice(_tokenIn, false);
        uint256 priceOut = _getPrice(_tokenOut, true);
        // Calculate the value change based on the input amount and token price
        uint256 valueChange = _amountIn * priceIn;
        // Calculate the swap fees for the input and output tokens
        uint256 feeIn = _calcSwapFee(_tokenIn, priceIn, valueChange, true);
        uint256 feeOut = _calcSwapFee(_tokenOut, priceOut, valueChange, false);
        // Use the higher fee between the input and output tokens
        uint256 _fee = feeIn > feeOut ? feeIn : feeOut;
        // Calculate the output amount after deducting fees
        amountOutAfterFee = valueChange * (PRECISION - _fee) / priceOut / PRECISION;
        // Calculate the total fee amount
        feeAmount = (valueChange * _fee) / priceIn / PRECISION;
    }

    /**
     * @dev Generates a unique key for a position based on the owner, index token, collateral token, and side.
     *
     * @param _owner The address of the position owner.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the position (e.g., long or short).
     *
     * @return A unique bytes32 key representing the position.
     */
    function _getPositionKey(address _owner, address _indexToken, address _collateralToken, Side _side)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

    /**
     * @dev Validates a position to ensure it meets the required conditions.
     *
     * @param _position The position to validate.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the position (e.g., long or short).
     * @param _isIncrease Whether the position is being increased.
     * @param _indexPrice The current price of the index token.
     *
     * @notice Reverts if the position size is invalid, leverage is invalid, or the update would cause liquidation.
     */
    function _validatePosition(
        Position memory _position,
        address _collateralToken,
        Side _side,
        bool _isIncrease,
        uint256 _indexPrice
    ) internal view {
        // Check if the position size is valid
        if ((_isIncrease && _position.size == 0)) {
            revert PoolErrors.InvalidPositionSize();
        }
        // Get the borrow index for the collateral token
        uint256 borrowIndex = poolTokens[_collateralToken].borrowIndex;
        // Validate the leverage of the position
        if (_position.size < _position.collateralValue || _position.size > _position.collateralValue * maxLeverage) {
            revert PoolErrors.InvalidLeverage(_position.size, _position.collateralValue, maxLeverage);
        }
        // Check if the position would be liquidated after the update
        if (_liquidatePositionAllowed(_position, _side, _indexPrice, borrowIndex)) {
            revert PoolErrors.UpdateCauseLiquidation();
        }
    }

    /**
     * @dev Ensures that the token pair (index token and collateral token) is valid for the given side and operation.
     *
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the position (e.g., long or short).
     * @param _isIncrease Whether the operation is increasing the position size.
     *
     * @notice Reverts with `PoolErrors.InvalidTokenPair` if the token pair is invalid.
     */
    function _requireValidTokenPair(address _indexToken, address _collateralToken, Side _side, bool _isIncrease)
        internal
        view
    {
        if (!_validateToken(_indexToken, _collateralToken, _side, _isIncrease)) {
            revert PoolErrors.InvalidTokenPair(_indexToken, _collateralToken);
        }
    }

    /**
     * @dev Validates that the provided token is a recognized asset in the pool.
     *
     * @param _token The address of the token to validate.
     *
     * @notice Reverts with `PoolErrors.UnknownToken` if the token is not a recognized asset.
     */
    function _validateAsset(address _token) internal view {
        if (!isAsset[_token]) {
            revert PoolErrors.UnknownToken(_token);
        }
    }

    /**
     * @dev Validates that the provided tranche address is recognized in the pool.
     *
     * @param _tranche The address of the tranche to validate.
     *
     * @notice Reverts with `PoolErrors.InvalidTranche` if the tranche is not recognized.
     */
    function _validateTranche(address _tranche) internal view {
        if (!isTranche[_tranche]) {
            revert PoolErrors.InvalidTranche(_tranche);
        }
    }

    /**
     * @dev Ensures that the provided address is not the zero address.
     *
     * @param _address The address to validate.
     *
     * @notice Reverts with `PoolErrors.ZeroAddress` if the address is zero.
     */
    function _requireAddress(address _address) internal pure {
        if (_address == address(0)) {
            revert PoolErrors.ZeroAddress();
        }
    }

    /**
     * @dev Ensures that the provided amount is greater than zero.
     *
     * @param _amount The amount to validate.
     *
     * @return The validated amount.
     *
     * @notice Reverts with `PoolErrors.ZeroAmount` if the amount is zero.
     */
    function _requireAmount(uint256 _amount) internal pure returns (uint256) {
        if (_amount == 0) {
            revert PoolErrors.ZeroAmount();
        }

        return _amount;
    }

    /**
     * @dev Ensures that the provided token is listed in the pool.
     *
     * @param _token The address of the token to validate.
     *
     * @notice Reverts with `PoolErrors.AssetNotListed` if the token is not listed.
     */
    function _requireListedToken(address _token) internal view {
        if (!isListed[_token]) {
            revert PoolErrors.AssetNotListed(_token);
        }
    }

    /**
     * @dev Ensures that the caller is the designated order manager.
     *
     * @notice Reverts with `PoolErrors.OrderManagerOnly` if the caller is not the order manager.
     */
    function _requireOrderManager() internal view {
        if (msg.sender != orderManager) {
            revert PoolErrors.OrderManagerOnly();
        }
    }

    /**
     * @dev Ensures that the input value does not exceed the specified maximum value.
     *
     * @param _input The input value to validate.
     * @param _max The maximum allowed value.
     *
     * @notice Reverts with `PoolErrors.ValueTooHigh` if the input exceeds the maximum value.
     */
    function _validateMaxValue(uint256 _input, uint256 _max) internal pure {
        if (_input > _max) {
            revert PoolErrors.ValueTooHigh(_max);
        }
    }

    /**
     * @dev Calculates the amount of tokens transferred into the pool since the last update.
     *
     * @param _token The address of the token to check.
     *
     * @return amount The amount of tokens transferred in.
     */
    function _getAmountIn(address _token) internal returns (uint256 amount) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        amount = balance - poolTokens[_token].poolBalance;
        poolTokens[_token].poolBalance = balance;
    }

    /**
     * @dev Transfers a specified amount of tokens to a recipient and updates the pool's token balance.
     *
     * @param _token The address of the token to transfer.
     * @param _to The address of the recipient.
     * @param _amount The amount of tokens to transfer.
     *
     * @notice If the amount is zero, no transfer occurs. The pool's token balance is updated after the transfer.
     */
    function _doTransferOut(address _token, address _to, uint256 _amount) internal {
        if (_amount != 0) {
            IERC20 token = IERC20(_token);
            token.safeTransfer(_to, _amount);
            poolTokens[_token].poolBalance = token.balanceOf(address(this));
        }
    }

    /**
     * @dev Accrues interest for a given token based on the elapsed time since the last accrual.
     *
     * @param _token The address of the token for which interest is being accrued.
     *
     * @return The updated borrow index after accruing interest.
     *
     * @notice This function calculates and updates the borrow index for the token, which represents the accumulated interest over time.
     *         The borrow index is updated based on the interest rate, reserved amount, and pool amount.
     *         If the token's last accrual timestamp is zero or the pool amount is zero, the function initializes the borrow index and timestamp.
     *         Emits an `InterestAccrued` event with the token address and the updated borrow index.
     */
    function _accrueInterest(address _token) internal returns (uint256) {
        // Retrieve the token's information and asset details from storage
        PoolTokenInfo memory tokenInfo = poolTokens[_token];
        AssetInfo memory asset = _getPoolAsset(_token);
        // Get the current block timestamp
        uint256 _now = block.timestamp;
        // Check if the token's last accrual timestamp is zero or the pool amount is zero
        if (tokenInfo.lastAccrualTimestamp == 0 || asset.poolAmount == 0) {
            // Initialize the last accrual timestamp to the nearest accrual interval
            tokenInfo.lastAccrualTimestamp = (_now / accrualInterval) * accrualInterval;
            // Initialize the borrow index to a base value (e.g., 1e30)
            tokenInfo.borrowIndex = 1e30;
        } else {
            // Calculate the number of intervals since the last accrual
            uint256 nInterval = (_now - tokenInfo.lastAccrualTimestamp) / accrualInterval;
            // If no full intervals have passed, return the current borrow index
            if (nInterval == 0) {
                return tokenInfo.borrowIndex;
            }
            // Update the borrow index based on the interest rate, reserved amount, and pool amount
            tokenInfo.borrowIndex += (nInterval * interestRate * asset.reservedAmount) / asset.poolAmount;
            // Update the last accrual timestamp to reflect the elapsed intervals
            tokenInfo.lastAccrualTimestamp += nInterval * accrualInterval;
        }
        // Update the token's information in storage
        poolTokens[_token] = tokenInfo;
        // Emit an event to log the interest accrual
        emit InterestAccrued(_token, tokenInfo.borrowIndex);
        // Return the updated borrow index
        return tokenInfo.borrowIndex;
    }

    /// @notice calculate adjusted fee rate
    /// fee is increased or decreased based on action's effect to pool amount
    /// each token has their target weight set by gov
    /// if action make the weight of token far from its target, fee will be increase, vice versa
    function _calcSwapFee(address _token, uint256 _tokenPrice, uint256 _valueChange, bool _isSwapIn)
        internal
        view
        returns (uint256)
    {
        (uint256 baseSwapFee, uint256 taxBasisPoint) = isStableCoin[_token]
            ? (fee.stableCoinBaseSwapFee, fee.stableCoinTaxBasisPoint)
            : (fee.baseSwapFee, fee.taxBasisPoint);
        return _calcFeeRate(_token, _tokenPrice, _valueChange, baseSwapFee, taxBasisPoint, _isSwapIn);
    }

    /**
     * @dev Calculates the adjusted fee rate based on the token's current and target values.
     *
     * @param _token The address of the token.
     * @param _tokenPrice The current price of the token.
     * @param _valueChange The change in value due to the operation (e.g., adding or removing liquidity).
     * @param _baseFee The base fee rate.
     * @param _taxBasisPoint The basis point used to calculate fee adjustments.
     * @param _isIncrease Whether the operation increases the token's value in the pool.
     *
     * @return The adjusted fee rate.
     *
     * @notice The fee rate is adjusted based on how close the token's current value is to its target value.
     *         If the operation brings the token's value closer to the target, the fee is reduced.
     *         If the operation moves the token's value further from the target, the fee is increased.
     */
    function _calcFeeRate(
        address _token,
        uint256 _tokenPrice,
        uint256 _valueChange,
        uint256 _baseFee,
        uint256 _taxBasisPoint,
        bool _isIncrease
    ) internal view returns (uint256) {
        // Calculate the target value for the token based on its weight and the virtual pool value
        uint256 _targetValue = totalWeight == 0 ? 0 : (targetWeights[_token] * virtualPoolValue) / totalWeight;
        // If the target value is zero, return the base fee
        if (_targetValue == 0) {
            return _baseFee;
        }
        // Calculate the current and next values of the token in the pool
        uint256 _currentValue = _tokenPrice * _getPoolAsset(_token).poolAmount;
        uint256 _nextValue = _isIncrease ? _currentValue + _valueChange : _currentValue - _valueChange;
        // Calculate the difference between the current/next value and the target value
        uint256 initDiff = MathUtils.diff(_currentValue, _targetValue);
        uint256 nextDiff = MathUtils.diff(_nextValue, _targetValue);
        // Adjust the fee based on whether the operation brings the value closer to or further from the target
        if (nextDiff < initDiff) {
            // If the operation brings the value closer to the target, reduce the fee
            uint256 feeAdjust = (_taxBasisPoint * initDiff) / _targetValue;
            return MathUtils.zeroCapSub(_baseFee, feeAdjust);
        } else {
            // If the operation moves the value further from the target, increase the fee
            uint256 avgDiff = (initDiff + nextDiff) / 2;
            uint256 feeAdjust = avgDiff > _targetValue ? _taxBasisPoint : (_taxBasisPoint * avgDiff) / _targetValue;
            return _baseFee + feeAdjust;
        }
    }

    /**
     * @dev Calculates the total value of the pool by summing the values of all tranches.
     *
     * @param _max Whether to use the maximum price for the calculation.
     *
     * @return sum The total value of the pool.
     */
    function _getPoolValue(bool _max) internal view returns (uint256 sum) {
        // Get all token prices
        uint256[] memory prices = _getAllPrices(_max);
        // Sum the values of all tranches
        for (uint256 i = 0; i < allTranches.length;) {
            sum += _getTrancheValue(allTranches[i], prices);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Retrieves the prices of all assets in the pool.
     *
     * @param _max Whether to use the maximum price.
     *
     * @return An array of prices for all assets.
     */
    function _getAllPrices(bool _max) internal view returns (uint256[] memory) {
        return oracle.getMultiplePrices(allAssets, _max);
    }

    /**
     * @dev Calculates the value of a tranche using the provided prices.
     *
     * @param _tranche The address of the tranche.
     * @param _max Whether to use the maximum price.
     *
     * @return sum The value of the tranche.
     */
    function _getTrancheValue(address _tranche, bool _max) internal view returns (uint256 sum) {
        return _getTrancheValue(_tranche, _getAllPrices(_max));
    }

    /**
     * @dev Calculates the value of a tranche using the provided prices.
     *
     * @param _tranche The address of the tranche.
     * @param prices An array of prices for all assets.
     *
     * @return sum The value of the tranche.
     */
    function _getTrancheValue(address _tranche, uint256[] memory prices) internal view returns (uint256 sum) {
        int256 aum;
        // Iterate through all assets to calculate the tranche's value
        for (uint256 i = 0; i < allAssets.length;) {
            address token = allAssets[i];
            assert(isAsset[token]); // Ensure the token is a valid asset
            AssetInfo memory asset = trancheAssets[_tranche][token];
            uint256 price = prices[i];
            // Calculate the asset's contribution to the tranche's value
            if (isStableCoin[token]) {
                aum = aum + (price * asset.poolAmount).toInt256();
            } else {
                uint256 averageShortPrice = averageShortPrices[_tranche][token];
                int256 shortPnl = PositionUtils.calcPnl(Side.SHORT, asset.totalShortSize, averageShortPrice, price);
                aum = aum + ((asset.poolAmount - asset.reservedAmount) * price + asset.guaranteedValue).toInt256()
                    - shortPnl;
            }
            unchecked {
                ++i;
            }
        }
        // Ensure the calculated value is non-negative
        return aum.toUint256();
    }

    /**
     * @dev Decreases the pool amount of a token in a tranche and validates the global short size.
     *
     * @param _tranche The address of the tranche.
     * @param _token The address of the token.
     * @param _amount The amount to decrease.
     * @param _assetPrice The current price of the token.
     *
     * @notice Reverts with `PoolErrors.InsufficientPoolAmount` if the pool amount falls below the reserved amount.
     *         For non-stablecoin tokens, it also validates the global short size to ensure it does not exceed the pool's capacity.
     */
    function _decreaseTranchePoolAmount(address _tranche, address _token, uint256 _amount, uint256 _assetPrice)
        internal
    {
        // Retrieve the asset information for the token in the tranche
        AssetInfo memory asset = trancheAssets[_tranche][_token];
        // Decrease the pool amount by the specified amount
        asset.poolAmount -= _amount;
        // Ensure the pool amount does not fall below the reserved amount
        if (asset.poolAmount < asset.reservedAmount) {
            revert PoolErrors.InsufficientPoolAmount(_token);
        }
        // Validate the global short size for non-stablecoin tokens
        if (!isStableCoin[_token]) {
            _validateGlobalShortSize(_token, asset, _assetPrice);
        }
        // Update the asset information in the tranche
        trancheAssets[_tranche][_token] = asset;
    }

    /**
     * @dev Ensures that the maximum short PnL (which equals the total short size) does not exceed the pool's value.
     *
     * @param _token The address of the token.
     * @param _asset The asset information for the token.
     * @param _assetPrice The current price of the token.
     *
     * @notice Reverts with `PoolErrors.InsufficientPoolAmount` if the total short size exceeds the pool's capacity.
     */
    function _validateGlobalShortSize(address _token, AssetInfo memory _asset, uint256 _assetPrice) internal pure {
        // Calculate the pool's available value
        uint256 poolValue = (_asset.poolAmount - _asset.reservedAmount) * _assetPrice + _asset.guaranteedValue;
        // Ensure the total short size does not exceed the pool's available value
        if (poolValue < _asset.totalShortSize) {
            revert PoolErrors.InsufficientPoolAmount(_token);
        }
    }

    /**
     * @dev Returns the pseudo pool asset by summing the asset information across all tranches.
     *
     * @param _token The address of the token.
     *
     * @return asset The aggregated asset information for the token across all tranches.
     */
    function _getPoolAsset(address _token) internal view returns (AssetInfo memory asset) {
        // Iterate through all tranches and sum the asset information
        for (uint256 i = 0; i < allTranches.length;) {
            address tranche = allTranches[i];
            asset.poolAmount += trancheAssets[tranche][_token].poolAmount;
            asset.reservedAmount += trancheAssets[tranche][_token].reservedAmount;
            asset.totalShortSize += trancheAssets[tranche][_token].totalShortSize;
            asset.guaranteedValue += trancheAssets[tranche][_token].guaranteedValue;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Reserves assets when opening a position and ensures the reserve does not exceed the pool's capacity.
     *
     * @param _key The position key.
     * @param _vars The variables for increasing the position.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the position (e.g., long or short).
     *
     * @notice Reverts with `PoolErrors.MaxGlobalShortSizeExceeded` if the global short size exceeds the maximum allowed.
     *         Reverts with `PoolErrors.InsufficientPoolAmount` if the reserve exceeds the pool's capacity.
     */
    function _reservePoolAsset(
        bytes32 _key,
        IncreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) internal {
        // Retrieve the collateral asset information
        AssetInfo memory collateral = _getPoolAsset(_collateralToken);
        // Determine the maximum reserve amount based on the position side
        uint256 maxReserve = collateral.poolAmount;
        if (_side == Side.LONG) {
            // Apply the maximum reserve ratio for long positions
            uint256 maxReserveRatio = maxGlobalLongSizeRatios[_indexToken];
            if (maxReserveRatio != 0) {
                maxReserve = MathUtils.frac(maxReserve, maxReserveRatio, PRECISION);
            }
        } else {
            // Validate the global short size for short positions
            uint256 maxGlobalShortSize = maxGlobalShortSizes[_indexToken];
            uint256 globalShortSize = collateral.totalShortSize + _vars.sizeChanged;
            if (maxGlobalShortSize != 0 && maxGlobalShortSize < globalShortSize) {
                revert PoolErrors.MaxGlobalShortSizeExceeded(_indexToken, globalShortSize);
            }
        }
        // Ensure the reserve does not exceed the pool's capacity
        if (collateral.reservedAmount + _vars.reserveAdded > maxReserve) {
            revert PoolErrors.InsufficientPoolAmount(_collateralToken);
        }
        // Add the DAO fee to the fee reserve
        poolTokens[_collateralToken].feeReserve += _vars.daoFee;
        // Reserve the asset in the tranche
        _reserveTrancheAsset(_key, _vars, _indexToken, _collateralToken, _side);
    }

    /**
     * @dev Releases assets when closing a position and distributes or takes realized PnL.
     *
     * @param _key The position key.
     * @param _vars The variables for decreasing the position.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the position (e.g., long or short).
     *
     * @notice Reverts with `PoolErrors.ReserveReduceTooMuch` if the reserve reduction exceeds the reserved amount.
     */
    function _releasePoolAsset(
        bytes32 _key,
        DecreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) internal {
        // Retrieve the collateral asset information
        AssetInfo memory collateral = _getPoolAsset(_collateralToken);
        // Ensure the reserve reduction does not exceed the reserved amount
        if (collateral.reservedAmount < _vars.reserveReduced) {
            revert PoolErrors.ReserveReduceTooMuch(_collateralToken);
        }
        // Add the DAO fee to the fee reserve
        poolTokens[_collateralToken].feeReserve += _vars.daoFee;
        // Release the asset in the tranche
        _releaseTranchesAsset(_key, _vars, _indexToken, _collateralToken, _side);
    }

    /**
     * @dev Reserves assets in tranches when opening a position and updates tranche-specific data.
     *
     * @param _key The position key.
     * @param _vars The variables for increasing the position.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the position (e.g., long or short).
     *
     * @notice This function distributes the reserve amount, LP fees, and collateral across all tranches.
     *         For long positions, it adjusts the guaranteed value.
     *         For short positions, it updates the global short price and validates the global short size.
     */
    function _reserveTrancheAsset(
        bytes32 _key,
        IncreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) internal {
        // Calculate the shares of the reserve or collateral amount across tranches
        uint256[] memory shares;
        uint256 totalShare;
        if (_vars.reserveAdded != 0) {
            totalShare = _vars.reserveAdded;
            shares = _calcTrancheSharesAmount(_indexToken, _collateralToken, totalShare, false);
        } else {
            totalShare = _vars.collateralAmount;
            shares = _calcTrancheSharesAmount(_indexToken, _collateralToken, totalShare, true);
        }
        // Iterate through all tranches and update their asset information
        for (uint256 i = 0; i < shares.length;) {
            address tranche = allTranches[i];
            uint256 share = shares[i];
            AssetInfo memory collateral = trancheAssets[tranche][_collateralToken];
            // Reserve the asset in the tranche
            uint256 reserveAmount = MathUtils.frac(_vars.reserveAdded, share, totalShare);
            tranchePositionReserves[tranche][_key] += reserveAmount;
            collateral.reservedAmount += reserveAmount;
            // Add LP fees to the pool amount
            collateral.poolAmount +=
                MathUtils.frac(_vars.totalLpFee, riskFactor[_indexToken][tranche], totalRiskFactor[_indexToken]);

            if (_side == Side.LONG) {
                // Adjust the pool amount and guaranteed value for long positions
                collateral.poolAmount = MathUtils.addThenSubWithFraction(
                    collateral.poolAmount, _vars.collateralAmount, _vars.feeAmount, share, totalShare
                );
                collateral.guaranteedValue = MathUtils.addThenSubWithFraction(
                    collateral.guaranteedValue,
                    _vars.sizeChanged + _vars.feeValue,
                    _vars.collateralValueAdded,
                    share,
                    totalShare
                );
            } else {
                // Update global short price and validate global short size for short positions
                AssetInfo memory indexAsset = trancheAssets[tranche][_indexToken];
                uint256 sizeChanged = MathUtils.frac(_vars.sizeChanged, share, totalShare);
                uint256 indexPrice = _vars.indexPrice;
                _updateGlobalShortPrice(tranche, _indexToken, sizeChanged, true, indexPrice, 0);
                indexAsset.totalShortSize += sizeChanged;
                _validateGlobalShortSize(_indexToken, indexAsset, indexPrice);
                trancheAssets[tranche][_indexToken] = indexAsset;
            }
            // Update the tranche's collateral information
            trancheAssets[tranche][_collateralToken] = collateral;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Releases assets in tranches when closing a position and distributes or takes realized PnL.
     *
     * @param _key The position key.
     * @param _vars The variables for decreasing the position.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the position (e.g., long or short).
     *
     * @notice This function reduces the reserve amount, updates the pool amount, and distributes PnL across all tranches.
     *         For long positions, it adjusts the guaranteed value.
     *         For short positions, it updates the global short price and reduces the total short size.
     */
    function _releaseTranchesAsset(
        bytes32 _key,
        DecreasePositionVars memory _vars,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) internal {
        // Get the total reserve amount for the position
        uint256 totalShare = positions[_key].reserveAmount;
        // Iterate through all tranches and update their asset information
        for (uint256 i = 0; i < allTranches.length;) {
            address tranche = allTranches[i];
            uint256 share = tranchePositionReserves[tranche][_key];
            AssetInfo memory collateral = trancheAssets[tranche][_collateralToken];
            // Reduce the reserve amount in the tranche
            {
                uint256 reserveReduced = MathUtils.frac(_vars.reserveReduced, share, totalShare);
                tranchePositionReserves[tranche][_key] -= reserveReduced;
                collateral.reservedAmount -= reserveReduced;
            }
            // Add LP fees to the pool amount and reduce the pool amount based on the share
            uint256 lpFee =
                MathUtils.frac(_vars.totalLpFee, riskFactor[_indexToken][tranche], totalRiskFactor[_indexToken]);
            collateral.poolAmount = (
                (collateral.poolAmount + lpFee).toInt256() - _vars.poolAmountReduced.frac(share, totalShare)
            ).toUint256();
            // Distribute PnL based on the share
            int256 pnl = _vars.pnl.frac(share, totalShare);
            if (_side == Side.LONG) {
                // Adjust the guaranteed value for long positions
                collateral.guaranteedValue = MathUtils.addThenSubWithFraction(
                    collateral.guaranteedValue, _vars.collateralReduced, _vars.sizeChanged, share, totalShare
                );
            } else {
                // Update global short price and reduce the total short size for short positions
                AssetInfo memory indexAsset = trancheAssets[tranche][_indexToken];
                uint256 sizeChanged = MathUtils.frac(_vars.sizeChanged, share, totalShare);
                {
                    uint256 indexPrice = _vars.indexPrice;
                    _updateGlobalShortPrice(tranche, _indexToken, sizeChanged, false, indexPrice, pnl);
                }
                indexAsset.totalShortSize = MathUtils.zeroCapSub(indexAsset.totalShortSize, sizeChanged);
                trancheAssets[tranche][_indexToken] = indexAsset;
            }
            // Update the tranche's collateral information
            trancheAssets[tranche][_collateralToken] = collateral;
            // Emit an event to log the PnL distribution
            emit PnLDistributed(_collateralToken, tranche, pnl.abs(), pnl >= 0);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Distributes an amount of tokens across all tranches based on their risk factors.
     *
     * @param _indexToken The token whose risk factors are used to calculate the distribution ratio.
     * @param _collateralToken The token whose pool amount or reserve will be changed.
     * @param _amount The total amount to distribute across tranches.
     * @param _isIncreasePoolAmount If true, the amount is added to the pool amount; if false, the amount is deducted from the reserve.
     *
     * @return reserves An array of amounts distributed to each tranche.
     *
     * @notice This function calculates how much of the `_amount` should be allocated to each tranche based on their risk factors.
     *         If `_isIncreasePoolAmount` is false, the amount distributed to each tranche is capped by the available amount
     *         (pool amount - reserved amount) to ensure no overflows.
     *         Reverts with `PoolErrors.CannotDistributeToTranches` if the amount cannot be fully distributed.
     */
    function _calcTrancheSharesAmount(
        address _indexToken,
        address _collateralToken,
        uint256 _amount,
        bool _isIncreasePoolAmount
    ) internal view returns (uint256[] memory reserves) {
        // Initialize arrays to store tranche-specific data
        uint256 nTranches = allTranches.length;
        reserves = new uint256[](nTranches);
        uint256[] memory factors = new uint256[](nTranches);
        uint256[] memory maxShare = new uint256[](nTranches);
        // Populate the factors and maxShare arrays for each tranche
        for (uint256 i = 0; i < nTranches;) {
            address tranche = allTranches[i];
            AssetInfo memory asset = trancheAssets[tranche][_collateralToken];
            // Use risk factor for non-stablecoin tokens; otherwise, use 1
            factors[i] = isStableCoin[_indexToken] ? 1 : riskFactor[_indexToken][tranche];
            // Set the maximum share for the tranche
            maxShare[i] = _isIncreasePoolAmount ? type(uint256).max : asset.poolAmount - asset.reservedAmount;
            unchecked {
                ++i;
            }
        }
        // Calculate the total factor (sum of all risk factors or number of tranches for stablecoins)
        uint256 totalFactor = isStableCoin[_indexToken] ? nTranches : totalRiskFactor[_indexToken];
        // Distribute the amount across tranches
        for (uint256 k = 0; k < nTranches;) {
            unchecked {
                ++k;
            }
            uint256 totalRiskFactor_ = totalFactor;
            // Iterate through each tranche to calculate its share
            for (uint256 i = 0; i < nTranches;) {
                uint256 riskFactor_ = factors[i];
                if (riskFactor_ != 0) {
                    // Calculate the share amount for the tranche
                    uint256 shareAmount = MathUtils.frac(_amount, riskFactor_, totalRiskFactor_);
                    // Ensure the share does not exceed the available amount
                    uint256 availableAmount = maxShare[i] - reserves[i];
                    if (shareAmount >= availableAmount) {
                        // Cap the share to the available amount and exclude the tranche from further rounds
                        shareAmount = availableAmount;
                        totalFactor -= riskFactor_;
                        factors[i] = 0;
                    }
                    // Update the tranche's reserve and reduce the remaining amount
                    reserves[i] += shareAmount;
                    _amount -= shareAmount;
                    totalRiskFactor_ -= riskFactor_;
                    // If the amount is fully distributed, return the reserves
                    if (_amount == 0) {
                        return reserves;
                    }
                }
                unchecked {
                    ++i;
                }
            }
        }
        // Revert if the amount cannot be fully distributed
        revert PoolErrors.CannotDistributeToTranches(_indexToken, _collateralToken, _amount, _isIncreasePoolAmount);
    }

    /**
     * @dev Rebalances funds between tranches after a token swap.
     *
     * @param _tokenIn The address of the input token.
     * @param _amountIn The amount of the input token.
     * @param _tokenOut The address of the output token.
     * @param _amountOut The amount of the output token.
     *
     * @notice This function distributes the output token amount across all tranches and updates the pool amounts
     *         for both the input and output tokens in each tranche.
     */
    function _rebalanceTranches(address _tokenIn, uint256 _amountIn, address _tokenOut, uint256 _amountOut) internal {
        // Calculate the amount of the output token to be deducted from each tranche
        uint256[] memory outAmounts = _calcTrancheSharesAmount(_tokenIn, _tokenOut, _amountOut, false);
        // Iterate through all tranches and update their pool amounts
        for (uint256 i = 0; i < allTranches.length;) {
            address tranche = allTranches[i];
            trancheAssets[tranche][_tokenOut].poolAmount -= outAmounts[i];
            trancheAssets[tranche][_tokenIn].poolAmount += MathUtils.frac(_amountIn, outAmounts[i], _amountOut);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Checks if a position is eligible for liquidation.
     *
     * @param _position The position to check.
     * @param _side The side of the position (e.g., long or short).
     * @param _indexPrice The current price of the index token.
     * @param _borrowIndex The current borrow index.
     *
     * @return allowed Whether the position can be liquidated.
     *
     * @notice A position can be liquidated if:
     *         1. Its collateral cannot cover the margin fee.
     *         2. Its collateral is below the maintenance margin.
     *         3. Its collateral is insufficient to cover the liquidation fee.
     */
    function _liquidatePositionAllowed(Position memory _position, Side _side, uint256 _indexPrice, uint256 _borrowIndex)
        internal
        view
        returns (bool allowed)
    {
        // If the position size is zero, liquidation is not allowed
        if (_position.size == 0) {
            return false;
        }
        // Calculate the fee required to close the position
        uint256 feeValue = _calcPositionFee(_position, _position.size, _borrowIndex);
        // Calculate the position's PnL
        int256 pnl = PositionUtils.calcPnl(_side, _position.size, _position.entryPrice, _indexPrice);
        // Calculate the remaining collateral after accounting for PnL
        int256 collateral = pnl + _position.collateralValue.toInt256();
        // Check if the position meets any of the liquidation conditions
        return collateral < 0 || uint256(collateral) * PRECISION < _position.size * maintenanceMargin
            || uint256(collateral) < (feeValue + fee.liquidationFee);
    }

    /**
     * @dev Calculates the payout and other variables when decreasing a position.
     *
     * @param _position The position to decrease.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the position (e.g., long or short).
     * @param _sizeChanged The amount by which the position size is decreased.
     * @param _collateralChanged The amount by which the collateral is decreased.
     * @param isLiquidate Whether the decrease is due to liquidation.
     *
     * @return vars A struct containing the calculated variables.
     *
     * @notice This function calculates the payout, fees, and other adjustments when decreasing a position.
     *         It ensures that the payout does not exceed the available collateral and handles liquidation-specific logic.
     */
    function _calcDecreasePayout(
        Position memory _position,
        address _indexToken,
        address _collateralToken,
        Side _side,
        uint256 _sizeChanged,
        uint256 _collateralChanged,
        bool isLiquidate
    ) internal view returns (DecreasePositionVars memory vars) {
        // Sanitize user input
        vars.sizeChanged = MathUtils.min(_position.size, _sizeChanged);
        vars.collateralReduced = _position.collateralValue < _collateralChanged || _position.size == vars.sizeChanged
            ? _position.collateralValue
            : _collateralChanged;
        // Get the current prices of the index and collateral tokens
        vars.indexPrice = _getIndexPrice(_indexToken, _side, false);
        vars.collateralPrice = _getCollateralPrice(_collateralToken, false);
        // Calculate the reduced reserve amount
        vars.reserveReduced = (_position.reserveAmount * vars.sizeChanged) / _position.size;
        // Calculate the PnL and fee for the position
        vars.pnl = PositionUtils.calcPnl(_side, vars.sizeChanged, _position.entryPrice, vars.indexPrice);
        vars.feeValue = _calcPositionFee(_position, vars.sizeChanged, poolTokens[_collateralToken].borrowIndex);
        // Calculate the payout value after deducting fees and losses
        int256 payoutValue = vars.pnl + vars.collateralReduced.toInt256() - vars.feeValue.toInt256();
        if (isLiquidate) {
            payoutValue = payoutValue - fee.liquidationFee.toInt256();
        }
        // Calculate the remaining collateral
        int256 remainingCollateral = (_position.collateralValue - vars.collateralReduced).toInt256();
        // Adjust the payout and remaining collateral if the payout is negative
        if (payoutValue < 0) {
            remainingCollateral = remainingCollateral + payoutValue;
            payoutValue = 0;
        }
        // Convert the payout value to the collateral token amount
        int256 collateralPrice = vars.collateralPrice.toInt256();
        vars.payout = uint256(payoutValue / collateralPrice);
        // Calculate the reduced pool value
        int256 poolValueReduced = vars.pnl;
        if (remainingCollateral < 0) {
            if (!isLiquidate) {
                revert PoolErrors.UpdateCauseLiquidation();
            }
            // If liquidation is too slow, the pool must absorb the loss
            poolValueReduced = poolValueReduced - remainingCollateral;
            vars.remainingCollateral = 0;
        } else {
            vars.remainingCollateral = uint256(remainingCollateral);
        }
        // Adjust the pool value reduction for long and short positions
        if (_side == Side.LONG) {
            poolValueReduced = poolValueReduced + vars.collateralReduced.toInt256();
        } else if (poolValueReduced < 0) {
            // For short positions, cap the pool's loss to the collateral value minus fees
            poolValueReduced = poolValueReduced.cap(
                MathUtils.zeroCapSub(_position.collateralValue, vars.feeValue + fee.liquidationFee)
            );
        }
        // Calculate the reduced pool amount in the collateral token
        vars.poolAmountReduced = poolValueReduced / collateralPrice;
        // Calculate the DAO and LP fees
        (vars.daoFee, vars.totalLpFee) = _calcDaoFee(vars.feeValue / vars.collateralPrice);
    }

    /**
     * @dev Calculates the fee for a position.
     *
     * @param _position The position for which to calculate the fee.
     * @param _sizeChanged The amount by which the position size is changed.
     * @param _borrowIndex The current borrow index.
     *
     * @return feeValue The total fee for the position.
     *
     * @notice The fee consists of a borrow fee and a position fee.
     */
    function _calcPositionFee(Position memory _position, uint256 _sizeChanged, uint256 _borrowIndex)
        internal
        view
        returns (uint256 feeValue)
    {
        // Calculate the borrow fee
        uint256 borrowFee = ((_borrowIndex - _position.borrowIndex) * _position.size) / PRECISION;
        // Calculate the position fee
        uint256 positionFee = (_sizeChanged * fee.positionFee) / PRECISION;
        // Return the total fee
        feeValue = borrowFee + positionFee;
    }

    /**
     * @dev Retrieves the index price for a token based on the position side and operation type.
     *
     * @param _token The address of the token.
     * @param _side The side of the position (e.g., long or short).
     * @param _isIncrease Whether the operation is increasing the position size.
     *
     * @return The index price of the token.
     *
     * @notice The price is fetched as the maximum price if:
     *         - The operation is increasing the position size and the side is LONG.
     *         - The operation is decreasing the position size and the side is SHORT.
     *         Otherwise, the minimum price is fetched.
     */
    function _getIndexPrice(address _token, Side _side, bool _isIncrease) internal view returns (uint256) {
        // Determine whether to fetch the maximum price based on the side and operation type
        return _getPrice(_token, _isIncrease == (_side == Side.LONG));
    }

    /**
     * @dev Retrieves the collateral price for a token based on the operation type.
     *
     * @param _token The address of the collateral token.
     * @param _isIncrease Whether the operation is increasing the position size.
     *
     * @return The collateral price of the token.
     *
     * @notice If the token is a stablecoin, the price is forced to 1 (adjusted for decimals).
     *         Otherwise, the price is fetched as the minimum price if the operation is increasing,
     *         and the maximum price if the operation is decreasing.
     */
    function _getCollateralPrice(address _token, bool _isIncrease) internal view returns (uint256) {
        // If the token is a stablecoin, return a fixed price of 1 (adjusted for decimals)
        return (isStableCoin[_token])
            ? 10 ** (USD_VALUE_DECIMAL - IERC20Metadata(_token).decimals())
            : _getPrice(_token, !_isIncrease);
    }

    /**
     * @dev Retrieves the price of a token from the oracle.
     *
     * @param _token The address of the token.
     * @param _max Whether to fetch the maximum price.
     *
     * @return The price of the token.
     */
    function _getPrice(address _token, bool _max) internal view returns (uint256) {
        return oracle.getPrice(_token, _max);
    }

    /**
     * @dev Updates the global average short price for a token in a tranche.
     *
     * @param _tranche The address of the tranche.
     * @param _indexToken The address of the index token.
     * @param _sizeChanged The change in the short position size.
     * @param _isIncrease Whether the operation is increasing the short position size.
     * @param _indexPrice The current index price of the token.
     * @param _realizedPnl The realized PnL from the operation.
     *
     * @notice This function calculates the new average short price based on the change in position size,
     *         the current index price, and the realized PnL. The result is stored in `averageShortPrices`.
     */
    function _updateGlobalShortPrice(
        address _tranche,
        address _indexToken,
        uint256 _sizeChanged,
        bool _isIncrease,
        uint256 _indexPrice,
        int256 _realizedPnl
    ) internal {
        // Get the current total short size for the token in the tranche
        uint256 lastSize = trancheAssets[_tranche][_indexToken].totalShortSize;
        // Calculate the next total short size after the change
        uint256 nextSize = _isIncrease ? lastSize + _sizeChanged : MathUtils.zeroCapSub(lastSize, _sizeChanged);
        // Get the current average short price
        uint256 entryPrice = averageShortPrices[_tranche][_indexToken];
        // Calculate the new average short price
        uint256 shortPrice =
            PositionUtils.calcAveragePrice(Side.SHORT, lastSize, nextSize, entryPrice, _indexPrice, _realizedPnl);
        // Update the average short price in storage
        averageShortPrices[_tranche][_indexToken] = shortPrice;
    }

    /**
     * @dev Calculates the DAO fee and LP fee from a given fee amount.
     *
     * @param _feeAmount The total fee amount.
     *
     * @return daoFee The portion of the fee allocated to the DAO.
     * @return lpFee The portion of the fee allocated to LPs.
     *
     * @notice The DAO fee is calculated as a fraction of the total fee based on the `fee.daoFee` rate.
     *         The LP fee is the remaining amount after deducting the DAO fee.
     */
    function _calcDaoFee(uint256 _feeAmount) internal view returns (uint256 daoFee, uint256 lpFee) {
        // Calculate the DAO fee as a fraction of the total fee
        daoFee = MathUtils.frac(_feeAmount, fee.daoFee, PRECISION);
        // Calculate the LP fee as the remaining amount
        lpFee = _feeAmount - daoFee;
    }

    /**
     * @dev Decreases a position's size and collateral, and updates the position's state.
     *
     * @param _owner The address of the position owner.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _collateralChanged The amount of collateral to decrease.
     * @param _sizeChanged The amount by which to decrease the position size.
     * @param _side The side of the position (e.g., long or short).
     * @param _receiver The address to receive the payout.
     *
     * @notice This function reduces the position's size and collateral, calculates the payout,
     *         and updates the position's state. If the position size reaches zero, the position is closed.
     *         Emits events for position updates, payouts, and closures.
     *         Reverts if the position does not exist or if the token pair is invalid.
     */
    function _decreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _collateralChanged,
        uint256 _sizeChanged,
        Side _side,
        address _receiver
    ) internal {
        // Validate the token pair for the position
        _requireValidTokenPair(_indexToken, _collateralToken, _side, false);
        // Accrue interest for the collateral token
        uint256 borrowIndex = _accrueInterest(_collateralToken);
        // Get the position key and retrieve the position
        bytes32 key = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        // Revert if the position does not exist
        if (position.size == 0) {
            revert PoolErrors.PositionNotExists(_owner, _indexToken, _collateralToken, _side);
        }
        // Calculate the payout and other variables for decreasing the position
        DecreasePositionVars memory vars =
            _calcDecreasePayout(position, _indexToken, _collateralToken, _side, _sizeChanged, _collateralChanged, false);
        // Reset the collateral reduction to the actual reduced value
        vars.collateralReduced = position.collateralValue - vars.remainingCollateral;
        // Release the reserved assets in the pool
        _releasePoolAsset(key, vars, _indexToken, _collateralToken, _side);
        // Update the position's size, borrow index, reserve amount, and collateral value
        position.size = position.size - vars.sizeChanged;
        position.borrowIndex = borrowIndex;
        position.reserveAmount = position.reserveAmount - vars.reserveReduced;
        position.collateralValue = vars.remainingCollateral;
        // Validate the updated position
        _validatePosition(position, _collateralToken, _side, false, vars.indexPrice);
        // Emit an event for the decrease in position
        emit DecreasePosition(
            key,
            _owner,
            _collateralToken,
            _indexToken,
            vars.collateralReduced,
            vars.sizeChanged,
            _side,
            vars.indexPrice,
            vars.pnl.asTuple(),
            vars.feeValue
        );
        // If the position size reaches zero, close the position
        if (position.size == 0) {
            emit ClosePosition(
                key,
                position.size,
                position.collateralValue,
                position.entryPrice,
                position.borrowIndex,
                position.reserveAmount
            );
            // Delete the position from storage
            delete positions[key];
        } else {
            // Otherwise, emit an event for the updated position and store the changes
            emit UpdatePosition(
                key,
                position.size,
                position.collateralValue,
                position.entryPrice,
                position.borrowIndex,
                position.reserveAmount,
                vars.indexPrice
            );
            positions[key] = position;
        }
        // Transfer the payout to the receiver
        _doTransferOut(_collateralToken, _receiver, vars.payout);
        // Trigger the pool hook if it exists
        if (address(poolHook) != address(0)) {
            poolHook.postDecreasePosition(
                _owner,
                _indexToken,
                _collateralToken,
                _side,
                abi.encode(vars.sizeChanged, vars.collateralReduced, vars.feeValue)
            );
        }
    }

    // Order management functions

    /**
     * @dev Creates a stop-loss order for a position.
     *
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _triggerPrice The price at which the stop-loss order should trigger.
     * @param _size The size of the position to be closed when the order triggers.
     * @param _side The side of the position (e.g., long or short).
     *
     * @notice This function creates a stop-loss order and stores it in the `stopLossOrders` mapping.
     *         It emits a `StopLossOrderCreated` event with the order details.
     *         Debugging logs are included to track the order creation process.
     */
    function createStopLossOrder(
        address _indexToken,
        address _collateralToken,
        uint256 _triggerPrice,
        uint256 _size,
        Side _side
    ) external {
        // Generate a unique key for the order
        bytes32 key = _getOrderKey(msg.sender, _indexToken, _collateralToken, _side);
        // Store the stop-loss order in the mapping
        stopLossOrders[key] = StopLossOrder({
            owner: msg.sender,
            indexToken: _indexToken,
            collateralToken: _collateralToken,
            triggerPrice: _triggerPrice,
            size: _size,
            side: _side,
            isExecuted: false
        });
        // Log values for debugging
        console.log("Order Created - Key:", uint256(key));
        console.log("Owner:", msg.sender);
        console.log("Index Token:", _indexToken);
        console.log("Collateral Token:", _collateralToken);
        console.log("Trigger Price:", _triggerPrice);
        console.log("Size:", _size);
        console.log("Side:", uint256(_side));
        // Emit an event for the created stop-loss order
        emit StopLossOrderCreated(key, msg.sender, _indexToken, _collateralToken, _triggerPrice, _size, _side);
    }

    /**
     * @dev Creates a take-profit order for a position.
     *
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _triggerPrice The price at which the take-profit order should trigger.
     * @param _size The size of the position to be closed when the order triggers.
     * @param _side The side of the position (e.g., long or short).
     *
     * @notice This function creates a take-profit order and stores it in the `takeProfitOrders` mapping.
     *         It emits a `TakeProfitOrderCreated` event with the order details.
     */
    function createTakeProfitOrder(
        address _indexToken,
        address _collateralToken,
        uint256 _triggerPrice,
        uint256 _size,
        Side _side
    ) external {
        // Generate a unique key for the order
        bytes32 key = _getOrderKey(msg.sender, _indexToken, _collateralToken, _side);
        // Store the take-profit order in the mapping
        takeProfitOrders[key] = TakeProfitOrder({
            owner: msg.sender,
            indexToken: _indexToken,
            collateralToken: _collateralToken,
            triggerPrice: _triggerPrice,
            size: _size,
            side: _side,
            isExecuted: false
        });
        // Emit an event for the created take-profit order
        emit TakeProfitOrderCreated(key, msg.sender, _indexToken, _collateralToken, _triggerPrice, _size, _side);
    }

    /**
     * @dev Creates a trailing stop order for a position.
     *
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _trailingDelta The delta used to calculate the trailing stop price.
     * @param _size The size of the position to be closed when the order triggers.
     * @param _side The side of the position (e.g., long or short).
     *
     * @notice This function creates a trailing stop order and stores it in the `trailingStopOrders` mapping.
     *         It emits a `TrailingStopOrderCreated` event with the order details.
     *         Debugging logs are included to track the order creation process.
     *         Reverts if the index token or collateral token is invalid.
     */
    function createTrailingStopOrder(
        address _indexToken,
        address _collateralToken,
        uint256 _trailingDelta,
        uint256 _size,
        Side _side
    ) external {
        // Validate the input tokens
        require(_indexToken != address(0), "Invalid index token");
        require(_collateralToken != address(0), "Invalid collateral token");
        // Generate a unique key for the order
        bytes32 key = _getOrderKey(msg.sender, _indexToken, _collateralToken, _side);
        // Log values for debugging
        console.log("Creating trailing stop order with key:", uint256(key));
        console.log("Index Token:", _indexToken);
        console.log("Collateral Token:", _collateralToken);
        console.log("Trailing Delta:", _trailingDelta);
        console.log("Size:", _size);
        console.log("Side:", uint256(_side));
        // Store the trailing stop order in the mapping
        trailingStopOrders[key] = TrailingStopOrder({
            owner: msg.sender,
            indexToken: _indexToken,
            collateralToken: _collateralToken,
            trailingDelta: _trailingDelta,
            size: _size,
            side: _side,
            lastPrice: _getIndexPrice(_indexToken, _side, true),
            isExecuted: false
        });
        // Emit an event for the created trailing stop order
        emit TrailingStopOrderCreated(key, msg.sender, _indexToken, _collateralToken, _trailingDelta, _size, _side);
    }

    /**
     * @dev Generates a unique key for an order based on the owner, tokens, and position side.
     *
     * @param _owner The address of the order owner.
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _side The side of the position (e.g., long or short).
     *
     * @return A unique bytes32 key representing the order.
     */
    function _getOrderKey(address _owner, address _indexToken, address _collateralToken, Side _side)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

    /**
     * @dev Executes a stop-loss order if the trigger conditions are met.
     *
     * @param _key The unique key identifying the stop-loss order.
     *
     * @notice This function checks if the stop-loss order has not already been executed and validates the token addresses.
     *         It then checks if the current price meets the trigger condition based on the position side (LONG or SHORT).
     *         If the condition is met, the position is decreased, and the order is marked as executed.
     *         Debugging logs are included to track the execution process.
     *         Reverts if the order has already been executed or if the token addresses are invalid.
     */
    function executeStopLossOrder(bytes32 _key) external onlyOrderManager {
        // Retrieve the stop-loss order from storage
        StopLossOrder memory order = stopLossOrders[_key];
        require(!order.isExecuted, "Order already executed");
        // Debug logs for tracking execution
        console.log("Executing Order - Key:", uint256(_key));
        console.log("Order Owner:", order.owner);
        console.log("Index Token:", order.indexToken);
        console.log("Collateral Token:", order.collateralToken);
        console.log("Trigger Price:", order.triggerPrice);
        console.log("Size:", order.size);
        console.log("Side:", uint256(order.side));
        // Validate the token addresses
        require(order.indexToken != address(0), "Invalid index token");
        require(order.collateralToken != address(0), "Invalid collateral token");
        // Get the current price of the index token
        uint256 currentPrice = _getIndexPrice(order.indexToken, order.side, false);
        // Check if the trigger condition is met based on the position side
        if (
            (order.side == Side.LONG && currentPrice <= order.triggerPrice)
                || (order.side == Side.SHORT && currentPrice >= order.triggerPrice)
        ) {
            // Decrease the position if the condition is met
            _decreasePosition(
                order.owner, order.indexToken, order.collateralToken, order.size, order.size, order.side, order.owner
            );
            // Mark the order as executed and update storage
            order.isExecuted = true;
            stopLossOrders[_key] = order;
            // Emit an event for the executed stop-loss order
            emit StopLossOrderExecuted(
                _key, order.owner, order.indexToken, order.collateralToken, order.triggerPrice, order.size, order.side
            );
        }
    }

    /**
     * @dev Executes a take-profit order if the trigger conditions are met.
     *
     * @param _key The unique key identifying the take-profit order.
     *
     * @notice This function checks if the take-profit order has not already been executed and validates the token addresses.
     *         It then checks if the current price meets the trigger condition based on the position side (LONG or SHORT).
     *         If the condition is met, the position is decreased, and the order is marked as executed.
     *         Reverts if the order has already been executed, the token addresses are invalid, or the trigger condition is not met.
     */
    function executeTakeProfitOrder(bytes32 _key) external onlyOrderManager {
        // Retrieve the take-profit order from storage
        TakeProfitOrder memory order = takeProfitOrders[_key];
        require(!order.isExecuted, "Order already executed");
        // Validate the token addresses
        require(order.indexToken != address(0), "Invalid index token");
        require(order.collateralToken != address(0), "Invalid collateral token");
        // Get the current price of the index token
        uint256 currentPrice = _getIndexPrice(order.indexToken, order.side, false);
        // Check if the trigger condition is met based on the position side
        bool isTriggered = (order.side == Side.LONG && currentPrice >= order.triggerPrice)
            || (order.side == Side.SHORT && currentPrice <= order.triggerPrice);
        // Revert if the trigger condition is not met
        require(isTriggered, "Order not triggered");
        // Decrease the position if the condition is met
        _decreasePosition(
            order.owner, order.indexToken, order.collateralToken, order.size, order.size, order.side, order.owner
        );
        // Mark the order as executed and update storage
        order.isExecuted = true;
        takeProfitOrders[_key] = order;
        // Emit an event for the executed take-profit order
        emit TakeProfitOrderExecuted(
            _key, order.owner, order.indexToken, order.collateralToken, order.triggerPrice, order.size, order.side
        );
    }

    /**
     * @dev Executes a trailing stop order if the trigger conditions are met.
     *
     * @param _key The unique key identifying the trailing stop order.
     *
     * @notice This function checks if the trailing stop order has not already been executed and validates the token addresses.
     *         It then checks if the current price meets the trigger condition based on the position side (LONG or SHORT).
     *         For LONG positions, the trigger condition is met if the price drops below (lastPrice - trailingDelta).
     *         For SHORT positions, the trigger condition is met if the price rises above (lastPrice + trailingDelta).
     *         If the condition is met, the position is decreased, and the order is marked as executed.
     *         If the condition is not met, the last price is updated.
     *         Debugging logs are included to track the execution process.
     *         Reverts if the order has already been executed or if the token addresses are invalid.
     */
    function executeTrailingStopOrder(bytes32 _key) external onlyOrderManager {
        // Retrieve the trailing stop order from storage
        TrailingStopOrder memory order = trailingStopOrders[_key];
        // Debug logs for tracking execution
        console.log("Executing trailing stop order with key:", uint256(_key));
        console.log("Order Owner:", order.owner);
        console.log("Index Token:", order.indexToken);
        console.log("Collateral Token:", order.collateralToken);
        console.log("Trailing Delta:", order.trailingDelta);
        console.log("Size:", order.size);
        console.log("Side:", uint256(order.side));
        console.log("Last Price:", order.lastPrice);
        console.log("Is Executed:", order.isExecuted);
        // Validate the token addresses
        require(!order.isExecuted, "Order already executed");
        require(order.indexToken != address(0), "Invalid index token");
        require(order.collateralToken != address(0), "Invalid collateral token");
        // Get the current price of the index token
        uint256 currentPrice = _getIndexPrice(order.indexToken, order.side, false);
        console.log("Current Price:", currentPrice);

        if (order.side == Side.LONG) {
            // For LONG positions, trigger if price drops below (lastPrice - trailingDelta)
            uint256 triggerPrice = order.lastPrice - order.trailingDelta;
            console.log("Trigger Price (LONG):", triggerPrice);

            if (currentPrice <= triggerPrice) {
                console.log("Trailing stop condition met. Decreasing position...");
                _decreasePosition(
                    order.owner,
                    order.indexToken,
                    order.collateralToken,
                    order.size,
                    order.size,
                    order.side,
                    order.owner
                );

                // Mark the order as executed and update storage
                order.isExecuted = true;
                trailingStopOrders[_key] = order;
                // Emit an event for the executed trailing stop order
                emit TrailingStopOrderExecuted(
                    _key,
                    order.owner,
                    order.indexToken,
                    order.collateralToken,
                    order.trailingDelta,
                    order.size,
                    order.side
                );
            } else {
                console.log("Trailing stop condition not met. Updating last price...");
                order.lastPrice = currentPrice;
                trailingStopOrders[_key] = order;
            }
        } else if (order.side == Side.SHORT) {
            // For SHORT positions, trigger if price rises above (lastPrice + trailingDelta)
            uint256 triggerPrice = order.lastPrice + order.trailingDelta;
            console.log("Trigger Price (SHORT):", triggerPrice);

            if (currentPrice >= triggerPrice) {
                console.log("Trailing stop condition met. Decreasing position...");
                _decreasePosition(
                    order.owner,
                    order.indexToken,
                    order.collateralToken,
                    order.size,
                    order.size,
                    order.side,
                    order.owner
                );
                // Mark the order as executed and update storage
                order.isExecuted = true;
                trailingStopOrders[_key] = order;
                // Emit an event for the executed trailing stop order
                emit TrailingStopOrderExecuted(
                    _key,
                    order.owner,
                    order.indexToken,
                    order.collateralToken,
                    order.trailingDelta,
                    order.size,
                    order.side
                );
            } else {
                console.log("Trailing stop condition not met. Updating last price...");
                order.lastPrice = currentPrice;
                trailingStopOrders[_key] = order;
            }
        }
    }
}
