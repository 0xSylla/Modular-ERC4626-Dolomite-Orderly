// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAttributionRegistry} from "../interfaces/IAttributionRegistry.sol";
import {IDiracVaultFactory} from "../interfaces/IDiracVaultFactory.sol";
import {SoulboundReceiptPool} from "../token/SoulboundReceiptPool.sol";
import {Data} from "../libraries/Data.sol";

/// @dev Subset of V5 vault surface the registry needs at cycle close.
interface IV5Vault {
    function depositors() external view returns (address[] memory);
    function getUserDeposit(address user) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

/// @dev Subset of V5 factory surface the registry reads from.
interface IV5Factory {
    function vaultInfo(address vault) external view returns (Data.VaultInfo memory);
    function templateAuthor(bytes32 templateId) external view returns (address);
    function isVault(address vault) external view returns (bool);
}

/// @title AttributionRegistry
/// @notice Centralized eligibility + minting brain for the Dirac soulbound
///         receipt system. V5 vaults call `onCycleClose` and `onCuratorGateHit`;
///         the multisig (later DAO) calls `attestStrategistPerformance`. For
///         each qualifying actor the registry calls
///         `SoulboundReceiptPool.mintReceipt(user, amount)`.
///
///         The registry holds the only `attributor` role on the pool — vaults
///         can't mint receipts directly. This isolates the eligibility logic
///         and makes it independently governable (Phase 4 DAO can tune
///         thresholds without redeploying vaults).
///
///         **Attribution rules (boss's 3 examples, all DAO-tunable):**
///
///         | Actor      | Gate                                          | Weight                           |
///         |------------|-----------------------------------------------|----------------------------------|
///         | LP         | deposit ≥ minLpDeposit, held through ≥1 close | deposit × lpWeightPerDeposit / 1e6 |
///         | Curator    | TVL ≥ minTvlForCurator AND uniqueLPs ≥ N      | curatorBaseSbt                   |
///         | Strategist | template used ≥1x AND multisig-attested       | strategistBaseSbt × min(vaults, cap) |
contract AttributionRegistry is IAttributionRegistry {
    SoulboundReceiptPool public immutable pool;
    IV5Factory public immutable factory;

    address public admin;
    /// @notice Off-chain attester for Step 4 "strategy in line with backtest."
    ///         Multisig in Phase 3. Becomes DAO governor in Phase 4. The
    ///         check itself can be auto-computed on-chain in a later rev
    ///         (compare realized APY ± tolerance to backtest APY).
    address public strategistAttester;

    // ===== DAO-tunable thresholds =====
    /// @notice Minimum LP deposit to qualify for an SBT mint at cycle close
    ///         (in deposit-token units — USDC = 6 decimals).
    uint256 public minLpDeposit;

    /// @notice Per-unit-deposit SBT mint multiplier. SBT amount =
    ///         `deposit × lpWeightPerDeposit / 1e6`. Units chosen so the
    ///         default of 1e18 (= 1 SBT per 1 USDC of deposit, at USDC 6
    ///         decimals) is round.
    uint256 public lpWeightPerDeposit;

    uint256 public minTvlForCurator;
    uint256 public minUniqueLps;
    uint256 public curatorBaseSbt;

    uint256 public strategistBaseSbt;
    /// @notice Cap on the multiplier for strategist mints. A template used
    ///         in 100 vaults shouldn't 100x the strategist's stake — diminish
    ///         beyond `maxStrategistVaultsCounted`.
    uint256 public maxStrategistVaultsCounted;

    // ===== Tracking (de-dup) =====
    /// @notice (vault, cycleId, user) → already attributed for this close
    mapping(address => mapping(uint256 => mapping(address => bool))) public lpAttributedInCycle;
    /// @notice (templateId, vault) → strategist already paid for this pairing
    mapping(bytes32 => mapping(address => bool)) public strategistAttested;

    // ===== Events =====
    event LpAttributed(address indexed vault, address indexed user, uint256 indexed cycleId, uint256 deposit, uint256 sbtAmount);
    event CuratorAttributed(address indexed vault, address indexed curator, uint256 tvl, uint256 uniqueLps, uint256 sbtAmount);
    event StrategistAttested(bytes32 indexed templateId, address indexed vault, address indexed author, uint256 sbtAmount);
    event AdminChanged(address indexed prev, address indexed next);
    event StrategistAttesterChanged(address indexed prev, address indexed next);
    event ParamsChanged(string key, uint256 value);

    // ===== Errors =====
    error AR__OnlyAdmin();
    error AR__OnlyStrategistAttester();
    error AR__NotFactoryVault();
    error AR__StrategistAlreadyAttested();
    error AR__TemplateMismatch();
    error AR__NoAuthor();
    error AR__ZeroAddress();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert AR__OnlyAdmin();
        _;
    }

    modifier onlyStrategistAttester() {
        if (msg.sender != strategistAttester) revert AR__OnlyStrategistAttester();
        _;
    }

    modifier onlyFactoryVault() {
        if (!factory.isVault(msg.sender)) revert AR__NotFactoryVault();
        _;
    }

