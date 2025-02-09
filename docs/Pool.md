# Pool Contract

The Pool is the heart of the protocol, holding all LP's assets and controlling traders' positions.

## 1. Tranche

A tranche is a logical division of the pool. The assets are managed by tranches, each having its pool amount and position shares.

### Key Attributes of Tranches
- **Pool Amount**: The token amount available for traders to open positions. When a trader opens a position, an amount of tokens is reserved from the pool and returned when they close their positions.
- **Reserved Amount**: The amount of tokens reserved to pay to the trader when they close their position.
- **Total Short Size & Avg Short Price**: Size and entry price of a pseudo short position, used to calculate the total PnL of all short positions.
- **Guaranteed Value**: The total difference between position size and collateral value at the time the trader opens their position. Calculated as:
  $$
  G = S - C
  $$
  The Guaranteed Value of a tranche is the total of all guaranteed values of all positions.
- **Managed Value**: The dollar value of all assets controlled by the pool at any given moment, even if all traders close their positions at that time.

## 2. Pricing

- Token prices are returned from the oracle in decimals of (30 - token_decimals). This ensures that all token values (calculated as token_amount * token_price) have their decimals of 30.

## 3. Position

A position is defined as:
- **Position** = (owner, index_token, collateral_token, side, collateral_value, size)

All position parameters are valued in dollars of tokens. Traders open positions by depositing an amount of collateral tokens. In the case of LONG, the collateral token is the same as the index token. For SHORT, they must deposit a stable coin, minimizing the risk of value loss.

### Profit and Loss (PnL)

PnL of a position is calculated from the index token price:
$$
PnL = \frac{(entryPrice - markPrice) \times side \times size}{entryPrice}
$$
Where:
$$
side = \begin{cases}
  1, & \text {if side = LONG}\\
  -1, & \text {if side = SHORT}
\end{cases}
$$
**NOTE**: $markPrice$ is the price of the index token at the time of observation.

### Fees

Fees consist of position fees and margin fees (the fee for borrowing assets as margin):
$$
positionFee = positionSize \times positionFeeRate
$$
$$
marginFee = positionSize \times marginFeeRate
$$
Where:
- $positionFeeRate$ is fixed.
- $marginFeeRate = \frac{reservedAmount \times borrowInterestRate }{poolAmount}$

The margin fee rate changes with each accrual interval and is stored as an accumulated value (borrow_index), similar to Compound. The margin fee is calculated as:
$$
borrowIndex = borrowIndex + marginFeeRate \times \Delta t \\
marginFee = positionSize \times \Delta borrowIndex
$$
Where $
\Delta t$ is the number of accrual intervals that have passed.

### Entry Price

The entry price changes each time a trader increases their position and does not change if they decrease their position, allowing the position's PnL to be maintained.

For a LONG position:
$$
PnL = \frac{P - P^{'}_0}{P^{'}_0} \times (S + \Delta S) \\
\Rightarrow P^{'}_0 = \frac{(S + \Delta S) \times P}{S + \Delta S + PnL}
$$
For a SHORT position:
$$
\Rightarrow P^{'}_0 = \frac{(S + \Delta S) \times P}{S + \Delta S - PnL}
$$

## 4. Managed Value

Managed value is defined as the total dollar value of all assets the pool currently holds if all traders close their positions at any given time. This value is the sum of the values of all tokens deposited by LPs and collateral deposited by traders, minus collateral and profits paid to users when they close their positions.

In the case of a LONG position, we hold the index token as collateral, so the value of the token in the pool is:
$$
(D + c) \times P
$$
Where:
- $D$: amount deposited by LPs.
- $c$: collateral by the trader.
- $P$: mark price.

We must pay the trader:
$$
PnL + C
$$
Where $C = c \times P_0$ is the value of collateral at the time of opening the position.

Thus, the managed value is:
$$
ManagedValue = (D + c) \times P - PnL - C
$$
This can be simplified to:
$$
ManagedValue = (poolAmount - reserve) \times indexPrice - guaranteedValue
$$
Guaranteed value is calculated cumulatively each time a long position is updated.

For short positions, we use stable coins as collateral, so the managed value is:
$$
ManagedValue = (D_1 + c) \times P_1 - \frac{(P_0 - P) \times S}{P_0} - c \times P_1
$$
Where $P_1$ is the stable coin price and $D_1$ is the amount of stable coin tokens deposited by LPs.

Thus, the final managed value is:
$$
ManagedValue = stablePoolAmount \times stablePrice - globalShortPnL
$$
This requires calculating and storing a pseudo global short position, updated whenever a short position is updated.
