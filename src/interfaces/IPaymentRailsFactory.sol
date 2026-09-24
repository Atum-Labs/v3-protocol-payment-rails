// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title IPaymentRailsFactory
/// @notice The slice of Credit Cooperative's PaymentRailsFactory this repo depends on.
/// @dev The factory itself lives upstream. It records every PaymentRails it deploys, and only its
///      owner can add to that list, so `isDeployedInstance` is a record a lookalike cannot forge.
interface IPaymentRailsFactory {
    /// @notice Check whether an address was deployed by this factory.
    /// @param instance The address to check.
    /// @return isInstance True if the address was deployed by this factory.
    function isDeployedInstance(address instance) external view returns (bool isInstance);
}
