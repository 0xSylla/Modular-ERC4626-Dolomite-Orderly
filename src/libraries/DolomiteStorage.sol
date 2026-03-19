// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library DolomiteStorage {
    bytes32 constant SLOT = keccak256("dirac.module.dolomite.v1");

    struct Layout {
        // Legacy single-value fields (kept for storage slot compatibility, unused by new modules)
        uint256 _deprecated_totalCollateralDeposited;
        uint256 _deprecated_totalAssetBorrowed;
        address _deprecated_isolationProxy;
        // Per-market tracking
        mapping(uint256 => uint256) collateralDeposited;  // marketId => amount
        mapping(uint256 => uint256) assetBorrowed;        // marketId => amount
        mapping(uint256 => address) isolationProxies;     // marketId => proxy (zero = regular market)
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly {
            l.slot := slot
        }
    }
}
