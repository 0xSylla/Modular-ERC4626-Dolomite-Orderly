// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Data} from "../libraries/Data.sol";

interface IDiracVaultFactory {
    function createVault(
        string memory name,
        string memory symbol,
        address depositToken,
        uint256 maxDeposit,
        bytes32 templateId,
        Data.CuratorFeeConfig calldata curatorFee
    ) external returns (address);

    // Protocol fee management
    function setProtocolFee(uint256 feeBps, address recipient) external;
    function setDaoFee(uint256 feeBps, address recipient) external;

    // Asset whitelisting
    function whitelistDepositToken(address token) external;
    function removeDepositToken(address token) external;
    function whitelistStrategyAsset(Data.AssetInfo calldata assetInfo) external;
    function removeStrategyAsset(address token) external;
    function setModuleLendingConfig(bytes32 moduleTypeHash, address token, bytes calldata config_) external;

    // Module management
    function registerModule(bytes32 moduleType, address moduleAddress) external;
    function removeModule(bytes32 moduleType) external;

    // Operator management
    function setOperator(address _operator) external;
    function updateOperator(address newOperator, uint256 start, uint256 end) external;
    function grantVaultOperator(address vault, address _operator) external;
    function revokeVaultOperator(address vault, address _operator) external;

    // Curator management
    function grantVaultCurator(address vault, address _curator) external;
    function revokeVaultCurator(address vault, address _curator) external;

    // Emergency
    function emergencyPause(address vault) external;
    function emergencyUnpause(address vault) external;
    function emergencyEndCycle(address vault) external;
    function emergencyExecute(
        address vault,
        bytes32 moduleType,
        bytes calldata data
    ) external payable;
    function emergencyRescueToken(
        address vault,
        address token,
        address to,
        uint256 amount
    ) external;

    // View
    function isVault(address vault) external view returns (bool);
    function isPerpsAssetAllowed(address collateralAsset, string calldata perpsAsset) external view returns (bool);
    function isStrategyAssetWhitelisted(address token) external view returns (bool);
    function getModule(bytes32 moduleType) external view returns (address);
    function moduleLendingConfig(bytes32 moduleTypeHash, address token) external view returns (bytes memory);
}
