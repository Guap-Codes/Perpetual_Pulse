// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IWETH} from "../interfaces/IWETH.sol";
import {IETHUnwrapper} from "../interfaces/IETHUnwrapper.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ETHUnwrapper
 * @notice A contract to unwrap WETH (Wrapped Ether) into ETH (Ether) and transfer it to a specified address.
 * @dev This contract implements the `IETHUnwrapper` interface and uses `SafeERC20` for secure WETH transfers.
 */
contract ETHUnwrapper is IETHUnwrapper {
    using SafeERC20 for IWETH;

    /// @notice Immutable WETH contract address.
    IWETH private immutable weth;

    /**
     * @dev Constructor to initialize the ETHUnwrapper contract.
     * @param _weth The address of the WETH contract.
     * @notice Reverts if the `_weth` address is zero.
     */
    constructor(address _weth) {
        require(_weth != address(0), "Invalid weth address"); // Ensure the WETH address is not zero
        weth = IWETH(_weth); // Set the WETH contract address
    }

    /**
     * @dev Unwraps WETH into ETH and transfers it to the specified address.
     * @param _amount The amount of WETH to unwrap.
     * @param _to The address to receive the unwrapped ETH.
     * @notice This function transfers WETH from the caller to this contract, unwraps it into ETH, and transfers
     *         all ETH in the contract to the specified address.
     */
    function unwrap(uint256 _amount, address _to) external {
        // Transfer WETH from the caller to this contract
        weth.safeTransferFrom(msg.sender, address(this), _amount);
        // Unwrap WETH into ETH
        weth.withdraw(_amount);
        // Transfer all ETH in the contract to the specified address
        _safeTransferETH(_to, address(this).balance);
    }

    /**
     * @dev Safely transfers ETH to a specified address.
     * @param _to The address to receive the ETH.
     * @param _amount The amount of ETH to transfer.
     * @notice This function uses a low-level call to transfer ETH and reverts if the transfer fails.
     */
    function _safeTransferETH(address _to, uint256 _amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = _to.call{value: _amount}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED"); // Revert if the ETH transfer fails
    }

    /**
     * @dev Fallback function to receive ETH.
     * @notice This function allows the contract to receive ETH directly.
     */
    receive() external payable {}
}
