// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OrderInfo, InputToken, OutputToken, ResolvedOrder, SignedOrder} from "../../src/base/ReactorStructs.sol";
import {ReactorEvents} from "../../src/base/ReactorEvents.sol";
import {MockERC20} from "../util/mock/MockERC20.sol";
import {PriorityOrder, PriorityOrderLib, PriorityInput, PriorityOutput} from "../../src/lib/PriorityOrderLib.sol";
import {PriorityFeeLib} from "../../src/lib/PriorityFeeLib.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {DeployPermit2} from "../util/DeployPermit2.sol";
import {MockValidationContract} from "../util/mock/MockValidationContract.sol";
import {MockFillContract} from "../util/mock/MockFillContract.sol";
import {MockFeeController} from "../util/mock/MockFeeController.sol";
import {PriorityOrderReactor} from "../../src/reactors/PriorityOrderReactor.sol";
import {BaseReactor} from "../../src/reactors/BaseReactor.sol";
import {IValidationCallback} from "../../src/interfaces/IValidationCallback.sol";
import {OrderInfoBuilder} from "../util/OrderInfoBuilder.sol";
import {OutputsBuilder} from "../util/OutputsBuilder.sol";
import {PermitSignature} from "../util/PermitSignature.sol";
import {BaseReactorTest} from "../base/BaseReactor.t.sol";

