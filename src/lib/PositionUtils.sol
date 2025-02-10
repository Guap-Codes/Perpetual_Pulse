// SPDX-License-Identifier: UNLCIENSED

pragma solidity 0.8.25;

import {Side} from "../interfaces/IPool.sol";
import {SignedInt, SignedIntOps} from "./SignedInt.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

library PositionUtils {
    using SafeCast for uint256;
    using SignedIntOps for int256;

    /**
     * @dev Calculates the profit and loss (PnL) for a position.
     * @param _side The position side (LONG or SHORT).
     * @param _positionSize The size of the position.
     * @param _entryPrice The price at which the position was entered.
     * @param _indexPrice The current price of the index.
     * @return int256 The calculated PnL. Positive value indicates profit, negative indicates loss.
     */
    function calcPnl(Side _side, uint256 _positionSize, uint256 _entryPrice, uint256 _indexPrice)
        internal
        pure
        returns (int256)
    {
        if (_positionSize == 0 || _entryPrice == 0) {
            return 0;
        }
        int256 entryPrice = _entryPrice.toInt256();
        int256 positionSize = _positionSize.toInt256();
        int256 indexPrice = _indexPrice.toInt256();
        if (_side == Side.LONG) {
            return (indexPrice - entryPrice) * positionSize / entryPrice;
        } else {
            return (entryPrice - indexPrice) * positionSize / entryPrice;
        }
    }

   /**
     * @notice Calculates the new average entry price when increasing a position.
     * @dev 
     * - For long positions: `nextAveragePrice = (nextPrice * nextSize) / (nextSize + delta)`
     * - For short positions: `nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)`
     * @param _side The position side (LONG or SHORT).
     * @param _lastSize The current size of the position before the increase.
     * @param _nextSize The new size of the position after the increase.
     * @param _entryPrice The current average entry price.
     * @param _nextPrice The price at which the position is being increased.
     * @param _realizedPnL The realized profit and loss from previous trades.
     * @return uint256 The new average entry price.
     */
    function calcAveragePrice(
        Side _side,
        uint256 _lastSize,
        uint256 _nextSize,
        uint256 _entryPrice,
        uint256 _nextPrice,
        int256 _realizedPnL
    ) internal pure returns (uint256) {
        if (_nextSize == 0) {
            return 0;
        }
        if (_lastSize == 0) {
            return _nextPrice;
        }
        int256 pnl = calcPnl(_side, _lastSize, _entryPrice, _nextPrice) - _realizedPnL;
        int256 nextSize = _nextSize.toInt256();
        int256 divisor = _side == Side.LONG ? nextSize + pnl : nextSize - pnl;
        return divisor <= 0 ? 0 : _nextSize * _nextPrice / uint256(divisor);
    }
}
