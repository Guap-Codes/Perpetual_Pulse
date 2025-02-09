// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

/**
 * @title IOrderHook
 * @dev Interface for handling post-order placement hooks.
 */
interface IOrderHook {
    /**
     * @notice Hook executed after an order is placed.
     * @dev Can be used for logging, validation, or additional processing.
     * @param orderId The ID of the order that was placed.
     * @param extradata Additional data that may be required for processing.
     */
    function postPlaceOrder(uint256 orderId, bytes calldata extradata) external;

    /**
     * @notice Hook executed after a swap order is placed.
     * @dev Allows for custom logic after a swap order is submitted.
     * @param swapOrderId The ID of the swap order that was placed.
     * @param extradata Additional data that may be required for processing.
     */
    function postPlaceSwapOrder(uint256 swapOrderId, bytes calldata extradata) external;
}
