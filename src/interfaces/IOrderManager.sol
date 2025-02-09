// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {IPool} from "./IPool.sol";

/**
 * @title Order
 * @dev Represents an order in the system.
 * @param pool The pool associated with the order.
 * @param owner The address of the order owner.
 * @param indexToken The token used as the index for the order.
 * @param collateralToken The token used as collateral for the order.
 * @param payToken The token used to pay for the order.
 * @param expiresAt The timestamp when the order expires.
 * @param submissionBlock The block number when the order was submitted.
 * @param price The price associated with the order.
 * @param executionFee The fee required to execute the order.
 * @param triggerAboveThreshold A boolean indicating whether the order triggers above a certain threshold.
 */
struct Order {
    IPool pool;
    address owner;
    address indexToken;
    address collateralToken;
    address payToken;
    uint256 expiresAt;
    uint256 submissionBlock;
    uint256 price;
    uint256 executionFee;
    bool triggerAboveThreshold;
}

/**
 * @title SwapOrder
 * @dev Represents a swap order in the system.
 * @param pool The pool associated with the swap order.
 * @param owner The address of the swap order owner.
 * @param tokenIn The token to be swapped.
 * @param tokenOut The token to be received after the swap.
 * @param amountIn The amount of `tokenIn` to be swapped.
 * @param minAmountOut The minimum amount of `tokenOut` expected from the swap.
 * @param price The price associated with the swap order.
 * @param executionFee The fee required to execute the swap order.
 */
struct SwapOrder {
    IPool pool;
    address owner;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    uint256 price;
    uint256 executionFee;
}

/**
 * @title IOrderManager
 * @dev Interface for managing orders and swap orders.
 */
interface IOrderManager {
    /**
     * @dev Retrieves the details of an order by its ID.
     * @param id The ID of the order.
     * @return Order The order details.
     */
    function orders(uint256 id) external view returns (Order memory);

    /**
     * @dev Retrieves the details of a swap order by its ID.
     * @param id The ID of the swap order.
     * @return SwapOrder The swap order details.
     */
    function swapOrders(uint256 id) external view returns (SwapOrder memory);

    /**
     * @dev Executes an order.
     * @param _key The key (ID) of the order to execute.
     * @param _feeTo The address to receive the execution fee.
     */
    function executeOrder(uint256 _key, address payable _feeTo) external;

    /**
     * @dev Executes a swap order.
     * @param _orderId The ID of the swap order to execute.
     * @param _feeTo The address to receive the execution fee.
     */
    function executeSwapOrder(uint256 _orderId, address payable _feeTo) external;
}