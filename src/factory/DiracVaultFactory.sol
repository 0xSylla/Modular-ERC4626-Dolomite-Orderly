// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Data} from "../libraries/Data.sol";
import {Events} from "../libraries/Events.sol";
import {DiracVault} from "../vault/DiracVault.sol";
import {IDiracVaultFactory} from "../interfaces/IDiracVaultFactory.sol";

/// @title DiracVaultFactory
/// @notice Central registry for vault deployment, module management, and asset whitelisting
/// @dev Owned by the Dirac multisig. Gets OWNER_ROLE on every vault it deploys.
contract DiracVaultFactory is AccessControl, IDiracVaultFactory {
    bytes32 public constant DIRAC_ADMIN_ROLE = keccak256("DIRAC_ADMIN_ROLE");

    // ============ State ============
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
    /// collateralAsset => keccak256(perpsAsset) => allowed
    mapping(address => mapping(bytes32 => bool)) private _allowedPerpsAssets;
    /// collateralToken => moduleTypeHash => module-specific symbol/identifier (bytes-encoded)
    mapping(address => mapping(bytes32 => bytes)) public perpsModuleSymbol;
    /// moduleTypeHash => token => module-specific lending config (bytes-encoded, e.g. abi.encode(marketId))
    mapping(bytes32 => mapping(address => bytes)) public moduleLendingConfig;

    /// Registered strategy templates
    mapping(bytes32 => bool) public registeredTemplates;
    /// vault => VaultInfo
    mapping(address => Data.VaultInfo) public vaultInfo;

    constructor(
        address admin,
        address _operator
    ) {
        if (_operator == address(0)) revert Events.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DIRAC_ADMIN_ROLE, admin);
        operator = _operator;
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
            moduleTypes
        );

        address vaultAddr = address(vault);

        // Grant the curator router both roles so it can orchestrate positions on behalf of curators/operators
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

        emit Events.VaultCreated(vaultAddr, msg.sender, depositToken);
        return vaultAddr;
    }

    // ============ Protocol Fee Management ============


    // ============ Deposit Token Whitelisting ============

    function whitelistDepositToken(
        address token
    ) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (token == address(0)) revert Events.ZeroAddress();
        whitelistedDepositTokens[token] = true;
        emit Events.DepositTokenWhitelisted(token);
    }

    function removeDepositToken(
        address token
    ) external override onlyRole(DIRAC_ADMIN_ROLE) {
        delete whitelistedDepositTokens[token];
        emit Events.DepositTokenRemoved(token);
    }

    // ============ Strategy Asset Whitelisting ============

    function whitelistStrategyAsset(
        Data.AssetInfo calldata assetInfo
    ) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (assetInfo.token == address(0)) revert Events.ZeroAddress();

        // Clear old perps mappings if re-whitelisting
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

        // Populate perps lookup
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

    function removeStrategyAsset(
        address token
    ) external override onlyRole(DIRAC_ADMIN_ROLE) {
        // Clear perps mappings
        Data.AssetInfo storage info = whitelistedStrategyAssets[token];
        for (uint256 i = 0; i < info.allowedPerpsAssets.length; i++) {
            delete _allowedPerpsAssets[token][keccak256(abi.encodePacked(info.allowedPerpsAssets[i]))];
        }

        delete whitelistedStrategyAssets[token];

        // Remove from enumerable list
        for (uint256 i = 0; i < strategyAssetList.length; i++) {
            if (strategyAssetList[i] == token) {
                strategyAssetList[i] = strategyAssetList[
                    strategyAssetList.length - 1
                ];
                strategyAssetList.pop();
                break;
            }
        }
        _isStrategyAsset[token] = false;
        emit Events.StrategyAssetRemoved(token);
    }

    // ============ Module Management ============

    function registerModule(
        bytes32 moduleType_,
        address moduleAddress
    ) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (moduleAddress == address(0)) revert Events.ZeroAddress();
        if (registeredModules[moduleType_] == address(0)) {
            moduleTypes.push(moduleType_);
        }
        registeredModules[moduleType_] = moduleAddress;
        emit Events.ModuleRegistered(moduleType_, moduleAddress);
    }

    function removeModule(
        bytes32 moduleType_
    ) external override onlyRole(DIRAC_ADMIN_ROLE) {
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

    // ============ Template Management ============

    function registerTemplate(
        bytes32 templateId
    ) external onlyRole(DIRAC_ADMIN_ROLE) {
        registeredTemplates[templateId] = true;
        emit Events.TemplateRegistered(templateId);
    }

    function removeTemplate(
        bytes32 templateId
    ) external onlyRole(DIRAC_ADMIN_ROLE) {
        delete registeredTemplates[templateId];
        emit Events.TemplateRemoved(templateId);
    }

    // ============ Operator Management ============

    /// @notice Set the curator router — granted OPERATOR_ROLE + CURATOR_ROLE on every new vault
    function setCuratorRouter(address _curatorRouter) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (_curatorRouter == address(0)) revert Events.ZeroAddress();
        curatorRouter = _curatorRouter;
    }

    /// @notice Set the global operator address for future vaults
    function setOperator(address _operator) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (_operator == address(0)) revert Events.ZeroAddress();
        operator = _operator;
    }

    /// @notice Grant OPERATOR_ROLE to an additional address on a specific vault.
    ///         Used to authorize the router as operator.
    function grantVaultOperator(
        address vault,
        address _operator
    ) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).grantRole(keccak256("OPERATOR_ROLE"), _operator);
    }

    /// @notice Revoke OPERATOR_ROLE from an address on a specific vault.
    function revokeVaultOperator(
        address vault,
        address _operator
    ) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).revokeRole(keccak256("OPERATOR_ROLE"), _operator);
    }


    /// @notice Grant CURATOR_ROLE to an additional address on a specific vault.
    function grantVaultCurator(
        address vault,
        address _curator
    ) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).grantRole(keccak256("CURATOR_ROLE"), _curator);
    }

    /// @notice Revoke CURATOR_ROLE from an address on a specific vault.
    function revokeVaultCurator(
        address vault,
        address _curator
    ) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).revokeRole(keccak256("CURATOR_ROLE"), _curator);
    }

    /// @notice Rotate operator across a range of deployed vaults.
    ///         Call with (0, 50), (50, 100), etc. to paginate.
    function updateOperator(
        address newOperator,
        uint256 start,
        uint256 end
    ) external onlyRole(DIRAC_ADMIN_ROLE) {
        if (newOperator == address(0)) revert Events.ZeroAddress();
        address oldOperator = operator;
        operator = newOperator;

        if (end > allVaults.length) end = allVaults.length;
        bytes32 opRole = keccak256("OPERATOR_ROLE");
        for (uint256 i = start; i < end; i++) {
            DiracVault v = DiracVault(payable(allVaults[i]));
            v.revokeRole(opRole, oldOperator);
            v.grantRole(opRole, newOperator);
        }
    }

    // ============ Emergency Functions ============

    function emergencyPause(
        address vault
    ) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).pause();
        emit Events.EmergencyAction(vault, "pause");
    }

    function emergencyUnpause(
        address vault
    ) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).unpause();
        emit Events.EmergencyAction(vault, "unpause");
    }

    function emergencyEndCycle(
        address vault
    ) external override onlyRole(DIRAC_ADMIN_ROLE) {
        if (!_isVault[vault]) revert Events.NotFactoryVault();
        DiracVault(payable(vault)).emergencyEndCycle();
        emit Events.EmergencyAction(vault, "endCycle");
    }


    // ============ View Functions ============
    // Note: most state is public (auto-getters). Only functions needed by
    // other contracts or that wrap private mappings live here.

    function isVault(address vault) external view override returns (bool) {
        return _isVault[vault];
    }

    function isPerpsAssetAllowed(
        address collateralAsset,
        string calldata perpsAsset
    ) external view override returns (bool) {
        return _allowedPerpsAssets[collateralAsset][keccak256(abi.encodePacked(perpsAsset))];
    }

    function isStrategyAssetWhitelisted(
        address token
    ) external view override returns (bool) {
        return _isStrategyAsset[token];
    }

    function getModule(
        bytes32 moduleType_
    ) external view override returns (address) {
        return registeredModules[moduleType_];
    }
}
