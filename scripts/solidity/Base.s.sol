// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script } from "forge-std/src/Script.sol";

/// @title BaseScript
/// @author Credit Cooperative
/// @notice Base contract for deployment scripts with transaction broadcasting utilities
abstract contract BaseScript is Script {
    /// @dev Thrown when the broadcaster would be derived from the public test mnemonic on a chain that
    /// is not a local node and `ALLOW_TEST_MNEMONIC` is not set.
    error BaseScript_TestMnemonicOnLiveChain(uint256 chainId);

    /// @dev Included to enable compilation of the script without a $MNEMONIC environment variable.
    string internal constant TEST_MNEMONIC = "test test test test test test test test test test test junk";

    /// @dev Needed for the deterministic deployments.
    bytes32 internal constant ZERO_SALT = bytes32(0);

    /// @dev The address of the transaction broadcaster.
    address internal broadcaster;

    /// @dev Used to derive the broadcaster's address if $ETH_FROM is not defined.
    string internal mnemonic;

    /// @dev Initializes the transaction broadcaster like this:
    ///
    /// - If $ETH_FROM is defined, use it.
    /// - Otherwise, derive the broadcaster address from $MNEMONIC.
    /// - If $MNEMONIC is not defined, default to a test mnemonic — local nodes only. On any other chain
    ///   id this reverts unless $ALLOW_TEST_MNEMONIC is set, which only the fork harnesses should do.
    ///
    /// The use case for $ETH_FROM is to specify the broadcaster key and its address via the command line.
    constructor() {
        address from = vm.envOr({ name: "ETH_FROM", defaultValue: address(0) });
        if (from != address(0)) {
            broadcaster = from;
        } else {
            mnemonic = vm.envOr({ name: "MNEMONIC", defaultValue: TEST_MNEMONIC });
            // The test mnemonic is public and its addresses carry EIP-7702 delegations on live chains:
            // a broadcast would sign with a key everyone holds, and gas sent to it is forwarded away on
            // arrival. Anvil forks report the forked chain's id, so harnesses opt in explicitly.
            if (
                block.chainid != 31_337 && keccak256(bytes(mnemonic)) == keccak256(bytes(TEST_MNEMONIC))
                    && !vm.envOr({ name: "ALLOW_TEST_MNEMONIC", defaultValue: false })
            ) {
                revert BaseScript_TestMnemonicOnLiveChain(block.chainid);
            }
            (broadcaster,) = deriveRememberKey({ mnemonic: mnemonic, index: 0 });
        }
    }

    modifier broadcast() {
        vm.startBroadcast(broadcaster);
        _;
        vm.stopBroadcast();
    }
}
