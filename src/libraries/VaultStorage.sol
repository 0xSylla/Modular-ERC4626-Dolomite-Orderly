// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Data} from "./Data.sol";

library VaultStorage {
    bytes32 constant SLOT = keccak256("dirac.vault.storage.v1");

    struct Layout {
        uint256 maxDeposit;
        uint256 totalTVL;
        uint256 totalUsers;
        Data.CuratorFeeConfig curatorFee;
        Data.ProtocolFees protocolFees;
        Data.VaultFees vaultFees;
        Data.TradeCycle currentCycle;
        uint256 rebalanceThresholdBps;   // e.g. 2500 = 25%, 0 = disabled
        uint256 fundingRateThresholdBps; // e.g. 50 = 0.5%, 0 = disabled
        mapping(address => uint256) userDeposits;
        mapping(bytes32 => bool) whitelistedModuleTypes;
        mapping(address => bool) vaultTargetAssets;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
