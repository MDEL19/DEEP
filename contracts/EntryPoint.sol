// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.7;

import "./StakeManager.sol";
import "./UserOperation.sol";
import "./IWallet.sol";
import "./IPaymaster.sol";

interface ICreate2Deployer {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address);
}

contract EntryPoint is StakeManager {

    using UserOperationLib for UserOperation;

    enum PaymentMode {
        paymasterStake, // if paymaster is set, use paymaster's stake to pay.
        walletStake // pay with wallet deposit.
    }

    address public immutable create2factory;

    event UserOperationEvent(bytes32 indexed requestId, address indexed sender, address indexed paymaster, uint nonce, uint actualGasCost, uint actualGasPrice, bool success);
    event UserOperationRevertReason(bytes32 indexed requestId, address indexed sender, uint nonce, bytes revertReason);

    //handleOps reverts with this error struct, to mark the offending op
    // NOTE: if simulateOp passes successfully, there should be no reason for handleOps to fail on it.
    // @param opIndex - index into the array of ops to the failed one (in simulateOp, this is always zero)
    // @param paymaster - if paymaster.validatePaymasterUserOp fails, this will be the paymaster's address. if validateUserOp failed,
    //      this value will be zero (since it failed before accessing the paymaster)
    // @param reason - revert reason
    //  only to aid troubleshooting of wallet/paymaster reverts
    error FailedOp(uint opIndex, address paymaster, string reason);

    /**
     * @param _create2factory - contract to "create2" wallets (not the EntryPoint itself, so that it can be upgraded)
     * @param _paymasterStake - locked stake of paymaster (actual value should also cover TX cost)
     * @param _unstakeDelaySec - minimum time (in seconds) a paymaster stake must be locked
     */
    constructor(address _create2factory, uint _paymasterStake, uint32 _unstakeDelaySec) StakeManager(_paymasterStake, _unstakeDelaySec) {
        require(_create2factory != address(0), "invalid create2factory");
        require(_unstakeDelaySec > 0, "invalid unstakeDelay");
        require(_paymasterStake > 0, "invalid paymasterStake");
        create2factory = _create2factory;
    }

    function _compensate(address payable beneficiary, uint amount) internal {
        require(beneficiary != address(0), "invalid beneficiary");
        (bool success,) = beneficiary.call{value : amount}("");
        require(success);
    }

    /**
     * Execute a batch of UserOperation.
     * @param ops the operations to execute
     * @param beneficiary the address to receive the fees
     */
    function handleOps(UserOperation[] calldata ops, address payable beneficiary) public {

        uint opslen = ops.length;
        UserOpInfo[] memory opInfos = new UserOpInfo[](opslen);

    unchecked {
        for (uint i = 0; i < opslen; i++) {
            uint preGas = gasleft();
            UserOperation calldata op = ops[i];

            bytes memory context;
            uint contextOffset;
            bytes32 requestId = getRequestId(op);
            uint prefund;
            PaymentMode paymentMode;
            (prefund, paymentMode, context) = _validatePrepayment(i, op, requestId);
            assembly {contextOffset := context}
            opInfos[i] = UserOpInfo(
                requestId,
                prefund,
                paymentMode,
                contextOffset,
                preGas - gasleft() + op.preVerificationGas
            );
        }

        uint collected = 0;

        for (uint i = 0; i < ops.length; i++) {
            uint preGas = gasleft();
            UserOperation calldata op = ops[i];
            UserOpInfo memory opInfo = opInfos[i];
            uint contextOffset = opInfo.contextOffset;
            bytes memory context;
            assembly {context := contextOffset}

            try this.innerHandleOp(op, opInfo, context) returns (uint _actualGasCost) {
                collected += _actualGasCost;
            } catch {
                uint actualGas = preGas - gasleft() + opInfo.preOpGas;
                collected += _handlePostOp(i, IPaymaster.PostOpMode.postOpReverted, op, opInfo, context, actualGas);
            }
        }

        _compensate(beneficiary, collected);
    } //unchecked
    }

    struct UserOpInfo {
        bytes32 requestId;
        uint prefund;
        PaymentMode paymentMode;
        uint contextOffset;
        uint preOpGas;
    }

    /**
     * inner function to handle a UserOperation.
     * Must be declared "external" to open a call context, but it can only be called by handleOps.
     */
    function innerHandleOp(UserOperation calldata op, UserOpInfo calldata opInfo, bytes calldata context) external returns (uint actualGasCost) {
        uint preGas = gasleft();
        require(msg.sender == address(this));

        IPaymaster.PostOpMode mode = IPaymaster.PostOpMode.opSucceeded;
        if (op.callData.length > 0) {

            (bool success,bytes memory result) = address(op.getSender()).call{gas : op.callGas}(op.callData);
            if (!success) {
                if (result.length > 0) {
                    emit UserOperationRevertReason(opInfo.requestId, op.getSender(), op.nonce, result);
                }
                mode = IPaymaster.PostOpMode.opReverted;
            }
        }

    unchecked {
        uint actualGas = preGas - gasleft() + opInfo.preOpGas;
        return _handlePostOp(0, mode, op, opInfo, context, actualGas);
    }
    }

    /**
     * generate a request Id - unique identifier for this request.
     * the request ID is a hash over the content of the userOp (except the signature).
     */
    function getRequestId(UserOperation calldata userOp) public view returns (bytes32) {
        return keccak256(abi.encode(userOp.hash(), address(this), block.chainid));
    }

    /**
    * Simulate a call to wallet.validateUserOp and paymaster.validatePaymasterUserOp.
    * Validation succeeds of the call doesn't revert.
    * @dev The node must also verify it doesn't use banned opcodes, and that it doesn't reference storage outside the wallet's data.
     *      In order to split the running opcodes of the wallet (validateUserOp) from the paymaster's validatePaymasterUserOp,
     *      it should look for the NUMBER opcode at depth=1 (which itself is a banned opcode)
     * @return preOpGas total gas used by validation (including contract creation)
     * @return prefund the amount the wallet had to prefund (zero in case a paymaster pays)
     */
    function simulateValidation(UserOperation calldata userOp) external returns (uint preOpGas, uint prefund) {
        uint preGas = gasleft();

        bytes32 requestId = getRequestId(userOp);
        (prefund,,) = _validatePrepayment(0, userOp, requestId);
        preOpGas = preGas - gasleft() + userOp.preVerificationGas;

        require(msg.sender == address(0), "must be called off-chain with from=zero-addr");
    }

    function _getPaymentInfo(UserOperation calldata userOp) internal view returns (uint requiredPrefund, PaymentMode paymentMode) {
        requiredPrefund = userOp.requiredPreFund();
        if (userOp.hasPaymaster()) {
            paymentMode = PaymentMode.paymasterStake;
        } else {
            paymentMode = PaymentMode.walletStake;
        }
    }

    // create the sender's contract if needed.
    function _createSenderIfNeeded(UserOperation calldata op) internal {
        if (op.initCode.length != 0) {
            // note that we're still under the gas limit of validate, so probably
            // this create2 creates a proxy account.
            // @dev initCode must be unique (e.g. contains the signer address), to make sure
            //   it can only be executed from the entryPoint, and called with its initialization code (callData)
            address sender1 = ICreate2Deployer(create2factory).deploy(op.initCode, bytes32(op.nonce));
            require(sender1 != address(0), "create2 failed");
            require(sender1 == op.getSender(), "sender doesn't match create2 address");
        }
    }

    /// Get counterfactual sender address.
    ///  Calculate the sender contract address that will be generated by the initCode and salt in the UserOperation.
    function getSenderAddress(bytes memory initCode, uint salt) public view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(create2factory),
                salt,
                keccak256(initCode)
            )
        );

        // NOTE: cast last 20 bytes of hash to address
        return address(uint160(uint256(hash)));
    }

    //call wallet.validateUserOp, validate that it paid as needed, and decrement wallet's deposit.
    function _validateWalletPrepayment(uint opIndex, UserOperation calldata op, bytes32 requestId, uint requiredPrefund, PaymentMode paymentMode) internal returns (uint gasUsedByValidateUserOp) {
    unchecked {
        uint preGas = gasleft();
        _createSenderIfNeeded(op);
        uint missingWalletFunds = 0;
        address sender = op.getSender();
        if (paymentMode != PaymentMode.paymasterStake) {
            uint bal = balanceOf(sender);
            missingWalletFunds = bal > requiredPrefund ? 0 : requiredPrefund - bal;
        }
        try IWallet(sender).validateUserOp{gas : op.verificationGas}(op, requestId, missingWalletFunds) {
        } catch Error(string memory revertReason) {
            revert FailedOp(opIndex, address(0), revertReason);
        } catch {
            revert FailedOp(opIndex, address(0), "");
        }
        if (paymentMode != PaymentMode.paymasterStake) {
            if (requiredPrefund > balanceOf(sender)) {
                revert FailedOp(opIndex, address(0), "wallet didn't pay prefund");
            }
            internalDecrementDeposit(sender, requiredPrefund);
        }
        gasUsedByValidateUserOp = preGas - gasleft();
    }
    }

    //validate paymaster.validatePaymasterUserOp, and decrement its deposit
    function _validatePaymasterPrepayment(uint opIndex, UserOperation calldata op, bytes32 requestId, uint requiredPreFund, uint gasUsedByValidateUserOp) internal view returns (bytes memory context) {
    unchecked {
        address paymaster = op.paymaster;
        DepositInfo memory paymasterInfo = getDepositInfo(paymaster);
        if (!paymasterInfo.staked) {
            revert FailedOp(opIndex, paymaster, "not staked");
        }
        if (paymasterInfo.deposit < requiredPreFund) {
            revert FailedOp(opIndex, paymaster, "paymaster deposit too low");
        }
        paymasterInfo.deposit = uint112(paymasterInfo.deposit - requiredPreFund);

        uint gas = op.verificationGas - gasUsedByValidateUserOp;
        try IPaymaster(paymaster).validatePaymasterUserOp{gas : gas}(op, requestId, requiredPreFund) returns (bytes memory _context){
            context = _context;
        } catch Error(string memory revertReason) {
            revert FailedOp(opIndex, paymaster, revertReason);
        } catch {
            revert FailedOp(opIndex, paymaster, "");
        }
    }
    }

    function _validatePrepayment(uint opIndex, UserOperation calldata userOp, bytes32 requestId) private returns (uint requiredPreFund, PaymentMode paymentMode, bytes memory context){

        uint preGas = gasleft();
        uint maxGasValues = userOp.preVerificationGas | userOp.verificationGas |
        userOp.callGas | userOp.maxFeePerGas | userOp.maxPriorityFeePerGas;
        require(maxGasValues < type(uint120).max, "gas values overflow");
        uint gasUsedByValidateUserOp;
        (requiredPreFund, paymentMode) = _getPaymentInfo(userOp);

        (gasUsedByValidateUserOp) = _validateWalletPrepayment(opIndex, userOp, requestId, requiredPreFund, paymentMode);

        //a "marker" where wallet opcode validation is done, by paymaster opcode validation is about to start
        // (used only by off-chain simulateValidation)
        uint marker = block.number;
        (marker);

        if (paymentMode == PaymentMode.paymasterStake) {
            (context) = _validatePaymasterPrepayment(opIndex, userOp, requestId, requiredPreFund, gasUsedByValidateUserOp);
        } else {
            context = "";
        }
    unchecked {
        uint gasUsed = preGas - gasleft();

        if (userOp.verificationGas < gasUsed) {
            revert FailedOp(opIndex, userOp.paymaster, "Used more than verificationGas");
        }
    }
    }

    function _handlePostOp(uint opIndex, IPaymaster.PostOpMode mode, UserOperation calldata op, UserOpInfo memory opInfo, bytes memory context, uint actualGas) private returns (uint actualGasCost) {
        uint preGas = gasleft();
        uint gasPrice = UserOperationLib.gasPrice(op);
    unchecked {
        address refundAddress;

        if (opInfo.paymentMode != PaymentMode.paymasterStake) {
            refundAddress = op.getSender();
        } else {
            address paymaster = op.paymaster;
            refundAddress = paymaster;
            if (context.length > 0) {
                actualGasCost = actualGas * gasPrice;
                if (mode != IPaymaster.PostOpMode.postOpReverted) {
                    IPaymaster(paymaster).postOp{gas : op.verificationGas}(mode, context, actualGasCost);
                } else {
                    try IPaymaster(paymaster).postOp{gas : op.verificationGas}(mode, context, actualGasCost) {}
                    catch Error(string memory reason) {
                        revert FailedOp(opIndex, paymaster, reason);
                    }
                    catch {
                        revert FailedOp(opIndex, paymaster, "postOp revert");
                    }
                }
            }
        }
        actualGas += preGas - gasleft();
        actualGasCost = actualGas * gasPrice;
        if (opInfo.prefund < actualGasCost) {
            revert ("prefund below actualGasCost");
        }
        uint refund = opInfo.prefund - actualGasCost;
        internalIncrementDeposit(refundAddress, refund);
        bool success = mode == IPaymaster.PostOpMode.opSucceeded;
        emit UserOperationEvent(opInfo.requestId, op.getSender(), op.paymaster, op.nonce, actualGasCost, gasPrice, success);
    } // unchecked
    }
}

