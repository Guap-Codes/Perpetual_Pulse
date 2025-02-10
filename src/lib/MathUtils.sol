// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

library MathUtils {
    /**
     * @dev Returns the absolute difference between two numbers.
     * @param a First number.
     * @param b Second number.
     * @return uint256 The absolute difference between `a` and `b`.
     */
    function diff(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return a > b ? a - b : b - a;
        }
    }


    /**
     * @dev Returns the result of subtracting `b` from `a`, but ensures the result is never negative. 
     * If the result would be negative, returns 0.
     * @param a Minuend (the number from which `b` is subtracted).
     * @param b Subtrahend (the number to be subtracted).
     * @return uint256 The result of `a - b`, or 0 if the result is negative.
     */
    function zeroCapSub(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return a > b ? a - b : 0;
        }
    }

    /**
     * @dev Returns the fraction of an amount, calculated as `amount * num / denom`.
     * @param amount The total amount.
     * @param num The numerator of the fraction.
     * @param denom The denominator of the fraction.
     * @return uint256 The result of `amount * num / denom`.
     */
    function frac(uint256 amount, uint256 num, uint256 denom) internal pure returns (uint256) {
        return amount * num / denom;
    }

    /**
     * @dev Returns the minimum of two numbers.
     * @param a First number.
     * @param b Second number.
     * @return uint256 The smaller of `a` and `b`.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Adds `add` to `orig`, then subtracts `sub`, with both operations scaled by `num/denum`.
     * Returns the result of the operation, ensuring the subtraction result does not go below zero.
     * @param orig The original value.
     * @param add The value to add to `orig`.
     * @param sub The value to subtract from the result of `orig + add`.
     * @param num The numerator used for scaling.
     * @param denum The denominator used for scaling.
     * @return uint256 The result of the operation `(orig + add * num / denum) - (sub * num / denum)`.
     */
    function addThenSubWithFraction(uint256 orig, uint256 add, uint256 sub, uint256 num, uint256 denum)
        internal
        pure
        returns (uint256)
    {
        return zeroCapSub(orig + MathUtils.frac(add, num, denum), MathUtils.frac(sub, num, denum));
    }
}
