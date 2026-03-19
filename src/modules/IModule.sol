// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IModule
/// @notice Common interface for all Dirac modules
/// @dev Modules are stateless contracts that execute via delegatecall from the vault
interface IModule {
    /// @notice Returns the module type identifier
    function moduleType() external pure returns (bytes32);
}
