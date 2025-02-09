// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {ReentrancyGuardUpgradeable} from "openzeppelin-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "openzeppelin-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IPool, Side} from "../interfaces/IPool.sol";
import {SwapOrder, Order} from "../interfaces/IOrderManager.sol";
import {IPulseOracle} from "../interfaces/IPulseOracle.sol";
import {IPool} from "../interfaces/IPool.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {IETHUnwrapper} from "../interfaces/IETHUnwrapper.sol";
import {IOrderHook} from "../interfaces/IOrderHook.sol";

// Interface for whitelisted pool functions
interface IWhitelistedPool is IPool {
    function isListed(address) external returns (bool);
    function isAsset(address) external returns (bool);
}

// Enum for update position types
enum UpdatePositionType {
    INCREASE,
    DECREASE
}

// Enum for order types
enum OrderType {
    MARKET,
    LIMIT
}

// Struct for update position requests
struct UpdatePositionRequest {
    Side side; // Side of the position (LONG or SHORT)
    uint256 sizeChange; // Change in position size
    uint256 collateral; // Collateral amount
    UpdatePositionType updateType; // Type of update (INCREASE or DECREASE)
}

/**
 * @title OrderManager
 * @notice Manages orders for increasing/decreasing positions and swaps in the protocol.
 * @dev This contract handles order creation, execution, and cancellation. It supports both market and limit orders.
 */
