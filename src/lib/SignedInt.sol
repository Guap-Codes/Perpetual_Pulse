// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.25;

import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

uint256 constant POS = 1;
uint256 constant NEG = 0;

/// @title SignedInt
/// @dev A structure to represent signed integers (with sign and absolute value)
///      The value range is from -(2 ^ 256 - 1) to (2 ^ 256 - 1).
/// @notice `sig` is the sign of the number: 1 for positive, 0 for negative.
///         `abs` stores the absolute value of the integer.
struct SignedInt {
    /// @dev sig = 1 -> positive, sig = 0 is negative
    /// using uint256 which take up full word to optimize gas and contract size
    uint256 sig;    // Sign of the number (1 for positive, 0 for negative)
    uint256 abs;    // Absolute value of the integer
}

library SignedIntOps {
    using SafeCast for uint256;

    /**
     * @dev Returns a fraction of an integer `a` scaled by `num` and `denom`.
     * @param a The integer to be scaled.
     * @param num The numerator to multiply with.
     * @param denom The denominator to divide by.
     * @return The resulting fraction.
     */
    function frac(int256 a, uint256 num, uint256 denom) internal pure returns (int256) {
        return a * num.toInt256() / denom.toInt256();
    }

    /**
     * @dev Returns the absolute value of a signed integer `x`.
     * @param x The signed integer.
     * @return The absolute value of `x`.
     */
    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /**
     * @dev Converts a signed integer `x` into a `SignedInt` structure.
     * @param x The signed integer to be converted.
     * @return A `SignedInt` struct representing the signed integer.
     */
    function asTuple(int256 x) internal pure returns (SignedInt memory) {
        return SignedInt({abs: abs(x), sig: x < 0 ? NEG : POS});
    }

    /**
     * @dev Caps the value of `x` to be within the range of [-maxAbs, maxAbs].
     * @param x The signed integer to be capped.
     * @param maxAbs The maximum absolute value allowed.
     * @return The capped integer value.
     */
    function cap(int256 x, uint256 maxAbs) internal pure returns (int256) {
        int256 min = -maxAbs.toInt256();
        return x > min ? x : min;
    }
}
