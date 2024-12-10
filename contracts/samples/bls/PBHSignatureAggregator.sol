//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.23;

import "./BLSSignatureAggregator.sol";

interface IPBHVerifier {
    function verifyProof(
        PackedUserOperation memory userOp,
        uint256 root,
        uint256 nullifierHash,
        uint256[8] memory proof
    ) external view returns (bool);
}

/**
 * @title PBHSignatureAggregator
 * @notice Extends BLSSignatureAggregator with ZKP verification capabilities
 * @dev Inherits from BLSSignatureAggregator and only overrides necessary functions
 */
contract PBHSignatureAggregator is BLSSignatureAggregator {
    IPBHVerifier public immutable PBH_VERIFIER;
    
    error InvalidProof();
    error InvalidSignatureLength();

    struct ZKProofData {
        uint256 root;
        uint256 nullifierHash;
        uint256[8] proof;
    }

    constructor(address _entryPoint, address _pbhVerifier) BLSSignatureAggregator(_entryPoint) {
        PBH_VERIFIER = IPBHVerifier(_pbhVerifier);
    }

    /**
     * @dev Verifies the ZK proof component against PBH Verifier
     */
    function verifyProof(PackedUserOperation calldata userOp, ZKProofData memory zkData) internal view {
        if (!PBH_VERIFIER.verifyProof(userOp, zkData.root, zkData.nullifierHash, zkData.proof)) {
            revert InvalidProof();
        }
    }

    /**
     * @dev Decodes ZKP data from the extended signature
     * @param signature Combined signature (BLS signature + ZKP data)
     * @return blsSig The BLS signature component
     * @return zkData The ZKP data component
     */
    function decodeSignatureAndProof(bytes memory signature) 
        internal 
        pure 
        returns (uint256[2] memory blsSig, ZKProofData[] memory zkData) 
    {
        (blsSig, zkData) = abi.decode(
            signature,
            (uint256[2], ZKProofData[])
        );
    }

    /**
     * @dev Override validateSignatures to include ZKP verification
     */
    function validateSignatures(PackedUserOperation[] calldata userOps, bytes calldata signature)
        external
        view
        override
    {
        (uint256[2] memory blsSig, ZKProofData[] memory zkDataArray) = decodeSignatureAndProof(signature);

        // Verify array length matches userOps
        require(zkDataArray.length == userOps.length, "Proof count mismatch");
        
        // Verify each ZK proof
        for (uint256 i = 0; i < userOps.length; i++) {
            verifyProof(userOps[i], zkDataArray[i]);
        }

        // Use parent contract to verify BLS signatures
        bytes memory blsOnlySignature = abi.encode(blsSig);

        return _validateSignaturesInternal(userOps, blsOnlySignature);
    }

    /**
     * @dev Override validateUserOpSignature to include ZKP verification
     */
    function validateUserOpSignature(PackedUserOperation calldata userOp)
        external
        view
        override
        returns (bytes memory sigForUserOp)
    {
        (uint256[2] memory userSig, ZKProofData[] memory zkDataArray) = decodeSignatureAndProof(userOp.signature);
        if(zkDataArray.length != 1) revert InvalidProof();

        // Remove the proof from the userOp signature
        PackedUserOperation memory modifiedUserOp = userOp;
        modifiedUserOp.signature = abi.encode(userSig);

        return super._validateUserOpSignatureInternal(modifiedUserOp);
    }

    function aggregateSignaturesWithProofs(PackedUserOperation[] calldata userOps, ZKProofData[] calldata zkDataArray)
        external
        pure
        returns (bytes memory aggregatedSignature)
    {
        // Get aggregated BLS signature from parent
        bytes memory aggregatedBLS = super._aggregateSignaturesInternal(userOps);
        // TODO: Do we need to abi.encode(zkDataArray) here?
        return abi.encode(aggregatedBLS, zkDataArray);
    }
}