// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title IWETH
/// @notice Interface for Wrapped Ether (WETH), an ERC-20 token that represents Ether.
/// @dev WETH allows Ether (ETH) to be used as an ERC-20 token, enabling compatibility with DeFi protocols.
interface IWETH is IERC20 {
    /**
     * @notice Deposits ETH and mints WETH tokens.
     * @dev The amount of ETH sent with this call is wrapped into WETH.
     */
    function deposit() external payable;

    /**
     * @notice Transfers WETH tokens to another address.
     * @param to The recipient address.
     * @param value The amount of WETH to transfer.
     * @return A boolean indicating whether the transfer was successful.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @notice Converts WETH back into ETH and sends it to the caller.
     * @param amount The amount of WETH to unwrap.
     * @dev This burns WETH tokens and sends the equivalent ETH back to the caller.
     */
    function withdraw(uint256 amount) external;
}
