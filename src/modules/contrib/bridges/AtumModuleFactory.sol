// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IAtumModuleFactory } from "../../../interfaces/IAtumModuleFactory.sol";
import { AtumModule } from "./AtumModule.sol";
import { Errors } from "../../../libraries/Errors.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title AtumModuleFactory
/// @custom:tier contrib
/// @custom:maintainer @atum-labs (security@atumlabs.xyz)
/// @custom:audit-status unaudited
/// @author Credit Cooperative
/// @notice See the documentation in {IAtumModuleFactory}.
/// @dev `create`/`createDeterministic` are permissionless: anyone can deploy an AtumModule and it is
///      recorded in the registry. The registry is informational only — membership is NOT an
///      authorization or trust signal, and `_deployedModules` grows unbounded. Consumers must verify
///      a module's `owner`/`keeper`/`paymentRails` wiring rather than trusting registry presence, and
///      read `getDeployedModules` offchain (it returns the full array).
contract AtumModuleFactory is IAtumModuleFactory {
    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAtumModuleFactory
    address public immutable override permit2;

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
    constructor(address _permit2) {
        if (_permit2 == address(0)) {
            revert Errors.AtumModuleFactory_ZeroPermit2();
        }
        // The module constructor calls DOMAIN_SEPARATOR() on this address; rejecting EOAs here fails
        // fast at factory deployment instead of on every create().
        if (_permit2.code.length == 0) {
            revert Errors.AtumModuleFactory_Permit2NotContract(_permit2);
        }

        permit2 = _permit2;
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

    /// @dev Validates the per-instance deployment parameters shared by both create functions.
    /// @dev Certora L-01: only the PaymentRails owner may create a module bound to it.
    ///
    ///      Creation was permissionless, so anyone could deploy a genuine factory module naming a
    ///      victim's PaymentRails while making themselves its owner and keeper. The result passes
    ///      `isDeployedModule` and shows up in `getModulesForPaymentRails(victim)`. The registry
    ///      documents itself as informational, which is a fair answer to "is this authorisation?"
    ///      but not to "can a stranger write into my listing?" -- this closes the write.
    ///
    ///      OPERATIONAL CONSEQUENCE, flagged deliberately: if Atum deploys modules on a customer's
    ///      behalf, that flow now requires the customer's PaymentRails owner to be the caller, or
    ///      an explicit deployer allowlist instead of this check. Raised with the module owner.
    function _checkPaymentRailsOwner(address paymentRails) private view {
        if (paymentRails.code.length == 0) {
            revert Errors.AtumModuleFactory_PaymentRailsNotContract(paymentRails);
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
