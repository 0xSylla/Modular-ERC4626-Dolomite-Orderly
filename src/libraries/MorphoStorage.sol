// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library MorphoStorage {
    bytes32 constant SLOT = keccak256("dirac.module.morpho.v1");

    struct Layout {
        mapping(bytes32 => uint256) collateralDeposited;  // marketId => amount
        mapping(bytes32 => uint256) assetBorrowed;        // marketId => amount
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
