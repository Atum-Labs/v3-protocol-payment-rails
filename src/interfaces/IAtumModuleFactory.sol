// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title IAtumModuleFactory
/// @notice Interface for the factory that deploys and tracks AtumModule instances.
/// @dev AtumModule is stateful (owns pulled source balances, immutable `paymentRails` and `permit2`),
/// so each PaymentRails needs its own dedicated module instance. This factory deploys them with the
/// chain-specific Permit2 fixed as a factory immutable, so the registry guarantees both bytecode and
/// wiring of every registered module. Supports both CREATE (simple) and CREATE2 (deterministic).
interface IAtumModuleFactory {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new AtumModule instance is deployed.
    /// @param module The address of the deployed AtumModule contract.
    /// @param paymentRails The PaymentRails instance the module is wired to.
    /// @param owner The initial owner of the AtumModule contract.
    event AtumModuleCreated(address indexed module, address indexed paymentRails, address indexed owner);

    /*//////////////////////////////////////////////////////////////////////////
                            DEPLOYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploy a new AtumModule instance using CREATE.
    /// @dev Emits an {AtumModuleCreated} event.
    ///
    /// Requirements:
    /// - `owner` must not be `address(0)`
    /// - `paymentRails` must not be `address(0)`
    /// - `keeper` must not be `address(0)`
    ///
    /// @param owner The initial owner of the AtumModule (can rotate the keeper and pause).
    /// @param paymentRails The PaymentRails instance authorized to call the module's execute().
    /// @param keeper The keeper authorized to invalidate digests on the module.
    /// @return module The address of the deployed AtumModule contract.
    function create(address owner, address paymentRails, address keeper) external returns (address module);

    /// @notice Deploy a new AtumModule instance using CREATE2 for deterministic addressing.
    /// @dev Emits an {AtumModuleCreated} event. The deployment address can be predicted off-chain
    /// via {predictDeterministicAddress}. Reverts if a contract already exists at the predicted address.
    ///
    /// Requirements:
    /// - `owner` must not be `address(0)`
    /// - `paymentRails` must not be `address(0)`
    /// - `keeper` must not be `address(0)`
    /// - The `(owner, paymentRails, keeper, salt)` combination must not have been used before
    ///
    /// @param owner The initial owner of the AtumModule (can rotate the keeper and pause).
    /// @param paymentRails The PaymentRails instance authorized to call the module's execute().
    /// @param keeper The keeper authorized to invalidate digests on the module.
    /// @param salt The salt for CREATE2 address derivation.
    /// @return module The address of the deployed AtumModule contract.
    function createDeterministic(
        address owner,
        address paymentRails,
        address keeper,
        bytes32 salt
    )
        external
        returns (address module);

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice The Permit2 contract every deployed module is wired to.
    /// @return The Permit2 address.
    function permit2() external view returns (address);

    /// @notice Predict the address of a deterministic deployment.
    /// @param owner The initial owner that would be passed to {createDeterministic}.
    /// @param paymentRails The PaymentRails that would be passed to {createDeterministic}.
    /// @param keeper The keeper that would be passed to {createDeterministic}.
    /// @param salt The salt that would be passed to {createDeterministic}.
    /// @return predicted The address where the AtumModule would be deployed.
    /// @param deployer Address that will call `createDeterministic`. The salt is bound to it
    ///        (Certora I-04), so the predicted address differs per deployer.
    function predictDeterministicAddress(
        address deployer,
        address owner,
        address paymentRails,
        address keeper,
        bytes32 salt
    )
        external
        view
        returns (address predicted);

    /// @notice Check whether an address was deployed by this factory.
    /// @param module The address to check.
    /// @return isModule True if the address was deployed by this factory.
    function isDeployedModule(address module) external view returns (bool isModule);

    /// @notice Return all AtumModule instances deployed by this factory.
    /// @dev May be expensive for off-chain calls if the array is very large. Prefer event indexing at scale.
    /// @return modules Array of deployed AtumModule addresses.
    function getDeployedModules() external view returns (address[] memory modules);

    /// @notice Return the total number of AtumModule instances deployed by this factory.
    /// @return count Number of deployed modules.
    function getModuleCount() external view returns (uint256 count);

    /// @notice Return all AtumModule instances deployed for a given PaymentRails.
    /// @dev Multiple modules per PaymentRails are possible (e.g. redeployments); the last entry
    /// is the most recently deployed.
    /// @param paymentRails The PaymentRails instance to look up.
    /// @return modules Array of AtumModule addresses wired to `paymentRails`.
    function getModulesForPaymentRails(address paymentRails) external view returns (address[] memory modules);
}
