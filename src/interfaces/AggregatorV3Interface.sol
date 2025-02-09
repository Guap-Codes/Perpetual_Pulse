// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

/**
 * @title AggregatorV3Interface
 * @dev Interface for Chainlink price feeds, providing external data such as asset prices.
 */
interface AggregatorV3Interface {
    /**
     * @notice Returns the number of decimal places used by the aggregator.
     * @return The number of decimals in the price data.
     */
    function decimals() external view returns (uint8);

    /**
     * @notice Returns a human-readable description of the aggregator.
     * @return A string containing the description of the data feed.
     */
    function description() external view returns (string memory);

    /**
     * @notice Returns the version of the aggregator contract.
     * @return The version number.
     */
    function version() external view returns (uint256);

    /**
     * @notice Retrieves historical round data for a given round ID.
     * @dev If no data is available for the round, this function should revert with "No data present."
     * @param _roundId The ID of the round to fetch data for.
     * @return roundId The round ID.
     * @return answer The reported price or data value.
     * @return startedAt The timestamp when the round started.
     * @return updatedAt The timestamp when the round was last updated.
     * @return answeredInRound The round ID in which the answer was computed.
     */
    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    /**
     * @notice Retrieves the latest available round data.
     * @dev If no data is available, this function should revert with "No data present."
     * @return roundId The round ID.
     * @return answer The reported price or data value.
     * @return startedAt The timestamp when the round started.
     * @return updatedAt The timestamp when the round was last updated.
     * @return answeredInRound The round ID in which the answer was computed.
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
