// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {PoolStorage, AssetInfo, PoolTokenInfo, Position, MAX_TRANCHES} from "src/pool/PoolStorage.sol";
import {Side, IPool} from "../interfaces/IPool.sol";
import {SignedIntOps} from "../lib/SignedInt.sol";
import {PositionUtils} from "../lib/PositionUtils.sol";
import {IPulseOracle} from "../interfaces/IPulseOracle.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";

/**
 * @title PoolLens Library Contracts
 * @notice This file provides several helper structures and a contract (PoolLens)
 * that aggregates and exposes read-only data on pool assets, positions, and asset under management.
 */

/**
 * @notice Represents a view of a trading position.
 * @param key The unique identifier of the position.
 * @param size The notional size of the position.
 * @param collateralValue The total collateral value assigned to the position.
 * @param entryPrice The price at which the position was opened.
 * @param pnl The absolute profit and loss value of the position.
 * @param reserveAmount The reserved collateral for the position.
 * @param hasProfit Boolean indicating whether the position is in profit.
 * @param collateralToken The token address used as collateral.
 * @param borrowIndex The borrow index at position creation.
 */
struct PositionView {
    bytes32 key;
    uint256 size;
    uint256 collateralValue;
    uint256 entryPrice;
    uint256 pnl;
    uint256 reserveAmount;
    bool hasProfit;
    address collateralToken;
    uint256 borrowIndex;
}

/**
 * @notice Represents aggregated information about an asset in the pool.
 * @param poolAmount The total amount of the asset held in the pool.
 * @param reservedAmount The portion of the asset reserved for open positions.
 * @param feeReserve The amount of fees reserved in the asset.
 * @param guaranteedValue The guaranteed collateral value for open positions.
 * @param totalShortSize The total short position size for the asset.
 * @param averageShortPrice The weighted average price of all short positions.
 * @param poolBalance The effective pool balance of the asset.
 * @param lastAccrualTimestamp Timestamp when interest was last accrued.
 * @param borrowIndex The current borrow index for interest calculations.
 */
struct PoolAsset {
    uint256 poolAmount;
    uint256 reservedAmount;
    uint256 feeReserve;
    uint256 guaranteedValue;
    uint256 totalShortSize;
    uint256 averageShortPrice;
    uint256 poolBalance;
    uint256 lastAccrualTimestamp;
    uint256 borrowIndex;
}

/**
 * @notice Extended interface for a pool, adding additional view methods for lens functionality.
 */
interface IPoolForLens is IPool {
    function getPoolAsset(address _token) external view returns (AssetInfo memory);
    function trancheAssets(address _tranche, address _token) external view returns (AssetInfo memory);
    function getAllTranchesLength() external view returns (uint256);
    function allTranches(uint256) external view returns (address);
    function poolTokens(address) external view returns (PoolTokenInfo memory);
    function positions(bytes32) external view returns (Position memory);
    function oracle() external view returns (IPulseOracle);
    function getPoolValue(bool _max) external view returns (uint256);
    function getTrancheValue(address _tranche, bool _max) external view returns (uint256 sum);
    function averageShortPrices(address _tranche, address _token) external view returns (uint256);
    function isStableCoin(address) external view returns (bool);
}

/**
 * @title PoolLens
 * @notice Aggregates and exposes read-only information about a pool. It provides helper
 * methods to view asset metrics, positions, and assets under management across the pool and its tranches.
 */