contract OrderManager is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    // Constants
    uint8 public constant VERSION = 4; // Contract version
    uint256 public constant ORDER_VERSION = 2; // Order version
    uint256 constant MARKET_ORDER_TIMEOUT = 5 minutes; // Timeout for market orders
    uint256 constant MAX_MIN_EXECUTION_FEE = 1e17; // Maximum minimum execution fee (0.1 ETH)
    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // ETH pseudo-address
    IWETH public weth; // WETH contract

    // State variables
    uint256 public nextOrderId; // Next order ID
    mapping(uint256 => Order) public orders; // Mapping of order IDs to orders
    mapping(uint256 => UpdatePositionRequest) public requests; // Mapping of order IDs to update requests
    uint256 public nextSwapOrderId; // Next swap order ID
    mapping(uint256 => SwapOrder) public swapOrders; // Mapping of swap order IDs to swap orders
    IWhitelistedPool public pool; // Pool contract
    IPulseOracle public oracle; // Oracle contract
    uint256 public minPerpetualExecutionFee; // Minimum execution fee for perpetual orders
    IOrderHook public orderHook; // Order hook contract
    mapping(address => uint256[]) public userOrders; // Mapping of user addresses to their order IDs
    mapping(address => uint256[]) public userSwapOrders; // Mapping of user addresses to their swap order IDs
    IETHUnwrapper public ethUnwrapper; // ETH unwrapper contract
    address public executor; // Executor address
    mapping(uint256 => uint256) public orderVersions; // Mapping of order IDs to their versions
    uint256 public minSwapExecutionFee; // Minimum execution fee for swap orders

    // Modifiers
    modifier onlyExecutor() {
        _validateExecutor(msg.sender); // Ensure the caller is the executor
        _;
    }

    // Constructor
    constructor() {
        _disableInitializers(); // Disable initializers to prevent reinitialization
    }

    // Receive function
    receive() external payable {
        // Prevent direct ETH transfers to the contract
        require(msg.sender == address(weth), "OrderManager:rejected");
    }

    /**
     * @dev Initializes the contract.
     * @param _weth The address of the WETH contract.
     * @param _oracle The address of the oracle contract.
     * @param _minExecutionFee The minimum execution fee for orders.
     * @param _ethUnwrapper The address of the ETH unwrapper contract.
     */
    function initialize(address _weth, address _oracle, uint256 _minExecutionFee, address _ethUnwrapper)
        external
        initializer
    {
        __Ownable_init(); // Initialize Ownable
        __ReentrancyGuard_init(); // Initialize ReentrancyGuard
        require(_oracle != address(0), "OrderManager:invalidOracle"); // Validate oracle address
        require(_weth != address(0), "OrderManager:invalidWeth"); // Validate WETH address
        require(_minExecutionFee <= MAX_MIN_EXECUTION_FEE, "OrderManager:minExecutionFeeTooHigh"); // Validate execution fee
        require(_ethUnwrapper != address(0), "OrderManager:invalidEthUnwrapper"); // Validate ETH unwrapper address
        minPerpetualExecutionFee = _minExecutionFee; // Set minimum execution fee
        oracle = IPulseOracle(_oracle); // Set oracle
        nextOrderId = 1; // Initialize order ID
        nextSwapOrderId = 1; // Initialize swap order ID
        weth = IWETH(_weth); // Set WETH contract
        ethUnwrapper = IETHUnwrapper(_ethUnwrapper); // Set ETH unwrapper
    }

    /**
     * @dev Reinitializes the contract (version 3).
     * @param _oracle The address of the oracle contract.
     * @param _executor The address of the executor.
     */
    function reinit(address _oracle, address _executor) external reinitializer(3) {
        oracle = IPulseOracle(_oracle); // Set oracle
        executor = _executor; // Set executor
        emit OracleChanged(_oracle); // Emit OracleChanged event
        emit ExecutorSet(_executor); // Emit ExecutorSet event
    }

    /**
     * @dev Reinitializes the contract (version 4).
     * @param _minPerpExecutionFee The minimum execution fee for perpetual orders.
     * @param _minSwapExecutionFee The minimum execution fee for swap orders.
     */
    function reinit_v4(uint256 _minPerpExecutionFee, uint256 _minSwapExecutionFee) external reinitializer(VERSION) {
        _setMinExecutionFee(_minPerpExecutionFee, _minSwapExecutionFee); // Set execution fees
    }

    // ============= VIEW FUNCTIONS ==============

    /**
     * @dev Retrieves a list of orders for a user.
     * @param user The address of the user.
     * @param skip The number of orders to skip.
     * @param take The number of orders to retrieve.
     * @return orderIds The list of order IDs.
     * @return total The total number of orders for the user.
     */
    function getOrders(address user, uint256 skip, uint256 take)
        external
        view
        returns (uint256[] memory orderIds, uint256 total)
    {
        total = userOrders[user].length; // Get total orders for the user
        uint256 toIdx = skip + take; // Calculate end index
        toIdx = toIdx > total ? total : toIdx; // Adjust end index if it exceeds total
        uint256 nOrders = toIdx > skip ? toIdx - skip : 0; // Calculate number of orders to retrieve
        orderIds = new uint256[](nOrders); // Initialize order IDs array
        for (uint256 i = skip; i < skip + nOrders; i++) {
            orderIds[i] = userOrders[user][i]; // Populate order IDs array
        }
    }

    /**
     * @dev Retrieves a list of swap orders for a user.
     * @param user The address of the user.
     * @param skip The number of swap orders to skip.
     * @param take The number of swap orders to retrieve.
     * @return orderIds The list of swap order IDs.
     * @return total The total number of swap orders for the user.
     */
    function getSwapOrders(address user, uint256 skip, uint256 take)
        external
        view
        returns (uint256[] memory orderIds, uint256 total)
    {
        total = userSwapOrders[user].length; // Get total swap orders for the user
        uint256 toIdx = skip + take; // Calculate end index
        toIdx = toIdx > total ? total : toIdx; // Adjust end index if it exceeds total
        uint256 nOrders = toIdx > skip ? toIdx - skip : 0; // Calculate number of swap orders to retrieve
        orderIds = new uint256[](nOrders); // Initialize swap order IDs array
        for (uint256 i = skip; i < skip + nOrders; i++) {
            orderIds[i] = userSwapOrders[user][i]; // Populate swap order IDs array
        }
    }

    // =========== MUTATIVE FUNCTIONS ==========

    /**
     * @dev Places an order to increase or decrease a position.
     * @param _updateType The type of update (INCREASE or DECREASE).
     * @param _side The side of the position (LONG or SHORT).
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _orderType The type of order (MARKET or LIMIT).
     * @param data Additional order data.
     */
    function placeOrder(
        UpdatePositionType _updateType,
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes calldata data
    ) external payable nonReentrant {
        bool isIncrease = _updateType == UpdatePositionType.INCREASE; // Check if the order is an increase
        require(pool.validateToken(_indexToken, _collateralToken, _side, isIncrease), "OrderManager:invalidTokens"); // Validate tokens
        uint256 orderId;
        if (isIncrease) {
            orderId = _createIncreasePositionOrder(_side, _indexToken, _collateralToken, _orderType, data); // Create increase order
        } else {
            orderId = _createDecreasePositionOrder(_side, _indexToken, _collateralToken, _orderType, data); // Create decrease order
        }
        userOrders[msg.sender].push(orderId); // Add order ID to user's order list
    }

    /**
     * @dev Places a swap order.
     * @param _tokenIn The address of the input token.
     * @param _tokenOut The address of the output token.
     * @param _amountIn The amount of input tokens.
     * @param _minOut The minimum amount of output tokens.
     * @param _price The price for the swap.
     */
    function placeSwapOrder(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minOut, uint256 _price)
        external
        payable
        nonReentrant
    {
        address payToken;
        (payToken, _tokenIn) = _tokenIn == ETH ? (ETH, address(weth)) : (_tokenIn, _tokenIn); // Handle ETH/WETH conversion
        require(
            pool.isListed(_tokenIn) && pool.isAsset(_tokenOut == ETH ? address(weth) : _tokenOut),
            "OrderManager:invalidTokens"
        ); // Validate tokens

        uint256 executionFee;
        if (payToken == ETH) {
            executionFee = msg.value - _amountIn; // Calculate execution fee for ETH
            weth.deposit{value: _amountIn}(); // Wrap ETH into WETH
        } else {
            executionFee = msg.value; // Execution fee for ERC20 tokens
            IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn); // Transfer input tokens
        }

        require(executionFee >= minSwapExecutionFee, "OrderManager:executionFeeTooLow"); // Validate execution fee

        SwapOrder memory order = SwapOrder({
            pool: pool,
            owner: msg.sender,
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            amountIn: _amountIn,
            minAmountOut: _minOut,
            price: _price,
            executionFee: executionFee
        });
        swapOrders[nextSwapOrderId] = order; // Store swap order
        userSwapOrders[msg.sender].push(nextSwapOrderId); // Add swap order ID to user's list
        emit SwapOrderPlaced(nextSwapOrderId); // Emit SwapOrderPlaced event
        nextSwapOrderId += 1; // Increment swap order ID
    }

    /**
     * @dev Executes a swap.
     * @param _fromToken The address of the input token.
     * @param _toToken The address of the output token.
     * @param _amountIn The amount of input tokens.
     * @param _minAmountOut The minimum amount of output tokens.
     */
    function swap(address _fromToken, address _toToken, uint256 _amountIn, uint256 _minAmountOut) external payable {
        (address outToken, address receiver) = _toToken == ETH ? (address(weth), address(this)) : (_toToken, msg.sender); // Handle ETH/WETH conversion

        address inToken;
        if (_fromToken == ETH) {
            _amountIn = msg.value; // Use sent ETH as input
            inToken = address(weth); // Set input token as WETH
            weth.deposit{value: _amountIn}(); // Wrap ETH into WETH
            weth.safeTransfer(address(pool), _amountIn); // Transfer WETH to the pool
        } else {
            inToken = _fromToken; // Set input token
            IERC20(inToken).safeTransferFrom(msg.sender, address(pool), _amountIn); // Transfer input tokens to the pool
        }

        uint256 amountOut = _doSwap(inToken, outToken, _minAmountOut, receiver, msg.sender); // Execute swap
        if (outToken == address(weth) && _toToken == ETH) {
            _safeUnwrapETH(amountOut, msg.sender); // Unwrap WETH into ETH if needed
        }
        emit Swap(msg.sender, _fromToken, _toToken, address(pool), _amountIn, amountOut); // Emit Swap event
    }

    /**
     * @dev Executes an order.
     * @param _orderId The ID of the order.
     * @param _feeTo The address to receive the execution fee.
     */
    function executeOrder(uint256 _orderId, address payable _feeTo) external nonReentrant onlyExecutor {
        Order memory order = orders[_orderId]; // Retrieve order
        require(order.owner != address(0), "OrderManager:orderNotExists"); // Validate order existence
        require(order.pool == pool, "OrderManager:invalidOrPausedPool"); // Validate pool
        require(block.number > order.submissionBlock, "OrderManager:blockNotPass"); // Validate block number

        if (order.expiresAt != 0 && order.expiresAt < block.timestamp) {
            _expiresOrder(_orderId, order); // Handle expired order
            return;
        }

        UpdatePositionRequest memory request = requests[_orderId]; // Retrieve request
        uint256 indexPrice = _getMarkPrice(order, request); // Get mark price
        bool isValid = order.triggerAboveThreshold ? indexPrice >= order.price : indexPrice <= order.price; // Validate trigger condition
        if (!isValid) {
            return; // Skip if condition is not met
        }

        _executeRequest(_orderId, order, request); // Execute request
        delete orders[_orderId]; // Delete order
        delete requests[_orderId]; // Delete request
        _safeTransferETH(_feeTo, order.executionFee); // Transfer execution fee
        emit OrderExecuted(_orderId, order, request, indexPrice); // Emit OrderExecuted event
    }

    /**
     * @dev Cancels an order.
     * @param _orderId The ID of the order.
     */
    function cancelOrder(uint256 _orderId) external nonReentrant {
        Order memory order = orders[_orderId]; // Retrieve order
        require(order.owner == msg.sender, "OrderManager:unauthorizedCancellation"); // Validate ownership
        UpdatePositionRequest memory request = requests[_orderId]; // Retrieve request

        delete orders[_orderId]; // Delete order
        delete requests[_orderId]; // Delete request

        _safeTransferETH(order.owner, order.executionFee); // Refund execution fee
        if (request.updateType == UpdatePositionType.INCREASE) {
            address refundToken = orderVersions[_orderId] == ORDER_VERSION ? order.payToken : order.collateralToken; // Determine refund token
            _refundCollateral(refundToken, request.collateral, order.owner); // Refund collateral
        }

        emit OrderCancelled(_orderId); // Emit OrderCancelled event
    }

    /**
     * @dev Cancels a swap order.
     * @param _orderId The ID of the swap order.
     */
    function cancelSwapOrder(uint256 _orderId) external nonReentrant {
        SwapOrder memory order = swapOrders[_orderId]; // Retrieve swap order
        require(order.owner == msg.sender, "OrderManager:unauthorizedCancellation"); // Validate ownership
        delete swapOrders[_orderId]; // Delete swap order
        _safeTransferETH(order.owner, order.executionFee); // Refund execution fee
        IERC20(order.tokenIn).safeTransfer(order.owner, order.amountIn); // Refund input tokens
        emit SwapOrderCancelled(_orderId); // Emit SwapOrderCancelled event
    }

    /**
     * @dev Executes a swap order.
     * @param _orderId The ID of the swap order.
     * @param _feeTo The address to receive the execution fee.
     */
    function executeSwapOrder(uint256 _orderId, address payable _feeTo) external nonReentrant onlyExecutor {
        SwapOrder memory order = swapOrders[_orderId]; // Retrieve swap order
        require(order.owner != address(0), "OrderManager:notFound"); // Validate order existence
        delete swapOrders[_orderId]; // Delete swap order
        IERC20(order.tokenIn).safeTransfer(address(order.pool), order.amountIn); // Transfer input tokens to the pool
        uint256 amountOut;
        if (order.tokenOut != ETH) {
            amountOut = _doSwap(order.tokenIn, order.tokenOut, order.minAmountOut, order.owner, order.owner); // Execute swap
        } else {
            amountOut = _doSwap(order.tokenIn, address(weth), order.minAmountOut, address(this), order.owner); // Execute swap and unwrap WETH
            _safeUnwrapETH(amountOut, order.owner); // Unwrap WETH into ETH
        }
        _safeTransferETH(_feeTo, order.executionFee); // Transfer execution fee
        require(amountOut >= order.minAmountOut, "OrderManager:slippageReached"); // Validate slippage
        emit SwapOrderExecuted(_orderId, order.amountIn, amountOut); // Emit SwapOrderExecuted event
    }

    // ========= INTERNAL FUNCTIONS ==========

    /**
     * @dev Executes an update position request.
     * @param _orderId The ID of the order.
     * @param _order The order details.
     * @param _request The update position request.
     */
    function _executeRequest(uint256 _orderId, Order memory _order, UpdatePositionRequest memory _request) internal {
        if (_request.updateType == UpdatePositionType.INCREASE) {
            bool noSwap = orderVersions[_orderId] < ORDER_VERSION
                || (_order.payToken == ETH && _order.collateralToken == address(weth))
                || (_order.payToken == _order.collateralToken);

            if (!noSwap) {
                address fromToken = _order.payToken == ETH ? address(weth) : _order.payToken;
                _request.collateral =
                    _poolSwap(fromToken, _order.collateralToken, _request.collateral, 0, address(this), _order.owner); // Swap tokens
            }

            IERC20(_order.collateralToken).safeTransfer(address(_order.pool), _request.collateral); // Transfer collateral
            _order.pool.increasePosition(
                _order.owner, _order.indexToken, _order.collateralToken, _request.sizeChange, _request.side
            ); // Increase position
        } else {
            IERC20 collateralToken = IERC20(_order.collateralToken);
            uint256 priorBalance = collateralToken.balanceOf(address(this)); // Get prior balance
            _order.pool.decreasePosition(
                _order.owner,
                _order.indexToken,
                _order.collateralToken,
                _request.collateral,
                _request.sizeChange,
                _request.side,
                address(this)
            ); // Decrease position
            uint256 payoutAmount = collateralToken.balanceOf(address(this)) - priorBalance; // Calculate payout
            if (_order.collateralToken == address(weth) && _order.payToken == ETH) {
                _safeUnwrapETH(payoutAmount, _order.owner); // Unwrap WETH into ETH
            } else if (_order.collateralToken != _order.payToken) {
                IERC20(_order.payToken).safeTransfer(address(_order.pool), payoutAmount); // Transfer payout to pool
                _order.pool.swap(_order.collateralToken, _order.payToken, 0, _order.owner, abi.encode(_order.owner)); // Swap tokens
            } else {
                collateralToken.safeTransfer(_order.owner, payoutAmount); // Transfer payout to owner
            }
        }
    }

    /**
     * @dev Gets the mark price for an order.
     * @param order The order details.
     * @param request The update position request.
     * @return The mark price.
     */
    function _getMarkPrice(Order memory order, UpdatePositionRequest memory request) internal view returns (uint256) {
        bool max = (request.updateType == UpdatePositionType.INCREASE) == (request.side == Side.LONG);
        return oracle.getPrice(order.indexToken, max); // Get price from oracle
    }

    /**
     * @dev Creates a decrease position order.
     * @param _side The side of the position (LONG or SHORT).
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _orderType The type of order (MARKET or LIMIT).
     * @param _data Additional order data.
     * @return orderId The ID of the created order.
     */
    function _createDecreasePositionOrder(
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes memory _data
    ) internal returns (uint256 orderId) {
        Order memory order;
        UpdatePositionRequest memory request;
        bytes memory extradata;

        if (_orderType == OrderType.MARKET) {
            (order.price, order.payToken, request.sizeChange, request.collateral, extradata) =
                abi.decode(_data, (uint256, address, uint256, uint256, bytes));
            order.triggerAboveThreshold = _side == Side.LONG;
        } else {
            (
                order.price,
                order.triggerAboveThreshold,
                order.payToken,
                request.sizeChange,
                request.collateral,
                extradata
            ) = abi.decode(_data, (uint256, bool, address, uint256, uint256, bytes));
        }
        order.pool = pool;
        order.owner = msg.sender;
        order.indexToken = _indexToken;
        order.collateralToken = _collateralToken;
        order.expiresAt = _orderType == OrderType.MARKET ? block.timestamp + MARKET_ORDER_TIMEOUT : 0;
        order.submissionBlock = block.number;
        order.executionFee = msg.value;
        uint256 minExecutionFee = _calcMinPerpetualExecutionFee(order.collateralToken, order.payToken);
        require(order.executionFee >= minExecutionFee, "OrderManager:executionFeeTooLow");

        request.updateType = UpdatePositionType.DECREASE;
        request.side = _side;
        orderId = nextOrderId;
        nextOrderId = orderId + 1;
        orders[orderId] = order;
        requests[orderId] = request;

        if (address(orderHook) != address(0)) {
            orderHook.postPlaceOrder(orderId, extradata);
        }

        emit OrderPlaced(orderId, order, request);
    }

    /**
     * @dev Creates an increase position order.
     * @param _side The side of the position (LONG or SHORT).
     * @param _indexToken The address of the index token.
     * @param _collateralToken The address of the collateral token.
     * @param _orderType The type of order (MARKET or LIMIT).
     * @param _data Additional order data.
     * @return orderId The ID of the created order.
     */
    function _createIncreasePositionOrder(
        Side _side,
        address _indexToken,
        address _collateralToken,
        OrderType _orderType,
        bytes memory _data
    ) internal returns (uint256 orderId) {
        Order memory order;
        UpdatePositionRequest memory request;
        order.triggerAboveThreshold = _side == Side.SHORT;
        uint256 purchaseAmount;
        bytes memory extradata;
        (order.price, order.payToken, purchaseAmount, request.sizeChange, request.collateral, extradata) =
            abi.decode(_data, (uint256, address, uint256, uint256, uint256, bytes));

        require(purchaseAmount != 0, "OrderManager:invalidPurchaseAmount");
        require(order.payToken != address(0), "OrderManager:invalidPurchaseToken");

        order.pool = pool;
        order.owner = msg.sender;
        order.indexToken = _indexToken;
        order.collateralToken = _collateralToken;
        order.expiresAt = _orderType == OrderType.MARKET ? block.timestamp + MARKET_ORDER_TIMEOUT : 0;
        order.submissionBlock = block.number;
        order.executionFee = order.payToken == ETH ? msg.value - purchaseAmount : msg.value;

        uint256 minExecutionFee = _calcMinPerpetualExecutionFee(order.collateralToken, order.payToken);
        require(order.executionFee >= minExecutionFee, "OrderManager:executionFeeTooLow");
        request.updateType = UpdatePositionType.INCREASE;
        request.side = _side;
        request.collateral = purchaseAmount;

        orderId = nextOrderId;
        nextOrderId = orderId + 1;
        orders[orderId] = order;
        requests[orderId] = request;
        orderVersions[orderId] = ORDER_VERSION;

        if (order.payToken == ETH) {
            weth.deposit{value: purchaseAmount}();
        } else {
            IERC20(order.payToken).safeTransferFrom(msg.sender, address(this), request.collateral);
        }

        if (address(orderHook) != address(0)) {
            orderHook.postPlaceOrder(orderId, extradata);
        }

        emit OrderPlaced(orderId, order, request);
    }

    /**
     * @dev Executes a swap in the pool.
     * @param _fromToken The address of the input token.
     * @param _toToken The address of the output token.
     * @param _amountIn The amount of input tokens.
     * @param _minAmountOut The minimum amount of output tokens.
     * @param _receiver The address to receive the output tokens.
     * @param _beneficier The address of the beneficiary.
     * @return amountOut The amount of output tokens.
     */
    function _poolSwap(
        address _fromToken,
        address _toToken,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver,
        address _beneficier
    ) internal returns (uint256 amountOut) {
        IERC20(_fromToken).safeTransfer(address(pool), _amountIn); // Transfer input tokens to the pool
        return _doSwap(_fromToken, _toToken, _minAmountOut, _receiver, _beneficier); // Execute swap
    }

    /**
     * @dev Executes a swap.
     * @param _fromToken The address of the input token.
     * @param _toToken The address of the output token.
     * @param _minAmountOut The minimum amount of output tokens.
     * @param _receiver The address to receive the output tokens.
     * @param _beneficier The address of the beneficiary.
     * @return amountOut The amount of output tokens.
     */
    function _doSwap(
        address _fromToken,
        address _toToken,
        uint256 _minAmountOut,
        address _receiver,
        address _beneficier
    ) internal returns (uint256 amountOut) {
        IERC20 tokenOut = IERC20(_toToken);
        uint256 priorBalance = tokenOut.balanceOf(_receiver); // Get prior balance
        pool.swap(_fromToken, _toToken, _minAmountOut, _receiver, abi.encode(_beneficier)); // Execute swap
        amountOut = tokenOut.balanceOf(_receiver) - priorBalance; // Calculate output amount
    }

    /**
     * @dev Handles an expired order.
     * @param _orderId The ID of the order.
     * @param _order The order details.
     */
    function _expiresOrder(uint256 _orderId, Order memory _order) internal {
        UpdatePositionRequest memory request = requests[_orderId]; // Retrieve request
        delete orders[_orderId]; // Delete order
        delete requests[_orderId]; // Delete request
        emit OrderExpired(_orderId); // Emit OrderExpired event

        _safeTransferETH(_order.owner, _order.executionFee); // Refund execution fee
        if (request.updateType == UpdatePositionType.INCREASE) {
            address refundToken = orderVersions[_orderId] == ORDER_VERSION ? _order.payToken : _order.collateralToken; // Determine refund token
            _refundCollateral(refundToken, request.collateral, _order.owner); // Refund collateral
        }
    }

    /**
     * @dev Refunds collateral to the order owner.
     * @param _refundToken The address of the refund token.
     * @param _amount The amount to refund.
     * @param _orderOwner The address of the order owner.
     */
    function _refundCollateral(address _refundToken, uint256 _amount, address _orderOwner) internal {
        if (_refundToken == address(weth) || _refundToken == ETH) {
            _safeUnwrapETH(_amount, _orderOwner); // Unwrap WETH into ETH
        } else {
            IERC20(_refundToken).safeTransfer(_orderOwner, _amount); // Transfer ERC20 tokens
        }
    }

    /**
     * @dev Safely transfers ETH to a specified address.
     * @param _to The address to receive the ETH.
     * @param _amount The amount of ETH to transfer.
     */
    function _safeTransferETH(address _to, uint256 _amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = _to.call{value: _amount}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED"); // Ensure transfer success
    }

    /**
     * @dev Safely unwraps WETH into ETH and transfers it to a specified address.
     * @param _amount The amount of WETH to unwrap.
     * @param _to The address to receive the ETH.
     */
    function _safeUnwrapETH(uint256 _amount, address _to) internal {
        weth.safeIncreaseAllowance(address(ethUnwrapper), _amount); // Approve ETH unwrapper
        ethUnwrapper.unwrap(_amount, _to); // Unwrap WETH into ETH
    }

    /**
     * @dev Validates the executor address.
     * @param _sender The address to validate.
     */
    function _validateExecutor(address _sender) internal view {
        require(_sender == executor, "OrderManager:onlyExecutor"); // Ensure sender is the executor
    }

    /**
     * @dev Calculates the minimum execution fee for a perpetual order.
     * @param _collateralToken The address of the collateral token.
     * @param _payToken The address of the pay token.
     * @return The minimum execution fee.
     */
    function _calcMinPerpetualExecutionFee(address _collateralToken, address _payToken)
        internal
        view
        returns (uint256)
    {
        bool noSwap = _collateralToken == _payToken || (_collateralToken == address(weth) && _payToken == ETH);
        return noSwap ? minPerpetualExecutionFee : minPerpetualExecutionFee + minSwapExecutionFee;
    }

    /**
     * @dev Sets the minimum execution fees.
     * @param _perpExecutionFee The minimum execution fee for perpetual orders.
     * @param _swapExecutionFee The minimum execution fee for swap orders.
     */
    function _setMinExecutionFee(uint256 _perpExecutionFee, uint256 _swapExecutionFee) internal {
        require(_perpExecutionFee != 0, "OrderManager:invalidFeeValue");
        require(_perpExecutionFee <= MAX_MIN_EXECUTION_FEE, "OrderManager:minExecutionFeeTooHigh");
        require(_swapExecutionFee != 0, "OrderManager:invalidFeeValue");
        require(_swapExecutionFee <= MAX_MIN_EXECUTION_FEE, "OrderManager:minExecutionFeeTooHigh");
        minPerpetualExecutionFee = _perpExecutionFee;
        minSwapExecutionFee = _swapExecutionFee;
        emit MinExecutionFeeSet(_perpExecutionFee);
        emit MinSwapExecutionFeeSet(_swapExecutionFee);
    }

    // ============ ADMINISTRATIVE FUNCTIONS =============

    /**
     * @dev Sets the oracle address.
     * @param _oracle The address of the oracle.
     */
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "OrderManager:invalidOracleAddress");
        oracle = IPulseOracle(_oracle);
        emit OracleChanged(_oracle);
    }

    /**
     * @dev Sets the pool address.
     * @param _pool The address of the pool.
     */
    function setPool(address _pool) external onlyOwner {
        require(_pool != address(0), "OrderManager:invalidPoolAddress");
        require(address(pool) != _pool, "OrderManager:poolAlreadyAdded");
        pool = IWhitelistedPool(_pool);
        emit PoolSet(_pool);
    }

    /**
     * @dev Sets the minimum execution fees.
     * @param _perpExecutionFee The minimum execution fee for perpetual orders.
     * @param _swapExecutionFee The minimum execution fee for swap orders.
     */
    function setMinExecutionFee(uint256 _perpExecutionFee, uint256 _swapExecutionFee) external onlyOwner {
        _setMinExecutionFee(_perpExecutionFee, _swapExecutionFee);
    }

    /**
     * @dev Sets the order hook address.
     * @param _hook The address of the order hook.
     */
    function setOrderHook(address _hook) external onlyOwner {
        orderHook = IOrderHook(_hook);
        emit OrderHookSet(_hook);
    }

    /**
     * @dev Sets the executor address.
     * @param _executor The address of the executor.
     */
    function setExecutor(address _executor) external onlyOwner {
        require(_executor != address(0), "OrderManager:invalidAddress");
        executor = _executor;
        emit ExecutorSet(_executor);
    }

    // ========== EVENTS =========

    event OrderPlaced(uint256 indexed key, Order order, UpdatePositionRequest request);
    event OrderCancelled(uint256 indexed key);
    event OrderExecuted(uint256 indexed key, Order order, UpdatePositionRequest request, uint256 fillPrice);
    event OrderExpired(uint256 indexed key);
    event OracleChanged(address);
    event SwapOrderPlaced(uint256 indexed key);
    event SwapOrderCancelled(uint256 indexed key);
    event SwapOrderExecuted(uint256 indexed key, uint256 amountIn, uint256 amountOut);
    event Swap(
        address indexed account,
        address indexed tokenIn,
        address indexed tokenOut,
        address pool,
        uint256 amountIn,
        uint256 amountOut
    );
    event PoolSet(address indexed pool);
    event MinExecutionFeeSet(uint256 perpetualFee); // keep this event signature unchanged
    event MinSwapExecutionFeeSet(uint256 swapExecutionFee);
    event OrderHookSet(address indexed hook);
    event ExecutorSet(address indexed executor);
}
