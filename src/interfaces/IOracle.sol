// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

/**
 * @title IOracle
 * @dev Interface for retrieving asset prices from an oracle.
 */
interface IOracle {
    /**
     * @notice Retrieves the price of a given token.
     * @dev Returns the price in the smallest unit of the quote currency (e.g., wei for ETH-based pricing).
     * @param token The address of the token to fetch the price for.
     * @return The price of the token in the oracle’s pricing unit.
     */
    function getPrice(address token) external view returns (uint256);
}
