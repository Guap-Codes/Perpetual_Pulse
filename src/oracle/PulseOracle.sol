// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IPulseOracle} from "../interfaces/IPulseOracle.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/**
 * @title PulseOracle
 * @notice A price feed oracle that combines on-chain price reporting with off-chain validation using Chainlink price feeds.
 * @dev This contract allows authorized reporters to post token prices, which are validated against Chainlink price feeds.
 *      It provides price retrieval functions with optional spreads to account for potential inaccuracies or stale data.
 */
contract PulseOracle is Ownable, IPulseOracle {
    // ============ Structs ============

    /**
     * @dev Struct representing the configuration for a token.
     */
    struct TokenConfig {
        uint256 baseUnits; // 10 ^ token decimals
        uint256 priceUnits; // Precision of price posted by reporter
        AggregatorV3Interface chainlinkPriceFeed; // Chainlink price feed for reference
        uint256 chainlinkDeviation; // Allowed deviation from Chainlink price
        uint256 chainlinkTimeout; // Timeout for Chainlink price feed updates
    }

    // ============ Constants ============

    /// @dev Precision for price values (10^30)
    uint256 constant VALUE_PRECISION = 1e30;
    /// @notice Precision used for spreads and deviations (10^6)
    uint256 constant PRECISION = 1e6;
    /// @notice Time after which a price feed is considered in error (1 hour)
    uint256 public constant PRICE_FEED_ERROR = 1 hours;
    /// @notice Time after which a price feed is considered inactive (5 minutes)
    uint256 public constant PRICE_FEED_INACTIVE = 5 minutes;
    /// @notice Spread applied when the price feed is in error (5%)
    uint256 public constant PRICE_FEED_ERROR_SPREAD = 5e4; // 5%
    /// @notice Spread applied when the price feed is inactive (0.2%)
    uint256 public constant PRICE_FEED_INACTIVE_SPREAD = 2e3; // 0.2%

    // ============ State Variables ============

    /// @notice Mapping of token addresses to their configurations
    mapping(address => TokenConfig) public tokenConfig;
    /// @notice List of whitelisted tokens
    address[] public whitelistedTokens;
    /// @notice Last reported price for each token
    mapping(address => uint256) public lastAnswers;
    /// @notice Timestamp of the last reported price for each token
    mapping(address => uint256) public lastAnswerTimestamp;
    /// @notice Block number of the last reported price for each token
    mapping(address => uint256) public lastAnswerBlock;
    /// @notice Mapping of authorized reporters
    mapping(address => bool) public isReporter;
    /// @notice List of authorized reporters
    address[] public reporters;

    // ============ Mutative Functions ============

    /**
     * @notice Allows authorized reporters to post prices for multiple tokens.
     * @param tokens Array of token addresses.
     * @param prices Array of prices corresponding to the tokens.
     * @dev Only authorized reporters can call this function.
     */
    function postPrices(address[] calldata tokens, uint256[] calldata prices) external {
        require(isReporter[msg.sender], "PriceFeed:unauthorized");
        uint256 count = tokens.length;
        require(prices.length == count, "PriceFeed:lengthMissMatch");
        for (uint256 i = 0; i < count;) {
            _postPrice(tokens[i], prices[i]);
            unchecked {
                ++i;
            }
        }
    }

    // ============ View Functions ============

    /**
     * @notice Retrieves prices for multiple tokens.
     * @param tokens Array of token addresses.
     * @param max Whether to return the maximum price (with spread).
     * @return Array of prices for the tokens.
     */
    function getMultiplePrices(address[] calldata tokens, bool max) external view returns (uint256[] memory) {
        uint256 len = tokens.length;
        uint256[] memory result = new uint256[](len);

        for (uint256 i = 0; i < len;) {
            result[i] = _getPrice(tokens[i], max);
            unchecked {
                ++i;
            }
        }

        return result;
    }

    /**
     * @notice Retrieves the price for a single token.
     * @param token Address of the token.
     * @param max Whether to return the maximum price (with spread).
     * @return The price of the token.
     */
    function getPrice(address token, bool max) external view returns (uint256) {
        return _getPrice(token, max);
    }

    /**
     * @notice Retrieves the last reported price for a token.
     * @param token Address of the token.
     * @return lastPrice The last reported price.
     */
    function getLastPrice(address token) external view returns (uint256 lastPrice) {
        (lastPrice,) = _getLastPrice(token);
    }

    // ============ Restricted Functions ============

    /**
     * @notice Configures a token for price reporting.
     * @param token Address of the token.
     * @param tokenDecimals Decimals of the token.
     * @param priceFeed Address of the Chainlink price feed.
     * @param priceDecimals Precision of the price posted by the reporter.
     * @param chainlinkTimeout Timeout for Chainlink price feed updates.
     * @param chainlinkDeviation Allowed deviation from the Chainlink price.
     * @dev Only the owner can call this function.
     */
    function configToken(
        address token,
        uint256 tokenDecimals,
        address priceFeed,
        uint256 priceDecimals,
        uint256 chainlinkTimeout,
        uint256 chainlinkDeviation
    ) external onlyOwner {
        require(priceFeed != address(0), "PriceFeed:invalidPriceFeed");
        require(tokenDecimals != 0 && priceDecimals != 0, "PriceFeed:invalidDecimals");
        require(chainlinkTimeout != 0, "PriceFeed:invalidTimeout");
        require(chainlinkDeviation != 0 && chainlinkDeviation < PRECISION / 2, "PriceFeed:invalidChainlinkDeviation");

        if (tokenConfig[token].baseUnits == 0) {
            whitelistedTokens.push(token);
        }

        tokenConfig[token] = TokenConfig({
            baseUnits: 10 ** tokenDecimals,
            priceUnits: 10 ** priceDecimals,
            chainlinkPriceFeed: AggregatorV3Interface(priceFeed),
            chainlinkTimeout: chainlinkTimeout,
            chainlinkDeviation: chainlinkDeviation
        });
        emit TokenAdded(token);
    }

    /**
     * @notice Adds an authorized reporter.
     * @param reporter Address of the reporter.
     * @dev Only the owner can call this function.
     */
    function addReporter(address reporter) external onlyOwner {
        require(!isReporter[reporter], "PriceFeed:reporterAlreadyAdded");
        isReporter[reporter] = true;
        reporters.push(reporter);
        emit ReporterAdded(reporter);
    }

    /**
     * @notice Removes an authorized reporter.
     * @param reporter Address of the reporter.
     * @dev Only the owner can call this function.
     */
    function removeReporter(address reporter) external onlyOwner {
        require(reporter != address(0), "PriceFeed:invalidAddress");
        require(isReporter[reporter], "PriceFeed:reporterNotExists");
        isReporter[reporter] = false;
        for (uint256 i = 0; i < reporters.length; i++) {
            if (reporters[i] == reporter) {
                reporters[i] = reporters[reporters.length - 1];
                break;
            }
        }
        reporters.pop();
        emit ReporterRemoved(reporter);
    }

    // ============ Internal Functions ============

    /**
     * @dev Posts a price for a token.
     * @param token Address of the token.
     * @param price The price to post.
     */
    function _postPrice(address token, uint256 price) internal {
        TokenConfig memory config = tokenConfig[token];
        require(config.baseUnits > 0, "PriceFeed:tokenNotConfigured");
        uint256 normalizedPrice = (price * VALUE_PRECISION) / config.baseUnits / config.priceUnits;
        lastAnswers[token] = normalizedPrice;
        lastAnswerTimestamp[token] = block.timestamp;
        lastAnswerBlock[token] = block.number;
        emit PricePosted(token, normalizedPrice);
    }

    /**
     * @dev Retrieves the price for a token with optional spread.
     * @param token Address of the token.
     * @param max Whether to return the maximum price (with spread).
     * @return The price of the token.
     */
    function _getPrice(address token, bool max) internal view returns (uint256) {
        (uint256 lastPrice, uint256 lastPriceTimestamp) = _getLastPrice(token);
        (uint256 refPrice, uint256 lowerBound, uint256 upperBound, uint256 minLowerBound, uint256 maxUpperBound) =
            _getReferencePrice(token);
        if (lastPriceTimestamp + PRICE_FEED_ERROR < block.timestamp) {
            return _getPriceSpread(refPrice, PRICE_FEED_ERROR_SPREAD, max);
        }

        if (lastPriceTimestamp + PRICE_FEED_INACTIVE < block.timestamp) {
            return _getPriceSpread(refPrice, PRICE_FEED_INACTIVE_SPREAD, max);
        }

        if (lastPrice > upperBound) {
            return max ? _min(lastPrice, maxUpperBound) : refPrice;
        }

        if (lastPrice < lowerBound) {
            return max ? refPrice : _max(lastPrice, minLowerBound);
        }

        // no spread, trust keeper
        return lastPrice;
    }

    /**
     * @dev Returns the minimum of two values.
     * @param _a The first value.
     * @param _b The second value.
     * @return The minimum value.
     */
    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a < _b ? _a : _b;
    }

    /**
     * @dev Returns the maximum of two values.
     * @param _a The first value.
     * @param _b The second value.
     * @return The maximum value.
     */
    function _max(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a > _b ? _a : _b;
    }

    /**
     * @dev Calculates the price with a spread.
     * @param pivot The base price.
     * @param spread The spread percentage.
     * @param max Whether to return the maximum price (with spread).
     * @return The price with the spread applied.
     */
    function _getPriceSpread(uint256 pivot, uint256 spread, bool max) internal pure returns (uint256) {
        return max ? pivot * (PRECISION + spread) / PRECISION : pivot * (PRECISION - spread) / PRECISION;
    }

    /**
     * @dev Retrieves the reference price from Chainlink and calculates bounds.
     * @param token Address of the token.
     * @return refPrice The reference price from Chainlink.
     * @return lowerBound The lower bound for the price.
     * @return upperBound The upper bound for the price.
     * @return minLowerBound The minimum lower bound for the price.
     * @return maxUpperBound The maximum upper bound for the price.
     */
    function _getReferencePrice(address token)
        internal
        view
        returns (uint256 refPrice, uint256 lowerBound, uint256 upperBound, uint256 minLowerBound, uint256 maxUpperBound)
    {
        TokenConfig memory config = tokenConfig[token];
        (, int256 guardPrice,, uint256 updatedAt,) = config.chainlinkPriceFeed.latestRoundData();
        require(block.timestamp <= updatedAt + config.chainlinkTimeout, "PriceFeed:chainlinkStaled");
        refPrice = (uint256(guardPrice) * VALUE_PRECISION) / config.baseUnits / config.priceUnits;
        lowerBound = refPrice * (PRECISION - config.chainlinkDeviation) / PRECISION;
        minLowerBound = refPrice * (PRECISION - 3 * config.chainlinkDeviation) / PRECISION;
        upperBound = refPrice * (PRECISION + config.chainlinkDeviation) / PRECISION;
        maxUpperBound = refPrice * (PRECISION + 3 * config.chainlinkDeviation) / PRECISION;
    }

    /**
     * @dev Retrieves the last reported price and timestamp for a token.
     * @param token Address of the token.
     * @return price The last reported price.
     * @return timestamp The timestamp of the last reported price.
     */
    function _getLastPrice(address token) internal view returns (uint256 price, uint256 timestamp) {
        return (lastAnswers[token], lastAnswerTimestamp[token]);
    }

    // ============ Events ============

    /// @notice Emitted when a reporter is added.
    event ReporterAdded(address indexed);
    /// @notice Emitted when a reporter is removed.
    event ReporterRemoved(address indexed);
    /// @notice Emitted when a price is posted.
    event PricePosted(address indexed token, uint256 price);
    /// @notice Emitted when a token is added.
    event TokenAdded(address indexed token);
}