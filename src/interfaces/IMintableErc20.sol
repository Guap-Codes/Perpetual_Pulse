// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

/**
 * @title IMintableErc20
 * @dev Interface for an ERC-20 token with minting functionality.
 */
interface IMintableErc20 is IERC20 {
    /**
     * @notice Mints new tokens and assigns them to a specified address.
     * @dev Can only be called by authorized minters.
     * @param to The address to receive the minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external;
}
