// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title IPaymentRailsFactory
/// @notice Interface for the factory that deploys and tracks PaymentRails instances.
/// @dev Supports both CREATE (simple) and CREATE2 (deterministic) deployment. Maintains an on-chain
/// registry of all deployed instances for trust verification.
interface IPaymentRailsFactory {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new PaymentRails instance is deployed.
    /// @param paymentRails The address of the deployed PaymentRails contract.
    /// @param owner The initial owner of the PaymentRails contract.
    event PaymentRailsCreated(address indexed paymentRails, address indexed owner);

    /*//////////////////////////////////////////////////////////////////////////
                            DEPLOYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deploy a new PaymentRails instance using CREATE.
    /// @dev Emits a {PaymentRailsCreated} event. Restricted to the factory owner so the registry
    /// only lists instances this organization deployed.
    ///
    /// Requirements:
    /// - caller must be the factory owner
    /// - `railsOwner` must not be `address(0)`
    ///
    /// @param railsOwner The initial owner of the deployed PaymentRails contract.
    /// @return paymentRails The address of the deployed PaymentRails contract.
    function create(address railsOwner) external returns (address paymentRails);

    /// @notice Deploy a new PaymentRails instance using CREATE2 for deterministic addressing.
    /// @dev Emits a {PaymentRailsCreated} event. The deployment address can be predicted off-chain
    /// via {predictDeterministicAddress}. Reverts if a contract already exists at the predicted address.
    ///
    /// Requirements:
    /// - caller must be the factory owner
    /// - `railsOwner` must not be `address(0)`
    /// - The `(railsOwner, salt)` combination must not have been used before
    ///
    /// @param railsOwner The initial owner of the deployed PaymentRails contract.
    /// @param salt The salt for CREATE2 address derivation.
    /// @return paymentRails The address of the deployed PaymentRails contract.
    function createDeterministic(address railsOwner, bytes32 salt) external returns (address paymentRails);

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Predict the address of a deterministic deployment.
    /// @param railsOwner The initial owner that would be passed to {createDeterministic}.
    /// @param salt The salt that would be passed to {createDeterministic}.
    /// @return predicted The address where the PaymentRails would be deployed.
    function predictDeterministicAddress(address railsOwner, bytes32 salt) external view returns (address predicted);

    /// @notice Check whether an address was deployed by this factory.
    /// @param instance The address to check.
    /// @return isInstance True if the address was deployed by this factory.
    function isDeployedInstance(address instance) external view returns (bool isInstance);

    /// @notice Return all PaymentRails instances deployed by this factory.
    /// @dev May be expensive for off-chain calls if the array is very large. Prefer event indexing at scale.
    /// @return instances Array of deployed PaymentRails addresses.
    function getDeployedInstances() external view returns (address[] memory instances);

    /// @notice Return the total number of PaymentRails instances deployed by this factory.
    /// @return count Number of deployed instances.
    function getInstanceCount() external view returns (uint256 count);
}
