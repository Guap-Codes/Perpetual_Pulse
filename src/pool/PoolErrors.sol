// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {Side} from "../interfaces/IPool.sol";

/**
 * @title PoolErrors
 * @notice A library containing custom errors used in the pool contract.
 * @dev These errors provide detailed information about specific failure conditions in the pool.
 */
library PoolErrors {
    // General Errors
    error UpdateCauseLiquidation(); // Thrown when an update would cause a position to be liquidated.
    error InvalidTokenPair(address index, address collateral); // Thrown when an invalid token pair is provided.
    error InvalidLeverage(uint256 size, uint256 margin, uint256 maxLeverage); // Thrown when leverage exceeds the maximum allowed.
    error InvalidPositionSize(); // Thrown when the position size is invalid.
    error OrderManagerOnly(); // Thrown when a function is called by someone other than the order manager.
    error UnknownToken(address token); // Thrown when an unknown token is referenced.
    error AssetNotListed(address token); // Thrown when an asset is not listed in the pool.
    error InsufficientPoolAmount(address token); // Thrown when the pool has insufficient funds for a token.
    error ReserveReduceTooMuch(address token); // Thrown when attempting to reduce reserves beyond available amounts.
    error SlippageExceeded(); // Thrown when slippage exceeds the allowed limit.
    error ValueTooHigh(uint256 maxValue); // Thrown when a value exceeds the maximum allowed.
    error InvalidInterval(); // Thrown when an invalid interval is provided.
    error PositionNotLiquidated(bytes32 key); // Thrown when a position is not liquidated as expected.
    error ZeroAmount(); // Thrown when a zero amount is provided where it is not allowed.
    error ZeroAddress(); // Thrown when a zero address is provided where it is not allowed.
    error RequireAllTokens(); // Thrown when all tokens are required but not provided.
    error DuplicateToken(address token); // Thrown when a duplicate token is provided.
    error FeeDistributorOnly(); // Thrown when a function is called by someone other than the fee distributor.
    error InvalidMaxLeverage(); // Thrown when an invalid max leverage value is provided.
    error SameTokenSwap(address token); // Thrown when attempting to swap the same token.
    error InvalidTranche(address tranche); // Thrown when an invalid tranche is referenced.
    error TrancheAlreadyAdded(address tranche); // Thrown when a tranche is already added to the pool.
    error RemoveLiquidityTooMuch(address tranche, uint256 outAmount, uint256 trancheBalance); // Thrown when attempting to remove more liquidity than available.
    error CannotDistributeToTranches(
        address indexToken, address collateralToken, uint256 amount, bool CannotDistributeToTranches
    ); // Thrown when funds cannot be distributed to tranches.
    error CannotSetRiskFactorForStableCoin(address token); // Thrown when attempting to set a risk factor for a stablecoin.
    error PositionNotExists(address owner, address indexToken, address collateralToken, Side side); // Thrown when a position does not exist.
    error MaxNumberOfTranchesReached(); // Thrown when the maximum number of tranches is reached.
    error TooManyTokenAdded(uint256 number, uint256 max); // Thrown when too many tokens are added to the pool.
    error AddLiquidityNotAllowed(address tranche, address token); // Thrown when adding liquidity is not allowed for a specific tranche and token.
    error MaxGlobalShortSizeExceeded(address token, uint256 globalShortSize); // Thrown when the global short size exceeds the maximum allowed.
    error NotApplicableForStableCoin(); // Thrown when an operation is not applicable for stablecoins.

    // Order-Related Errors
    error OrderAlreadyExecuted(); // Thrown when an order has already been executed.
    error InvalidTriggerPrice(); // Thrown when an invalid trigger price is provided.
    error InvalidTrailingDelta(); // Thrown when an invalid trailing delta is provided.
}