contract PriorityOrderReactorTest is PermitSignature, DeployPermit2, BaseReactorTest {
    using OrderInfoBuilder for OrderInfo;
    using PriorityOrderLib for PriorityOrder;
    using PriorityFeeLib for PriorityInput;
    using PriorityFeeLib for PriorityOutput;
    using PriorityFeeLib for PriorityOutput[];

    string constant PRIORITY_ORDER_TYPE_NAME = "PriorityOrder";

    error OrderNotFillable();
    error InputOutputScaling();

    function setUp() public {
        tokenIn.mint(address(swapper), ONE);
        tokenOut.mint(address(fillContract), ONE);
    }

    function name() public pure override returns (string memory) {
        return "PriorityOrderReactor";
    }

    function createReactor() public override returns (BaseReactor) {
        return new PriorityOrderReactor(permit2, PROTOCOL_FEE_OWNER);
    }

    /// @dev Create and return a basic PriorityOrder along with its signature, hash, and orderInfo
    /// uses default parameter values for startBlock and mpsPerPriorityFeeWei
    function createAndSignOrder(ResolvedOrder memory request)
        public
        view
        override
        returns (SignedOrder memory signedOrder, bytes32 orderHash)
    {
        PriorityOutput[] memory outputs = new PriorityOutput[](request.outputs.length);
        for (uint256 i = 0; i < request.outputs.length; i++) {
            outputs[i] = PriorityOutput({
                token: request.outputs[i].token,
                amount: request.outputs[i].amount,
                mpsPerPriorityFeeWei: 0,
                recipient: request.outputs[i].recipient
            });
        }

        PriorityOrder memory order = PriorityOrder({
            info: request.info,
            startBlock: block.number,
            input: PriorityInput({token: request.input.token, amount: request.input.amount, mpsPerPriorityFeeWei: 0}),
            outputs: outputs
        });
        orderHash = order.hash();
        return (SignedOrder(abi.encode(order), signOrder(swapperPrivateKey, address(permit2), order)), orderHash);
    }

    /// @notice Test a basic order when output priority fee is non zero
    function testExecuteWithOutputPriorityFee() public {
        uint256 priorityFee = 100 wei;
        vm.txGasPrice(priorityFee);

        uint256 inputAmount = 1 ether;
        uint256 outputAmount = 1 ether;
        uint256 inputMpsPerPriorityFeeWei = 0;
        uint256 outputMpsPerPriorityFeeWei = 1; // exact input
        uint256 deadline = block.timestamp + 1000;

        tokenIn.mint(address(swapper), uint256(inputAmount) * 100);
        tokenOut.mint(address(fillContract), uint256(outputAmount) * 100);
        tokenIn.forceApprove(swapper, address(permit2), inputAmount);

        PriorityOutput[] memory outputs =
            OutputsBuilder.singlePriority(address(tokenOut), outputAmount, outputMpsPerPriorityFeeWei, address(swapper));
        uint256 scaledOutputAmount = outputs[0].scale(priorityFee).amount;

        PriorityOrder memory order = PriorityOrder({
            info: OrderInfoBuilder.init(address(reactor)).withSwapper(swapper).withDeadline(deadline),
            startBlock: block.number,
            input: PriorityInput({token: tokenIn, amount: inputAmount, mpsPerPriorityFeeWei: inputMpsPerPriorityFeeWei}),
            outputs: outputs
        });

        SignedOrder memory signedOrder =
            SignedOrder(abi.encode(order), signOrder(swapperPrivateKey, address(permit2), order));
        bytes32 orderHash = order.hash();

        uint256 swapperInputBalanceStart = tokenIn.balanceOf(address(swapper));
        uint256 swapperOutputBalanceStart = tokenOut.balanceOf(address(swapper));

        vm.expectEmit(true, true, true, true, address(reactor));
        emit Fill(orderHash, address(fillContract), swapper, order.info.nonce);
        // execute order
        fillContract.execute(signedOrder);

        assertEq(tokenOut.balanceOf(address(swapper)), swapperOutputBalanceStart + scaledOutputAmount);
        assertEq(tokenIn.balanceOf(address(swapper)), swapperInputBalanceStart - inputAmount);
    }

    /// @notice Test a basic order when input priority fee is non zero
    function testExecuteWithInputPriorityFee() public {
        uint256 priorityFee = 100 wei;
        vm.txGasPrice(priorityFee);

        uint256 inputAmount = 1 ether;
        uint256 outputAmount = 1 ether;
        uint256 inputMpsPerPriorityFeeWei = 1; // exact output
        uint256 outputMpsPerPriorityFeeWei = 0; 
        uint256 deadline = block.timestamp + 1000;

        tokenIn.mint(address(swapper), uint256(inputAmount) * 100);
        tokenOut.mint(address(fillContract), uint256(outputAmount) * 100);
        tokenIn.forceApprove(swapper, address(permit2), inputAmount);

        PriorityInput memory input = PriorityInput({token: tokenIn, amount: inputAmount, mpsPerPriorityFeeWei: inputMpsPerPriorityFeeWei});
        PriorityOutput[] memory outputs =
            OutputsBuilder.singlePriority(address(tokenOut), outputAmount, outputMpsPerPriorityFeeWei, address(swapper));
        uint256 scaledInputAmount = input.scale(priorityFee).amount;

        PriorityOrder memory order = PriorityOrder({
            info: OrderInfoBuilder.init(address(reactor)).withSwapper(swapper).withDeadline(deadline),
            startBlock: block.number,
            input: input,
            outputs: outputs
        });

        SignedOrder memory signedOrder =
            SignedOrder(abi.encode(order), signOrder(swapperPrivateKey, address(permit2), order));
        bytes32 orderHash = order.hash();

        uint256 swapperInputBalanceStart = tokenIn.balanceOf(address(swapper));
        uint256 swapperOutputBalanceStart = tokenOut.balanceOf(address(swapper));

        vm.expectEmit(true, true, true, true, address(reactor));
        emit Fill(orderHash, address(fillContract), swapper, order.info.nonce);
        // execute order
        fillContract.execute(signedOrder);

        assertEq(tokenIn.balanceOf(address(swapper)), swapperInputBalanceStart - scaledInputAmount);
        assertEq(tokenOut.balanceOf(address(swapper)), swapperOutputBalanceStart + outputAmount);
    }

    function testRevertsWithInputOutputScaling() public {
        uint256 mpsPerPriorityFeeWei = 1;

        PriorityOutput[] memory outputs =
            OutputsBuilder.singlePriority(address(tokenOut), 0, mpsPerPriorityFeeWei, address(swapper));

        PriorityOrder memory order = PriorityOrder({
            info: OrderInfoBuilder.init(address(reactor)).withSwapper(swapper).withDeadline(block.timestamp + 1000),
            startBlock: block.number,
            input: PriorityInput({token: tokenIn, amount: 0, mpsPerPriorityFeeWei: mpsPerPriorityFeeWei}),
            outputs: outputs
        });

        SignedOrder memory signedOrder =
            SignedOrder(abi.encode(order), signOrder(swapperPrivateKey, address(permit2), order));

        vm.expectRevert(InputOutputScaling.selector);
        fillContract.execute(signedOrder);
    }

    function testRevertsBeforeStartBlock() public {
        PriorityOutput[] memory outputs = OutputsBuilder.singlePriority(address(tokenOut), 0, 0, address(swapper));

        PriorityOrder memory order = PriorityOrder({
            info: OrderInfoBuilder.init(address(reactor)).withSwapper(swapper).withDeadline(block.timestamp + 1000),
            startBlock: block.number + 1,
            input: PriorityInput({token: tokenIn, amount: 0, mpsPerPriorityFeeWei: 0}),
            outputs: outputs
        });

        SignedOrder memory signedOrder =
            SignedOrder(abi.encode(order), signOrder(swapperPrivateKey, address(permit2), order));

        vm.expectRevert(OrderNotFillable.selector);
        fillContract.execute(signedOrder);
    }
}
