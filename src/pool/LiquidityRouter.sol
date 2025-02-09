// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IPool, Side} from "../interfaces/IPool.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {SafeERC20, IERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LiquidityRouter
 * @notice A helper contract to add/remove liquidity and wrap/unwrap ETH as needed.
 * @dev This contract interacts with a pool contract to manage liquidity and supports ETH/WETH conversions.
 */
contract LiquidityRouter {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    // State variables
    IPool public pool; // The pool contract to interact with
    IWETH public weth; // The WETH contract for ETH/WETH conversions

    /**
     * @dev Constructor to initialize the LiquidityRouter contract.
     * @param _pool The address of the pool contract.
     * @param _weth The address of the WETH contract.
     * @notice Reverts if either `_pool` or `_weth` is the zero address.
     */
    constructor(address _pool, address _weth) {
        require(_pool != address(0), "ETHHelper:zeroAddress");
        require(_weth != address(0), "ETHHelper:zeroAddress");

        pool = IPool(_pool);
        weth = IWETH(_weth);
    }

    /**
     * @dev Adds liquidity to the pool using ETH.
     * @param _tranche The address of the tranche to add liquidity to.
     * @param _minLpAmount The minimum amount of LP tokens to receive.
     * @param _to The address to receive the LP tokens.
     * @notice This function wraps the sent ETH into WETH and adds liquidity to the pool.
     */
    function addLiquidityETH(address _tranche, uint256 _minLpAmount, address _to) external payable {
        uint256 amountIn = msg.value;
        weth.deposit{value: amountIn}(); // Wrap ETH into WETH
        weth.safeIncreaseAllowance(address(pool), amountIn); // Approve the pool to spend WETH
        _addLiquidity(_tranche, address(weth), amountIn, _minLpAmount, _to); // Add liquidity to the pool
    }

    /**
     * @dev Adds liquidity to the pool using an ERC20 token.
     * @param _tranche The address of the tranche to add liquidity to.
     * @param _token The address of the token to add as liquidity.
     * @param _amountIn The amount of tokens to add.
     * @param _minLpAmount The minimum amount of LP tokens to receive.
     * @param _to The address to receive the LP tokens.
     * @notice This function transfers tokens from the caller and adds liquidity to the pool.
     */
    function addLiquidity(address _tranche, address _token, uint256 _amountIn, uint256 _minLpAmount, address _to)
        external
    {
        IERC20 token = IERC20(_token);
        token.safeTransferFrom(msg.sender, address(this), _amountIn); // Transfer tokens from the caller
        _addLiquidity(_tranche, _token, _amountIn, _minLpAmount, _to); // Add liquidity to the pool
    }

    /**
     * @dev Internal function to add liquidity to the pool.
     * @param _tranche The address of the tranche to add liquidity to.
     * @param _token The address of the token to add as liquidity.
     * @param _amountIn The amount of tokens to add.
     * @param _minLpAmount The minimum amount of LP tokens to receive.
     * @param _to The address to receive the LP tokens.
     * @notice This function approves the pool to spend the tokens and calls the pool's `addLiquidity` function.
     */
    function _addLiquidity(address _tranche, address _token, uint256 _amountIn, uint256 _minLpAmount, address _to)
        internal
    {
        IERC20 token = IERC20(_token);
        token.safeIncreaseAllowance(address(pool), _amountIn); // Approve the pool to spend tokens
        pool.addLiquidity(_tranche, _token, _amountIn, _minLpAmount, _to); // Add liquidity to the pool
    }

    /**
     * @dev Removes liquidity from the pool and converts WETH to ETH.
     * @param _tranche The address of the tranche to remove liquidity from.
     * @param _lpAmount The amount of LP tokens to remove.
     * @param _minOut The minimum amount of tokens to receive.
     * @param _to The address to receive the ETH.
     * @notice This function removes liquidity from the pool, unwraps WETH into ETH, and transfers ETH to the recipient.
     */
    function removeLiquidityETH(address _tranche, uint256 _lpAmount, uint256 _minOut, address payable _to) external {
        IERC20 lpToken = IERC20(_tranche);
        lpToken.safeTransferFrom(msg.sender, address(this), _lpAmount); // Transfer LP tokens from the caller
        lpToken.safeIncreaseAllowance(address(pool), _lpAmount); // Approve the pool to spend LP tokens

        uint256 balanceBefore = weth.balanceOf(address(this)); // Record WETH balance before removal
        pool.removeLiquidity(_tranche, address(weth), _lpAmount, _minOut, address(this)); // Remove liquidity from the pool
        uint256 received = weth.balanceOf(address(this)) - balanceBefore; // Calculate the received WETH amount

        weth.withdraw(received); // Unwrap WETH into ETH
        safeTransferETH(_to, received); // Transfer ETH to the recipient
    }

    /**
     * @dev Removes liquidity from the pool using an ERC20 token.
     * @param _tranche The address of the tranche to remove liquidity from.
     * @param _tokenOut The address of the token to receive.
     * @param _lpAmount The amount of LP tokens to remove.
     * @param _minOut The minimum amount of tokens to receive.
     * @param _to The address to receive the tokens.
     * @notice This function removes liquidity from the pool and transfers the tokens to the recipient.
     */
    function removeLiquidity(address _tranche, address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to)
        external
    {
        IERC20 lpToken = IERC20(_tranche);
        lpToken.safeTransferFrom(msg.sender, address(this), _lpAmount); // Transfer LP tokens from the caller
        lpToken.safeIncreaseAllowance(address(pool), _lpAmount); // Approve the pool to spend LP tokens
        pool.removeLiquidity(_tranche, _tokenOut, _lpAmount, _minOut, _to); // Remove liquidity from the pool
    }

    /**
     * @dev Safely transfers ETH to a recipient.
     * @param to The address to receive the ETH.
     * @param amount The amount of ETH to transfer.
     * @notice Reverts if the ETH transfer fails.
     */
    function safeTransferETH(address to, uint256 amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = to.call{value: amount}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }

    /**
     * @dev Fallback function to receive ETH.
     */
    receive() external payable {}

    // Advanced functions

    /**
     * @dev Adds liquidity to the pool and creates a stop-loss order.
     * @param _tranche The address of the tranche to add liquidity to.
     * @param _token The address of the token to add as liquidity.
     * @param _amountIn The amount of tokens to add.
     * @param _minLpAmount The minimum amount of LP tokens to receive.
     * @param _to The address to receive the LP tokens.
     * @param _triggerPrice The trigger price for the stop-loss order.
     * @param _side The side of the position (e.g., long or short).
     * @notice This function adds liquidity and creates a stop-loss order in the pool.
     */
    function addLiquidityWithStopLoss(
        address _tranche,
        address _token,
        uint256 _amountIn,
        uint256 _minLpAmount,
        address _to,
        uint256 _triggerPrice,
        Side _side
    ) external {
        _addLiquidity(_tranche, _token, _amountIn, _minLpAmount, _to); // Add liquidity to the pool
        pool.createStopLossOrder(_token, _token, _triggerPrice, _amountIn, _side); // Create a stop-loss order
    }

    /**
     * @dev Adds liquidity to the pool and creates a take-profit order.
     * @param _tranche The address of the tranche to add liquidity to.
     * @param _token The address of the token to add as liquidity.
     * @param _amountIn The amount of tokens to add.
     * @param _minLpAmount The minimum amount of LP tokens to receive.
     * @param _to The address to receive the LP tokens.
     * @param _triggerPrice The trigger price for the take-profit order.
     * @param _side The side of the position (e.g., long or short).
     * @notice This function adds liquidity and creates a take-profit order in the pool.
     */
    function addLiquidityWithTakeProfit(
        address _tranche,
        address _token,
        uint256 _amountIn,
        uint256 _minLpAmount,
        address _to,
        uint256 _triggerPrice,
        Side _side
    ) external {
        _addLiquidity(_tranche, _token, _amountIn, _minLpAmount, _to); // Add liquidity to the pool
        pool.createTakeProfitOrder(_token, _token, _triggerPrice, _amountIn, _side); // Create a take-profit order
    }
}
