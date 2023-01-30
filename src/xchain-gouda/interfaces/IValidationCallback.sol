// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.16;

import {SettlementInfo, ResolvedOrder} from "../base/SettlementStructs.sol";

/// @notice Callback to validate an order
interface IValidationCallback {
    /// @notice Called by the settler for custom validation of an order
    /// @param filler The filler of the order
    /// @param resolvedOrder The resolved order to fill
    /// @return true if valid, else false
    function validate(address filler, ResolvedOrder calldata resolvedOrder) external view returns (bool);
}
