// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {DolomiteRegularModule} from "./DolomiteRegularModule.sol";
import {IDolomiteMargin} from "../../../interfaces/IDolomite.sol";

/// @title DolomiteArbModule
/// @notice Arbitrum Dolomite module — provides chain-specific constants.
///         All logic lives in DolomiteRegularModule (operate()-based).
contract DolomiteArbModule is DolomiteRegularModule {

    IDolomiteMargin internal constant DOLOMITE_MARGIN =
        IDolomiteMargin(0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072);

    /// @notice Odos Router V2
    address internal constant ODOS_ROUTER = 0xa669e7A0d4b3e4Fa48af2dE86BD4CD7126Be4e13;

    function _dolomiteMargin() internal view override returns (IDolomiteMargin) {
        return DOLOMITE_MARGIN;
    }

    function _swapRouter() internal view override returns (address) {
        return ODOS_ROUTER;
    }
}
