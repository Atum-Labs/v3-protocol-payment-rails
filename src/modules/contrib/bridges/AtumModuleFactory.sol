// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IAtumModuleFactory } from "../../../interfaces/IAtumModuleFactory.sol";
import { IPaymentRailsFactory } from "../../../interfaces/IPaymentRailsFactory.sol";
import { AtumModule } from "./AtumModule.sol";
import { Errors } from "../../../libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title AtumModuleFactory
/// @custom:tier contrib
/// @custom:maintainer @atum-labs (security@atumlabs.xyz)
/// @custom:audit-status unaudited
/// @author Credit Cooperative
/// @notice See the documentation in {IAtumModuleFactory}.
/// @dev `create`/`createDeterministic` require two things of `paymentRails`. It must be an instance
///      {paymentRailsFactory} deployed — only that factory's owner can add to the list, so a
///      lookalike cannot get on it — and the caller must be its owner (Certora L-01). The module
///      registry is still informational only: membership is NOT an authorization or trust signal,
///      `_deployedModules` grows unbounded, and a module deployed with `new AtumModule(...)` rather
///      than through this factory is unaffected. Consumers must verify a module's
///      `owner`/`keeper`/`paymentRails` wiring rather than trusting registry presence, and read
///      `getDeployedModules` offchain (it returns the full array).
contract AtumModuleFactory is IAtumModuleFactory {
    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAtumModuleFactory
    address public immutable override permit2;

    /// @inheritdoc IAtumModuleFactory
    IPaymentRailsFactory public immutable override paymentRailsFactory;

    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Array of all deployed AtumModule instances.
    address[] private _deployedModules;

    /// @dev Maps deployed module addresses to true for O(1) lookups.
    mapping(address module => bool deployed) private _isDeployedModule;

    /// @dev Maps a PaymentRails to all modules deployed for it.
    mapping(address paymentRails => address[] modules) private _modulesByPaymentRails;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Permit2 is fixed at factory deployment so the registry guarantees the wiring of every
    /// module it lists, not just the bytecode.
    /// @param _permit2 The canonical Permit2 contract on this chain.
    /// @param _paymentRailsFactory PaymentRailsFactory whose deployment list is the record of real
    ///        PaymentRails. Fixed here so every module this factory deploys is checked against the
    ///        same list.
    constructor(address _permit2, IPaymentRailsFactory _paymentRailsFactory) {
        if (_permit2 == address(0)) {
            revert Errors.AtumModuleFactory_ZeroPermit2();
        }
        // The module constructor rejects a codeless Permit2 itself; checking here fails fast at
        // factory deployment instead of on every create(). This used to be justified by the
        // module calling DOMAIN_SEPARATOR() on the address, which reverted against an EOA as a
        // side effect -- that call was dead state and has been removed, so both checks are now
        // explicit.
        if (_permit2.code.length == 0) {
            revert Errors.AtumModuleFactory_Permit2NotContract(_permit2);
        }
        if (address(_paymentRailsFactory) == address(0)) {
            revert Errors.AtumModuleFactory_ZeroPaymentRailsFactory();
        }
        if (address(_paymentRailsFactory).code.length == 0) {
            revert Errors.AtumModuleFactory_PaymentRailsFactoryNotContract(address(_paymentRailsFactory));
        }

        permit2 = _permit2;
        paymentRailsFactory = _paymentRailsFactory;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            DEPLOYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAtumModuleFactory
    function create(address owner, address paymentRails, address keeper) external returns (address module) {
        // Checks: Validate the per-instance parameters.
        _checkCreateParams(owner, paymentRails, keeper);
        _checkPaymentRailsOwner(paymentRails);

        // Interactions: Deploy new AtumModule wired to the PaymentRails.
        module = address(new AtumModule(permit2, paymentRails, owner, keeper));

        // Effects: Register in the on-chain registry.
        _register(module, paymentRails, owner, keeper);
    }

    /// @inheritdoc IAtumModuleFactory
    function createDeterministic(
        address owner,
        address paymentRails,
        address keeper,
        bytes32 salt
    )
        external
        returns (address module)
    {
        // Checks: Validate the per-instance parameters.
        _checkCreateParams(owner, paymentRails, keeper);
        _checkPaymentRailsOwner(paymentRails);

        // Interactions: Deploy new AtumModule with deterministic address. The salt is bound to the
        // caller so a front-runner cannot occupy the address first (Certora I-04).
        module = address(new AtumModule{ salt: _effectiveSalt(msg.sender, salt) }(permit2, paymentRails, owner, keeper));

        // Effects: Register in the on-chain registry.
        _register(module, paymentRails, owner, keeper);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAtumModuleFactory
    function predictDeterministicAddress(
        address deployer,
        address owner,
        address paymentRails,
        address keeper,
        bytes32 salt
    )
        external
        view
        returns (address predicted)
    {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(type(AtumModule).creationCode, abi.encode(permit2, paymentRails, owner, keeper))
        );
        // `deployer` is explicit rather than msg.sender: prediction is an off-chain read, and the
        // party asking is usually not the party deploying.
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), _effectiveSalt(deployer, salt), bytecodeHash)
                    )
                )
            )
        );
    }

    /// @inheritdoc IAtumModuleFactory
    function isDeployedModule(address module) external view returns (bool) {
        return _isDeployedModule[module];
    }

    /// @inheritdoc IAtumModuleFactory
    function getDeployedModules() external view returns (address[] memory) {
        return _deployedModules;
    }

    /// @inheritdoc IAtumModuleFactory
    function getModuleCount() external view returns (uint256) {
        return _deployedModules.length;
    }

    /// @inheritdoc IAtumModuleFactory
    function getModulesForPaymentRails(address paymentRails) external view returns (address[] memory) {
        return _modulesByPaymentRails[paymentRails];
    }

    /*//////////////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Certora L-01, plus a provenance check on what `paymentRails` is.
    ///
    ///      Creation was permissionless, so anyone could deploy a genuine factory module naming a
    ///      victim's PaymentRails while making themselves its owner and keeper. Requiring the
    ///      caller to be `Ownable(paymentRails).owner()` closes that write.
    ///
    ///      `owner()` alone is not a type check: any contract can return a chosen address.
    ///      Membership in {paymentRailsFactory} is. That factory records every PaymentRails it
    ///      deploys, and only its owner can add to the list, so a lookalike can copy `owner()` and
    ///      still fail `isDeployedInstance`. Once that passes, the code at `paymentRails` is a
    ///      real PaymentRails and its `owner()` answer can be trusted. A PaymentRails deployed
    ///      outside the factory is rejected; that is the cost of trusting the list. The code-length
    ///      check stays in front of it, so an EOA fails by name before the registry read.
    ///
    ///      OPERATIONAL CONSEQUENCE, flagged deliberately: if Atum deploys modules on a customer's
    ///      behalf, that flow now requires the customer's PaymentRails owner to be the caller.
    ///      The module registry remains informational. `new AtumModule(...)` bypasses it, so
    ///      consumers must still verify a module's `owner`/`keeper`/`paymentRails` wiring directly.
    function _checkPaymentRailsOwner(address paymentRails) private view {
        if (paymentRails.code.length == 0) {
            revert Errors.AtumModuleFactory_PaymentRailsNotContract(paymentRails);
        }
        if (!paymentRailsFactory.isDeployedInstance(paymentRails)) {
            revert Errors.AtumModuleFactory_UnknownPaymentRails(paymentRails);
        }
        address railsOwner = Ownable(paymentRails).owner();
        if (msg.sender != railsOwner) {
            revert Errors.AtumModuleFactory_NotPaymentRailsOwner(msg.sender, railsOwner);
        }
    }

    /// @dev Certora I-04: bind the CREATE2 salt to the caller.
    ///
    ///      A bare user-supplied salt lets anyone watch `createDeterministic` in the mempool and
    ///      deploy to the same address first, so the legitimate deployment reverts on a collision.
    ///      Hashing the caller in makes each deployer's address space disjoint, which removes the
    ///      race rather than narrowing it.
    ///
    ///      NOTE: this CHANGES every deterministic address. Anything that precomputed one must be
    ///      recalculated via `predictDeterministicAddress`, which takes the deployer explicitly.
    function _effectiveSalt(address deployer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(deployer, salt));
    }

    /// @dev Validates the per-instance deployment parameters shared by both create functions.
    function _checkCreateParams(address owner, address paymentRails, address keeper) private pure {
        // Zero owner would brick the module: no one could rotate the keeper or pause.
        if (owner == address(0)) {
            revert Errors.AtumModuleFactory_ZeroOwner();
        }
        // Zero paymentRails would make the module unusable: execute() only accepts the wired caller.
        if (paymentRails == address(0)) {
            revert Errors.AtumModuleFactory_ZeroPaymentRails();
        }
        // Zero keeper is rejected by the module constructor; check here for a clear factory-level error.
        if (keeper == address(0)) {
            revert Errors.AtumModuleFactory_ZeroKeeper();
        }
    }

    /// @dev Registers a newly deployed module in the on-chain registry and emits the creation event.
    function _register(address module, address paymentRails, address owner, address keeper) private {
        _deployedModules.push(module);
        _isDeployedModule[module] = true;
        _modulesByPaymentRails[paymentRails].push(module);

        emit AtumModuleCreated(module, paymentRails, owner, keeper);
    }
}
