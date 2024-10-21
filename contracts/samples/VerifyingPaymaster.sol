// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import { BasePaymaster, IEntryPoint } from "../core/BasePaymaster.sol";
import { UserOperationLib, PackedUserOperation } from "../core/UserOperationLib.sol";
import { _packValidationData } from "../core/Helpers.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * A verifying paymaster based on the eth-infinitism sample VerifyingPaymaster contract.
 * It has the same functionality as the sample, but with added support for verifying signer access control.
 *
 * This paymaster uses an external service to decide whether to pay for the UserOp and
 * trusts an external signer to sign the transaction.
 *
 * The calling user must pass the UserOp to that external signer first, which performs
 * whatever off-chain verification before signing the UserOp.
 *
 * Note that this signature is NOT a replacement for the account-specific signature:
 * - the paymaster checks a signature to agree to PAY for GAS.
 * - the account checks a signature to prove identity and account ownership.
 */
contract VerifyingPaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;

    uint256 private constant VALID_TIMESTAMP_OFFSET = PAYMASTER_DATA_OFFSET;
    uint256 private constant SIGNATURE_OFFSET = VALID_TIMESTAMP_OFFSET + 64;

    address public verifier;

    event VerifierChanged(address indexed newVerifier);

    constructor(IEntryPoint _entryPoint, address _verifier) BasePaymaster(_entryPoint) {
        verifier = _verifier;
    }

    function setVerifier(address _verifier) public onlyOwner {
        verifier = _verifier;
        emit VerifierChanged(_verifier);
    }

    /**
     * Return the hash we're going to sign off-chain (and validate on-chain).
     * This method is called by the off-chain service, to sign the request.
     * It is called on-chain from the validatePaymasterUserOp, to validate the signature.
     * Note that this signature covers all fields of the UserOperation, except the "paymasterAndData",
     * which will carry the signature itself.
     */
    function getHash(
        PackedUserOperation calldata userOp,
        uint48 validUntil,
        uint48 validAfter
    ) public view returns (bytes32) {
        // Can't use userOp.hash(), since it contains also the paymasterAndData itself.
        address sender = userOp.getSender();
        return
            keccak256(
                abi.encode(
                    sender,
                    userOp.nonce,
                    keccak256(userOp.initCode),
                    keccak256(userOp.callData),
                    userOp.accountGasLimits,
                    uint256(bytes32(userOp.paymasterAndData[PAYMASTER_VALIDATION_GAS_OFFSET:PAYMASTER_DATA_OFFSET])),
                    userOp.preVerificationGas,
                    userOp.gasFees,
                    block.chainid,
                    address(this),
                    validUntil,
                    validAfter
                )
            );
    }

    /**
     * Verify our external signer signed this request.
     * The "paymasterAndData" is expected to be the paymaster and a signature over the entire request params.
     * paymasterAndData[:20] : address(this)
     * paymasterAndData[20:84] : abi.encode(validUntil, validAfter)
     * paymasterAndData[84:] : signature
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 /*userOpHash*/,
        uint256 requiredPreFund
    ) internal view override returns (bytes memory context, uint256 validationData) {
        (requiredPreFund);

        (uint48 validUntil, uint48 validAfter, bytes calldata signature) = parsePaymasterAndData(
            userOp.paymasterAndData
        );

        // ECDSA library supports both 64 and 65-byte long signatures.
        // We only "require" it here so that the revert reason on invalid signature will be of "VerifyingPaymaster", and not "ECDSA".
        require(
            signature.length == 64 || signature.length == 65,
            "VerifyingPaymaster: invalid signature length in paymasterAndData"
        );
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(getHash(userOp, validUntil, validAfter));

        // Don't revert on signature failure: return SIG_VALIDATION_FAILED
        if (verifier != ECDSA.recover(hash, signature)) {
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        // No need for other on-chain validation: entire UserOp should have been checked by the external service prior to signing it.
        return ("", _packValidationData(false, validUntil, validAfter));
    }

    function parsePaymasterAndData(
        bytes calldata paymasterAndData
    ) public pure returns (uint48 validUntil, uint48 validAfter, bytes calldata signature) {
        (validUntil, validAfter) = abi.decode(paymasterAndData[VALID_TIMESTAMP_OFFSET:], (uint48, uint48));
        signature = paymasterAndData[SIGNATURE_OFFSET:];
    }
}
