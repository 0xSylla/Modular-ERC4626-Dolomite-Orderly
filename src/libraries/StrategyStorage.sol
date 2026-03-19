// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Data} from "./Data.sol";

/// @dev Legacy storage layout — no longer used by vault (positions moved to VaultCuratorRouter)
library StrategyStorage {
    bytes32 constant SLOT = keccak256("dirac.vault.strategies.v1");

    struct Layout {
        Data.Position[] positions;
        uint256 nextPositionId;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
