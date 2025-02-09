// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.25;

import {ERC20Burnable} from "openzeppelin/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

/**
 * @title LP Token
 * @notice LP Tokens are issued to users when they deposit tokens into the protocol. These tokens can be redeemed to
 *         receive any token of their choice.
 * @dev This contract extends `ERC20Burnable` to allow burning of LP tokens and restricts minting to a specific minter address.
 */
contract LPToken is ERC20Burnable {
    /// @notice Address of the minter, which is the only address allowed to mint new LP tokens.
    address public immutable minter;

    /**
     * @dev Constructor to initialize the LP Token contract.
     * @param _name The name of the LP token.
     * @param _symbol The symbol of the LP token.
     * @param _minter The address of the minter, which is the only address allowed to mint new LP tokens.
     * @notice Reverts if the `_minter` address is zero.
     */
    constructor(string memory _name, string memory _symbol, address _minter) ERC20(_name, _symbol) {
        require(_minter != address(0), "LPToken: address 0"); // Ensure the minter address is not zero
        minter = _minter; // Set the minter address
    }

    /**
     * @dev Mints new LP tokens to a specified address.
     * @param _to The address to receive the minted LP tokens.
     * @param _amount The amount of LP tokens to mint.
     * @notice Only the minter can call this function.
     * @notice Reverts if the caller is not the minter.
     */
    function mint(address _to, uint256 _amount) external {
        require(msg.sender == minter, "LPToken: !minter"); // Ensure only the minter can mint tokens
        _mint(_to, _amount); // Mint the tokens to the specified address
    }
}
