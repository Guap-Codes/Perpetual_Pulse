// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

/**
 * @title ILPToken
 * @dev Interface for a Liquidity Provider (LP) token, extending the ERC-20 standard with mint and burn functionality.
 */
interface ILPToken is IERC20 {
    /**
     * @notice Mints new LP tokens and assigns them to a specified address.
     * @dev Can only be called by authorized contracts or roles.
     * @param to The address to receive the minted LP tokens.
     * @param amount The amount of LP tokens to mint.
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burns LP tokens from a specified address.
     * @dev The caller must have approval to burn tokens from the given account.
     * @param account The address from which to burn LP tokens.
     * @param amount The amount of LP tokens to burn.
     */
    function burnFrom(address account, uint256 amount) external;
}
