// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev ERC20 that credits the recipient in full and charges the fee to the SENDER on top.
///
/// Distinct from {FeeOnTransferERC20}, which shorts the recipient and is therefore caught by a
/// received-amount check. Here the recipient gets exactly `amount` while the sender is debited
/// `amount + fee`, so a module that only measures what arrived sees a clean transfer and reports
/// success while its funding source is down more than it gained (Certora I-06).
contract SenderFeeERC20 is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor() ERC20("SFEE", "SFEE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            super._update(from, to, amount);
            uint256 fee = (amount * FEE_BPS) / 10_000;
            if (fee != 0) super._update(from, address(0), fee);
        } else {
            super._update(from, to, amount);
        }
    }
}
