# Perpetual Pulse

An advanced decentralized exchange focused on perpetual trading, integrating effective risk management and innovative liquidity mechanisms.

## Disclaimer

This project is provided "as-is" without any warranties or guarantees of any kind. The developers and contributors are not responsible for any financial losses, damages, or other issues that may arise from the use of this software. Use at your own risk. Always conduct thorough testing and auditing before deploying any smart contracts to a production environment.

## Description

Perpetual Pulse is a cutting-edge decentralized exchange designed to facilitate perpetual trading with a focus on risk management and liquidity. This platform empowers users with the tools they need to engage in seamless trading while effectively managing their risks.

## Features

- **Decentralized Trading**: Trade without intermediaries, ensuring transparency and security.
- **Risk Management**: Advanced features to help users manage their exposure and protect their investments.
- **Innovative Liquidity Solutions**: Efficient mechanisms to provide liquidity and enhance trading experiences.
- **User-Friendly Interface**: An intuitive platform that caters to both novice and experienced traders.

## Components Overview

### Pool
- **File:** [src/pool/Pool.sol]
- **Description:** The core contract that manages the exchange, including order management, token swaps, and liquidity provision.

### LiquidityRouter
- **File:** [src/pool/LiquidityRouter.sol]
- **Description:** A helper contract to add/remove liquidity and wrap/unwrap ETH as needed.

### PoolHook
- **File:** [src/hooks/PoolHook.sol]
- **Description:** Implements the `IPoolHook` interface to allow interaction with the pool contract. It includes functionality for managing multipliers and precision for trading operations.

### PulseOracle
- **File:** [src/oracle/PulseOracle.sol]
- **Description:** A price feed oracle that combines on-chain price reporting with off-chain validation using Chainlink price feeds. It allows authorized reporters to post token prices and provides price retrieval functions.

### ETHUnwrapper
- **File:** [src/orders/ETHUnwrapper.sol]
- **Description:** A contract to unwrap WETH (Wrapped Ether) into ETH (Ether) and transfer it to a specified address. It implements the `IETHUnwrapper` interface for secure WETH transfers.

### OrderManager
- **File:** [src/orders/OrderManager.sol]
- **Description:** Manages orders within the decentralized exchange, including order creation, cancellation, and execution. It integrates with the pool and handles token swaps.

### PoolLens
- **File:** [src/lens/PoolLens.sol]
- **Description:** The `PoolLens` contract provides helper structures and functions to aggregate and expose read-only data on pool assets, positions, and assets under management.

### PoolStorage
- **File:** [src/pool/PoolStorage.sol]
- **Description:** Abstract contract that defines the storage structure for the pool, including fee configurations and distributions.


## Installation

To set up the project locally, follow these steps:

1. Clone the repository:
   ```bash
   git clone https://github.com/Guap-Codes/Perpetual_Pulse.git
   
   cd Perpetual_Pulse
   ```

2. Install Foundry:
   If you haven't installed Foundry yet, you can do so using the following command:
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   ```

3. Compile the smart contracts:
   ```bash
   forge build
   ```

4. Deploy the contracts:
   ```bash
   forge script script/Deploy.s.sol
   ```

## Usage

To interact with the Perpetual Pulse exchange, you can use our web interface or directly interact with the smart contracts via web3 libraries.

1. Connect your wallet (e.g., MetaMask).
2. Access the trading interface.
3. Start trading by selecting your desired assets and managing your positions.

## Testing

The project includes comprehensive testing to ensure the reliability and correctness of the code. The testing framework supports:

- **Unit Testing:** Each component of the project is thoroughly tested with unit tests to verify individual functionalities.
- **Fuzz Testing:** Fuzz testing is employed to identify potential vulnerabilities and edge cases by providing random inputs to the functions.

To run the tests, use the following command:
```bash
# Run all tests
forge test
```

To run specific tests, use:
```bash
# Run specific tests
forge test --match-path test/units/Pool.t.sol

forge test --match-path test/fuzz/PoolFuzzTest.t.sol --match-test test_fuzz_liquidate_long -vvvv
```

## Contributing

We welcome contributions to improve Perpetual Pulse! Please follow these steps to contribute:

1. Fork the repository.
2. Create a new branch (`git checkout -b feature-branch`).
3. Make your changes and commit them (`git commit -m 'Add new feature'`).
4. Push to the branch (`git push origin feature-branch`).
5. Create a pull request.


## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.
