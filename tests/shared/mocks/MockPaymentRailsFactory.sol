// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPaymentRailsFactory } from "../../../src/interfaces/IPaymentRailsFactory.sol";

/// @dev Test stand-in for Credit Cooperative's PaymentRailsFactory registry.
///      `register` is open here. On the production factory only the owner can add an instance.
contract MockPaymentRailsFactory is IPaymentRailsFactory {
    mapping(address instance => bool deployed) private _isDeployedInstance;

    function register(address instance) external {
        _isDeployedInstance[instance] = true;
    }

    function isDeployedInstance(address instance) external view returns (bool isInstance) {
        return _isDeployedInstance[instance];
    }
}
