// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {IPulseOracle} from "../interfaces/IPulseOracle.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {IPoolHook} from "../interfaces/IPoolHook.sol";

// Common precision for fee, tax, interest rate, and maintenance margin ratio
uint256 constant PRECISION = 1e10; // Precision factor for calculations
uint256 constant LP_INITIAL_PRICE = 1e12; // Initial price of LP tokens, fixed to $1
uint256 constant MAX_BASE_SWAP_FEE = 1e8; // Maximum base swap fee (1%)
uint256 constant MAX_TAX_BASIS_POINT = 1e8; // Maximum tax basis point (1%)
uint256 constant MAX_POSITION_FEE = 1e8; // Maximum position fee (1%)
uint256 constant MAX_LIQUIDATION_FEE = 10e30; // Maximum liquidation fee ($10)
uint256 constant MAX_TRANCHES = 3; // Maximum number of tranches allowed
uint256 constant MAX_ASSETS = 10; // Maximum number of assets allowed
uint256 constant MAX_INTEREST_RATE = 1e7; // Maximum interest rate (0.1%)
uint256 constant MAX_MAINTENANCE_MARGIN = 5e8; // Maximum maintenance margin (5%)

/**
 * @dev Struct representing fee configuration for the pool.
 */
struct Fee {
    uint256 positionFee; // Fee charged when changing position size
    uint256 liquidationFee; // Fee charged when liquidating a position (in dollars)
    uint256 baseSwapFee; // Swap fee used when adding/removing liquidity or swapping tokens
    uint256 taxBasisPoint; // Tax used to adjust swap fee based on token weight
    uint256 stableCoinBaseSwapFee; // Swap fee for stablecoins
    uint256 stableCoinTaxBasisPoint; // Tax for stablecoins
    uint256 daoFee; // Part of the fee allocated to the DAO
}

/**
 * @dev Struct representing a position in the pool.
 */
struct Position {
    uint256 size; // Contract size in dollars
    uint256 collateralValue; // Collateral value in dollars
    uint256 reserveAmount; // Contract size in index tokens
    uint256 entryPrice; // Average entry price
    uint256 borrowIndex; // Last cumulative interest rate
}

/**
 * @dev Struct representing pool token information.
 */
struct PoolTokenInfo {
    uint256 feeReserve; // Amount reserved for fees
    uint256 poolBalance; // Recorded balance of the token in the pool
    uint256 lastAccrualTimestamp; // Last borrow index update timestamp
    uint256 borrowIndex; // Accumulated interest rate
    uint256 ___averageShortPrice; // Deprecated: Average short price (must be calculated per tranche)
}

/**
 * @dev Struct representing asset information in the pool.
 */
struct AssetInfo {
    uint256 poolAmount; // Amount of token deposited (via add liquidity or increase long position)
    uint256 reservedAmount; // Amount reserved for paying out when decreasing long positions
    uint256 guaranteedValue; // Total borrowed (in USD) for leverage
    uint256 totalShortSize; // Total size of all short positions
}

/**
 * @title PoolStorage
 * @notice Abstract contract defining the storage layout and constants for the pool.
 * @dev This contract contains the state variables, constants, and structs used by the pool.
 */
abstract contract PoolStorage {
    // ========= Fee Configuration =========
    Fee public fee; // Fee configuration for the pool

    // ========= Fee Distribution =========
    address public feeDistributor; // Address of the fee distributor

    // ========= Oracle =========
    IPulseOracle public oracle; // Oracle contract for price feeds

    // ========= Order Management =========
    address public orderManager; // Address of the order manager

    // ========= Assets Management =========
    mapping(address => bool) public isAsset; // Mapping to check if an address is an asset
    address[] public allAssets; // List of all configured assets (including delisted ones)
    mapping(address => bool) public isListed; // Mapping to check if an asset is listed
    mapping(address => bool) public isStableCoin; // Mapping to check if an asset is a stablecoin
    mapping(address => PoolTokenInfo) public poolTokens; // Mapping of token addresses to their pool info
    mapping(address => uint256) public targetWeights; // Target weights for each token

    // ========= Tranche Management =========
    mapping(address => bool) public isTranche; // Mapping to check if an address is a tranche
    mapping(address => mapping(address => uint256)) public riskFactor; // Risk factor of each token in each tranche
    mapping(address => uint256) public totalRiskFactor; // Total risk score for each token
    address[] public allTranches; // List of all tranches
    mapping(address => mapping(address => AssetInfo)) public trancheAssets; // Asset info per tranche
    mapping(address => mapping(bytes32 => uint256)) public tranchePositionReserves; // Position reserves per tranche

    // ========= Interest Rate =========
    uint256 public interestRate; // Current interest rate
    uint256 public accrualInterval; // Interval for interest accrual

    // ========= Pool Value and Weight =========
    uint256 public totalWeight; // Total weight of all tokens
    uint256 public virtualPoolValue; // Cached pool value for faster computation

    // ========= Positions Management =========
    uint256 public maxLeverage; // Maximum leverage for each token
    mapping(bytes32 => Position) public positions; // Mapping of all open positions

    // ========= Pool Hook =========
    IPoolHook public poolHook; // Pool hook for external integrations

    // ========= Maintenance Margin =========
    uint256 public maintenanceMargin; // Maintenance margin ratio

    // ========= Liquidity Fee =========
    uint256 public addRemoveLiquidityFee; // Fee for adding/removing liquidity

    // ========= Short Positions =========
    mapping(address => mapping(address => uint256)) public averageShortPrices; // Average short prices per tranche

    // ========= Global Size Limits =========
    mapping(address => uint256) public maxGlobalShortSizes; // Maximum global short size per token
    mapping(address => uint256) public maxGlobalLongSizeRatios; // Maximum global long size ratio per token
}
