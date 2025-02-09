// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IPoolHook} from "../interfaces/IPoolHook.sol";
import {Side, IPool} from "../interfaces/IPool.sol";
import {IMintableErc20} from "../interfaces/IMintableErc20.sol";
import {IPulseOracle} from "../interfaces/IPulseOracle.sol";
import {IReferralController} from "../interfaces/IReferralController.sol";

/**
 * @title IPoolForHook
 * @dev Interface for interacting with the pool contract in the context of the hook.
 */
interface IPoolForHook {
    function oracle() external view returns (IPulseOracle);
    function isStableCoin(address) external view returns (bool);
}

/**
 * @title PoolHook
 * @dev A contract that integrates with a liquidity pool, handling position updates, swaps, and referral rewards.
 * It mints LY tokens as rewards for traders and updates referral data for traders.
 */
contract PoolHook is Ownable, IPoolHook {
    uint256 constant MULTIPLIER_PRECISION = 100;    // Precision for multipliers
    uint256 constant MAX_MULTIPLIER = 5 * MULTIPLIER_PRECISION;     // Maximum allowed multiplier value
    uint8 constant lyPulseDecimals = 18;     // Decimals for LY token
    uint256 constant VALUE_PRECISION = 1e30;    // Precision for value calculations

    // Immutable state variables
    address private immutable pool;     // Address of the pool contract
    IMintableErc20 public immutable lyPulse;  // LY token contract

      // State variables
    uint256 public positionSizeMultiplier = 100; // Multiplier for position size rewards
    uint256 public swapSizeMultiplier = 100; // Multiplier for swap size rewards
    uint256 public stableSwapSizeMultiplier = 5; // Multiplier for stablecoin swap rewards
    IReferralController public referralController; // Referral controller contract

    /**
     * @dev Constructor to initialize the contract.
     * @param _lyPulse Address of the LY token contract.
     * @param _pool Address of the pool contract.
     */
    constructor(address _lyPulse, address _pool) {
        require(_lyPulse != address(0), "PoolHook:invalidAddress");
        require(_pool != address(0), "PoolHook:invalidAddress");
        lyPulse = IMintableErc20(_lyPulse);
        pool = _pool;
    }

    /**
     * @dev Validates that the sender is the pool contract.
     * @param sender Address of the sender.
     */
    function validatePool(address sender) internal view {
        require(sender == pool, "PoolHook:!pool");
    }

    /**
     * @dev Modifier to restrict access to the pool contract.
     */
    modifier onlyPool() {
        validatePool(msg.sender);
        _;
    }

    /**
     * @dev Executes logic after a position is increased.
     * @param _owner Address of the position owner.
     * @param _indexToken Address of the index token.
     * @param _collateralToken Address of the collateral token.
     * @param _side Side of the position (LONG or SHORT).
     * @param _extradata Additional data related to the position increase.
     */
    function postIncreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side,
        bytes calldata _extradata
    ) external onlyPool {
        (,, uint256 _feeValue) = abi.decode(_extradata, (uint256, uint256, uint256));
        _updateReferralData(_owner, _feeValue);
        emit PostIncreasePositionExecuted(pool, _owner, _indexToken, _collateralToken, _side, _extradata);
    }

    /**
     * @dev Executes logic after a position is decreased.
     * @param _owner Address of the position owner.
     * @param _indexToken Address of the index token.
     * @param _collateralToken Address of the collateral token.
     * @param _side Side of the position (LONG or SHORT).
     * @param _extradata Additional data related to the position decrease.
     */
    function postDecreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side,
        bytes calldata _extradata
    ) external onlyPool {
        (uint256 sizeChange, /* uint256 collateralValue */, uint256 _feeValue) =
            abi.decode(_extradata, (uint256, uint256, uint256));
        _handlePositionClosed(_owner, _indexToken, _collateralToken, _side, sizeChange);
        _updateReferralData(_owner, _feeValue);
        emit PostDecreasePositionExecuted(msg.sender, _owner, _indexToken, _collateralToken, _side, _extradata);
    }

    /**
     * @dev Executes logic after a position is liquidated.
     * @param _owner Address of the position owner.
     * @param _indexToken Address of the index token.
     * @param _collateralToken Address of the collateral token.
     * @param _side Side of the position (LONG or SHORT).
     * @param _extradata Additional data related to the position liquidation.
     */
    function postLiquidatePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        Side _side,
        bytes calldata _extradata
    ) external onlyPool {
        (uint256 sizeChange, /* uint256 collateralValue */ ) = abi.decode(_extradata, (uint256, uint256));
        _handlePositionClosed(_owner, _indexToken, _collateralToken, _side, sizeChange);

        emit PostLiquidatePositionExecuted(msg.sender, _owner, _indexToken, _collateralToken, _side, _extradata);
    }

    /**
     * @dev Executes logic after a swap is executed.
     * @param _user Address of the user performing the swap.
     * @param _tokenIn Address of the input token.
     * @param _tokenOut Address of the output token.
     * @param _data Additional data related to the swap.
     */
    function postSwap(address _user, address _tokenIn, address _tokenOut, bytes calldata _data) external onlyPool {
        (uint256 amountIn, /* uint256 amountOut */, uint256 swapFee, bytes memory extradata) =
            abi.decode(_data, (uint256, uint256, uint256, bytes));
        (address benificier) = extradata.length != 0 ? abi.decode(extradata, (address)) : (address(0));
        benificier = benificier == address(0) ? _user : benificier;
        uint256 priceIn = _getPrice(_tokenIn, false);
        uint256 multiplier = _isStableSwap(_tokenIn, _tokenOut) ? stableSwapSizeMultiplier : swapSizeMultiplier;
        uint256 lyTokenAmount =
            (amountIn * priceIn * 10 ** lyPulseDecimals) * multiplier / MULTIPLIER_PRECISION / VALUE_PRECISION;
        if (lyTokenAmount != 0 && benificier != address(0)) {
            lyPulse.mint(benificier, lyTokenAmount);
        }

        _updateReferralData(benificier, swapFee * priceIn);
        emit PostSwapExecuted(msg.sender, _user, _tokenIn, _tokenOut, _data);
    }

    // ========= Admin Functions ========

    /**
     * @dev Sets the referral controller contract.
     * @param _referralController Address of the referral controller contract.
     */
    function setReferralController(address _referralController) external onlyOwner {
        require(_referralController != address(0), "PoolHook: _referralController invalid");
        referralController = IReferralController(_referralController);
        emit ReferralControllerSet(_referralController);
    }

    /**
     * @dev Sets the multipliers for position size, swap size, and stablecoin swap size.
     * @param _positionSizeMultiplier Multiplier for position size rewards.
     * @param _swapSizeMultiplier Multiplier for swap size rewards.
     * @param _stableSwapSizeMultiplier Multiplier for stablecoin swap rewards.
     */
    function setMultipliers(
        uint256 _positionSizeMultiplier,
        uint256 _swapSizeMultiplier,
        uint256 _stableSwapSizeMultiplier
    ) external onlyOwner {
        require(_positionSizeMultiplier <= MAX_MULTIPLIER, "Multiplier too high");
        require(_swapSizeMultiplier <= MAX_MULTIPLIER, "Multiplier too high");
        require(_stableSwapSizeMultiplier <= MAX_MULTIPLIER, "Multiplier too high");
        positionSizeMultiplier = _positionSizeMultiplier;
        swapSizeMultiplier = _swapSizeMultiplier;
        stableSwapSizeMultiplier = _stableSwapSizeMultiplier;
        emit MultipliersSet(positionSizeMultiplier, swapSizeMultiplier, stableSwapSizeMultiplier);
    }

    // ========= Internal function ========

    /**
     * @dev Updates referral data for a trader.
     * @param _trader Address of the trader.
     * @param _value Value to update in the referral system.
     */
    function _updateReferralData(address _trader, uint256 _value) internal {
        if (address(referralController) != address(0)) {
            referralController.updatePoint(_trader, _value);
        }
    }

    /**
     * @dev Handles logic when a position is closed.
     * @param _owner Address of the position owner.
     * @param _sizeChange Change in position size.
     */
    function _handlePositionClosed(
        address _owner,
        address, /* _indexToken */
        address, /* _collateralToken */
        Side, /* _side */
        uint256 _sizeChange
    ) internal {
        uint256 lyTokenAmount =
            (_sizeChange * 10 ** lyPulseDecimals) * positionSizeMultiplier / MULTIPLIER_PRECISION / VALUE_PRECISION;

        if (lyTokenAmount != 0) {
            lyPulse.mint(_owner, lyTokenAmount);
        }
    }

     /**
     * @dev Gets the price of a token from the oracle.
     * @param token Address of the token.
     * @param max Whether to get the maximum price.
     * @return uint256 Price of the token.
     */
    function _getPrice(address token, bool max) internal view returns (uint256) {
        IPulseOracle oracle = IPoolForHook(pool).oracle();
        return oracle.getPrice(token, max);
    }

    /**
     * @dev Checks if a swap involves stablecoins.
     * @param tokenIn Address of the input token.
     * @param tokenOut Address of the output token.
     * @return bool Whether the swap involves stablecoins.
     */
    function _isStableSwap(address tokenIn, address tokenOut) internal view returns (bool) {
        IPoolForHook _pool = IPoolForHook(pool);
        return _pool.isStableCoin(tokenIn) && _pool.isStableCoin(tokenOut);
    }

    /**
     * @dev Emitted when the referral controller is set.
     */
    event ReferralControllerSet(address controller);
    /**
     * @dev Emitted when the multipliers are set.
     */
    event MultipliersSet(uint256 positionSizeMultiplier, uint256 swapSizeMultiplier, uint256 stableSwapSizeMultiplier);
}
