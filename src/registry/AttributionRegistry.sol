// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAttributionRegistry} from "../interfaces/IAttributionRegistry.sol";
import {SoulboundReceiptPool} from "../token/SoulboundReceiptPool.sol";
import {Data} from "../libraries/Data.sol";

/// @dev Subset of the (live V4) factory surface the registry reads from. The
///      V4 factory exposes `isVault` and `vaultInfo`; it does NOT track
///      template authorship, so authorship lives in this registry instead
///      (see `templateAuthor` + `setTemplateAuthor`).
interface IDiracFactory {
    function vaultInfo(address vault) external view returns (Data.VaultInfo memory);
    function isVault(address vault) external view returns (bool);
}

/// @title AttributionRegistry
/// @notice Centralized eligibility + minting brain for the Dirac soulbound
///         receipt system. Works with the EXISTING V4 vaults — no V5 vault or
///         new factory required. The multisig (later DAO) attests the facts the
///         chain can't cheaply prove, and the registry verifies what it can:
///
///         | Actor      | Attestation fn               | On-chain checks                         |
///         |------------|------------------------------|------------------------------------------|
///         | LP         | `attestLpsForCycle`          | caller is attester; vault is a factory vault; per-LP deposit ≥ floor; per-(vault,cycle,lp) de-dup |
///         | Curator    | `attestCuratorGate`          | caller is attester; vault is a factory vault; attested tvl/uniqueLps ≥ thresholds; one-time latch per vault |
///         | Strategist | `attestStrategistPerformance`| caller is strategist attester; vault.templateId matches; author is set; per-(template,vault) de-dup |
///
///         The registry holds the only `attributor` role on the pool — nobody
///         mints receipts except through here. This isolates the eligibility
///         logic and makes it independently governable (Phase 4 DAO can tune
///         thresholds + swap the attester without redeploying vaults).
///
///         **Trust model (Phase 3):** the `attester` / `strategistAttester`
///         roles are the Dirac multisig. They push per-cycle LP lists, curator
///         milestone confirmations, and strategist performance attestations.
///         Misbehavior is governance-correctable (admin can `burnReceipt` via
///         the pool, rotate the attester, or re-point a template author). In
///         Phase 4 these roles become the DAO governor and the attestations
///         can be tightened to on-chain enforcement.
///
///         **Strategist authorship is wired manually.** The V4 factory doesn't
///         record who authored a template, so the admin/multisig connects a
///         template to its strategist whenever convenient via
///         `setTemplateAuthor(templateId, author)` — before or after the
///         performance attestation, and re-pointable if needed.
contract AttributionRegistry is IAttributionRegistry {
    SoulboundReceiptPool public immutable pool;
    IDiracFactory public immutable factory;

    address public admin;

    /// @notice Attests factual snapshots: per-cycle LP lists + curator
    ///         milestone confirmations. Multisig in Phase 3, DAO in Phase 4.
    address public attester;

    /// @notice Attests the Step 4 "strategy performed in line with backtest"
    ///         judgment, which can't be computed on-chain in v1. Multisig in
    ///         Phase 3, DAO in Phase 4. Kept separate from `attester` because
    ///         it's a judgment, not a snapshot — but the two may be the same
    ///         address.
    address public strategistAttester;

    // ===== DAO-tunable thresholds =====
    /// @notice Minimum LP deposit to qualify for an SBT mint
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

    // ===== Authorship (set manually by admin) =====
    /// @notice Author credited for each strategy template. Set + re-pointable
    ///         by admin via `setTemplateAuthor`. Zero = no strategist
    ///         attribution possible for that template yet.
    mapping(bytes32 => address) public templateAuthor;

    // ===== Tracking (de-dup) =====
    /// @notice (vault, cycleId, user) → already attributed for this cycle.
    mapping(address => mapping(uint256 => mapping(address => bool))) public lpAttributedInCycle;
    /// @notice vault → curator milestone already paid (one-time latch).
    mapping(address => bool) public curatorAttributed;
    /// @notice (templateId, vault) → strategist already paid for this pairing.
    mapping(bytes32 => mapping(address => bool)) public strategistAttested;

    // ===== Events =====
    event LpAttributed(address indexed vault, address indexed user, uint256 indexed cycleId, uint256 deposit, uint256 sbtAmount);
    event CuratorAttributed(address indexed vault, address indexed curator, uint256 tvl, uint256 uniqueLps, uint256 sbtAmount);
    event StrategistAttested(bytes32 indexed templateId, address indexed vault, address indexed author, uint256 sbtAmount);
    event TemplateAuthorSet(bytes32 indexed templateId, address indexed prev, address indexed next);
    event AdminChanged(address indexed prev, address indexed next);
    event AttesterChanged(address indexed prev, address indexed next);
    event StrategistAttesterChanged(address indexed prev, address indexed next);
    event ParamsChanged(string key, uint256 value);

    // ===== Errors =====
    error AR__OnlyAdmin();
    error AR__OnlyAttester();
    error AR__OnlyStrategistAttester();
    error AR__NotFactoryVault();
    error AR__LengthMismatch();
    error AR__CuratorAlreadyAttributed();
    error AR__CuratorGateNotMet();
    error AR__StrategistAlreadyAttested();
    error AR__TemplateMismatch();
    error AR__NoAuthor();
    error AR__ZeroAddress();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert AR__OnlyAdmin();
        _;
    }

    modifier onlyAttester() {
        if (msg.sender != attester) revert AR__OnlyAttester();
        _;
    }

    modifier onlyStrategistAttester() {
        if (msg.sender != strategistAttester) revert AR__OnlyStrategistAttester();
        _;
    }

    constructor(
        address _pool,
        address _factory,
        address _admin,
        address _attester,
        address _strategistAttester
    ) {
        if (
            _pool == address(0) || _factory == address(0) || _admin == address(0)
                || _attester == address(0) || _strategistAttester == address(0)
        ) revert AR__ZeroAddress();
        pool = SoulboundReceiptPool(_pool);
        factory = IDiracFactory(_factory);
        admin = _admin;
        attester = _attester;
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
    // Attestations (multisig → DAO)
    // ================================================================

    /// @inheritdoc IAttributionRegistry
    function attestLpsForCycle(
        address vault,
        uint256 cycleId,
        address[] calldata lps,
        uint256[] calldata deposits
    ) external onlyAttester {
        if (!factory.isVault(vault)) revert AR__NotFactoryVault();
        if (lps.length != deposits.length) revert AR__LengthMismatch();

        uint256 floor = minLpDeposit;
        uint256 weight = lpWeightPerDeposit;

        for (uint256 i = 0; i < lps.length; i++) {
            address u = lps[i];
            uint256 deposit = deposits[i];
            if (u == address(0)) continue;
            if (deposit < floor) continue;
            if (lpAttributedInCycle[vault][cycleId][u]) continue;

            lpAttributedInCycle[vault][cycleId][u] = true;
            // SBT amount = deposit × weight / 1e6 (USDC scale).
            uint256 sbtAmount = (deposit * weight) / 1e6;
            if (sbtAmount == 0) continue;
            pool.mintReceipt(u, sbtAmount);
            emit LpAttributed(vault, u, cycleId, deposit, sbtAmount);
        }
    }

    /// @inheritdoc IAttributionRegistry
    function attestCuratorGate(
        address vault,
        uint256 tvl,
        uint256 uniqueLps
    ) external onlyAttester {
        if (!factory.isVault(vault)) revert AR__NotFactoryVault();
        if (curatorAttributed[vault]) revert AR__CuratorAlreadyAttributed();
        if (tvl < minTvlForCurator || uniqueLps < minUniqueLps) revert AR__CuratorGateNotMet();

        Data.VaultInfo memory info = factory.vaultInfo(vault);

        curatorAttributed[vault] = true;
        pool.mintReceipt(info.creator, curatorBaseSbt);
        emit CuratorAttributed(vault, info.creator, tvl, uniqueLps, curatorBaseSbt);
    }

    /// @inheritdoc IAttributionRegistry
    function attestStrategistPerformance(
        bytes32 templateId,
        address vault,
        uint256 vaultsUsingTemplate
    ) external onlyStrategistAttester {
        if (!factory.isVault(vault)) revert AR__NotFactoryVault();
        if (strategistAttested[templateId][vault]) revert AR__StrategistAlreadyAttested();

        Data.VaultInfo memory info = factory.vaultInfo(vault);
        if (info.templateId != templateId) revert AR__TemplateMismatch();

        address author = templateAuthor[templateId];
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

    /// @notice Manually connect a strategy template to its strategist. Callable
    ///         any time (before or after performance attestation) and
    ///         re-pointable. Zero address disables strategist attribution for
    ///         the template.
    function setTemplateAuthor(bytes32 templateId, address author) external onlyAdmin {
        emit TemplateAuthorSet(templateId, templateAuthor[templateId], author);
        templateAuthor[templateId] = author;
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert AR__ZeroAddress();
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function setAttester(address newAttester) external onlyAdmin {
        if (newAttester == address(0)) revert AR__ZeroAddress();
        emit AttesterChanged(attester, newAttester);
        attester = newAttester;
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