contract PoolLens {
    using SignedIntOps for int256;
    using SafeCast for uint256;
    using SafeCast for int256;

    /**
     * @notice Aggregates asset information for a specified token in the pool.
     * @param _pool The address of the pool contract.
     * @param _token The address of the asset token.
     * @return poolAsset A PoolAsset structure containing aggregated data:
     * - poolAmount, reservedAmount, guaranteedValue, totalShortSize (from AssetInfo)
     * - feeReserve, poolBalance, lastAccrualTimestamp, borrowIndex (from PoolTokenInfo)
     * - averageShortPrice computed over all tranches.
     */
    function poolAssets(address _pool, address _token) external view returns (PoolAsset memory poolAsset) {
        IPoolForLens self = IPoolForLens(_pool);
        AssetInfo memory asset = self.getPoolAsset(_token);
        PoolTokenInfo memory tokenInfo = self.poolTokens(_token);
        uint256 avgShortPrice;
        uint256 nTranches = self.getAllTranchesLength();
        for (uint256 i = 0; i < nTranches;) {
            address tranche = self.allTranches(i);
            uint256 shortSize = self.trancheAssets(tranche, _token).totalShortSize;
            avgShortPrice += shortSize * self.averageShortPrices(tranche, _token);
            unchecked {
                ++i;
            }
        }
        poolAsset.poolAmount = asset.poolAmount;
        poolAsset.reservedAmount = asset.reservedAmount;
        poolAsset.guaranteedValue = asset.guaranteedValue;
        poolAsset.totalShortSize = asset.totalShortSize;
        poolAsset.feeReserve = tokenInfo.feeReserve;
        poolAsset.averageShortPrice = asset.totalShortSize == 0 ? 0 : avgShortPrice / asset.totalShortSize;
        poolAsset.poolBalance = tokenInfo.poolBalance;
        poolAsset.lastAccrualTimestamp = tokenInfo.lastAccrualTimestamp;
        poolAsset.borrowIndex = tokenInfo.borrowIndex;
    }

    /**
     * @notice Retrieves a detailed view of a trading position.
     * @param _pool The address of the pool contract.
     * @param _owner The address of the position owner.
     * @param _indexToken The address of the token being traded.
     * @param _collateralToken The address of the token used as collateral.
     * @param _side The side of the position (LONG or SHORT).
     * @return result A PositionView struct containing the position key, size, collateral value,
     * entry price, absolute PnL, profit flag, reserved collateral, borrow index, and collateral token.
     */
    function getPosition(
        address _pool,
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) external view returns (PositionView memory result) {
        IPoolForLens self = IPoolForLens(_pool);
        IPulseOracle oracle = self.oracle();
        bytes32 positionKey = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = self.positions(positionKey);
        uint256 indexPrice =
            _side == Side.LONG ? oracle.getPrice(_indexToken, false) : oracle.getPrice(_indexToken, true);
        int256 pnl = PositionUtils.calcPnl(_side, position.size, position.entryPrice, indexPrice);

        result.key = positionKey;
        result.size = position.size;
        result.collateralValue = position.collateralValue;
        result.pnl = pnl.abs();
        result.hasProfit = pnl > 0;
        result.entryPrice = position.entryPrice;
        result.borrowIndex = position.borrowIndex;
        result.reserveAmount = position.reserveAmount;
        result.collateralToken = _collateralToken;
    }

    /**
     * @notice Computes the unique key for a given position.
     * @dev Combines the owner, index token, collateral token, and position side.
     * @param _owner The owner of the position.
     * @param _indexToken The token being traded.
     * @param _collateralToken The token used for collateral.
     * @param _side The position side (LONG or SHORT).
     * @return A bytes32 hash that uniquely identifies the position.
     */
    function _getPositionKey(
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

    /**
     * @notice Computes the average value of a given tranche.
     * @param _pool The pool instance implementing IPoolForLens.
     * @param _tranche The address of the tranche.
     * @return The average tranche value, computed as the average of its min and max values.
     */
    function getTrancheValue(IPoolForLens _pool, address _tranche) external view returns (uint256) {
        return (_pool.getTrancheValue(_tranche, true) + _pool.getTrancheValue(_tranche, false)) / 2;
    }

    /**
     * @notice Computes the average overall pool value (AUM) by averaging the min and max pool values.
     * @param _pool The pool instance.
     * @return The average pool value.
     */
    function getPoolValue(IPoolForLens _pool) external view returns (uint256) {
        return (_pool.getPoolValue(true) + _pool.getPoolValue(false)) / 2;
    }

    /**
     * @notice Structure that holds aggregated pool value data.
     * @param minValue The minimum pool value.
     * @param maxValue The maximum pool value.
     * @param tranchesMinValue An array of minimum values for each tranche.
     * @param tranchesMaxValue An array of maximum values for each tranche.
     */
    struct PoolInfo {
        uint256 minValue;
        uint256 maxValue;
        uint256[MAX_TRANCHES] tranchesMinValue;
        uint256[MAX_TRANCHES] tranchesMaxValue;
    }

    /**
     * @notice Returns comprehensive pool information including overall pool values and per-tranche values.
     * @param _pool The pool instance.
     * @return info A PoolInfo struct containing the min and max pool value and arrays of min and max values for each tranche.
     */
    function getPoolInfo(IPoolForLens _pool) external view returns (PoolInfo memory info) {
        info.minValue = _pool.getPoolValue(false);
        info.maxValue = _pool.getPoolValue(true);
        uint256 nTranches = _pool.getAllTranchesLength();
        for (uint256 i = 0; i < nTranches;) {
            address tranche = _pool.allTranches(i);
            info.tranchesMinValue[i] = _pool.getTrancheValue(tranche, false);
            info.tranchesMaxValue[i] = _pool.getTrancheValue(tranche, true);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Calculates the Asset Under Management (AUM) for a specific asset within a given tranche.
     * @param _poolAddress The address of the pool (which is a PoolStorage contract).
     * @param _tranche The tranche address.
     * @param _token The asset token address.
     * @param _max A flag indicating whether to use the maximum price (true) or the minimum price (false).
     * @return The AUM for the asset within the tranche.
     */
    function getAssetAum(
        address _poolAddress,
        address _tranche,
        address _token,
        bool _max
    ) external view returns (uint256) {
        PoolStorage _pool = PoolStorage(_poolAddress);
        bool isStable = _pool.isStableCoin(_token);
        IPulseOracle oracle = _pool.oracle();
        uint256 price = oracle.getPrice(_token, _max);
        (uint256 poolAmount, uint256 reservedAmount, uint256 guaranteedValue, uint256 totalShortSize) =
            _pool.trancheAssets(_tranche, _token);
        if (isStable) {
            return poolAmount * price;
        } else {
            uint256 averageShortPrice = _pool.averageShortPrices(_tranche, _token);
            int256 shortPnl = PositionUtils.calcPnl(Side.SHORT, totalShortSize, averageShortPrice, price);
            int256 aum = ((poolAmount - reservedAmount) * price + guaranteedValue).toInt256() - shortPnl;
            return aum.toUint256();
        }
    }

    /**
     * @notice Calculates the total Assets Under Management (AUM) for a given asset across all tranches in the pool.
     * @param _pool The pool instance.
     * @param _token The asset token address.
     * @param _max A flag indicating whether to use the maximum price (true) or the minimum price (false).
     * @return The total AUM for the asset aggregated across all tranches.
     */
    function getAssetPoolAum(
        IPoolForLens _pool,
        address _token,
        bool _max
    ) external view returns (uint256) {
        bool isStable = _pool.isStableCoin(_token);
        uint256 price = _pool.oracle().getPrice(_token, _max);
        uint256 nTranches = _pool.getAllTranchesLength();

        int256 sum = 0;

        for (uint256 i = 0; i < nTranches; ++i) {
            address _tranche = _pool.allTranches(i);
            AssetInfo memory asset = _pool.trancheAssets(_tranche, _token);
            if (isStable) {
                sum = sum + (asset.poolAmount * price).toInt256();
            } else {
                uint256 averageShortPrice = _pool.averageShortPrices(_tranche, _token);
                int256 shortPnl = PositionUtils.calcPnl(Side.SHORT, asset.totalShortSize, averageShortPrice, price);
                sum = ((asset.poolAmount - asset.reservedAmount) * price + asset.guaranteedValue).toInt256() + sum - shortPnl;
            }
        }

        return sum.toUint256();
    }
}
