// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Data} from "../libraries/Data.sol";
import {Events} from "../libraries/Events.sol";
// V5 factory mints DiracVaultV5 instances (V4 + attribution hooks).
import {DiracVaultV5 as DiracVault} from "../vault/DiracVaultV5.sol";
import {IDiracVaultFactory} from "../interfaces/IDiracVaultFactory.sol";

/// @title DiracVaultFactoryV5
/// @notice V5 factory — identical to V4 except:
///         1. Every newly-deployed vault is a `DiracVaultV5` that knows about
///            the `attributionRegistry` (Phase 3 engine).
///         2. New `templateAuthor[templateId]` mapping records who authored
///            each strategy template, needed for strategist SBT attribution.
///         3. New `registerTemplate(bytes32, address)` overload to set the
///            author at registration. The legacy `registerTemplate(bytes32)`
///            still works and leaves the author as `address(0)` (no strategist
///            attribution for those templates).
///         4. `attributionRegistry` is mutable by admin so the V5 factory can
///            be deployed BEFORE the registry (chicken-and-egg) and wired up
///            in a follow-up tx — or rotated if the DAO ever redeploys the
///            registry.
///
///         Storage layout matches V1/V2/V3/V4 for tooling compatibility;
///         new fields are appended at the end.
contract DiracVaultFactoryV5 is AccessControl, IDiracVaultFactory {
    bytes32 public constant DIRAC_ADMIN_ROLE = keccak256("DIRAC_ADMIN_ROLE");

    // ============ State (V1-V4 compatible prefix) ============
    address public operator;
    address public curatorRouter;

    address[] public allVaults;
    mapping(address => address[]) public vaultsByCurator;
    mapping(address => bool) private _isVault;

    mapping(bytes32 => address) public registeredModules;
    bytes32[] public moduleTypes;

    mapping(address => bool) public whitelistedDepositTokens;
    mapping(address => Data.AssetInfo) public whitelistedStrategyAssets;
    address[] public strategyAssetList;
    mapping(address => bool) private _isStrategyAsset;
    mapping(address => mapping(bytes32 => bool)) private _allowedPerpsAssets;
    mapping(address => mapping(bytes32 => bytes)) public perpsModuleSymbol;
    mapping(bytes32 => mapping(address => bytes)) public moduleLendingConfig;

    mapping(bytes32 => bool) public registeredTemplates;
    mapping(address => Data.VaultInfo) public vaultInfo;

    // ============ State (V5 additions) ============
    /// @notice Phase 3 attribution engine. Passed into new vault constructors.
    ///         May be zero — vault hooks short-circuit when the address is 0,
    ///         so the factory works pre-registry.
    address public attributionRegistry;

    /// @notice Author of each registered strategy template. Used by the
    ///         registry's `attestStrategistPerformance` to mint SBT to the
    ///         correct recipient. Stays at zero for templates registered
    ///         via the legacy `registerTemplate(bytes32)` overload.
    mapping(bytes32 => address) public templateAuthor;

    // ============ Events (V5 additions) ============
    event AttributionRegistrySet(address indexed prev, address indexed next);
    event TemplateAuthorSet(bytes32 indexed templateId, address indexed author);

    constructor(address admin, address _operator) {
        if (_operator == address(0)) revert Events.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DIRAC_ADMIN_ROLE, admin);
        operator = _operator;
    }

    // ============ V5: Attribution wiring ============

    /// @notice Set / rotate the AttributionRegistry address. New vaults
    ///         deployed AFTER this call will be constructed with the new
    ///         registry. Already-deployed vaults retain their immutable
    ///         registry binding.
    function setAttributionRegistry(address newRegistry) external onlyRole(DIRAC_ADMIN_ROLE) {
        emit AttributionRegistrySet(attributionRegistry, newRegistry);
        attributionRegistry = newRegistry;
    }

    // ============ Vault Deployment ============

    function createVault(
        string memory name,
        string memory symbol,
        address depositToken,
        uint256 maxDeposit,
        bytes32 templateId,
        Data.VaultFees calldata vaultFees,
        uint256 rebalanceThresholdBps,
        uint256 fundingRateThresholdBps
    ) external override returns (address) {
        if (!whitelistedDepositTokens[depositToken])
            revert Events.DepositTokenNotWhitelisted();
        if (!registeredTemplates[templateId])
            revert Events.TemplateNotRegistered();

        DiracVault vault = new DiracVault(
            msg.sender,
            address(this),
            operator,
            depositToken,
            name,
            symbol,
            maxDeposit,
            templateId,
            vaultFees,
            rebalanceThresholdBps,
            fundingRateThresholdBps,
            moduleTypes,
            attributionRegistry // V5 NEW
        );

        address vaultAddr = address(vault);

        if (curatorRouter != address(0)) {
            vault.grantRole(keccak256("OPERATOR_ROLE"), curatorRouter);
            vault.grantRole(keccak256("CURATOR_ROLE"), curatorRouter);
        }

        allVaults.push(vaultAddr);
        vaultsByCurator[msg.sender].push(vaultAddr);
        _isVault[vaultAddr] = true;
        vaultInfo[vaultAddr] = Data.VaultInfo({
            vault: vaultAddr,
            creator: msg.sender,
            templateId: templateId,
            deployedAt: block.timestamp
        });

        emit Events.VaultCreated(
            vaultAddr, msg.sender, depositToken,
            name, symbol, maxDeposit,
            vaultFees.performanceFeeBps, vaultFees.managementFeeBps, vaultFees.feeRecipient,
            rebalanceThresholdBps, fundingRateThresholdBps
        );
        return vaultAddr;
    }

    // ============ Deposit Token Whitelisting ============

    function whitelistDepositToken(address token) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (token == address(0)) revert Events.ZeroAddress();
        whitelistedDepositTokens[token] = true;
        emit Events.DepositTokenWhitelisted(token);
    }

    function removeDepositToken(address token) external override onlyRole(DIRAC_ADMIN_ROLE) {
        delete whitelistedDepositTokens[token];
        emit Events.DepositTokenRemoved(token);
    }

    // ============ Strategy Asset Whitelisting ============

    function whitelistStrategyAsset(Data.AssetInfo calldata assetInfo) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (assetInfo.token == address(0)) revert Events.ZeroAddress();

        if (_isStrategyAsset[assetInfo.token]) {
            Data.AssetInfo storage old = whitelistedStrategyAssets[assetInfo.token];
            for (uint256 i = 0; i < old.allowedPerpsAssets.length; i++) {
                delete _allowedPerpsAssets[assetInfo.token][keccak256(abi.encodePacked(old.allowedPerpsAssets[i]))];
            }
        } else {
            strategyAssetList.push(assetInfo.token);
            _isStrategyAsset[assetInfo.token] = true;
        }

        whitelistedStrategyAssets[assetInfo.token] = assetInfo;

        for (uint256 i = 0; i < assetInfo.allowedPerpsAssets.length; i++) {
            _allowedPerpsAssets[assetInfo.token][keccak256(abi.encodePacked(assetInfo.allowedPerpsAssets[i]))] = true;
        }

        emit Events.StrategyAssetWhitelisted(assetInfo.token, assetInfo);
    }

    function setPerpsModuleSymbol(
        address token,
        bytes32 moduleTypeHash,
        bytes calldata symbol
    ) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (token == address(0)) revert Events.ZeroAddress();
        if (!_isStrategyAsset[token]) revert Events.AssetNotWhitelisted();
        perpsModuleSymbol[token][moduleTypeHash] = symbol;
        emit Events.PerpsModuleSymbolSet(token, moduleTypeHash, symbol);
    }

    function setModuleLendingConfig(
        bytes32 moduleTypeHash,
        address token,
        bytes calldata config_
    ) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (token == address(0)) revert Events.ZeroAddress();
        if (!_isStrategyAsset[token]) revert Events.AssetNotWhitelisted();
        moduleLendingConfig[moduleTypeHash][token] = config_;
        emit Events.ModuleLendingConfigSet(moduleTypeHash, token, config_);
    }

    function removeStrategyAsset(address token) external override onlyRole(DIRAC_ADMIN_ROLE) {
        Data.AssetInfo storage info = whitelistedStrategyAssets[token];
        for (uint256 i = 0; i < info.allowedPerpsAssets.length; i++) {
            delete _allowedPerpsAssets[token][keccak256(abi.encodePacked(info.allowedPerpsAssets[i]))];
        }

        delete whitelistedStrategyAssets[token];

        for (uint256 i = 0; i < strategyAssetList.length; i++) {
            if (strategyAssetList[i] == token) {
                strategyAssetList[i] = strategyAssetList[strategyAssetList.length - 1];
                strategyAssetList.pop();
                break;
            }
        }
        _isStrategyAsset[token] = false;
        emit Events.StrategyAssetRemoved(token);
    }

    // ============ Module Management ============

    function registerModule(bytes32 moduleType_, address moduleAddress) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (moduleAddress == address(0)) revert Events.ZeroAddress();
        if (registeredModules[moduleType_] == address(0)) {
            moduleTypes.push(moduleType_);
        }
        registeredModules[moduleType_] = moduleAddress;
        emit Events.ModuleRegistered(moduleType_, moduleAddress);
    }

    function removeModule(bytes32 moduleType_) external override onlyRole(DIRAC_ADMIN_ROLE) {
        delete registeredModules[moduleType_];
        for (uint256 i = 0; i < moduleTypes.length; i++) {
            if (moduleTypes[i] == moduleType_) {
                moduleTypes[i] = moduleTypes[moduleTypes.length - 1];
                moduleTypes.pop();
                break;
            }
        }
        emit Events.ModuleRemoved(moduleType_);
    }

    // ============ Template Management (V5: author tracking) ============
    //
    // V5 breaking change vs V4: `registerTemplate` now takes a mandatory
    // `author` parameter for strategist attribution. Pass `author = 0` to
    // disable strategist SBT for that template (equivalent to V4 behavior).
    // To rotate authorship after registration, call `removeTemplate` then
    // re-register.

    function registerTemplate(bytes32 templateId, address author) external onlyRole(DIRAC_ADMIN_ROLE) {
        registeredTemplates[templateId] = true;
        templateAuthor[templateId] = author;
        emit Events.TemplateRegistered(templateId);
        emit TemplateAuthorSet(templateId, author);
    }

    function removeTemplate(bytes32 templateId) external onlyRole(DIRAC_ADMIN_ROLE) {
        delete registeredTemplates[templateId];
        delete templateAuthor[templateId];
        emit Events.TemplateRemoved(templateId);
    }

    // ============ Operator Management ============

    function setCuratorRouter(address _curatorRouter) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (_curatorRouter == address(0)) revert Events.ZeroAddress();
        curatorRouter = _curatorRouter;
    }

    function setOperator(address _operator) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (_operator == address(0)) revert Events.ZeroAddress();
        operator = _operator;
    }

    function grantVaultOperator(address vault, address _operator) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).grantRole(keccak256("OPERATOR_ROLE"), _operator);
    }

    function revokeVaultOperator(address vault, address _operator) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).revokeRole(keccak256("OPERATOR_ROLE"), _operator);
    }

    function grantVaultCurator(address vault, address _curator) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).grantRole(keccak256("CURATOR_ROLE"), _curator);
    }

    function revokeVaultCurator(address vault, address _curator) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).revokeRole(keccak256("CURATOR_ROLE"), _curator);
    }

    // V4's `updateOperator` bulk-rotate dropped in V5 — use `setOperator` (sets
    // the default for future vaults) + per-vault `grantVaultOperator` /
    // `revokeVaultOperator` to rotate existing vaults. Saves ~700 bytes runtime.

    // ============ Emergency Functions ============

    function emergencyPause(address vault) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).pause();
        emit Events.EmergencyAction(vault, "pause");
    }

    function emergencyUnpause(address vault) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).unpause();
        emit Events.EmergencyAction(vault, "unpause");
    }

    function emergencyEndCycle(address vault) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).emergencyEndCycle();
        emit Events.EmergencyAction(vault, "endCycle");
    }

    // ============ View Functions ============

    function isVault(address vault) external view override returns (bool) { return _isVault[vault]; }

    function isPerpsAssetAllowed(address collateralAsset, string calldata perpsAsset) external view override returns (bool) {
        return _allowedPerpsAssets[collateralAsset][keccak256(abi.encodePacked(perpsAsset))];
    }

    function isStrategyAssetWhitelisted(address token) external view override returns (bool) { return _isStrategyAsset[token]; }

    function getModule(bytes32 moduleType_) external view override returns (address) { return registeredModules[moduleType_]; }
}
