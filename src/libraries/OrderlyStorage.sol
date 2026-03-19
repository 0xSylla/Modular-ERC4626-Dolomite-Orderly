// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library OrderlyStorage {
    bytes32 constant SLOT = keccak256("dirac.module.orderly.v1");

    struct Layout {
        address orderlyVault;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
