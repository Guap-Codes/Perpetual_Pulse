// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Side, IPool} from "./IPool.sol";

/// @title IPoolHook
/// @notice Interface for a hook system that allows external contracts to execute logic after key pool operations.
/// @dev This interface provides hooks for post-execution logic in a decentralized exchange or liquidity pool.
interface IPoolHook {
    
    /**
     * @notice Hook triggered after a position is increased.
     * @dev This function allows external contracts to execute logic after a position increase.
     * @param owner The address of the position owner.
     * @param indexToken The address of the index token.
     * @param collateralToken The address of the collateral token.
     * @param side The side of the position (LONG or SHORT).
     * @param extradata Additional data passed for custom logic execution.
     */
    function postIncreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        bytes calldata extradata
    ) external;

    /**
     * @notice Hook triggered after a position is decreased.
     * @dev This function allows external contracts to execute logic after a position decrease.
     * @param owner The address of the position owner.
     * @param indexToken The address of the index token.
     * @param collateralToken The address of the collateral token.
     * @param side The side of the position (LONG or SHORT).
     * @param extradata Additional data passed for custom logic execution.
     */
    function postDecreasePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        bytes calldata extradata
    ) external;

    /**
     * @notice Hook triggered after a position is liquidated.
     * @dev This function allows external contracts to execute logic after a position liquidation.
     * @param owner The address of the position owner.
     * @param indexToken The address of the index token.
     * @param collateralToken The address of the collateral token.
     * @param side The side of the position (LONG or SHORT).
     * @param extradata Additional data passed for custom logic execution.
     */
    function postLiquidatePosition(
        address owner,
        address indexToken,
        address collateralToken,
        Side side,
        bytes calldata extradata
    ) external;

    /**
     * @notice Hook triggered after a token swap.
     * @dev This function allows external contracts to execute logic after a swap operation in the pool.
     * @param user The address of the user performing the swap.
     * @param tokenIn The address of the token being swapped from.
     * @param tokenOut The address of the token being swapped to.
     * @param data Additional data passed for custom logic execution.
     */
    function postSwap(
        address user,
        address tokenIn,
        address tokenOut,
        bytes calldata data
    ) external;

    /// @notice Event emitted before a position increase is executed.
    event PreIncreasePositionExecuted(
        address pool, address owner, address indexToken, address collateralToken, Side side, bytes extradata
    );
    /// @notice Event emitted after a position increase is executed.
    event PostIncreasePositionExecuted(
        address pool, address owner, address indexToken, address collateralToken, Side side, bytes extradata
    );
    /// @notice Event emitted before a position decrease is executed.
    event PreDecreasePositionExecuted(
        address pool, address owner, address indexToken, address collateralToken, Side side, bytes extradata
    );
    /// @notice Event emitted after a position decrease is executed.
    event PostDecreasePositionExecuted(
        address pool, address owner, address indexToken, address collateralToken, Side side, bytes extradata
    );
    /// @notice Event emitted before a position liquidation is executed.
    event PreLiquidatePositionExecuted(
        address pool, address owner, address indexToken, address collateralToken, Side side, bytes extradata
    );
    /// @notice Event emitted after a position liquidation is executed.
    event PostLiquidatePositionExecuted(
        address pool, address owner, address indexToken, address collateralToken, Side side, bytes extradata
    );
    /// @notice Event emitted after a token swap is executed.
    event PostSwapExecuted(address pool, address user, address tokenIn, address tokenOut, bytes data);
}
