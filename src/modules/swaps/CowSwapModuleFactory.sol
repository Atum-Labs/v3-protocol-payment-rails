// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { ICowSwapModuleFactory } from "../../interfaces/ICowSwapModuleFactory.sol";
import { CowSwapModule } from "./CowSwapModule.sol";
import { Errors } from "../../libraries/Errors.sol";

/// @title CowSwapModuleFactory
/// @author Credit Cooperative
/// @notice See the documentation in {ICowSwapModuleFactory}.
/// @dev Creation is owner-gated so the registry only lists modules this organization deployed. The
/// factory cannot verify `paymentRails` is a genuine PaymentRails; the owner is trusted to pass it.
contract CowSwapModuleFactory is ICowSwapModuleFactory, Ownable2Step {
    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICowSwapModuleFactory
    address public immutable override cowSettlement;

    /// @inheritdoc ICowSwapModuleFactory
    address public immutable override sequencerUptimeFeed;

    /// @inheritdoc ICowSwapModuleFactory
    uint256 public immutable override sequencerGracePeriod;

    /// @dev Upper bound on `sequencerGracePeriod`; catches a units slip. Chainlink's reference uses 3600.
    uint256 private constant MAX_SEQUENCER_GRACE_PERIOD = 1 days;

    /*//////////////////////////////////////////////////////////////////////////
                                    STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Array of all deployed CowSwapModule instances.
    address[] private _deployedModules;

    /// @dev Maps deployed module addresses to true for O(1) lookups.
    mapping(address module => bool deployed) private _isDeployedModule;

    /// @dev Maps a PaymentRails to all modules deployed for it.
    mapping(address paymentRails => address[] modules) private _modulesByPaymentRails;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Chain-specific configuration is fixed at factory deployment so the registry
    /// guarantees the wiring of every module it lists, not just the bytecode.
    /// @param initialOwner Address allowed to create modules. Taken as an argument, not
    /// `msg.sender`, so the deployer never holds the role and no handover is required.
    /// @param _cowSettlement GPv2Settlement contract address.
    /// @param _sequencerUptimeFeed Chainlink L2 sequencer uptime feed; address(0) on L1.
    /// @param _sequencerGracePeriod Seconds after sequencer recovery before trusting oracles.
    constructor(
        address initialOwner,
        address _cowSettlement,
        address _sequencerUptimeFeed,
        uint256 _sequencerGracePeriod
    )
        Ownable(initialOwner)
    {
        if (_cowSettlement == address(0)) {
            revert Errors.CowSwapModuleFactory_ZeroCowSettlement();
        }
        // The module constructor calls domainSeparator() and vaultRelayer() on this address;
        // rejecting EOAs here fails fast at factory deployment instead of on every create().
        if (_cowSettlement.code.length == 0) {
            revert Errors.CowSwapModuleFactory_SettlementNotContract(_cowSettlement);
        }
        // address(0) is the L1 profile and stays valid. A non-zero EOA is always a misconfiguration:
        // the module's oracle read would hit the extcodesize check and revert, so every module this
        // factory deploys could never place an order. The wiring is immutable, so a typo caught here
        // costs a factory redeployment instead of the factory plus every module under it.
        if (_sequencerUptimeFeed != address(0) && _sequencerUptimeFeed.code.length == 0) {
            revert Errors.CowSwapModuleFactory_SequencerFeedNotContract(_sequencerUptimeFeed);
        }
        // The feed and the grace period are two halves of one guard, so they must agree. A zero
        // grace period makes the module's check `block.timestamp - startedAt < 0` — never true for
        // uint256 — deleting the guard rather than shortening it.
        if (_sequencerUptimeFeed == address(0)) {
            if (_sequencerGracePeriod != 0) {
                revert Errors.CowSwapModuleFactory_GracePeriodWithoutFeed(_sequencerGracePeriod);
            }
        } else if (_sequencerGracePeriod == 0 || _sequencerGracePeriod > MAX_SEQUENCER_GRACE_PERIOD) {
            revert Errors.CowSwapModuleFactory_InvalidGracePeriod(_sequencerGracePeriod);
        }

        cowSettlement = _cowSettlement;
        sequencerUptimeFeed = _sequencerUptimeFeed;
        sequencerGracePeriod = _sequencerGracePeriod;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    OWNERSHIP
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Disables renounceOwnership(): renouncing would leave both creation paths permanently
    /// uncallable, bricking the factory.
    function renounceOwnership() public pure override {
        revert Errors.CowSwapModuleFactory_OwnershipCannotBeRenounced();
    }

    /*//////////////////////////////////////////////////////////////////////////
                            DEPLOYMENT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICowSwapModuleFactory
    function create(address owner, address paymentRails) external onlyOwner returns (address module) {
        // Checks: Validate the per-instance parameters.
        _checkCreateParams(owner, paymentRails);

        // Interactions: Deploy new CowSwapModule wired to the PaymentRails.
        module =
            address(new CowSwapModule(cowSettlement, owner, paymentRails, sequencerUptimeFeed, sequencerGracePeriod));

        // Effects: Register in the on-chain registry.
        _register(module, paymentRails, owner);
    }

    /// @inheritdoc ICowSwapModuleFactory
    function createDeterministic(
        address owner,
        address paymentRails,
        bytes32 salt
    )
        external
        onlyOwner
        returns (address module)
    {
        // Checks: Validate the per-instance parameters.
        _checkCreateParams(owner, paymentRails);

        // Interactions: Deploy new CowSwapModule with deterministic address.
        module = address(
            new CowSwapModule{ salt: salt }(
                cowSettlement, owner, paymentRails, sequencerUptimeFeed, sequencerGracePeriod
            )
        );

        // Effects: Register in the on-chain registry.
        _register(module, paymentRails, owner);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICowSwapModuleFactory
    function predictDeterministicAddress(
        address owner,
        address paymentRails,
        bytes32 salt
    )
        external
        view
        returns (address predicted)
    {
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(CowSwapModule).creationCode,
                abi.encode(cowSettlement, owner, paymentRails, sequencerUptimeFeed, sequencerGracePeriod)
            )
        );
        predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }

    /// @inheritdoc ICowSwapModuleFactory
    function isDeployedModule(address module) external view returns (bool) {
        return _isDeployedModule[module];
    }

    /// @inheritdoc ICowSwapModuleFactory
    function getDeployedModules() external view returns (address[] memory) {
        return _deployedModules;
    }

    /// @inheritdoc ICowSwapModuleFactory
    function getModuleCount() external view returns (uint256) {
        return _deployedModules.length;
    }

    /// @inheritdoc ICowSwapModuleFactory
    function getModulesForPaymentRails(address paymentRails) external view returns (address[] memory) {
        return _modulesByPaymentRails[paymentRails];
    }

    /*//////////////////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Validates the per-instance deployment parameters shared by both create functions.
    /// The code-length check is a typo guard, not authentication: a 7702-delegated EOA passes it.
    /// Verify `module.paymentRails()` and `module.owner()` before wiring a module.
    function _checkCreateParams(address owner, address paymentRails) private view {
        // Zero owner would brick the module: renounceOwnership is disabled and no one could cancel orders.
        if (owner == address(0)) {
            revert Errors.CowSwapModuleFactory_ZeroOwner();
        }
        // Zero paymentRails would make the module unusable: execute() only accepts the wired caller.
        if (paymentRails == address(0)) {
            revert Errors.CowSwapModuleFactory_ZeroPaymentRails();
        }
        // An EOA can never call execute(), so a module wired to one would be permanently inert.
        if (paymentRails.code.length == 0) {
            revert Errors.CowSwapModuleFactory_PaymentRailsNotContract(paymentRails);
        }
    }

    /// @dev Registers a newly deployed module in the on-chain registry and emits the creation event.
    function _register(address module, address paymentRails, address owner) private {
        _deployedModules.push(module);
        _isDeployedModule[module] = true;
        _modulesByPaymentRails[paymentRails].push(module);

        emit CowSwapModuleCreated(module, paymentRails, owner);
    }
}
