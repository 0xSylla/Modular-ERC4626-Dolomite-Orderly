// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IModule} from "./IModule.sol";
import {Events} from "../libraries/Events.sol";

/// @title ModuleBase
/// @notice Abstract base for all Dirac modules — enforces delegatecall-only execution
/// @dev Stores its own address at deploy time. If `address(this)` matches at runtime,
///      the call is direct (not delegatecall) and gets rejected.
abstract contract ModuleBase is IModule {
    address private immutable _self;

    constructor() {
        _self = address(this);
    }

    modifier onlyDelegatecall() {
        if (address(this) == _self) revert Events.OnlyDelegatecall();
        _;
    }
}
