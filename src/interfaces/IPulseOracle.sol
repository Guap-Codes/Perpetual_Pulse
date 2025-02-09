// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

/// @title IPulseOracle
/// @notice Interface for an oracle that provides asset price data.
/// @dev This oracle can return single or multiple asset prices based on the specified parameters.
interface IPulseOracle {
    /**
     * @notice Retrieves the price of a given token.
     * @param token The address of the token to fetch the price for.
     * @param max A boolean indicating whether to return the maximum or minimum price.
     * @return The price of the token in the smallest unit (e.g., wei for ETH-based assets).
     */
    function getPrice(address token, bool max) external view returns (uint256);

    /**
     * @notice Retrieves the prices of multiple tokens in a single call.
     * @param tokens An array of token addresses to fetch prices for.
     * @param max A boolean indicating whether to return the maximum or minimum prices.
     * @return An array of prices corresponding to the input tokens, in the same order.
     */
    function getMultiplePrices(address[] calldata tokens, bool max) external view returns (uint256[] memory);
}
