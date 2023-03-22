// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.16;

import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {SafeCast} from "openzeppelin-contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/security/ReentrancyGuard.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ReactorEvents} from "../base/ReactorEvents.sol";
import {ResolvedOrderLib} from "../lib/ResolvedOrderLib.sol";
import {CurrencyLibrary, ETH_ADDRESS} from "../lib/CurrencyLibrary.sol";
import {ExpectedBalanceLib, ExpectedBalance} from "../lib/ExpectedBalanceLib.sol";
import {IReactorCallback} from "../interfaces/IReactorCallback.sol";
import {IReactor} from "../interfaces/IReactor.sol";
import {IPSFees} from "../base/IPSFees.sol";
import {SignedOrder, ResolvedOrder, OrderInfo, InputToken, OutputToken} from "../base/ReactorStructs.sol";

/// @notice Generic reactor logic for settling off-chain signed orders
///     using arbitrary fill methods specified by a taker
abstract contract BaseReactor is IReactor, ReactorEvents, IPSFees, ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using ResolvedOrderLib for ResolvedOrder;
    using ExpectedBalanceLib for ResolvedOrder[];
    using ExpectedBalanceLib for ExpectedBalance[];
    using CurrencyLibrary for address;

    // Occurs when an output = ETH and the reactor does contain enough ETH but
    // the direct taker did not include enough ETH in their call to execute/executeBatch
    error InsufficientEth();

    address public immutable permit2;
    address public constant DIRECT_TAKER_FILL = address(1);

    constructor(address _permit2, uint256 _protocolFeeBps, address _protocolFeeRecipient)
        IPSFees(_protocolFeeBps, _protocolFeeRecipient)
    {
        permit2 = _permit2;
    }

    receive() external payable {}

    /// @inheritdoc IReactor
    function execute(SignedOrder calldata order, address fillContract, bytes calldata fillData)
        external
        payable
        override
        nonReentrant
    {
        ResolvedOrder[] memory resolvedOrders = new ResolvedOrder[](1);
        resolvedOrders[0] = resolve(order);

        _fill(resolvedOrders, fillContract, fillData);
    }

    /// @inheritdoc IReactor
    function executeBatch(SignedOrder[] calldata orders, address fillContract, bytes calldata fillData)
        external
        payable
        override
        nonReentrant
    {
        ResolvedOrder[] memory resolvedOrders = new ResolvedOrder[](orders.length);

        unchecked {
            for (uint256 i = 0; i < orders.length; i++) {
                resolvedOrders[i] = resolve(orders[i]);
            }
        }
        _fill(resolvedOrders, fillContract, fillData);
    }

    /// @notice validates and fills a list of orders, marking it as filled
    function _fill(ResolvedOrder[] memory orders, address fillContract, bytes calldata fillData) internal {
        bool directTaker = fillContract == DIRECT_TAKER_FILL;
        unchecked {
            for (uint256 i = 0; i < orders.length; i++) {
                ResolvedOrder memory order = orders[i];
                _takeFees(order);
                order.validate(msg.sender);
                transferInputTokens(order, directTaker ? msg.sender : fillContract);

                // Batch fills are all-or-nothing so emit fill events now to save a loop
                emit Fill(orders[i].hash, msg.sender, order.info.offerer, order.info.nonce);
            }
        }

        if (directTaker) {
            _processDirectTakerFill(orders);
        } else {
            ExpectedBalance[] memory expectedBalances = orders.getExpectedBalances();
            IReactorCallback(fillContract).reactorCallback(orders, msg.sender, fillData);
            expectedBalances.check();
        }
    }

    /// @notice Process transferring tokens from a direct taker to the recipients
    /// @dev in the case of ETH outputs, ETh should be provided as value in the execute call
    /// @param orders The orders to process
    function _processDirectTakerFill(ResolvedOrder[] memory orders) internal {
        // track outputs from msg.value as the contract may have
        // a standing ETH balance due to collected fees
        unchecked {
            uint256 ethAvailable = msg.value;
            for (uint256 i = 0; i < orders.length; i++) {
                ResolvedOrder memory order = orders[i];
                for (uint256 j = 0; j < order.outputs.length; j++) {
                    OutputToken memory output = order.outputs[j];
                    output.token.transferFromDirectTaker(output.recipient, output.amount, permit2);

                    if (output.token == ETH_ADDRESS) {
                        if (ethAvailable >= output.amount) {
                            ethAvailable -= output.amount;
                        } else {
                            revert InsufficientEth();
                        }
                    }
                }
            }

            // refund any remaining ETH to the taker
            if (ethAvailable > 0) {
                ETH_ADDRESS.transfer(msg.sender, ethAvailable);
            }
        }
    }

    /// @notice Resolve order-type specific requirements into a generic order with the final inputs and outputs.
    /// @param order The encoded order to resolve
    /// @return resolvedOrder generic resolved order of inputs and outputs
    /// @dev should revert on any order-type-specific validation errors
    function resolve(SignedOrder calldata order) internal view virtual returns (ResolvedOrder memory resolvedOrder);

    /// @notice Transfers tokens to the fillContract
    /// @param order The encoded order to transfer tokens for
    /// @param to The address to transfer tokens to
    function transferInputTokens(ResolvedOrder memory order, address to) internal virtual;
}
