// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {Side} from "./IPool.sol";

/// @title IReferralController
/// @notice Interface for a referral system that tracks and updates referral points for traders.
/// @dev This contract is used to manage referral rewards by updating trader points based on their activity.
interface IReferralController {
    /**
     * @notice Updates the referral points for a given trader.
     * @dev This function is called externally to modify the trader's referral points based on their trading volume or activity.
     * @param _trader The address of the trader whose points are being updated.
     * @param _value The amount of points to be added or adjusted.
     */
    function updatePoint(address _trader, uint256 _value) external;
}
