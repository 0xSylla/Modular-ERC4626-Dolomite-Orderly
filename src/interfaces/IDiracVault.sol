// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Data} from "../libraries/Data.sol";

interface IDiracVault {
    // ============ Module Execution ============
    function setupModule(
        bytes32 moduleType,
        bytes calldata data
    ) external returns (bytes memory);

    function executeModule(
        bytes32 moduleType,
        bytes calldata data
    ) external payable returns (bytes memory);

    function executeBatch(
        bytes32[] calldata moduleTypes,
        bytes[] calldata datas
    ) external payable returns (bytes[] memory);

    // ============ Curator: Vault Configuration ============
    function whitelistTargetAsset(address asset) external;
    function removeTargetAsset(address asset) external;
    function setMaxDeposit(uint256 amount) external;

    // ============ Curator: Cycle Management ============
    function openDeposits() external;
    function startTrading() external;
    function openWithdrawals() external;
    function closeCycle() external;

    // ============ Emergency (OWNER_ROLE) ============
    function pause() external;
    function unpause() external;
    function emergencyEndCycle() external;
    function emergencyExecuteModule(
        bytes32 moduleType,
        bytes calldata data
    ) external payable returns (bytes memory);

    // ============ View ============
    function getCurrentCycle() external view returns (Data.TradeCycle memory);
    function isTargetAssetWhitelisted(address asset) external view returns (bool);
    function isModuleTypeWhitelisted(bytes32 moduleType) external view returns (bool);
}
