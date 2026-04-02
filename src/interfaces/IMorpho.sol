// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @dev Morpho Blue market parameters — identifies a unique lending market
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @dev Morpho Blue core interface — only functions needed by MorphoModule
interface IMorpho {
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalfOf,
        bytes memory data
    ) external;

    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalfOf,
        address receiver
    ) external;

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    /// @notice Returns the position of a user in a market
    function position(bytes32 id, address user)
        external view returns (
            uint256 supplyShares,
            uint128 borrowShares,
            uint128 collateral
        );

    /// @notice Returns the market state
    function market(bytes32 id)
        external view returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );

    /// @notice Returns the market ID for a given MarketParams
    function idToMarketParams(bytes32 id)
        external view returns (MarketParams memory);
}

/// @dev Morpho oracle interface — returns price with 36 decimals of precision
interface IMorphoOracle {
    function price() external view returns (uint256);
}
