// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library AaveStorage {
    bytes32 constant SLOT = keccak256("dirac.module.aave.v1");

    struct Layout {
        mapping(address => uint256) collateralDeposited;  // collateralAsset => amount
        mapping(address => uint256) assetBorrowed;        // borrowAsset => amount
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