    constructor(
        address _pool,
        address _factory,
        address _admin,
        address _strategistAttester
    ) {
        if (_pool == address(0) || _factory == address(0) || _admin == address(0) || _strategistAttester == address(0))
            revert AR__ZeroAddress();
        pool = SoulboundReceiptPool(_pool);
        factory = IV5Factory(_factory);
        admin = _admin;
        strategistAttester = _strategistAttester;

        // Sensible defaults — DAO will tune. Comments cite the rationale.
        minLpDeposit = 100 * 1e6;            // 100 USDC — dust floor
        lpWeightPerDeposit = 1e18;            // 1 SBT per 1 USDC of deposit (at USDC 6dec → 1e18 = 1 SBT/USDC)
        minTvlForCurator = 10_000 * 1e6;      // 10k USDC — boss's number
        minUniqueLps = 10;                    // boss's number
        curatorBaseSbt = 1000 * 1e18;         // 1000 SBT one-time
        strategistBaseSbt = 2000 * 1e18;      // 2000 SBT base
        maxStrategistVaultsCounted = 5;       // cap
    }

    // ================================================================
    // Hooks called by V5 vault
    // ================================================================

    /// @inheritdoc IAttributionRegistry
    function onCycleClose(uint256 cycleId) external onlyFactoryVault {
        address vault = msg.sender;
        address[] memory lps = IV5Vault(vault).depositors();
        uint256 n = lps.length;
        uint256 floor = minLpDeposit;
        uint256 weight = lpWeightPerDeposit;

        for (uint256 i = 0; i < n; i++) {
            address u = lps[i];
            if (lpAttributedInCycle[vault][cycleId][u]) continue;
            uint256 deposit = IV5Vault(vault).getUserDeposit(u);
            if (deposit < floor) continue;

            lpAttributedInCycle[vault][cycleId][u] = true;
            // SBT amount = deposit × weight / 1e6 (USDC scale).
            uint256 sbtAmount = (deposit * weight) / 1e6;
            pool.mintReceipt(u, sbtAmount);
            emit LpAttributed(vault, u, cycleId, deposit, sbtAmount);
        }
    }

    /// @inheritdoc IAttributionRegistry
    function onCuratorGateHit() external onlyFactoryVault {
        address vault = msg.sender;
        Data.VaultInfo memory info = factory.vaultInfo(vault);
        // Read tvl + lps independently from the vault for the event log + as a
        // sanity check against vault state at call time.
        uint256 tvl = IV5Vault(vault).totalAssets();

        pool.mintReceipt(info.creator, curatorBaseSbt);
        emit CuratorAttributed(vault, info.creator, tvl, minUniqueLps, curatorBaseSbt);
    }

    /// @notice Multisig (or DAO) attests that strategy `templateId` deployed
    ///         in `vault` performed in line with its backtest. Mints SBT to
    ///         the template author proportional to `min(vaultsUsingTemplate,
    ///         maxStrategistVaultsCounted)`.
    /// @dev    Counting "how many vaults use this template" requires factory
    ///         enumeration. For a v1 draft we accept a `vaultsUsingTemplate`
    ///         argument passed in by the attester (off-chain count). The
    ///         attester is trusted to provide truthful values; misbehavior
    ///         is governance-correctable. A later rev can enforce this
    ///         on-chain by adding a per-template vault counter to the factory.
    function attestStrategistPerformance(
        bytes32 templateId,
        address vault,
        uint256 vaultsUsingTemplate
    ) external onlyStrategistAttester {
        if (!factory.isVault(vault)) revert AR__NotFactoryVault();
        if (strategistAttested[templateId][vault]) revert AR__StrategistAlreadyAttested();

        Data.VaultInfo memory info = factory.vaultInfo(vault);
        if (info.templateId != templateId) revert AR__TemplateMismatch();

        address author = factory.templateAuthor(templateId);
        if (author == address(0)) revert AR__NoAuthor();

        strategistAttested[templateId][vault] = true;

        uint256 capped = vaultsUsingTemplate > maxStrategistVaultsCounted
            ? maxStrategistVaultsCounted
            : vaultsUsingTemplate;
        if (capped == 0) capped = 1; // attestation implies ≥1
        uint256 sbtAmount = strategistBaseSbt * capped;

        pool.mintReceipt(author, sbtAmount);
        emit StrategistAttested(templateId, vault, author, sbtAmount);
    }

    // ================================================================
    // Admin / DAO knobs
    // ================================================================

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert AR__ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function setStrategistAttester(address newAttester) external onlyAdmin {
        if (newAttester == address(0)) revert AR__ZeroAddress();
        emit StrategistAttesterChanged(strategistAttester, newAttester);
        strategistAttester = newAttester;
    }

    function setMinLpDeposit(uint256 v) external onlyAdmin { minLpDeposit = v; emit ParamsChanged("minLpDeposit", v); }
    function setLpWeightPerDeposit(uint256 v) external onlyAdmin { lpWeightPerDeposit = v; emit ParamsChanged("lpWeightPerDeposit", v); }
    function setMinTvlForCurator(uint256 v) external onlyAdmin { minTvlForCurator = v; emit ParamsChanged("minTvlForCurator", v); }
    function setMinUniqueLps(uint256 v) external onlyAdmin { minUniqueLps = v; emit ParamsChanged("minUniqueLps", v); }
    function setCuratorBaseSbt(uint256 v) external onlyAdmin { curatorBaseSbt = v; emit ParamsChanged("curatorBaseSbt", v); }
    function setStrategistBaseSbt(uint256 v) external onlyAdmin { strategistBaseSbt = v; emit ParamsChanged("strategistBaseSbt", v); }
    function setMaxStrategistVaultsCounted(uint256 v) external onlyAdmin { maxStrategistVaultsCounted = v; emit ParamsChanged("maxStrategistVaultsCounted", v); }
}
