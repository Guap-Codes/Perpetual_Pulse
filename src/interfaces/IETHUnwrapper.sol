// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title IETHUnwrapper
 * @dev Interface for unwrapping Wrapped ETH (WETH) into native ETH.
 */
interface IETHUnwrapper {
    /**
     * @notice Unwraps WETH into native ETH and sends it to a specified address.
     * @dev Converts `_amount` of WETH into ETH and transfers it to `_to`.
     *      The caller must have sufficient WETH balance.
     * @param _amount The amount of WETH to unwrap.
     * @param _to The recipient address that will receive the unwrapped ETH.
     */
    function unwrap(uint256 _amount, address _to) external;
}
